#
#           Atlas Package Cloner
#        (c) Copyright 2021 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Simple tool to automate frequent workflows: Can "clone"
## a Nimble dependency and its dependencies recursively.

import std / [parseopt, files, dirs, strutils, os, osproc, tables, sets, json, jsonutils, uri, paths]
import basic / [versions, context, osutils, packageinfos,
                configutils, nimblechecksums, reporters,
                nimbleparser, gitops, pkgurls, nimblecontext]
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
  use <url|pkgname>     clone a package and all of its dependencies and make
                        it importable for the current project
  update <url|pkgname>  update a package and all of its dependencies
  install               use the nimble file to setup the project's dependencies
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

proc writeHelp(code = 2) =
  stdout.write(Usage)
  stdout.flushFile()
  quit(code)

proc writeVersion() =
  stdout.write("version: " & AtlasVersion & "\n")
  stdout.flushFile()
  quit(0)

proc tag(tag: string) =
  gitTag(workspace(), tag)
  pushTag(workspace(), tag)

proc tag(field: Natural) =
  let oldErrors = atlasErrors()
  let newTag = incrementLastTag(workspace(), field)
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
      setupNimEnv workspace(), v.string, Keep in context().flags

  if NoExec notin context().flags:
    g.runBuildSteps()

proc installDependencies(nc: var NimbleContext; nimbleFile: Path) =
  # 1. find .nimble file in CWD
  # 2. install deps from .nimble
  var (dir, pkgname, _) = splitFile(nimbleFile.absolutePath)
  if dir == Path "":
    dir = Path(".").absolutePath
  info pkgname, "installing dependencies"
  trace pkgname, "using nimble file at " & $nimbleFile
  let graph = dir.loadWorkspace(nc, AllReleases, onClone=DoClone)
  let paths = graph.activateGraph()
  let cfgPath = CfgPath workspace()
  patchNimCfg(paths, cfgPath)
  afterGraphActions graph

proc updateDir(dir, filter: string) =
  ## update the package's VCS
  for kind, file in walkDir(dir):
    debug (workspace() / Path("updating")), "checking directory: " & $kind & " file: " & file.absolutePath
    if kind == pcDir and isGitDir(file):
      trace file, "updating directory"
      gitops.updateDir(file.Path, filter)

proc detectWorkspace(customWorkspace = Path ""): bool =
  ## find workspace by checking `currentDir` and its parents.
  if customWorkspace.string.len() > 0:
    workspace() = customWorkspace
  elif GlobalWorkspace in context().flags:
    workspace() = Path(getHomeDir() / ".atlas")
    warn "atlas", "using global workspace:", $workspace()
  else:
    var cwd = paths.getCurrentDir().absolutePath

    while cwd.string.len() > 0:
      if cwd.isWorkspace():
        break
      cwd = cwd.parentDir()
    workspace() = cwd
  
  if workspace().len() > 0:
    result = workspace().fileExists
    if result:
      workspace() = workspace().absolutePath

proc autoWorkspace(currentDir: Path): bool =
  var cwd = currentDir
  while cwd.len > 0:
    if dirExists(cwd / Path ".git"):
      break
    cwd = cwd.parentDir()
  workspace() = cwd
  notice "atlas:workspace", "Detected workspace directory:", $workspace()

  if workspace().len() > 0:
    result = workspace().dirExists()

proc createWorkspace() =
  createDir(depsDir())
  if not fileExists(getWorkspaceConfig()):
    writeDefaultConfigFile()
    info workspace(), "created atlas.workspace"
  if workspace() != context().depsDir and context().depsDir != Path "":
    if not dirExists(absoluteDepsDir(workspace(), context().depsDir)):
      info context().depsDir, "creating deps directory"
    createDir absoluteDepsDir(workspace(), context().depsDir)

proc listOutdated(dir: Path) =
  var updateable = 0
  for k, f in walkDir(dir, relative=true):
    if k in {pcDir, pcLinkToDir} and isGitDir(dir / f):
      withDir $(dir / f):
        if gitops.isOutdated(dir / f):
          inc updateable

  if updateable == 0:
    info workspace(), "all packages are up to date"

proc listOutdated() =
  if context().depsDir.string.len > 0 and context().depsDir != workspace():
    listOutdated context().depsDir
  listOutdated workspace()

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

proc parseAtlasOptions(params: seq[string], action: var string, args: var seq[string]) =
  var autoinit = false
  var explicitProjectOverride = false
  var explicitDepsDirOverride = false
  if existsEnv("NO_COLOR") or not isatty(stdout) or (getEnv("TERM") == "dumb"):
    setAtlasNoColors(true)
  for kind, key, val in getopt(params):
    case kind
    of cmdArgument:
      if action.len == 0:
        action = key.normalize
      else:
        args.add key
    of cmdLongOption, cmdShortOption:
      case normalize(key)
      of "help", "h": writeHelp(0)
      of "version", "v": writeVersion()
      of "keepcommits": context().flags.incl KeepCommits
      of "workspace":
        if val == ".":
          workspace() = paths.getCurrentDir()
          createWorkspace()
        elif val.len > 0:
          workspace() = Path val
          # createDir(val)
          # createWorkspace()
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
      of "ignoreerrors": context().flags.incl IgnoreErrors
      of "showgraph": context().flags.incl ShowGraph
      of "ignoreurls": context().flags.incl IgnoreUrls
      of "keepworkspace": context().flags.incl KeepWorkspace
      of "keep": context().flags.incl Keep
      of "autoenv": context().flags.incl AutoEnv
      of "noexec": context().flags.incl NoExec
      of "list":
        if val.normalize in ["on", ""]:
          context().flags.incl ListVersions
        elif val.normalize == "off":
          context().flags.incl ListVersionsOff
        else:
          writeHelp()
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
      of "resolver":
        case val.normalize
        of "minver": context().defaultAlgo = MinVer
        of "maxver": context().defaultAlgo = MaxVer
        of "semver": context().defaultAlgo = SemVer
        else: writeHelp()
      of "verbosity":
        case val.normalize
        of "normal": setAtlasVerbosity(Info)
        of "info": setAtlasVerbosity(Info)
        of "error": setAtlasVerbosity(Error)
        of "warn": setAtlasVerbosity(Warning)
        of "warning": setAtlasVerbosity(Warning)
        of "trace": setAtlasVerbosity(Trace)
        of "debug": setAtlasVerbosity(Debug)
        else: writeHelp()
      else: writeHelp()
    of cmdEnd: assert false, "cannot happen"

  if workspace().string notin ["", ".", ".."]:
    if not dirExists(workspace()):
      fatal "atlas:workspace", "Workspace directory '" & $workspace() & "' not found."
    info "atlas:workspace", "Using workspace directory:", $workspace()
    readConfig()
  elif action notin ["init", "tag"]:
    if detectWorkspace():
      readConfig()
      info workspace().absolutePath, "is the current workspace"
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

proc mainRun(params: seq[string]) =
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
    if workspace() == workspace() or workspace() == context().depsDir:
      fatal action & " command must be executed in a project, not in the workspace"

  proc findCurrentNimble(): Path =
    for x in walkPattern("*.nimble"):
      return Path x

  parseAtlasOptions(params, action, args)

  if action notin ["init", "tag"]:
    doAssert workspace().string != "" and workspace().dirExists()

  case action
  of "":
    fatal "No action."
  of "init":
    if GlobalWorkspace in context().flags:
      workspace() = Path(getHomeDir() / ".atlas")
      createDir(workspace())
    else:
      workspace() = paths.getCurrentDir()
    createWorkspace()
  of "update":
    discard # TODO: what to do here?
    quit 1
  of "new":
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

    workspace() = paths.getCurrentDir() / Path purl.projectName
    let (status, msg) = gitops.clone(purl.toUri, workspace(), fullClones = true)
    if status != Ok:
      error "atlas", "error cloning project:", dir, "message:", msg
      quit(1)
    
    newProject(args[0])

  of "install":

    var nimbleFiles = findNimbleFile(workspace(), workspace().splitPath().tail.string)

    if nimbleFiles.len() == 0:
      let nimbleFile = workspace() / Path(splitPath($paths.getCurrentDir()).tail & ".nimble")
      error "atlas:install", "expected nimble file in workspace, but none found"
      quit(1)
    elif nimbleFiles.len() > 1:
      error "atlas:install", "Ambiguous Nimble files found: " & $nimbleFiles
      quit(1)

    var nc = createNimbleContext()
    installDependencies(nc, nimbleFiles[0].Path)

  of "use":
    singleArg()

    var nimbleFiles = findNimbleFile(workspace())
    var nc = createNimbleContext()

    if nimbleFiles.len() == 0:
      let nimbleFile = workspace() / Path(splitPath($paths.getCurrentDir()).tail & ".nimble")
      trace "atlas:use", "using nimble file:", $nimbleFile
      writeFile($nimbleFile, "")
      nimbleFiles.add(nimbleFile)
    elif nimbleFiles.len() > 1:
      error "atlas:use", "Ambiguous Nimble files found: " & $nimbleFiles

    info "atlas:use", "modifying nimble file to use package:", args[0], "at:", $nimbleFiles[0]
    patchNimbleFile(nc, nimbleFiles[0], args[0])

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
    if workspace() == workspace() or workspace() == context().depsDir:
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
    if args.len == 1:
      convertAndSaveNimbleLock(Path(args[0]), LockFileName)
    elif args.len == 2:
      convertAndSaveNimbleLock(Path(args[0]), Path(args[1]))
    else:
      fatal "convert command takes one or two arguments"
  of "env":
    singleArg()
    setupNimEnv workspace(), args[0], Keep in context().flags
  of "outdated":
    listOutdated()
  else:
    fatal "Invalid action: " & action

proc main =
  setContext AtlasContext()
  try:
    mainRun(commandLineParams())
  finally:
    atlasWritePendingMessages()
  if atlasErrors() > 0 and IgnoreErrors notin context().flags:
    quit 1

when isMainModule:
  main()
