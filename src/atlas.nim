#
#           Atlas Package Cloner
#        (c) Copyright 2021 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Simple tool to automate frequent workflows: Can "clone"
## a Nimble dependency and its dependencies recursively.

import std / [parseopt, files, dirs, strutils, os, options, osproc, tables, sets, json, uri, paths, algorithm, sequtils]
import basic / [versions, context, osutils, configutils, reporters,
                nimbleparser, gitops, pkgurls, nimblecontext,
                compiledpatterns, packageinfos, sattypes, atlasversion,
                gitprogresspool]
import depgraphs, nimenv, lockfiles, confighandler, dependencies, pkgsearch


from std/terminal import isatty

const
  LockFileName = Path "atlas.lock"
  Usage = "atlas - Nim Package Cloner Version " & AtlasVersion & """

  (c) 2021 Andreas Rumpf
Usage:
  atlas [options] [command] [arguments]
Commands:
  init                  initializes the current project as an Atlas project
  use <url|pkgname>     add package and its dependencies to the project
                        and patch the project's Nimble file
  install               use the nimble file to setup the project's dependencies
  update [filter]       update every dependency that matches the filter
                        whether by name or URL. All dependencies are updated
                        if no filter is given.
  search <keyA> [keyB ...]
                        search for package that contains the given keywords
  link <path>           link an existing project into the current project
                        to share its dependencies
  unlink <package>      remove a linked package and its linked dependencies
  tag [major|minor|patch|<semver>|a..z]
                        add and push a new tag, input must be one of:
                        ['major'|'minor'|'patch'] or a SemVer tag like ['1.0.3']
                        or a letter ['a'..'z']: a.b.c.d.e.f.g
  pin [atlas.lock]      pin the current checkouts and store them in the lock file
  rep [atlas.lock]      replay the state of projects according to the lock file
  replay [atlas.lock]   alias of `rep`
  reproduce [atlas.lock]
                        alias of `rep`
  changed [atlas.lock]  list any packages that differ from the lock file
  outdated              list the packages that are outdated
  deps                  list the currently selected dependencies
  env <nimversion>      setup a Nim virtual environment

Options:
  --help, -h            show this help
  --version, -v         show the version
  --project=path, -p    use the project at the given path
  --deps=path           override the deps directory
  --confdir=path        use the atlas.config at the given path
  --feature=<feature>   enables the given feature, pass multiple for multiple features
                        for project specific use: `<project>.<feature>`
                        (note always be passed when you want to use features)
  --features=<list>     enables one or more features separated by commas or spaces
  --allFeatures         enables every declared feature
  --keepFeatures, -k    reuse feature defines from the current nim.cfg
  --resolver=minver|semver|maxver
                        which resolution algorithm to use, default is semver
  --list[=on|off]       list all available and installed versions
  --keepCommits         do not perform any `git checkouts`
  --keepworkspace       keep generated workspace artifacts
  --ignoreerrors        continue even when errors were recorded
  --dumpformular        dump SAT formula for debugging
  --dumpgraphs          dump dependency graphs for debugging
  --showGraph           show the dependency graph
  --tree                show `atlas deps` output as a dependency tree
  --update, -u          for `install`, update dependency repos before solving
  --only                for `unlink`, leave child dependencies linked
  --noexec              do not perform any action that may run arbitrary code
  --autoenv             detect the minimal Nim $version and setup a
                        corresponding Nim virtual environment
  --noautoinit          do not auto initialize an atlas project
  --no-lazy-deps        disable lazy dependency loading and use eager loading
                        for all transitive dependencies during SAT solving
  --parallel[=count], -t[=count]
                        clone dependency repositories in parallel, default count is 3
  --proxy=url           use the given proxy URL for all git operations
  --dumbProxy           use a dumb proxy without smart git protocol
  --packagesRepo        use the nim-lang/packages git repo (legacy behavior)
  --forceGitToHttps     force git:// URLs to https://
  --ignoreUrls          don't error on mismatching urls
  --colors=on|off       turn on|off colored output
  --verbosity=normal|info|warn|warning|error|trace|debug
                        set verbosity level to normal/info/warn/warning/error/trace/debug
                        the default level is warning
"""

proc writeHelp(code = 2) =
  stdout.write(Usage)
  stdout.flushFile()
  quit(code)

proc writeVersion() =
  stdout.write("version: " & AtlasVersion & "\n")
  stdout.flushFile()
  quit(0)

proc parseParallelCloneWorkers(value: string): int =
  if value.len == 0:
    return DefaultParallelCloneWorkers
  try:
    result = parseInt(value)
  except ValueError:
    writeHelp()
  if result < 1:
    writeHelp()

proc addRequestedFeature(rawFeature: string) =
  # Package-scoped features use `<pkg>.<feature>` and are normalized to
  # `feature.<pkg>.<feature>` internally for nim.cfg defines.
  let raw = rawFeature.strip().toLowerAscii()
  if raw.len == 0:
    writeHelp()
  elif raw.startsWith("feature."):
    context().features.incl raw
  elif '.' in raw:
    context().features.incl "feature." & raw
  else:
    # Root-package feature shorthand.
    context().features.incl raw

proc addRequestedFeatures(rawFeatures: string) =
  let normalized = rawFeatures.multiReplace((",", " "), ("\n", " "), ("\t", " "))
  for raw in normalized.splitWhitespace():
    addRequestedFeature(raw)
  if normalized.strip().len == 0:
    writeHelp()

proc tag(tag: string) =
  if gitops.getCanonicalUrl(project()).len == 0:
    error "atlas:tag", "Missing canonical remote 'origin'"
    quit(1)
  if tag.len == 1 and tag[0] in {'a'..'z'}:
    # Handle single letter tags
    gitTag(project(), tag)
    pushTag(project(), tag = tag)
  elif tag in ["major", "minor", "patch"]:
    # Handle semantic version increments
    let field = case tag
      of "major": 0
      of "minor": 1
      of "patch": 2
      else: 0  # Should never happen due to above check
    
    let oldErrors = atlasErrors()
    let newTag = incrementLastTag(project(), field)
    if atlasErrors() == oldErrors:
      gitTag(project(), newTag)
      pushTag(project(), tag = newTag)
  elif tag.count('.') >= 2:  # Looks like a semver tag
    # Direct version tag like '1.0.3'
    gitTag(project(), tag)
    pushTag(project(), tag = tag)
  else:
    error "atlas:tag", "Invalid tag format. Must be one of: ['major'|'minor'|'patch'] or a SemVer tag like ['1.0.3'] or a letter ['a'..'z']"
    quit(1)

proc findProjectNimbleFile(writeNimbleFile: bool = false): Path =
  ## find the project's nimble file
  ##
  ## this will search for the project's nimble file in the project's directory
  ## and write a new one if it doesn't exist
  var nimbleFiles = findNimbleFile(project(), "")

  if nimbleFiles.len() == 0 and writeNimbleFile:
    let nimbleFile = project() / Path(splitPath($paths.getCurrentDir()).tail & ".nimble")
    debug "atlas:link", "writing nimble file:", $nimbleFile
    writeFile($nimbleFile, "")
    result = nimbleFile
  elif nimbleFiles.len() == 0:
    fatal "No Nimble file found in project"
    quit(1)
  elif nimbleFiles.len() > 1:
    fatal "Ambiguous Nimble files found: " & $nimbleFiles
    quit(1)
  else:
    result = nimbleFiles[0]

proc createWorkspace() =
  ## create the workspace directory and the config file
  ##
  ## this will create the workspace directory and the config file if they
  ## don't exist
  createDir(depsDir())
  if not fileExists(getProjectConfig()):
    writeDefaultConfigFile()
    info project(), "created atlas.config at:", $getProjectConfig()
  if depsDir() != Path "":
    if not dirExists(absoluteDepsDir(project(), depsDir())):
      info depsDir(), "creating deps directory"
    createDir absoluteDepsDir(project(), depsDir())

proc generateDepGraph(g: DepGraph) =
  proc repr(pkg: Package): string =
    let suffix =
      if pkg.activeVersion.isNil:
        "unresolved"
      else:
        $pkg.activeVersion.commit
    $(pkg.url.url / suffix)

  var dotGraph = ""
  for n in allNodes(g):
    dotGraph.addf("\"$1\" [label=\"$2\"];\n", [n.repr, if n.active: "" else: "unused"])
  for n in allNodes(g):
    if not n.activeVersion.isNil and n.activeNimbleRelease != nil:
      for child in directDependencies(g, n):
        dotGraph.addf("\"$1\" -> \"$2\";\n", [n.repr, child.repr])
  let dotFile = paths.getCurrentDir() / "deps.dot".Path
  writeFile($dotFile, "digraph deps {\n$1}\n" % dotGraph)
  let graphvizDotPath = findExe("dot")
  if graphvizDotPath.len == 0:
    warn("atlas:showgraph", "Graphviz's tool dot is required, " &
         "see https://graphviz.org/download for downloading")
  else:
    discard execShellCmd("dot -Tpng -odeps.png " & quoteShell($dotFile))

proc formatActivatedDep(pkg: ActivatedPackage): string =
  let commit =
    if pkg.commit.isEmpty():
      "-"
    else:
      $pkg.commit
  result = pkg.url.projectName & " " & pkg.version & " " & commit

proc formatSelectedDeps*(cache: ActivationCache): string =
  var lines: seq[string]
  for pkg in cache.packages:
    if pkg.isRoot:
      continue
    lines.add(formatActivatedDep(pkg))
  lines.sort()
  result = lines.join("\n")

proc findActivatedPackage(cache: ActivationCache; depUrl: PkgUrl): int =
  for i, pkg in cache.packages:
    if $pkg.url == $depUrl or
       pkg.url.projectName == depUrl.projectName or
       pkg.url.shortName == depUrl.shortName:
      return i
  return -1

proc activeDirectDependencies(cache: ActivationCache; pkg: ActivatedPackage): seq[ActivatedPackage] =
  let nimbleFiles = findNimbleFile(pkg.ondisk, "")
  if nimbleFiles.len != 1:
    return @[]

  var nc = createNimbleContext()
  for cachedPkg in cache.packages:
    if cachedPkg.url.projectName.len > 0:
      nc.put(cachedPkg.url.projectName, toPkgUriRaw(cachedPkg.url.url))
    if cachedPkg.url.shortName.len > 0 and cachedPkg.url.shortName != cachedPkg.url.projectName:
      nc.put(cachedPkg.url.shortName, toPkgUriRaw(cachedPkg.url.url))
  let rel = nc.parseNimbleFile(nimbleFiles[0])
  var seen = initHashSet[int]()
  for (depUrl, _) in rel.requirements:
    let idx = cache.findActivatedPackage(depUrl)
    if idx >= 0 and not cache.packages[idx].isRoot and not seen.containsOrIncl(idx):
      result.add(cache.packages[idx])
  for feature in pkg.features:
    let declaredFeature = rel.features.findFeature(feature)
    if declaredFeature.len > 0:
      for (depUrl, _) in rel.features[declaredFeature]:
        let idx = cache.findActivatedPackage(depUrl)
        if idx >= 0 and not cache.packages[idx].isRoot and not seen.containsOrIncl(idx):
          result.add(cache.packages[idx])
  result.sort(proc (a, b: ActivatedPackage): int = cmp(a.url.projectName, b.url.projectName))

proc formatSelectedDepsTree*(cache: ActivationCache): string =
  proc render(pkg: ActivatedPackage; prefix: string; isLast: bool; showBranch: bool;
              seen: var HashSet[string]; lines: var seq[string]) =
    let branch =
      if not showBranch:
        ""
      elif isLast:
        "\\-- "
      else:
        "|-- "
    lines.add(prefix & branch & formatActivatedDep(pkg))
    if seen.containsOrIncl($pkg.url):
      return
    let children = activeDirectDependencies(cache, pkg)
    let nextPrefix =
      if not showBranch:
        ""
      elif isLast:
        prefix & "    "
      else:
        prefix & "|   "
    for i, child in children:
      render(child, nextPrefix, i == children.high, true, seen, lines)

  var rootIdx = -1
  for i, pkg in cache.packages:
    if pkg.isRoot:
      rootIdx = i
      break
  if rootIdx < 0:
    return ""
  var lines: seq[string]
  var seen = initHashSet[string]()
  render(cache.packages[rootIdx], "", true, false, seen, lines)
  result = lines.join("\n")

proc showSelectedDeps() =
  let nimbleFile = findProjectNimbleFile().absolutePath
  let activationPath = activationCacheFile()
  if not fileExists($activationPath):
    fatal "No activation cache found. Run `atlas install` first."
    return
  let cache = loadActivationCache(nimbleFile)

  if TreeView in context().flags:
    stdout.write(formatSelectedDepsTree(cache) & "\n")
  else:
    stdout.write(formatSelectedDeps(cache) & "\n")
  stdout.flushFile()

type
  PendingUpdateJob = object
    repoName: string
    repoPath: Path

proc updateProgressJob(repoName: string; repoPath: Path): GitProgressJob =
  var args = @["fetch", "--all", "--tags", "--progress"]
  if ShallowClones in context().flags:
    args.insert("--depth=1", 1)
  GitProgressJob(
    label: repoName,
    command: "git",
    args: args,
    workingDir: $repoPath
  )

proc afterGraphActions(g: DepGraph) =
  ## perform any actions after the dependency graph has been generated
  ##
  ## this will write the config file, generate the dependency graph, and
  ## setup the Nim environment if the user has requested it
  if atlasErrors() == 0:
    writeConfig()

  if DumpGraphs in context().flags:
    writeDepGraph(g, debug = not g.root.active or KeepWorkspace in context().flags)
  else:
    removeDepGraphCache()

  if atlasErrors() == 0:
    writeActivationCache(g)

  if ShowGraph in context().flags:
    generateDepGraph g

  if atlasErrors() == 0 and AutoEnv in context().flags:
    let v = g.bestNimVersion
    if v != Version"":
      setupNimEnv v.string, KeepNimEnv in context().flags

  if NoExec notin context().flags:
    g.runBuildSteps()

proc installDependencies(nc: var NimbleContext; nimbleFile: Path) =
  ## install the dependencies for the project
  ##
  ## this will find the project's nimble file, install the dependencies, and
  ## patch the Nim configuration file
  var (dir, pkgname, _) = splitFile(nimbleFile.absolutePath)
  if dir == Path "":
    dir = Path(".").absolutePath
  info pkgname, "installing dependencies"
  let graph = dir.loadWorkspace(nc, AllReleases, onClone=DoClone, doSolve=true)
  let (paths, features) = graph.activateGraph()
  let cfgPath = CfgPath project()
  patchNimCfg(paths, cfgPath, features)
  afterGraphActions graph

proc linkPackage(linkDir, linkedNimble: Path) =
  ## link a project into the current project
  ##
  ## this will add the linked project's dependencies to the current project's
  ## nimble file and create links to the dependent nimble files in the current
  ## project's deps directory

  # Do this before altering the current project's Nimble file. Older Atlas
  # versions did not create this cache, so explain how to upgrade the linked
  # project instead of failing while trying to parse a missing file.
  let linkedActivationCache = activationCacheFileFor(linkedNimble)
  if not fileExists($linkedActivationCache):
    fatal "The linked project has no current activation cache at " &
      $linkedActivationCache & ". Run `atlas install` in " & $linkDir &
      " with this version of Atlas, then retry `atlas link`."
  let lcache = loadActivationCache(linkedNimble)

  let linkUri = toPkgUriRaw(parseUri("link://" & $linkedNimble))
  discard context().nameOverrides.addPattern(linkUri.projectName, $linkUri.url)
  info "atlas:link", "link uri:", $linkUri

  var nc = createNimbleContext()

  let nimbleFile = findProjectNimbleFile(writeNimbleFile = true)
  if hasNimbleRequirement(nimbleFile, linkUri):
    info "atlas:link", "nimble file already depends on package:", linkUri.projectName, "at:", $nimbleFile
  else:
    info "atlas:link", "modifying nimble file to use package:", linkUri.projectName, "at:", $nimbleFile
    patchNimbleFile(nc, nimbleFile, linkUri.projectName)

  writeConfig()
  info "atlas:link", "current project dir:", $project()

  # Load linked project's config to get its deps dir
  info "atlas:link", "linked project dir:", $linkDir

  # Create links for all nimble files and links in the linked project
  for pkg in lcache.packages:
    let nimbleFiles = pkg.ondisk.findNimbleFile()
    if nimbleFiles.len() != 1:
      error $pkg.url.projectName, "error finding nimble file; got:", $nimbleFiles
      continue
    let nimble = nimbleFiles[0]
    let linkPkgUrl =
      if pkg.isRoot and pkg.url.url.scheme == "atlas":
        linkUri
      else:
        pkg.url
    createNimbleLink(linkPkgUrl, nimble, CfgPath(pkg.srcDir))

  installDependencies(nc, nimbleFile)

proc activatedPackageMatches(pkg: ActivatedPackage; name: string): bool =
  let needle = name.toLowerAscii()
  result = needle == ($pkg.url).toLowerAscii() or
    needle == pkg.url.shortName().toLowerAscii() or
    needle == pkg.url.projectName().toLowerAscii() or
    needle == pkg.url.fullName().toLowerAscii()

proc findActivatedPackage(cache: ActivationCache; name: string): int =
  for i, pkg in cache.packages:
    if not pkg.isRoot and pkg.activatedPackageMatches(name):
      return i
  return -1

proc linkedPackageClosure(cache: ActivationCache; packageIndex: int;
                          only: bool): HashSet[int] =
  var closure: HashSet[int]

  proc collect(pkg: ActivatedPackage) =
    let idx = cache.findActivatedPackage($pkg.url)
    if idx < 0 or closure.containsOrIncl(idx):
      return
    if not only:
      for child in cache.activeDirectDependencies(cache.packages[idx]):
        collect(child)

  collect(cache.packages[packageIndex])
  if not only:
    var retained: HashSet[int]

    proc retain(pkg: ActivatedPackage) =
      let idx = cache.findActivatedPackage($pkg.url)
      if idx < 0 or idx == packageIndex or retained.containsOrIncl(idx):
        return
      for child in cache.activeDirectDependencies(cache.packages[idx]):
        retain(child)

    for pkg in cache.packages:
      if pkg.isRoot:
        for child in cache.activeDirectDependencies(pkg):
          retain(child)
        break
    for idx in retained:
      closure.excl(idx)
  result = closure

proc activationCachePaths(cache: ActivationCache): tuple[
    paths: seq[CfgPath], features: seq[string]] =
  for pkg in cache.packages:
    if pkg.isRoot:
      for feature in pkg.features:
        result.features.addUniqueFeature "feature." & pkg.url.projectName & "." & feature
    else:
      result.paths.add CfgPath(pkg.ondisk / pkg.srcDir)
      for feature in pkg.features:
        result.features.addUniqueFeature "feature." & pkg.url.shortName & "." & feature
  result.paths.sort(proc (a, b: CfgPath): int = cmp(a.string, b.string))

proc linkFileFor(pkg: ActivatedPackage): Path =
  result = pkg.url.toLinkPath()
  if result.len == 0:
    result = depsDir() / Path(pkg.url.projectName() & ".nimble-link")

proc unlinkPackage(name: string; only: bool = false) =
  ## Removes a linked package and optionally its cached child dependencies.
  let nimbleFile = findProjectNimbleFile().absolutePath
  let cache = loadActivationCache(nimbleFile)
  let packageIndex = cache.findActivatedPackage(name)
  if packageIndex < 0:
    fatal "No active linked package named: " & name

  let removal = cache.linkedPackageClosure(packageIndex, only)
  let target = cache.packages[packageIndex]
  if not target.url.isNimbleLink():
    fatal "Package is not linked: " & name
  if removeNimbleRequirement(nimbleFile, target.url):
    info "atlas:unlink", "removed dependency from:", $nimbleFile
  else:
    warn "atlas:unlink", "no top-level requirement found for:", target.url.projectName

  var updated: ActivationCache
  for i, pkg in cache.packages:
    if i in removal:
      let linkFile = pkg.linkFileFor()
      if fileExists($linkFile):
        removeFile($linkFile)
      info "atlas:unlink", "unlinked:", pkg.url.projectName
    else:
      updated.packages.add(pkg)

  discard context().nameOverrides.removePattern(target.url.projectName)
  writeConfig()
  removeDepGraphCache()
  writeActivationCache(updated)
  let (paths, features) = updated.activationCachePaths()
  patchNimCfg(paths, CfgPath project(), features)

proc detectProject(): bool =
  ## find project by checking `currentDir` and its parents.
  if GlobalWorkspace in context().flags:
    project(Path(getHomeDir() / ".atlas"))
    warn "atlas", "using global project:", $project()
  elif ManualProjectArg in context().flags:
    warn "atlas", "using manual project:", $project()
  else:
    var cwd = paths.getCurrentDir().absolutePath
    debug "atlas", "finding project from current dir:", $cwd

    while cwd.string.len() > 0:
      trace "atlas", "checking project config:", $(cwd.getProjectConfig()), "at:", $cwd
      if cwd.getProjectConfig().fileExists():
        break
      cwd = cwd.parentDir()
    project(cwd)

  debug "atlas", "using project:", $project()
  if project().len() > 0:
    debug "atlas", "project found:", $project()
    result = getProjectConfig().fileExists()
    if result:
      project(project().absolutePath)

proc autoProject*(currentDir: Path): bool =
  ## auto detect the project directory
  ##
  ## this will walk the current directory and all of its parents to find a
  ## directory that contains either a git repository or a Nimble file
  var cwd = currentDir
  while cwd.len > 0:
    if dirExists(cwd / Path ".git"):
      break
    if findNimbleFile(cwd, "").len > 0:
      break
    cwd = cwd.parentDir()
  project(cwd)
  notice "atlas:project", "Detected project directory:", $project()

  if project().len() > 0:
    result = project().dirExists()

proc listOutdated() =
  let dir = project()
  var nc = createNimbleContext()
  let graph = dir.loadWorkspace(nc, CurrentCommit, onClone=DoNothing, doSolve=false)

  var updateable = 0
  for pkg in allNodes(graph):
    if pkg.isRoot:
      continue
    let res = gitops.hasNewTags(pkg.ondisk)
    if res.isNone:
      warn pkg.url.projectName, "no remote version tags found"
      inc updateable
    else:
      let (outdated, cnt) = res.get()
      if outdated:
        warn pkg.url.projectName, "is outdated; " & $cnt & " new tags available"
        inc updateable
      else:
        notice pkg.url.projectName, "is up to date"

  if updateable == 0:
    info project(), "all packages are up to date"

proc update(filter: string) =
  ## update the dependencies
  ##
  ## this will check every git repository in `depsDir` and update it if needed
  info "atlas:update", "updating packages database"
  updatePackages()

  let depsRoot = depsDir()
  if depsRoot == Path"" or not dirExists(depsRoot):
    warn "atlas:update", "deps directory not found:", $depsRoot
    return

  var updateJobs: seq[PendingUpdateJob]
  for repoPath in findProjects(depsRoot):
    let repoName = $repoPath.splitPath().tail
    info "atlas:update", "checking package:", repoName

    let url = gitops.getRemoteUrl(repoPath)
    if url.len == 0:
      warn repoName, "no remote URL found; skipping..."
      continue
    if filter.len > 0 and filter notin url and filter notin repoName:
      info repoName, "filter not matched; skipping..."
      continue

    updateJobs.add PendingUpdateJob(repoName: repoName, repoPath: repoPath)

  if ParallelClones in context().flags:
    if updateJobs.len > 0:
      notice "atlas:update", "updating packages in parallel:", $updateJobs.len
    let updateResults = runGitProgressJobs(
      updateJobs.mapIt(updateProgressJob(it.repoName, it.repoPath)),
      title = "atlas:update",
      workerCount = context().parallelCloneWorkers
    )

    var updatedAny = false
    for i, job in updateJobs:
      let updateResult = updateResults[i]
      if updateResult.exitCode == 0:
        notice job.repoName, "updated remote refs"
        updatedAny = true
      else:
        var details = updateResult.output.strip()
        if details.len == 0:
          details = "git fetch failed"
        error job.repoName, details
    if updatedAny:
      notice project(), "dependency refs updated, run `atlas install` to update"
    return

  var updatedAny = false
  for job in updateJobs:
    info job.repoName, "updating remote refs"
    gitops.updateRepo(job.repoPath)
    updatedAny = true
  
  if updatedAny:
    notice project(), "dependency refs updated, run `atlas install` to update"

proc parseAtlasOptions(params: seq[string], action: var string, args: var seq[string]) =
  var autoinit = true
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
      of "keepfeatures", "k": context().flags.incl KeepFeatures
      of "allfeatures": context().flags.incl AllFeatures
      of "project", "p":
        context().flags.incl(ManualProjectArg)
        if val == ".":
          project(paths.getCurrentDir())
          createWorkspace()
        elif val.len > 0:
          project(val.Path.expandTilde())
        else:
          writeHelp()
      of "deps":
        if val.len > 0:
          context().depsDir = Path val
        else:
          writeHelp()
      of "shallow": context().flags.incl ShallowClones
      of "full": context().flags.excl ShallowClones
      of "noautoinit": autoinit = false
      of "ignoreerrors": context().flags.incl IgnoreErrors
      of "dumpformular": context().flags.incl DumpFormular
      of "showgraph": context().flags.incl ShowGraph
      of "tree": context().flags.incl TreeView
      of "update", "u": context().flags.incl UpdateBeforeInstall
      of "only": context().flags.incl UnlinkOnly
      of "ignoreurls": context().flags.incl IgnoreGitRemoteUrls
      of "keepworkspace": context().flags.incl KeepWorkspace
      of "autoenv": context().flags.incl AutoEnv
      of "noexec": context().flags.incl NoExec
      of "confdir":
        context().confDirOverride = Path val
      of "feature":
        addRequestedFeature(val)
      of "features":
        addRequestedFeatures(val)
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
        context().flags.incl DumbProxy
      of "packagesrepo":
        context().flags.incl PackagesGit
      of "dumpgraphs":
        context().flags.incl DumpGraphs
      of "forcegittohttps":
        context().flags.incl ForceGitToHttps
      of "resolver":
        case val.normalize
        of "minver": context().defaultAlgo = MinVer
        of "maxver": context().defaultAlgo = MaxVer
        of "semver": context().defaultAlgo = SemVer
        else: writeHelp()
      of "nolazydeps", "no-lazy-deps":
        context().flags.incl NoLazyDeps
      of "parallel", "t":
        context().flags.incl ParallelClones
        context().parallelCloneWorkers = parseParallelCloneWorkers(val)
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

  if detectProject():
    notice "atlas:project", "Using project directory:", $project()
    readConfig()
  elif action notin ["init", "tag"]:
    notice "atlas:project", "Using project directory:", $project()
    if autoinit and action notin ["search", "list"]:
      if autoProject(paths.getCurrentDir()):
        createWorkspace()
      else:
        fatal "No project found and unable to auto init project. Run `atlas init` if you want this current directory to be your project."
    elif action notin ["search", "list"]:
      fatal "No project found. Run `atlas init` if you want this current directory to be your project."

  if action notin ["tag", "search", "list"]:
    createDir(depsDir())
    if KeepFeatures in context().flags:
      for feature in parseNimCfgFeatures(CfgPath project()):
        context().features.incl feature

proc atlasRun*(params: seq[string]) =
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

  parseAtlasOptions(params, action, args)

  if UpdateBeforeInstall in context().flags and action != "install":
    fatal "--update option is only valid with `install`"
  if UnlinkOnly in context().flags and action != "unlink":
    fatal "--only option is only valid with `unlink`"

  if action notin ["init", "tag", "search", "list"]:
    doAssert project().string != "" and project().dirExists(), "project was not set"

  if action in ["install", "update", "use"]:
    context().flags.incl ListVersions

  case action
  of "":
    fatal "No action."
  of "init":
    if GlobalWorkspace in context().flags:
      project(Path(getHomeDir() / ".atlas"))
      createDir(project())
    else:
      project(paths.getCurrentDir())
    createWorkspace()
  of "tag":
    singleArg()
    tag(args[0])
  of "install":
    if UpdateBeforeInstall in context().flags:
      update("")
    let nimbleFile = findProjectNimbleFile()

    var nc = createNimbleContext()
    installDependencies(nc, nimbleFile)

  of "update":
    update(if args.len == 0: "" else: args[0])

  of "use":
    singleArg()

    if action == "update":
      context().flags.incl UpdateRepos

    var nc = createNimbleContext()
    let nimbleFile = findProjectNimbleFile(writeNimbleFile = true)

    info "atlas:use", "modifying nimble file to use package:", args[0], "at:", $nimbleFile
    patchNimbleFile(nc, nimbleFile, args[0])

    if atlasErrors() > 0:
      fatal "cannot continue"

    installDependencies(nc, nimbleFile)

  of "search":
    var pkgs: seq[PackageInfo] = @[]
    removeLegacyPackageCaches()
    if fileExists(packageInfosFile()):
      pkgs = getPackageInfos()
    pkgsearch.search(pkgs, args)

  of "link":
    singleArg()

    var linkDir = Path(args[0]).absolutePath
    if linkDir.splitFile().ext == "nimble":
      linkDir = linkDir.parentDir()

    if not linkDir.dirExists():
      fatal "cannot link to directory that does not exist: " & $linkDir

    let linkedNimbles = linkDir.findNimbleFile()
    if linkedNimbles.len() == 0:
      fatal "cannot link to directory that does not contain a nimble file: " & $linkDir
      quit(2)
    elif linkedNimbles.len() > 1:
      fatal "cannot link to directory that contains multiple nimble files: " & $linkDir
      quit(2)

    linkPackage(linkDir, linkedNimbles[0])

  of "unlink":
    singleArg()
    unlinkPackage(args[0], UnlinkOnly in context().flags)

  of "pin":
    optSingleArg($LockFileName)
    let exportNimble = Path(args[0]) == NimbleLockFileName
    pinProject Path(args[0]), exportNimble
  of "rep", "replay", "reproduce":
    optSingleArg($LockFileName)
    replay(Path(args[0]))
  of "changed":
    optSingleArg($LockFileName)
    listChanged(Path(args[0]))
  of "deps":
    if args.len != 0:
      fatal "deps command takes no arguments"
    showSelectedDeps()
  of "env":
    singleArg()
    setupNimEnv args[0], KeepNimEnv in context().flags
  of "outdated":
    listOutdated()
  else:
    fatal "Invalid action: " & action

proc main() =
  setContext AtlasContext()
  try:
    atlasRun(commandLineParams())
  finally:
    atlasWritePendingMessages()
  if atlasErrors() > 0 and IgnoreErrors notin context().flags:
    quit 1

when isMainModule:
  main()
