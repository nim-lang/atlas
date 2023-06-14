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
  parsecfg, streams, terminal, strscans, hashes, options]
import context, runners, osutils, packagesjson, sat, gitops, nimenv

export osutils, context

from unicode import nil

const
  AtlasVersion = "0.4"
  LockFileName = "atlas.lock"
  AtlasWorkspace = "atlas.workspace"
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
  --genlock             generate a lock file (use with `clone` and `update`)
  --uselock             use the lock file for the build
  --noexec              do not perform any action that may run arbitrary code
  --autoenv             detect the minimal Nim $version and setup a
                        corresponding Nim virtual environment
  --autoinit            auto initialize a workspace
  --colors=on|off       turn on|off colored output
  --resolver=minver|semver|maxver
                        which resolution algorithm to use, default is minver
  --showGraph           show the dependency graph
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


proc cloneUrl(c: var AtlasContext;
              url: PackageUrl,
              dest: string;
              cloneUsingHttps: bool): string =
  when MockupRun:
    result = ""
  else:
    result = osutils.cloneUrl(url, dest, cloneUsingHttps)
    when ProduceTest:
      echo "cloned ", url, " into ", dest

proc extractRequiresInfo(c: var AtlasContext; nimbleFile: string): NimbleFileInfo =
  result = extractRequiresInfo(nimbleFile)
  when ProduceTest:
    echo "nimble ", nimbleFile, " info ", result

proc tag(c: var AtlasContext; tag: string) =
  gitTag(c, tag)
  pushTag(c, tag)

proc tag(c: var AtlasContext; field: Natural) =
  let oldErrors = c.errors
  let newTag = incrementLastTag(c, field)
  if c.errors == oldErrors:
    tag(c, newTag)

proc updatePackages(c: var AtlasContext) =
  if dirExists(c.workspace / PackagesDir):
    withDir(c, c.workspace / PackagesDir):
      gitPull(c, PackageName PackagesDir)
  else:
    withDir c, c.workspace:
      let err = cloneUrl(c, getUrl "https://github.com/nim-lang/packages", PackagesDir, false)
      if err != "":
        error c, PackageName(PackagesDir), err

proc fillPackageLookupTable(c: var AtlasContext) =
  if not c.hasPackageList:
    c.hasPackageList = true
    when not MockupRun:
      if not fileExists(c.workspace / PackagesDir / "packages.json"):
        updatePackages(c)
    let plist = getPackages(when MockupRun: TestsDir else: c.workspace)
    for entry in plist:
      c.p[unicode.toLower entry.name] = entry.url

proc resolveUrl*(c: var AtlasContext; p: string): PackageUrl =
  proc lookup(c: var AtlasContext; p: string): string =
    if p.isUrl:
      if UsesOverrides in c.flags:
        result = c.overrides.substitute(p)
        if result.len > 0: return result
      result = p
    else:
      # either the project name or the URL can be overwritten!
      if UsesOverrides in c.flags:
        result = c.overrides.substitute(p)
        if result.len > 0: return result

      fillPackageLookupTable(c)
      result = c.p.getOrDefault(unicode.toLower p)

      if result.len == 0:
        let res = getUrlFromGithub(p)
        if res.isNone:
          inc c.errors
        else:
          result = res.get()

      if UsesOverrides in c.flags:
        let newUrl = c.overrides.substitute(result)
        if newUrl.len > 0: return newUrl

  let urlstr = lookup(c, p)
  result = urlstr.getUrl()

proc generateDepGraph(c: var AtlasContext; g: DepGraph) =
  proc repr(w: Dependency): string =
    $(w.url / w.commit)

  var dotGraph = ""
  for i in 0 ..< g.nodes.len:
    dotGraph.addf("\"$1\" [label=\"$2\"];\n", [g.nodes[i].repr, if g.nodes[i].active: "" else: "unused"])
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

proc afterGraphActions(c: var AtlasContext; g: DepGraph) =
  if ShowGraph in c.flags:
    generateDepGraph c, g
  if AutoEnv in c.flags and g.bestNimVersion != Version"":
    setupNimEnv c, g.bestNimVersion.string


proc commitFromLockFile(c: var AtlasContext; w: Dependency): string =
  let url = getRemoteUrl()
  let entry = c.lockFile.items.getOrDefault(w.name.string)
  if entry.commit.len > 0:
    result = entry.commit
    if entry.url != $url:
      error c, w.name, "remote URL has been compromised: got: " &
          $url & " but wanted: " & $entry.url
  else:
    error c, w.name, "package is not listed in the lock file"

const
  FileProtocol = "file"
  ThisVersion = "current_version.atlas"

proc selectNode(c: var AtlasContext; g: var DepGraph; w: Dependency) =
  # all other nodes of the same project name are not active
  for e in items g.byName[w.name]:
    g.nodes[e].active = e == w.self
  if c.lockMode == genLock:
    if w.url.scheme == FileProtocol:
      c.lockFile.items[w.name.string] = LockFileEntry(url: $w.url, commit: w.commit)
    else:
      genLockEntry(c, w)

proc checkoutCommit(c: var AtlasContext; g: var DepGraph; w: Dependency) =
  let dir = dependencyDir(c, w)
  withDir c, dir:
    if c.lockMode == useLock:
      checkoutGitCommit(c, w.name, commitFromLockFile(c, w))
    elif w.commit.len == 0 or cmpIgnoreCase(w.commit, "head") == 0:
      gitPull(c, w.name)
    else:
      let err = isCleanGit(c)
      if err != "":
        warn c, w.name, err
      else:
        let requiredCommit = getRequiredCommit(c, w)
        let (cc, status) = exec(c, GitCurrentCommit, [])
        let currentCommit = strutils.strip(cc)
        if requiredCommit == "" or status != 0:
          if requiredCommit == "" and w.commit == InvalidCommit:
            warn c, w.name, "package has no tagged releases"
          else:
            warn c, w.name, "cannot find specified version/commit " & w.commit
        else:
          if currentCommit != requiredCommit:
            # checkout the later commit:
            # git merge-base --is-ancestor <commit> <commit>
            let (cc, status) = exec(c, GitMergeBase, [currentCommit, requiredCommit])
            let mergeBase = strutils.strip(cc)
            if status == 0 and (mergeBase == currentCommit or mergeBase == requiredCommit):
              # conflict resolution: pick the later commit:
              if mergeBase == currentCommit:
                checkoutGitCommit(c, w.name, requiredCommit)
                selectNode c, g, w
            else:
              checkoutGitCommit(c, w.name, requiredCommit)
              selectNode c, g, w
              when false:
                warn c, w.name, "do not know which commit is more recent:",
                  currentCommit, "(current) or", w.commit, " =", requiredCommit, "(required)"

proc addUnique[T](s: var seq[T]; elem: sink T) =
  if not s.contains(elem): s.add elem

proc addUniqueDep(c: var AtlasContext; g: var DepGraph; parent: int;
                  pkg: PackageUrl; query: VersionInterval) =
  let commit = versionKey(query)
  let oldErrors = c.errors
  let url = pkg
  let name = pkg.toName
  if oldErrors != c.errors:
    warn c, toName(pkg), "cannot resolve package name"
  else:
    let key = url / commit
    if g.processed.hasKey($key):
      g.nodes[g.processed[$key]].parents.addUnique parent
    else:
      let self = g.nodes.len
      g.byName.mgetOrPut(name, @[]).add self
      g.processed[$key] = self
      if c.lockMode == useLock:
        if c.lockfile.items.contains(name.string):
          g.nodes.add Dependency(name: name,
                                 url: c.lockfile.items[name.string].url.getUrl(),
                                 commit: c.lockfile.items[name.string].commit,
                                 self: self,
                                 parents: @[parent],
                                 algo: c.defaultAlgo)
        else:
          error c, pkg.toName, "package is not listed in the lock file"
      else:
        g.nodes.add Dependency(name: name, url: url, commit: commit,
                               self: self,
                               query: query,
                               parents: @[parent],
                               algo: c.defaultAlgo)

proc rememberNimVersion(g: var DepGraph; q: VersionInterval) =
  let v = extractGeQuery(q)
  if v != Version"" and v > g.bestNimVersion: g.bestNimVersion = v

proc collectDeps(c: var AtlasContext; g: var DepGraph; parent: int;
                 dep: Dependency; nimbleFile: string): CfgPath =
  # If there is a .nimble file, return the dependency path & srcDir
  # else return "".
  assert nimbleFile != ""
  let nimbleInfo = extractRequiresInfo(c, nimbleFile)
  if dep.self >= 0 and dep.self < g.nodes.len:
    g.nodes[dep.self].hasInstallHooks = nimbleInfo.hasInstallHooks
  for r in nimbleInfo.requires:
    var i = 0
    while i < r.len and r[i] notin {'#', '<', '=', '>'} + Whitespace: inc i
    let pkgName = r.substr(0, i-1)
    var err = pkgName.len == 0
    let pkgUrl = c.resolveUrl(pkgName)
    let query = parseVersionInterval(r, i, err)
    if err:
      error c, toName(nimbleFile), "invalid 'requires' syntax: " & r
    else:
      if cmpIgnoreCase(pkgUrl.path, "nim") != 0:
        c.addUniqueDep g, parent, pkgUrl, query
      else:
        rememberNimVersion g, query
  result = CfgPath(toDestDir(dep.name) / nimbleInfo.srcDir)

proc collectNewDeps(c: var AtlasContext; g: var DepGraph; parent: int;
                    dep: Dependency): CfgPath =
  let nimbleFile = findNimbleFile(c, dep)
  if nimbleFile != "":
    result = collectDeps(c, g, parent, dep, nimbleFile)
  else:
    result = CfgPath toDestDir(dep.name)

proc copyFromDisk(c: var AtlasContext; w: Dependency) =
  let destDir = toDestDir(w.name)
  var u = w.url.getFilePath()
  if u.startsWith("./"): u = c.workspace / u.substr(2)
  copyDir(selectDir(u & "@" & w.commit, u), destDir)
  writeFile destDir / ThisVersion, w.commit
  #echo "WRITTEN ", destDir / ThisVersion

proc isLaterCommit(destDir, version: string): bool =
  let oldVersion = try: readFile(destDir / ThisVersion).strip except: "0.0"
  if isValidVersion(oldVersion) and isValidVersion(version):
    result = Version(oldVersion) < Version(version)
  else:
    result = true

proc collectAvailableVersions(c: var AtlasContext; g: var DepGraph; w: Dependency) =
  when MockupRun:
    # don't cache when doing the MockupRun:
    g.availableVersions[w.name] = collectTaggedVersions(c)
  else:
    if not g.availableVersions.hasKey(w.name):
      g.availableVersions[w.name] = collectTaggedVersions(c)


proc resolve(c: var AtlasContext; g: var DepGraph) =
  var b = sat.Builder()
  b.openOpr(AndForm)
  # Root must true:
  b.add newVar(VarId 0)

  assert g.nodes.len > 0
  #assert g.nodes[0].active # this does not have to be true if some
  # project is listed multiple times in the .nimble file.
  # Implications:
  for i in 0..<g.nodes.len:
    if g.nodes[i].active:
      for j in g.nodes[i].parents:
        # "parent has a dependency on x" is translated to:
        # "parent implies x" which is "not parent or x"
        if j >= 0:
          b.openOpr(OrForm)
          b.openOpr(NotForm)
          b.add newVar(VarId j)
          b.closeOpr
          b.add newVar(VarId i)
          b.closeOpr
  var idgen = 0
  var mapping: seq[(string, string, Version)] = @[]
  # Version selection:
  for i in 0..<g.nodes.len:
    let av {.cursor.} = g.availableVersions[g.nodes[i].name]
    if g.nodes[i].active and av.len > 0:
      # A -> (exactly one of: A1, A2, A3)
      b.openOpr(OrForm)
      b.openOpr(NotForm)
      b.add newVar(VarId i)
      b.closeOpr
      b.openOpr(ExactlyOneOfForm)

      var q = g.nodes[i].query
      if g.nodes[i].algo == SemVer: q = toSemVer(q)
      if g.nodes[i].algo == MinVer:
        for j in countup(0, av.len-1):
          if q.matches(av[j][1]):
            mapping.add (g.nodes[i].name.string, av[j][0], av[j][1])
            b.add newVar(VarId(idgen + g.nodes.len))
            inc idgen
      else:
        for j in countdown(av.len-1, 0):
          if q.matches(av[j][1]):
            mapping.add (g.nodes[i].name.string, av[j][0], av[j][1])
            b.add newVar(VarId(idgen + g.nodes.len))
            inc idgen

      b.closeOpr # ExactlyOneOfForm
      b.closeOpr # OrForm
  b.closeOpr()
  let f = toForm(b)
  var s = newSeq[BindingKind](idgen)
  if satisfiable(f, s):
    for i in g.nodes.len..<s.len:
      if s[i] == setToTrue:
        let destDir = mapping[i - g.nodes.len][0]
        let dir = selectDir(c.workspace / destDir, c.depsDir / destDir)
        withDir c, dir:
          checkoutGitCommit(c, toName(destDir), mapping[i - g.nodes.len][1])
    if NoExec notin c.flags:
      runBuildSteps(c, g)
    when false:
      echo "selecting: "
      for i in g.nodes.len..<s.len:
        if s[i] == setToTrue:
          echo "[x] ", mapping[i - g.nodes.len]
        else:
          echo "[ ] ", mapping[i - g.nodes.len]
      echo f
  else:
    error c, toName(c.workspace), "version conflict; for more information use --showGraph"
    var usedVersions = initCountTable[string]()
    for i in g.nodes.len..<s.len:
      if s[i] == setToTrue:
        usedVersions.inc mapping[i - g.nodes.len][0]
    for i in g.nodes.len..<s.len:
      if s[i] == setToTrue:
        let counter = usedVersions.getOrDefault(mapping[i - g.nodes.len][0])
        if counter > 0:
          error c, toName(mapping[i - g.nodes.len][0]), $mapping[i - g.nodes.len][2] & " required"

proc traverseLoop(c: var AtlasContext; g: var DepGraph; startIsDep: bool): seq[CfgPath] =
  if c.lockMode == useLock:
    let lockFilePath = dependencyDir(c, g.nodes[0]) / LockFileName
    c.lockFile = readLockFile(lockFilePath)

  result = @[]
  var i = 0
  while i < g.nodes.len:
    let w = g.nodes[i]
    let destDir = toDestDir(w.name)
    let oldErrors = c.errors

    let dir = selectDir(c.workspace / destDir, c.depsDir / destDir)
    if not dirExists(dir):
      withDir c, (if i != 0 or startIsDep: c.depsDir else: c.workspace):
        if w.url.scheme == FileProtocol:
          copyFromDisk c, w
        else:
          let err = cloneUrl(c, w.url, destDir, false)
          if err != "":
            error c, w.name, err
          elif w.algo != MinVer:
            withDir c, destDir:
              collectAvailableVersions c, g, w
    elif w.algo != MinVer:
      withDir c, dir:
        collectAvailableVersions c, g, w

    # assume this is the selected version, it might get overwritten later:
    selectNode c, g, w
    if oldErrors == c.errors:
      if KeepCommits notin c.flags and w.algo == MinVer:
        if w.url.scheme != FileProtocol:
          checkoutCommit(c, g, w)
        else:
          withDir c, (if i != 0 or startIsDep: c.depsDir else: c.workspace):
            if isLaterCommit(destDir, w.commit):
              copyFromDisk c, w
              selectNode c, g, w
      # even if the checkout fails, we can make use of the somewhat
      # outdated .nimble file to clone more of the most likely still relevant
      # dependencies:
      result.addUnique collectNewDeps(c, g, i, w)
    inc i

  if g.availableVersions.len > 0:
    resolve c, g
  if c.lockMode == genLock:
    writeFile c.currentDir / LockFileName, toJson(c.lockFile).pretty

proc createGraph(c: var AtlasContext; start: string, url: PackageUrl): DepGraph =
  result = DepGraph(nodes: @[Dependency(name: toName(start),
                                        url: url,
                                        commit: "",
                                        self: 0,
                                        algo: c.defaultAlgo)])
  result.byName.mgetOrPut(toName(start), @[]).add 0

proc traverse(c: var AtlasContext; start: string; startIsDep: bool): seq[CfgPath] =
  # returns the list of paths for the nim.cfg file.
  let url = resolveUrl(c, start)
  var g = createGraph(c, start, url)

  if $url == "":
    error c, toName(start), "cannot resolve package name"
    return

  c.projectDir = c.workspace / toDestDir(g.nodes[0].name)

  result = traverseLoop(c, g, startIsDep)
  afterGraphActions c, g

const
  configPatternBegin = "############# begin Atlas config section ##########\n"
  configPatternEnd =   "############# end Atlas config section   ##########\n"

proc patchNimCfg(c: var AtlasContext; deps: seq[CfgPath]; cfgPath: string) =
  var paths = "--noNimblePath\n"
  for d in deps:
    let pkgname = toDestDir d.string.PackageName
    let pkgdir = if dirExists(c.workspace / pkgname): c.workspace / pkgname
                 else: c.depsDir / pkgName
    let x = relativePath(pkgdir, cfgPath, '/')
    paths.add "--path:\"" & x & "\"\n"
  var cfgContent = configPatternBegin & paths & configPatternEnd

  when MockupRun:
    assert readFile(TestsDir / "nim.cfg") == cfgContent
    c.mockupSuccess = true
  else:
    let cfg = cfgPath / "nim.cfg"
    assert cfgPath.len > 0
    if cfgPath.len > 0 and not dirExists(cfgPath):
      error(c, c.projectDir.PackageName, "could not write the nim.cfg")
    elif not fileExists(cfg):
      writeFile(cfg, cfgContent)
      info(c, projectFromCurrentDir(), "created: " & cfg.readableFile)
    else:
      let content = readFile(cfg)
      let start = content.find(configPatternBegin)
      if start >= 0:
        cfgContent = content.substr(0, start-1) & cfgContent
        let theEnd = content.find(configPatternEnd, start)
        if theEnd >= 0:
          cfgContent.add content.substr(theEnd+len(configPatternEnd))
      else:
        cfgContent = content & "\n" & cfgContent
      if cfgContent != content:
        # do not touch the file if nothing changed
        # (preserves the file date information):
        writeFile(cfg, cfgContent)
        info(c, projectFromCurrentDir(), "updated: " & cfg.readableFile)

proc findSrcDir(c: var AtlasContext): string =
  for nimbleFile in walkPattern(c.currentDir / "*.nimble"):
    let nimbleInfo = extractRequiresInfo(c, nimbleFile)
    return c.currentDir / nimbleInfo.srcDir
  return c.currentDir

proc installDependencies(c: var AtlasContext; nimbleFile: string; startIsDep: bool) =
  # 1. find .nimble file in CWD
  # 2. install deps from .nimble
  var g = DepGraph(nodes: @[])
  let (_, pkgname, _) = splitFile(nimbleFile)
  let dep = Dependency(name: toName(pkgname), url: getUrl "", commit: "", self: 0,
                       algo: c.defaultAlgo)
  g.byName.mgetOrPut(toName(pkgname), @[]).add 0
  discard collectDeps(c, g, -1, dep, nimbleFile)
  let paths = traverseLoop(c, g, startIsDep)
  patchNimCfg(c, paths, if CfgHere in c.flags: c.currentDir else: findSrcDir(c))
  afterGraphActions c, g

proc updateDir(c: var AtlasContext; dir, filter: string) =
  ## update the package's VCS
  for kind, file in walkDir(dir):
    if kind == pcDir and isGitDir(file):
      gitops.updateDir(c, file, filter)

proc patchNimbleFile(c: var AtlasContext; dep: string): string =
  let thisProject = c.currentDir.splitPath.tail
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

proc parseOverridesFile(c: var AtlasContext; filename: string) =
  const Separator = " -> "
  let path = c.workspace / filename
  var f: File
  if open(f, path):
    c.flags.incl UsesOverrides
    try:
      var lineCount = 1
      for line in lines(path):
        let splitPos = line.find(Separator)
        if splitPos >= 0 and line[0] != '#':
          let key = line.substr(0, splitPos-1)
          let val = line.substr(splitPos+len(Separator))
          if key.len == 0 or val.len == 0:
            error c, toName(path), "key/value must not be empty"
          let err = c.overrides.addPattern(key, val)
          if err.len > 0:
            error c, toName(path), "(" & $lineCount & "): " & err
        else:
          discard "ignore the line"
        inc lineCount
    finally:
      close f
  else:
    error c, toName(path), "cannot open: " & path

proc readPluginsDir(c: var AtlasContext; dir: string) =
  for k, f in walkDir(c.workspace / dir):
    if k == pcFile and f.endsWith(".nims"):
      extractPluginInfo f, c.plugins

proc readConfig(c: var AtlasContext) =
  let configFile = c.workspace / AtlasWorkspace
  var f = newFileStream(configFile, fmRead)
  if f == nil:
    error c, toName(configFile), "cannot open: " & configFile
    return
  var p: CfgParser
  open(p, f, configFile)
  while true:
    var e = next(p)
    case e.kind
    of cfgEof: break
    of cfgSectionStart:
      discard "who cares about sections"
    of cfgKeyValuePair:
      case e.key.normalize
      of "deps":
        c.depsDir = absoluteDepsDir(c.workspace, e.value)
      of "overrides":
        parseOverridesFile(c, e.value)
      of "resolver":
        try:
          c.defaultAlgo = parseEnum[ResolutionAlgorithm](e.value)
        except ValueError:
          warn c, toName(configFile), "ignored unknown resolver: " & e.key
      of "plugins":
        readPluginsDir(c, e.value)
      else:
        warn c, toName(configFile), "ignored unknown setting: " & e.key
    of cfgOption:
      discard "who cares about options"
    of cfgError:
      error c, toName(configFile), e.msg
  close(p)

proc listOutdated(c: var AtlasContext; dir: string) =
  var updateable = 0
  for k, f in walkDir(dir, relative=true):
    if k in {pcDir, pcLinkToDir} and isGitDir(dir / f):
      withDir c, dir / f:
        if gitops.isOutdated(c, f):
          inc updateable

  if updateable == 0:
    info c, toName(c.workspace), "all packages are up to date"

proc listOutdated(c: var AtlasContext) =
  if c.depsDir.len > 0 and c.depsDir != c.workspace:
    listOutdated c, c.depsDir
  listOutdated c, c.workspace

proc main(c: var AtlasContext) =
  var action = ""
  var args: seq[string] = @[]
  template singleArg() =
    if args.len != 1:
      fatal action & " command takes a single package name"

  template noArgs() =
    if args.len != 0:
      fatal action & " command takes no arguments"

  template projectCmd() =
    if c.projectDir == c.workspace or c.projectDir == c.depsDir:
      fatal action & " command must be executed in a project, not in the workspace"

  var autoinit = false
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
          createDir(val)
          createWorkspaceIn c.workspace, c.depsDir
        else:
          writeHelp()
      of "project":
        if isAbsolute(val):
          c.currentDir = val
        else:
          c.currentDir = getCurrentDir() / val
      of "deps":
        if val.len > 0:
          c.depsDir = val
        else:
          writeHelp()
      of "cfghere": c.flags.incl CfgHere
      of "autoinit": autoinit = true
      of "showgraph": c.flags.incl ShowGraph
      of "keep": c.flags.incl Keep
      of "autoenv": c.flags.incl AutoEnv
      of "noexec": c.flags.incl NoExec
      of "genlock":
        if c.lockMode != useLock:
          c.lockMode = genLock
        else:
          writeHelp()
      of "uselock":
        if c.lockMode != genLock:
          c.lockMode = useLock
        else:
          writeHelp()
      of "colors":
        case val.normalize
        of "off": c.flags.incl NoColors
        of "on": c.flags.excl NoColors
        else: writeHelp()
      of "resolver":
        try:
          c.defaultAlgo = parseEnum[ResolutionAlgorithm](val)
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
      elif action notin ["search", "list"]:
        fatal "No workspace found. Run `atlas init` if you want this current directory to be your workspace."

  when MockupRun:
    c.depsDir = c.workspace

  case action
  of "":
    fatal "No action."
  of "init":
    c.workspace = getCurrentDir()
    createWorkspaceIn c.workspace, c.depsDir
  of "clone", "update":
    singleArg()
    let deps = traverse(c, args[0], startIsDep = false)
    patchNimCfg c, deps, if CfgHere in c.flags: c.currentDir else: findSrcDir(c)
    when MockupRun:
      if not c.mockupSuccess:
        fatal "There were problems."
  of "use":
    projectCmd()
    singleArg()
    let nimbleFile = patchNimbleFile(c, args[0])
    if nimbleFile.len > 0:
      installDependencies(c, nimbleFile, startIsDep = false)
  of "install":
    projectCmd()
    if args.len > 1:
      fatal "install command takes a single argument"
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
      installDependencies(c, nimbleFile, startIsDep = true)
  of "refresh":
    noArgs()
    updatePackages(c)
  of "search", "list":
    if c.workspace.len != 0:
      updatePackages(c)
      search getPackages(c.workspace), args
    else: search @[], args
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

when isMainModule:
  main()
