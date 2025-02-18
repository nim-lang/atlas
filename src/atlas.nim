#
#           Atlas Package Cloner
#        (c) Copyright 2021 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Simple tool to automate frequent workflows: Can "clone"
## a Nimble dependency and its dependencies recursively.

import std / [parseopt, files, dirs, strutils, os, osproc, tables, sets, json, jsonutils, uri]
import basic / [versions, context, osutils, packageinfos,
                configutils, nimblechecksums, reporters,
                nimbleparser, gitops, pkgurls]
import cloner, depgraphs, nimenv, lockfiles, confighandler, pkgcache, pkgsearch

from std/terminal import isatty

when defined(nimAtlasBootstrap):
  import ../dist/sat/src/sat/sat
else:
  import sat/sat

const
  AtlasVersion =
    block:
      var ver = ""
      for line in staticRead("../atlas.nimble").splitLines():
        if line.startsWith("version ="):
          ver = line.split("=")[1].replace("\"", "").replace(" ", "")
      assert ver != ""
      ver & " (sha: " & staticExec("git log -n 1 --format=%H") & ")"

const
  LockFileName = Path "atlas.lock"
  Usage = "atlas - Nim Package Cloner Version " & AtlasVersion & """

  (c) 2021 Andreas Rumpf
Usage:
  atlas [options] [command] [arguments]
Command:
  init                  initializes the current directory as a workspace
    --deps=DIR          use DIR as the directory for dependencies
                        (default: store directly in the workspace)

  use <url|pkgname>     clone a package and all of its dependencies and make
                        it importable for the current project
  clone <url|pkgname>   clone a package and all of its dependencies
  update <url|pkgname>  update a package and all of its dependencies
  install <proj.nimble> use the .nimble file to setup the project's dependencies
  new <project>         init a new project directory
  search <keyA> [keyB ...]
                        search for package that contains the given keywords
  extract <file.nimble> extract the requirements and custom commands from
                        the given Nimble file
  updateProjects [filter]
                        update every project that has a remote
                        URL that matches `filter` if a filter is given
  updateDeps [filter]
                        update every dependency that has a remote
                        URL that matches `filter` if a filter is given
  tag [major|minor|patch]
                        add and push a new tag, input must be one of:
                        ['major'|'minor'|'patch'] or a SemVer tag like ['1.0.3']
                        or a letter ['a'..'z']: a.b.c.d.e.f.g
  pin [atlas.lock]      pin the current checkouts and store them in the lock file
  rep [atlas.lock]      replay the state of the projects according to the lock file
  changed <atlack.lock> list any packages that differ from the lock file
  convert <nimble.lock> [atlas.lock]
                        convert Nimble lockfile into an Atlas one
  outdated              list the packages that are outdated
  build|test|doc|tasks  currently delegates to `nimble build|test|doc`
  task <taskname>       currently delegates to `nimble <taskname>`
  env <nimversion>      setup a Nim virtual environment
    --keep              keep the c_code subdirectory

Options:
  --keepCommits         do not perform any `git checkouts`
  --full                perform full checkouts rather than the default shallow
  --cfgHere             also create/maintain a nim.cfg in the current
                        working directory
  --workspace=DIR       use DIR as workspace
  --project=DIR         use DIR as the current project
  --noexec              do not perform any action that may run arbitrary code
  --autoenv             detect the minimal Nim $version and setup a
                        corresponding Nim virtual environment
  --autoinit            auto initialize a workspace
  --colors=on|off       turn on|off colored output
  --resolver=minver|semver|maxver
                        which resolution algorithm to use, default is semver
  --showGraph           show the dependency graph
  --keepWorkspace       do not update/overwrite `atlas.workspace`
  --list                list all available and installed versions
  --version             show the version
  --ignoreUrls          don't error on mismatching urls
  --verbosity=normal|trace|debug
                        set verbosity level to normal, trace, debug
  --global              use global workspace in ~/.atlas
  --help                show this help
"""

proc writeHelp() =
  stdout.write(Usage)
  stdout.flushFile()
  quit(0)

proc writeVersion() =
  stdout.write("version: " & AtlasVersion & "\n")
  stdout.flushFile()
  quit(0)

proc tag(c: var AtlasContext; tag: string) =
  gitTag(c, c.projectDir, tag)
  pushTag(c, c.projectDir, tag)

proc tag(c: var AtlasContext; field: Natural) =
  let oldErrors = c.errors
  let newTag = incrementLastTag(c, c.projectDir, field)
  if c.errors == oldErrors:
    tag(c, newTag)

proc generateDepGraph(c: var AtlasContext; g: DepGraph) =
  proc repr(w: Dependency): string =
    $(w.pkg.url / w.commit)

  var dotGraph = ""
  for n in allNodes(g):
    dotGraph.addf("\"$1\" [label=\"$2\"];\n", [n.repr, if n.active: "" else: "unused"])
  for n in allNodes(g):
    for child in directDependencies(g, c, n):
      dotGraph.addf("\"$1\" -> \"$2\";\n", [n.repr, child.repr])
  let dotFile = c.currentDir / "deps.dot".Path
  writeFile($dotFile, "digraph deps {\n$1}\n" % dotGraph)
  let graphvizDotPath = findExe("dot")
  if graphvizDotPath.len == 0:
    #echo("gendepend: Graphviz's tool dot is required, " &
    #  "see https://graphviz.org/download for downloading")
    discard
  else:
    discard execShellCmd("dot -Tpng -odeps.png " & quoteShell($dotFile))

proc afterGraphActions(c: var AtlasContext; g: DepGraph) =
  if c.errors == 0 and KeepWorkspace notin c.flags:
    writeConfig c, toJson(g)

  if ShowGraph in c.flags:
    generateDepGraph c, g
  if c.errors == 0 and AutoEnv in c.flags:
    let v = g.bestNimVersion
    if v != Version"":
      setupNimEnv c, c.workspace, v.string, Keep in c.flags

proc getRequiredCommit*(c: var AtlasContext; w: Dependency): string =
  if isShortCommitHash(w.commit): shortToCommit(c, w.ondisk, w.commit)
  else: w.commit

proc traverseLoop(c: var AtlasContext; nc: var NimbleContext; g: var DepGraph): seq[CfgPath] =
  result = @[]
  expand(c, g, nc, TraversalMode.AllReleases)
  let f = toFormular(c, g, c.defaultAlgo)
  solve(c, g, f)
  for w in allActiveNodes(g):
    result.add CfgPath(toDestDir(g, w) / getCfgPath(g, w).Path)

proc traverse(c: var AtlasContext; nc: var NimbleContext; start: string): seq[CfgPath] =
  # returns the list of paths for the nim.cfg file.
  let u = c.createUrl(start, c.overrides)
  var g = c.createGraph(u)

  #if $pkg.url == "":
  #  error c, pkg, "cannot resolve package name"
  #  return
  #c.projectDir = c.depsDir / u.projectName
  for n in allNodes(g):
    c.projectDir = n.ondisk
    break

  result = traverseLoop(c, nc, g)
  afterGraphActions c, g


proc installDependencies(c: var AtlasContext; nc: var NimbleContext; nimbleFile: Path) =
  # 1. find .nimble file in CWD
  # 2. install deps from .nimble
  var (dir, pkgname, _) = splitFile(nimbleFile)
  if dir == Path "":
    dir = Path "."
  info c, pkgname, "installing dependencies for " & $pkgname & ".nimble"
  trace c, pkgname, "using nimble file at " & $nimbleFile
  var g = createGraph(c, c.createUrlSkipPatterns($dir))
  let paths = traverseLoop(c, nc, g)
  let cfgPath = if CfgHere in c.flags: CfgPath c.currentDir else: findCfgDir(c)
  patchNimCfg(c, paths, cfgPath)
  afterGraphActions c, g

proc updateDir(c: var AtlasContext; dir, filter: string) =
  ## update the package's VCS
  for kind, file in walkDir(dir):
    debug c, (c.workspace / Path("updating")), "checking directory: " & $kind & " file: " & file.absolutePath
    if kind == pcDir and isGitDir(file):
      trace c, file, "updating directory"
      gitops.updateDir(c, file.Path, filter)

proc detectWorkspace(currentDir: Path): Path =
  ## find workspace by checking `currentDir` and its parents.
  result = currentDir
  while result.string.len > 0:
    if fileExists(result / AtlasWorkspace):
      return result
    result = result.parentDir()
  when false:
    # That is a bad idea and I know no other tool (git etc.) that
    # does such shenanigans.
    # alternatively check for "sub-directory" workspace
    for kind, file in walkDir(currentDir):
      if kind == pcDir and fileExists(file / AtlasWorkspace):
        return file

proc autoWorkspace(currentDir: Path): Path =
  result = currentDir
  while result.len > 0 and dirExists(result / Path ".git"):
    result = result.parentDir()

proc createWorkspaceIn(c: var AtlasContext) =
  if not fileExists(c.workspace / AtlasWorkspace):
    writeDefaultConfigFile c
    info c, c.workspace, "created atlas.workspace"
  if c.workspace != c.depsDir and c.depsDir != Path "":
    createDir absoluteDepsDir(c.workspace, c.depsDir)
    info c, c.depsDir, "created deps dir"

proc listOutdated(c: var AtlasContext; dir: Path) =
  var updateable = 0
  for k, f in walkDir(dir, relative=true):
    if k in {pcDir, pcLinkToDir} and isGitDir(dir / f):
      withDir c, $(dir / f):
        if gitops.isOutdated(c, dir / f):
          inc updateable

  if updateable == 0:
    info c, c.workspace, "all packages are up to date"

proc listOutdated(c: var AtlasContext) =
  if c.depsDir.string.len > 0 and c.depsDir != c.workspace:
    listOutdated c, c.depsDir
  listOutdated c, c.workspace

proc newProject(c: var AtlasContext; projectName: string) =
  ## Tries to create a new project directory in the current dir
  ## with a single bare `projectname.nim` file inside.
  ## `projectName` is validated.

  proc isValidProjectName(n: openArray[char]): bool =
    ## Validates `n` as a project name:
    ## Valid Nim identifier with addition of dashes (`-`) being allowed,
    ## but replaced with underscores (`_`) for the `.nim` file name.
    ## .. Note: Doesn't check if `n` is a valid file/directory name.
    if n.len > 0 and n[0] in IdentStartChars:
      for i, c in n:
        case c
        of Letters + Digits: discard "fine"
        of '-', '_':
          if i > 0 and n[i-1] in {'-', '_'}: return false
          else: discard "fine"
        else: return false
      return true
    else: return false

  let name = projectName.strip()
  if not (isValidFilename(name) and isValidProjectName(name)):
    error c, name, "'" & name & "' is not a vaild project name!"
    quit(1)
  if dirExists(name):
    error c, name, "Directory '" & name & "' already exists!"
    quit(1)
  try:
    createDir(name)
  except OSError as e:
    error c, name, "Failed to create directory '$#': $#" % [name, e.msg]
    quit(1)
  info c, name, "created project dir"
  withDir(c, name):
    let fname = name.replace('-', '_') & ".nim"
    try:
      # A header doc comment with the project's name
      fname.writeFile("## $#\n" % name)
    except IOError as e:
      error c, name, "Failed writing to file '$#': $#" % [fname, e.msg]
      quit(1)

proc main(c: var AtlasContext) =
  var action = ""
  var args: seq[string] = @[]
  template singleArg() =
    if args.len != 1:
      fatal c, action & " command takes a single package name"

  template optSingleArg(default: string) =
    if args.len == 0:
      args.add default
    elif args.len != 1:
      fatal c, action & " command takes a single package name"

  template noArgs() =
    if args.len != 0:
      fatal c, action & " command takes no arguments"

  template projectCmd() =
    if c.projectDir == c.workspace or c.projectDir == c.depsDir:
      fatal c, action & " command must be executed in a project, not in the workspace"

  proc findCurrentNimble(): Path =
    for x in walkPattern("*.nimble"):
      return Path x

  var autoinit = false
  var explicitProjectOverride = false
  var explicitDepsDirOverride = false
  if existsEnv("NO_COLOR") or not isatty(stdout) or (getEnv("TERM") == "dumb"):
    c.noColors = true
  for kind, key, val in getopt():
    case kind
    of cmdArgument:
      if action.len == 0:
        action = key.normalize
      else:
        args.add key
    of cmdLongOption, cmdShortOption:
      case normalize(key)
      of "help", "h": writeHelp()
      of "version", "v": writeVersion()
      of "keepcommits": c.flags.incl KeepCommits
      of "workspace":
        if val == ".":
          c.workspace = paths.getCurrentDir()
          createWorkspaceIn c
        elif val.len > 0:
          c.workspace = Path val
          if not explicitProjectOverride:
            c.currentDir = Path val
          createDir(val)
          createWorkspaceIn c
        else:
          writeHelp()
      of "project":
        explicitProjectOverride = true
        if isAbsolute(val):
          c.currentDir = Path val
        else:
          c.currentDir = paths.getCurrentDir() / Path val
      of "deps":
        if val.len > 0:
          c.origDepsDir = Path val
          explicitDepsDirOverride = true
        else:
          writeHelp()
      of "cfghere": c.flags.incl CfgHere
      of "full": c.flags.incl FullClones
      of "autoinit": autoinit = true
      of "showgraph": c.flags.incl ShowGraph
      of "ignoreurls": c.flags.incl IgnoreUrls
      of "keepworkspace": c.flags.incl KeepWorkspace
      of "keep": c.flags.incl Keep
      of "autoenv": c.flags.incl AutoEnv
      of "noexec": c.flags.incl NoExec
      of "list": c.flags.incl ListVersions
      of "global", "g": c.flags.incl GlobalWorkspace
      of "colors":
        case val.normalize
        of "off": c.noColors = true
        of "on": c.noColors = false
        else: writeHelp()
      of "proxy":
        c.proxy = val.parseUri()
      of "dumbproxy":
        c.dumbProxy = true
      of "verbosity":
        case val.normalize
        of "normal": c.verbosity = 0
        of "trace": c.verbosity = 1
        of "debug": c.verbosity = 2
        else: writeHelp()
      of "assertonerror": c.assertOnError = true
      of "resolver":
        try:
          c.defaultAlgo = parseEnum[ResolutionAlgorithm](val)
        except ValueError:
          quit "unknown resolver: " & val
      else: writeHelp()
    of cmdEnd: assert false, "cannot happen"

  if c.workspace.len > 0:
    if not dirExists(c.workspace): fatal c, "Workspace directory '" & $c.workspace & "' not found."
    readConfig c
  elif action notin ["init", "tag"]:
    if GlobalWorkspace in c.flags:
      c.workspace = detectWorkspace(Path(getHomeDir() / ".atlas"))
      warn c, c.workspace, "using global workspace"
    else:
      c.workspace = detectWorkspace(c.currentDir)
    if c.workspace.len > 0:
      readConfig c
      info c, c.workspace.absolutePath, "is the current workspace"
    elif autoinit:
      c.workspace = autoWorkspace(c.currentDir)
      createWorkspaceIn c
    elif action notin ["search", "list"]:
      fatal c, "No workspace found. Run `atlas init` if you want this current directory to be your workspace."

  if not explicitDepsDirOverride and action notin ["init", "tag"] and c.origDepsDir.len == 0:
    c.origDepsDir = Path ""
  if action != "tag":
    createDir(c.depsDir)

  case action
  of "":
    fatal c, "No action."
  of "init":
    if GlobalWorkspace in c.flags:
      c.workspace = Path(getHomeDir() / ".atlas")
      createDir(c.workspace)
    else:
      c.workspace = paths.getCurrentDir()
    createWorkspaceIn c
  of "clone", "update":
    singleArg()
    var nc = createNimbleContext(c, c.depsDir)
    let deps = traverse(c, nc, args[0])
    let cfgPath = if CfgHere in c.flags: CfgPath c.currentDir
                  else: findCfgDir(c)
    patchNimCfg c, deps, cfgPath
  of "use":
    singleArg()
    let currDirName = c.workspace.splitFile().name.string
    var (nimbleFile, nimbleFiles) = findNimbleFile(c.workspace, currDirName)
    var nc = createNimbleContext(c, c.depsDir)

    echo "USE:foundNimble: ", $nimbleFile, " cnt: ", nimbleFiles, " abs: ", $nimbleFile.absolutePath
    if nimbleFiles == 0:
      nimbleFile = c.workspace / Path(extractProjectName($c.workspace) & ".nimble")
      echo "USE:nimbleFile:set: ", $nimbleFile, " abs: ", $nimbleFile.absolutePath
      writeFile($nimbleFile, "")
    c.patchNimbleFile(nc, c, c.overrides, nimbleFile, args[0])

    if c.errors > 0:
      discard "don't continue for 'cannot resolve'"
    elif nimbleFiles == 1:
      c.installDependencies(nc, nimbleFile.Path)
    elif nimbleFiles > 1:
      error c, args[0], "ambiguous .nimble file"
    else:
      error c, args[0], "cannot find .nimble file"

  of "pin":
    optSingleArg($LockFileName)
    if c.projectDir == c.workspace or c.projectDir == c.depsDir:
      pinWorkspace c, Path(args[0])
    else:
      let exportNimble = Path(args[0]) == NimbleLockFileName
      pinProject c, Path(args[0]), exportNimble
  of "rep", "replay", "reproduce":
    optSingleArg($LockFileName)
    replay(c, Path(args[0]))
  of "changed":
    optSingleArg($LockFileName)
    listChanged(c, Path(args[0]))
  of "convert":
    if args.len < 1:
      fatal c, "convert command takes a nimble lockfile argument"
    let lfn = if args.len == 1: LockFileName
              else: Path(args[1])
    convertAndSaveNimbleLock c, Path(args[0]), lfn
  of "install", "setup":
    # projectCmd()
    if args.len > 1:
      fatal c, "install command takes a single argument"
    var nimbleFile = Path ""
    if args.len == 1:
      nimbleFile = Path args[0]
    else:
      nimbleFile = findCurrentNimble()
    if nimbleFile.len == 0:
      fatal c, "could not find a .nimble file"
    else:
      var nc = createNimbleContext(c, c.depsDir)
      installDependencies(c, nc, nimbleFile)
  of "refresh":
    noArgs()
    updatePackages(c, c.depsDir)
  of "search", "list":
    if c.workspace.len != 0:
      updatePackages(c, c.depsDir)
      let pkgInfos = getPackageInfos(c.depsDir)
      search c, pkgInfos, args
    else:
      search c, @[], args
  of "updateprojects":
    updateDir(c, c.workspace, if args.len == 0: "" else: args[0])
  of "updatedeps":
    updateDir(c, c.depsDir, if args.len == 0: "" else: args[0])
  of "extract":
    singleArg()
    if fileExists(args[0]):
      echo toJson(extractRequiresInfo(Path args[0]))
    else:
      fatal c, "File does not exist: " & args[0]
  of "tag":
    projectCmd()
    if args.len == 0:
      tag(c, ord(patch))
    elif args[0].len == 1 and args[0][0] in {'a'..'z'}:
      let field = ord(args[0][0]) - ord('a')
      tag(c, field)
    elif args[0].len == 1 and args[0][0] in {'A'..'Z'}:
      let field = ord(args[0][0]) - ord('A')
      tag(c, field)
    elif '.' in args[0]:
      tag(c, args[0])
    else:
      var field: SemVerField
      try: field = parseEnum[SemVerField](args[0])
      except: fatal c, "tag command takes one of 'patch' 'minor' 'major', a SemVer tag, or a letter from 'a' to 'z'"
      tag(c, ord(field))
  of "build", "test", "doc", "tasks":
    projectCmd()
    nimbleExec(action, args)
  of "task":
    projectCmd()
    nimbleExec("", args)
  of "env":
    singleArg()
    setupNimEnv c, c.workspace, args[0], Keep in c.flags
  of "outdated":
    listOutdated(c)
  of "new":
    singleArg()
    newProject(c, args[0])
  else:
    fatal c, "Invalid action: " & action

proc main =
  var c = AtlasContext(projectDir: paths.getCurrentDir(),
                       currentDir: paths.getCurrentDir(),
                       workspace: Path "")
  try:
    main(c)
  finally:
    writePendingMessages(c)
  if c.errors > 0:
    quit 1

when isMainModule:
  main()
