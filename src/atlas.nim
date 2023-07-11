#
#           Atlas Package Cloner
#        (c) Copyright 2021 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Simple tool to automate frequent workflows: Can "clone"
## a Nimble dependency and its dependencies recursively.

import std / [parseopt, strutils, os, osproc, tables, sets, json, jsonutils,
  hashes, options]
import context, runners, osutils, packagesjson, gitops, nimenv, lockfiles,
  traversal, confighandler, nameresolver, patchcfg, resolver

export osutils, context

const
  AtlasVersion = "0.6.2"
  LockFileName = "atlas.lock"
  NimbleLockFileName = "nimble.lock"
  Usage = "atlas - Nim Package Cloner Version " & AtlasVersion & """

  (c) 2021 Andreas Rumpf
Usage:
  atlas [options] [command] [arguments]
Command:
  init                  initializes the current directory as a workspace
    --deps=DIR          use DIR as the directory for dependencies
                        (default: store directly in the workspace)

  use url|pkgname       clone a package and all of its dependencies and make
                        it importable for the current project
  clone url|pkgname     clone a package and all of its dependencies
  update url|pkgname    update a package and all of its dependencies
  install proj.nimble   use the .nimble file to setup the project's dependencies
  search keyw keywB...  search for package that contains the given keywords
  extract file.nimble   extract the requirements and custom commands from
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
  pin [atlas.lock]      pin the current checkouts and store them in the lock
  rep [atlas.lock]      replay the state of the projects according to the lock
  convert <nimble.lock> [atlas.lock]
                        convert Nimble lockfile into an Atlas one
  outdated              list the packages that are outdated
  build|test|doc|tasks  currently delegates to `nimble build|test|doc`
  task <taskname>       currently delegates to `nimble <taskname>`
  env <nimversion>      setup a Nim virtual environment
    --keep              keep the c_code subdirectory

Options:
  --keepCommits         do not perform any `git checkouts`
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
                        which resolution algorithm to use, default is minver
  --showGraph           show the dependency graph
  --list                list all available and installed versions
  --version             show the version
  --help                show this help
"""

proc writeHelp() =
  stdout.write(Usage)
  stdout.flushFile()
  quit(0)

proc writeVersion() =
  stdout.write(AtlasVersion & "\n")
  stdout.flushFile()
  quit(0)


include testdata

proc tag(c: var AtlasContext; tag: string) =
  gitTag(c, tag)
  pushTag(c, tag)

proc tag(c: var AtlasContext; field: Natural) =
  let oldErrors = c.errors
  let newTag = incrementLastTag(c, field)
  if c.errors == oldErrors:
    tag(c, newTag)

when false:
  proc generateDepGraph(c: var AtlasContext; g: DepGraph) =
    proc repr(w: Dependency): string =
      $(w.url / w.commit)

    var dotGraph = ""
    for i in 0 ..< g.nodes.len:
      dotGraph.addf("\"$1\" [label=\"$2\"];\n", [g.nodes[i].repr, if g.nodes[i].selected >= 0: "" else: "unused"])
    for i in 0 ..< g.nodes.len:
      for p in items g.nodes[i].parents:
        if p >= 0:
          dotGraph.addf("\"$1\" -> \"$2\";\n", [g.nodes[p].repr, g.nodes[i].repr])
    let dotFile = c.currentDir / "deps.dot"
    writeFile(dotFile, "digraph deps {\n$1}\n" % dotGraph)
    let graphvizDotPath = findExe("dot")
    if graphvizDotPath.len == 0:
      #echo("gendepend: Graphviz's tool dot is required, " &
      #  "see https://graphviz.org/download for downloading")
      discard
    else:
      discard execShellCmd("dot -Tpng -odeps.png " & quoteShell(dotFile))

proc findSrcDir(c: var AtlasContext): string =
  for nimbleFile in walkPattern(c.currentDir / "*.nimble"):
    let nimbleInfo = extractRequiresInfo(c, nimbleFile)
    return c.currentDir / nimbleInfo.srcDir
  return c.currentDir

proc activePaths(c: var AtlasContext; g: DepGraph): seq[CfgPath] =
  result = @[]
  for i in 1 ..< g.nodes.len:
    let s = g.nodes[i].sindex
    if s >= 0:
      let x = CfgPath(g.nodes[i].dir / g.nodes[i].subs[s].srcDir)
      result.add x

proc findBestNimVersion(g: DepGraph): Version =
  result = Version""
  for i in 0 ..< g.nodes.len:
    let s = g.nodes[i].sindex
    if s >= 0:
      let v = extractGeQuery(g.nodes[i].subs[s].nimVersion)
      if v != Version"" and v > result: result = v

proc afterGraphActions(c: var AtlasContext; g: DepGraph) =
  let paths = activePaths(c, g)
  patchNimCfg(c, paths, if CfgHere in c.flags: c.currentDir else: findSrcDir(c))

  when false:
    if ShowGraph in c.flags:
      generateDepGraph c, g
  if AutoEnv in c.flags:
    let bestNimVersion = findBestNimVersion(g).string
    if bestNimVersion != "":
      setupNimEnv c, bestNimVersion

const
  FileProtocol = "file"

proc copyFromDisk(c: var AtlasContext; w: DepNode; destDir: string): (CloneStatus, string) =
  var u = w.url.getFilePath()
  if u.startsWith("./"): u = c.workspace / u.substr(2)
  if dirExists(u):
    copyDir(u, destDir)
    result = (Ok, "")
  else:
    result = (NotFound, u)

proc traverseLoop(c: var AtlasContext; g: var DepGraph; startIsDep: bool) =
  expandGraph c, g, 0
  var i = 1
  while i < g.nodes.len:
    template w(): untyped = g.nodes[i]
    let destDir = toDestDir(w.name)

    let cloneTarget = selectDir(c.workspace / destDir, c.depsDir / destDir)
    if not dirExists(cloneTarget):
      let targetDir = if i != 0 or startIsDep: c.depsDir else: c.workspace
      assert targetDir != ""
      g.nodes[i].dir = targetDir / destDir
      withDir c, targetDir:
        let (status, err) =
          if w.url.scheme == FileProtocol:
            copyFromDisk(c, w, destDir)
          else:
            cloneUrl(c, w.url, destDir, false)
        g.nodes[i].status = status
        case status
        of NotFound:
          discard "nothing to do"
        of OtherError:
          error c, w.name, err
        else:
          withDir c, destDir:
            expandGraph c, g, i
    else:
      g.nodes[i].dir = cloneTarget
      withDir c, cloneTarget:
        expandGraph c, g, i
    inc i

  resolve c, g

proc traverse(c: var AtlasContext; start: string; startIsDep: bool) =
  # returns the list of paths for the nim.cfg file.
  let url = resolveUrl(c, start)
  var g = createGraph(c, start, url)

  if $url == "":
    error c, toName(start), "cannot resolve package name"
    return

  c.projectDir = c.workspace / toDestDir(g.nodes[0].name)

  traverseLoop(c, g, startIsDep)
  afterGraphActions c, g


proc installDependencies(c: var AtlasContext; nimbleFile: string; startIsDep: bool) =
  # 1. find .nimble file in CWD
  # 2. install deps from .nimble
  let (_, pkgname, _) = splitFile(nimbleFile)

  var g = createGraph(c, pkgname, getUrl "")
  traverseLoop(c, g, startIsDep)
  afterGraphActions c, g

proc updateDir(c: var AtlasContext; dir, filter: string) =
  ## update the package's VCS
  for kind, file in walkDir(dir):
    if kind == pcDir and hasGitDir(file):
      gitops.updateDir(c, file, filter)

proc patchNimbleFile(c: var AtlasContext; dep: string): string =
  let thisProject = c.currentDir.lastPathComponent
  let oldErrors = c.errors
  let url = resolveUrl(c, dep)
  result = ""
  if oldErrors != c.errors:
    warn c, toName(dep), "cannot resolve package name"
  else:
    for x in walkFiles(c.currentDir / "*.nimble"):
      if result.len == 0:
        result = x
      else:
        # ambiguous .nimble file
        warn c, toName(dep), "cannot determine `.nimble` file; there are multiple to choose from"
        return ""
    # see if we have this requirement already listed. If so, do nothing:
    var found = false
    if result.len > 0:
      let nimbleInfo = extractRequiresInfo(c, result)
      for r in nimbleInfo.requires:
        var tokens: seq[string] = @[]
        for token in tokenizeRequires(r):
          tokens.add token
        if tokens.len > 0:
          let oldErrors = c.errors
          let urlB = resolveUrl(c, tokens[0])
          if oldErrors != c.errors:
            warn c, toName(tokens[0]), "cannot resolve package name; found in: " & result
          if url == urlB:
            found = true
            break

    if not found:
      let line = "requires \"$1\"\n" % dep.escape("", "")
      if result.len > 0:
        let oldContent = readFile(result)
        writeFile result, oldContent & "\n" & line
        info(c, toName(thisProject), "updated: " & result.readableFile)
      else:
        result = c.currentDir / thisProject & ".nimble"
        writeFile result, line
        info(c, toName(thisProject), "created: " & result.readableFile)
    else:
      info(c, toName(thisProject), "up to date: " & result.readableFile)

proc detectWorkspace(currentDir: string): string =
  result = currentDir
  while result.len > 0:
    if fileExists(result / AtlasWorkspace):
      return result
    result = result.parentDir()

proc autoWorkspace(currentDir: string): string =
  result = currentDir
  while result.len > 0 and dirExists(result / ".git"):
    result = result.parentDir()

proc createWorkspaceIn(workspace, depsDir: string) =
  if not fileExists(workspace / AtlasWorkspace):
    writeFile workspace / AtlasWorkspace, "deps=\"$#\"\nresolver=\"MaxVer\"\n" % escape(depsDir, "", "")
  createDir absoluteDepsDir(workspace, depsDir)

proc listOutdated(c: var AtlasContext; dir: string) =
  var updateable = 0
  for k, f in walkDir(dir, relative=true):
    if k in {pcDir, pcLinkToDir} and hasGitDir(dir / f):
      withDir c, dir / f:
        if gitops.isOutdated(c, f):
          inc updateable

  if updateable == 0:
    info c, toName(c.workspace), "all packages are up to date"

proc listOutdated(c: var AtlasContext) =
  if c.depsDir.len > 0 and c.depsDir != c.workspace:
    listOutdated c, c.depsDir
  listOutdated c, c.workspace

proc explore(c: var AtlasContext; nimbleFile: string) =
  echo allDeps(c, nimbleFile)

proc main(c: var AtlasContext) =
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
    if c.projectDir == c.workspace or c.projectDir == c.depsDir:
      fatal action & " command must be executed in a project, not in the workspace"

  var autoinit = false
  var explicitProjectOverride = false
  var explicitDepsDirOverride = false
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
          c.workspace = getCurrentDir()
          createWorkspaceIn c.workspace, c.depsDir
        elif val.len > 0:
          c.workspace = val
          if not explicitProjectOverride:
            c.currentDir = val
          createDir(val)
          createWorkspaceIn c.workspace, c.depsDir
        else:
          writeHelp()
      of "project":
        explicitProjectOverride = true
        if isAbsolute(val):
          c.currentDir = val
        else:
          c.currentDir = getCurrentDir() / val
      of "deps":
        if val.len > 0:
          c.depsDir = val
          explicitDepsDirOverride = true
        else:
          writeHelp()
      of "cfghere": c.flags.incl CfgHere
      of "autoinit": autoinit = true
      of "showgraph": c.flags.incl ShowGraph
      of "keep": c.flags.incl Keep
      of "autoenv": c.flags.incl AutoEnv
      of "noexec": c.flags.incl NoExec
      of "list": c.flags.incl ListVersions
      of "colors":
        case val.normalize
        of "off": c.flags.incl NoColors
        of "on": c.flags.excl NoColors
        else: writeHelp()
      of "resolver":
        try:
          c.defaultAlgo = parseEnum[ResolutionAlgorithm](val)
          c.flags.incl OverideResolver
        except ValueError:
          quit "unknown resolver: " & val
      else: writeHelp()
    of cmdEnd: assert false, "cannot happen"

  if c.workspace.len > 0:
    if not dirExists(c.workspace): fatal "Workspace directory '" & c.workspace & "' not found."
  elif action != "init":
    when MockupRun:
      c.workspace = autoWorkspace(c.currentDir)
    else:
      c.workspace = detectWorkspace(c.currentDir)
      if c.workspace.len > 0:
        readConfig c
        infoNow c, toName(c.workspace.readableFile), "is the current workspace"
      elif autoinit:
        c.workspace = autoWorkspace(c.currentDir)
        createWorkspaceIn c.workspace, c.depsDir
      elif action notin ["search", "list", "tag"]:
        fatal "No workspace found. Run `atlas init` if you want this current directory to be your workspace."

  when MockupRun:
    c.depsDir = c.workspace
  else:
    if not explicitDepsDirOverride and action != "init" and c.depsDir.len() == 0:
      c.depsDir = c.workspace

  case action
  of "":
    fatal "No action."
  of "init":
    c.workspace = getCurrentDir()
    createWorkspaceIn c.workspace, c.depsDir
  of "clone", "update":
    singleArg()
    traverse(c, args[0], startIsDep = false)
    when MockupRun:
      if not c.mockupSuccess:
        fatal "There were problems."
  of "use":
    singleArg()
    let nimbleFile = patchNimbleFile(c, args[0])
    if nimbleFile.len > 0:
      installDependencies(c, nimbleFile, startIsDep = false)
  of "pin":
    optSingleArg(LockFileName)
    if c.projectDir == c.workspace or c.projectDir == c.depsDir:
      pinWorkspace c, args[0]
    else:
      pinProject c, args[0]
  of "rep", "replay", "reproduce":
    optSingleArg(LockFileName)
    replay c, args[0]
  of "convert":
    if args.len < 1:
      fatal "convert command takes a nimble lockfile argument"
    let lfn = if args.len == 1: LockFileName else: args[1]
    convertAndSaveNimbleLock c, args[0], lfn
  of "install":
    projectCmd()
    if args.len > 1:
      fatal "install command takes a single argument"
    var nimbleFile = ""
    if args.len == 1:
      nimbleFile = args[0]
    else:
      for x in walkPattern(c.currentDir / "*.nimble"):
        nimbleFile = x
        break
    if nimbleFile.len == 0:
      fatal "could not find a .nimble file"
    else:
      installDependencies(c, nimbleFile, startIsDep = true)
  of "explore":
    projectCmd()
    if args.len > 1:
      fatal "install command takes a single argument"
    withDir c, c.currentDir:
      var nimbleFile = ""
      if args.len == 1:
        nimbleFile = args[0]
      else:
        for x in walkPattern("*.nimble"):
          nimbleFile = x
          break
      if nimbleFile.len == 0:
        fatal "could not find a .nimble file"
      else:
        explore(c, nimbleFile)
  of "refresh":
    noArgs()
    updatePackages(c)
  of "search", "list":
    if c.workspace.len != 0:
      updatePackages(c)
      search getPackages(c.workspace), args
    else:
      search @[], args
  of "updateprojects":
    updateDir(c, c.workspace, if args.len == 0: "" else: args[0])
  of "updatedeps":
    updateDir(c, c.depsDir, if args.len == 0: "" else: args[0])
  of "extract":
    singleArg()
    if fileExists(args[0]):
      echo toJson(extractRequiresInfo(args[0]))
    else:
      fatal "File does not exist: " & args[0]
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
      except: fatal "tag command takes one of 'patch' 'minor' 'major', a SemVer tag, or a letter from 'a' to 'z'"
      tag(c, ord(field))
  of "build", "test", "doc", "tasks":
    projectCmd()
    nimbleExec(action, args)
  of "task":
    projectCmd()
    nimbleExec("", args)
  of "env":
    singleArg()
    setupNimEnv c, args[0]
  of "outdated":
    listOutdated(c)
  else:
    fatal "Invalid action: " & action

proc main =
  var c = AtlasContext(projectDir: getCurrentDir(), currentDir: getCurrentDir(), workspace: "")
  try:
    main(c)
  finally:
    writePendingMessages(c)
  if c.errors > 0:
    quit 1

when isMainModule:
  main()
