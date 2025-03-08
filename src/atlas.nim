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
import depgraphs, nimenv, lockfiles, confighandler, dependencies, pkgsearch

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
                        or a letter ['a'..'z']: a.b.context().d.e.f.g
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

proc tag(tag: string) =
  gitTag(context().workspace, tag)
  pushTag(context().workspace, tag)

proc tag(field: Natural) =
  let oldErrors = atlasErrors()
  let newTag = incrementLastTag(context().workspace, field)
  if atlasErrors() == oldErrors:
    tag(newTag)

proc generateDepGraph(g: DepGraph) =
  proc repr(pkg: Package): string =
    $(pkg.url.url / $pkg.activeVersion.commit)

  var dotGraph = ""
  for n in allNodes(g):
    dotGraph.addf("\"$1\" [label=\"$2\"];\n", [n.repr, if n.active: "" else: "unused"])
  for n in allNodes(g):
    for child in directDependencies(g, n):
      dotGraph.addf("\"$1\" -> \"$2\";\n", [n.repr, child.repr])
  let dotFile = paths.getCurrentDir() / "deps.dot".Path
  writeFile($dotFile, "digraph deps {\n$1}\n" % dotGraph)
  let graphvizDotPath = findExe("dot")
  if graphvizDotPath.len == 0:
    #echo("gendepend: Graphviz's tool dot is required, " &
    #  "see https://graphviz.org/download for downloading")
    discard
  else:
    discard execShellCmd("dot -Tpng -odeps.png " & quoteShell($dotFile))

proc afterGraphActions(g: DepGraph) =
  if atlasErrors() == 0 and KeepWorkspace notin context().flags:
    writeConfig toJson(g)

  if ShowGraph in context().flags:
    generateDepGraph g

  if atlasErrors() == 0 and AutoEnv in context().flags:
    let v = g.bestNimVersion
    if v != Version"":
      setupNimEnv context().workspace, v.string, Keep in context().flags

  if NoExec notin context().flags:
    g.runBuildSteps()

proc installDependencies(nc: var NimbleContext; nimbleFile: Path) =
  # 1. find .nimble file in CWD
  # 2. install deps from .nimble
  var (dir, pkgname, _) = splitFile(nimbleFile)
  if dir == Path "":
    dir = Path(".").absolutePath
  info pkgname, "installing dependencies for " & $pkgname & ".nimble"
  trace pkgname, "using nimble file at " & $nimbleFile
  let graph = dir.expand(nc, AllReleases, onClone=DoClone)
  let paths = graph.activateGraph()
  let cfgPath = CfgPath context().workspace
  patchNimCfg(paths, cfgPath)
  afterGraphActions graph

proc updateDir(dir, filter: string) =
  ## update the package's VCS
  for kind, file in walkDir(dir):
    debug (context().workspace / Path("updating")), "checking directory: " & $kind & " file: " & file.absolutePath
    if kind == pcDir and isGitDir(file):
      trace file, "updating directory"
      gitops.updateDir(file.Path, filter)

proc detectWorkspace(customWorkspace = Path ""): bool =
  ## find workspace by checking `currentDir` and its parents.
  if customWorkspace.string.len() > 0:
    context().workspace = customWorkspace
  elif GlobalWorkspace in context().flags:
    context().workspace = Path(getHomeDir() / ".atlas")
    warn "atlas", "using global workspace:", $context().workspace
  else:
    var cwd = paths.getCurrentDir().absolutePath

    while cwd.string.len() > 0:
      if fileExists(cwd / getWorkspaceConfig()):
        break
      cwd = cwd.parentDir()
    context().workspace = cwd
  
  if context().workspace.len() > 0:
    result = context().workspace.fileExists

proc autoWorkspace(currentDir: Path): bool =
  var cwd = currentDir
  while cwd.len > 0:
    if dirExists(cwd / Path ".git"):
      break
    cwd = cwd.parentDir()
  context().workspace = cwd

  if context().workspace.len() > 0:
    result = context().workspace.fileExists

proc createWorkspace() =
  if not fileExists(getWorkspaceConfig()):
    writeDefaultConfigFile()
    info context().workspace, "created atlas.workspace"
  if context().workspace != context().depsDir and context().depsDir != Path "":
    createDir absoluteDepsDir(context().workspace, context().depsDir)
    info context().depsDir, "created deps dir"

proc listOutdated(dir: Path) =
  var updateable = 0
  for k, f in walkDir(dir, relative=true):
    if k in {pcDir, pcLinkToDir} and isGitDir(dir / f):
      withDir $(dir / f):
        if gitops.isOutdated(dir / f):
          inc updateable

  if updateable == 0:
    info context().workspace, "all packages are up to date"

proc listOutdated() =
  if context().depsDir.string.len > 0 and context().depsDir != context().workspace:
    listOutdated context().depsDir
  listOutdated context().workspace

proc newProject(projectName: string) =
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
    error name, "'" & name & "' is not a vaild project name!"
    quit(1)
  if dirExists(name):
    error name, "Directory '" & name & "' already exists!"
    quit(1)
  try:
    createDir(name)
  except OSError as e:
    error name, "Failed to create directory '$#': $#" % [name, e.msg]
    quit(1)
  info name, "created project dir"
  withDir(name):
    let fname = name.replace('-', '_') & ".nim"
    try:
      # A header doc comment with the project's name
      fname.writeFile("## $#\n" % name)
    except IOError as e:
      error name, "Failed writing to file '$#': $#" % [fname, e.msg]
      quit(1)

proc parseAtlasOptions(action: var string, args: var seq[string]) =
  var autoinit = false
  var explicitProjectOverride = false
  var explicitDepsDirOverride = false
  if existsEnv("NO_COLOR") or not isatty(stdout) or (getEnv("TERM") == "dumb"):
    setAtlasNoColors(true)
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
      of "keepcommits": context().flags.incl KeepCommits
      of "workspace":
        if val == ".":
          context().workspace = paths.getCurrentDir()
          createWorkspace()
        elif val.len > 0:
          context().workspace = Path val
          createDir(val)
          createWorkspace()
        else:
          writeHelp()
      of "deps":
        if val.len > 0:
          context().depsDir = Path val
          explicitDepsDirOverride = true
        else:
          writeHelp()
      of "cfghere": context().flags.incl CfgHere
      of "full": context().flags.incl FullClones
      of "autoinit": autoinit = true
      of "showgraph": context().flags.incl ShowGraph
      of "ignoreurls": context().flags.incl IgnoreUrls
      of "keepworkspace": context().flags.incl KeepWorkspace
      of "keep": context().flags.incl Keep
      of "autoenv": context().flags.incl AutoEnv
      of "noexec": context().flags.incl NoExec
      of "list": context().flags.incl ListVersions
      of "global", "g": context().flags.incl GlobalWorkspace
      of "colors":
        case val.normalize
        of "off": setAtlasNoColors(true)
        of "on": setAtlasNoColors(false)
        else: writeHelp()
      of "proxy":
        context().proxy = val.parseUri()
      of "dumbproxy":
        context().dumbProxy = true
      of "verbosity":
        case val.normalize
        of "quiet": setAtlasVerbosity(Ignore)
        of "error": setAtlasVerbosity(Error)
        of "warning": setAtlasVerbosity(Warning)
        of "normal": setAtlasVerbosity(Info)
        of "trace": setAtlasVerbosity(Trace)
        of "debug": setAtlasVerbosity(Debug)
        else: writeHelp()
      of "assertonerror": setAtlasAssertOnError(true)
      of "resolver":
        try:
          context().defaultAlgo = parseEnum[ResolutionAlgorithm](val)
        except ValueError:
          quit "unknown resolver: " & val
      else: writeHelp()
    of cmdEnd: assert false, "cannot happen"

  if context().workspace.len > 0:
    if not dirExists(context().workspace):
      fatal "Workspace directory '" & $context().workspace & "' not found."
    readConfig()
  elif action notin ["init", "tag"]:
    if detectWorkspace():
      readConfig()
      info context().workspace.absolutePath, "is the current workspace"
    elif autoinit:
      if autoWorkspace(paths.getCurrentDir()):
        createWorkspace()
      else:
        fatal "No workspace found and unable to auto init workspace. Run `atlas init` if you want this current directory to be your workspace."
    elif action notin ["search", "list"]:
      fatal "No workspace found. Run `atlas init` if you want this current directory to be your workspace."

  if not explicitDepsDirOverride and action notin ["init", "tag"] and context().depsDir.len == 0:
    context().depsDir = Path "deps"
  if action != "tag":
    createDir(context().depsDir)

proc mainRun() =
  var action = ""
  var args: seq[string] = @[]
  template singleArg() =
    if args.len != 1:
      fatal action & " command takes a single package name"

  template optSingleArg(default: string) =
    if args.len == 0:
      args.add default
    elif args.len != 1:
      fatal action & " command takes a single package name"

  template noArgs() =
    if args.len != 0:
      fatal action & " command takes no arguments"

  template projectCmd() =
    if context().workspace == context().workspace or context().workspace == context().depsDir:
      fatal action & " command must be executed in a project, not in the workspace"

  proc findCurrentNimble(): Path =
    for x in walkPattern("*.nimble"):
      return Path x

  parseAtlasOptions(action, args)

  case action
  of "":
    fatal "No action."
  of "init":
    if GlobalWorkspace in context().flags:
      context().workspace = Path(getHomeDir() / ".atlas")
      createDir(context().workspace)
    else:
      context().workspace = paths.getCurrentDir()
    createWorkspace()
  of "update":
    discard # TODO: what to do here?
    quit 1
  of "clone":
    singleArg()
    var nc = createNimbleContext()
    let dir = args[0]
    if dir.dirExists():
      error "atlas", "'" & dir & "' already exists! Cowardly refusing to overwrite"
      quit(1)

    var purl: PkgUrl
    try:
      purl = nc.createUrl(args[0])
    except CatchableError:
      error "atlas", "'" & dir & "' is not a vaild project name!"
      quit(1)

    context().workspace = paths.getCurrentDir() / Path purl.projectName
    let (status, msg) = gitops.clone(purl.toUri, context().workspace, fullClones = true)
    if status != Ok:
      error "atlas", "error cloning project:", dir, "message:", msg
      quit(1)

  of "use":
    singleArg()

    var nimbleFiles = findNimbleFile(context().workspace)
    var nc = createNimbleContext()

    if nimbleFiles.len() == 0:
      let nimbleFile = context().workspace / Path(extractProjectName($context().workspace) & ".nimble")
      trace "use", "USE:nimbleFile:set: " & $nimbleFile
      writeFile($nimbleFile, "")
      nimbleFiles.add(nimbleFile)
    elif nimbleFiles.len() > 1:
      error "use", "Ambiguous Nimble files found: " & $nimbleFiles

    patchNimbleFile(nc, context().overrides, nimbleFiles[0], args[0])

    if atlasErrors() > 0:
      discard "don't continue for 'cannot resolve'"
    elif nimbleFiles.len() == 1:
      installDependencies(nc, nimbleFiles[0].Path)
    elif nimbleFiles.len() > 1:
      error args[0], "ambiguous .nimble file"
    else:
      error args[0], "cannot find .nimble file"

  of "pin":
    optSingleArg($LockFileName)
    if context().workspace == context().workspace or context().workspace == context().depsDir:
      pinWorkspace Path(args[0])
    else:
      let exportNimble = Path(args[0]) == NimbleLockFileName
      pinProject Path(args[0]), exportNimble
  of "rep", "replay", "reproduce":
    optSingleArg($LockFileName)
    replay(Path(args[0]))
  of "changed":
    optSingleArg($LockFileName)
    listChanged(Path(args[0]))
  of "convert":
    if args.len < 1:
      fatal "convert command takes a nimble lockfile argument"
    let lfn = if args.len == 1: LockFileName
              else: Path(args[1])
    convertAndSaveNimbleLock Path(args[0]), lfn
  of "install", "setup":
    # projectCmd()
    if args.len > 1:
      fatal "install command takes a single argument"
    var nimbleFile = Path ""
    if args.len == 1:
      nimbleFile = Path args[0]
    else:
      nimbleFile = findCurrentNimble()
    if nimbleFile.len == 0:
      fatal "could not find a .nimble file"
    else:
      var nc = createNimbleContext()
      installDependencies(nc, nimbleFile)
  of "refresh":
    noArgs()
    updatePackages(context().depsDir)
  of "search", "list":
    if context().workspace.len != 0:
      updatePackages(context().depsDir)
      let pkgInfos = getPackageInfos(context().depsDir)
      search pkgInfos, args
    else:
      search @[], args
  of "updateprojects":
    updateDir(context().workspace, if args.len == 0: "" else: args[0])
  of "updatedeps":
    updateDir(context().depsDir, if args.len == 0: "" else: args[0])
  of "extract":
    singleArg()
    if fileExists(args[0]):
      echo toJson(extractRequiresInfo(Path args[0]))
    else:
      fatal "File does not exist: " & args[0]
  of "tag":
    projectCmd()
    if args.len == 0:
      tag(ord(patch))
    elif args[0].len == 1 and args[0][0] in {'a'..'z'}:
      let field = ord(args[0][0]) - ord('a')
      tag(field)
    elif args[0].len == 1 and args[0][0] in {'A'..'Z'}:
      let field = ord(args[0][0]) - ord('A')
      tag(field)
    elif '.' in args[0]:
      tag(args[0])
    else:
      var field: SemVerField
      try: field = parseEnum[SemVerField](args[0])
      except: fatal "tag command takes one of 'patch' 'minor' 'major', a SemVer tag, or a letter from 'a' to 'z'"
      tag(ord(field))
  of "build", "test", "doc", "tasks":
    projectCmd()
    nimbleExec(action, args)
  of "task":
    projectCmd()
    nimbleExec("", args)
  of "env":
    singleArg()
    setupNimEnv context().workspace, args[0], Keep in context().flags
  of "outdated":
    listOutdated()
  of "new":
    singleArg()
    newProject(args[0])
  else:
    fatal "Invalid action: " & action

proc main =
  setContext AtlasContext()
  try:
    mainRun()
  finally:
    atlasWritePendingMessages()
  if atlasErrors() > 0:
    quit 1

when isMainModule:
  main()
