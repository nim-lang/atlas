#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Lockfile implementation.

import std / [sequtils, paths, dirs, files, strutils, tables, sets, os, json, jsonutils]
import basic/[lockfiletypes, context, gitops, nimblechecksums, compilerversions,
  configutils, depgraphtypes, reporters, nimbleparser, pkgurls]
import cloner, depgraphs, pkgcache

const
  NimbleLockFileName* = Path "nimble.lock"


proc prefixedPath*(c: var AtlasContext, path: Path): string =
  let parts = splitPath($path)
  if path.isRelativeTo(c.depsDir):
    return "$deps" / parts.tail
  elif path.isRelativeTo(c.workspace):
    return "$workspace" / parts.tail
  else:
    return $path

proc fromPrefixedPath*(c: var AtlasContext, path: string): Path =
  var path = path
  if path.startsWith("$deps"):
    path.removePrefix("$deps")
    return c.depsDir / Path(path)
  elif path.startsWith("$workspace"):
    path.removePrefix("$workspace")
    return c.workspace / Path(path)
  else:
    return c.depsDir / Path(path)

proc genLockEntry(c: var AtlasContext; lf: var LockFile; w: Dependency) =
  lf.items[w.pkg.projectName] = LockFileEntry(
    dir: c.prefixedPath(w.ondisk),
    url: w.pkg.url,
    commit: getCurrentCommit(),
    version: ""
  )

when false:
  proc genLockEntriesForDir(c: var AtlasContext; lf: var LockFile; dir: string) =
    for k, f in walkDir(dir):
      if k == pcDir and dirExists(f / ".git"):
        if f.absolutePath == c.depsDir / "packages":
          # skipping this gives us the locking behavior for a project
          # TODO: is this what we want?
          # we could just create a fake Package item here
          continue
        withDir c, f:
          let path = "file://" & f
          debug c, "genLockEntries", "using pkg: " & path
          let pkg = resolvePackage(c, path)
          genLockEntry(c, lf, pkg)

proc newLockFile(): LockFile =
  result = LockFile(items: initOrderedTable[string, LockFileEntry](),
    hostOS: system.hostOS, hostCPU: system.hostCPU,
    nimVersion: detectNimVersion(),
    gccVersion: detectGccVersion(),
    clangVersion: detectClangVersion())

type
  NimbleLockFileEntry* = object
    version*: string
    vcsRevision*: string
    url*: string
    downloadMethod*: string
    dependencies*: seq[string]
    checksums*: Table[string, string]

  NimbleLockFile* = object # serialized as JSON
    packages*: OrderedTable[string, NimbleLockFileEntry]
    version*: int

proc newNimbleLockFile(): NimbleLockFile =
  let tbl = initOrderedTable[string, NimbleLockFileEntry]()
  result = NimbleLockFile(version: 1,
                          packages: tbl)

proc write(lock: NimbleLockFile; lockFilePath: string) =
  writeFile lockFilePath, toJson(lock).pretty

proc genLockEntry(c: var AtlasContext;
                  lf: var NimbleLockFile;
                  w: Dependency,
                  cfg: CfgPath,
                  deps: HashSet[string]) =
  # var amb = false
  let (nimbleFile, cnt) = findNimbleFile(w)
  let info = extractRequiresInfo(nimbleFile)
  let commit = getCurrentCommit()
  infoNow c, w.pkg.projectName, "calculating nimble checksum"
  let chk = c.nimbleChecksum(w.pkg.projectName, w.ondisk)
  lf.packages[w.pkg.projectName] = NimbleLockFileEntry(
    version: info.version,
    vcsRevision: commit,
    url: w.pkg.url,
    downloadMethod: "git",
    dependencies: deps.mapIt(it),
    checksums: {"sha1": chk}.toTable
  )

const
  NimCfg = Path "nim.cfg"

proc expandWithoutClone*(c: var AtlasContext; g: var DepGraph; nc: NimbleContext) =
  ## Expand the graph by adding all dependencies.
  var processed = initHashSet[PkgUrl]()
  var i = 0
  while i < g.nodes.len:
    if not processed.containsOrIncl(g.nodes[i].pkg):
      let (dest, todo) = pkgUrlToDirname(c, g, g.nodes[i])
      if todo == DoNothing:
        withDir c, $dest:
          c.traverseDependency(nc, g, i, CurrentCommit)
    inc i

proc pinGraph*(c: var AtlasContext; g: var DepGraph; lockFile: Path; exportNimble = false) =
  info c, "pin", "pinning project"
  var lf = newLockFile()
  let startPkg = c.currentDir # resolvePackage(c, "file://" & c.currentDir)

  # only used for exporting nimble locks
  var nlf = newNimbleLockFile()
  var nimbleDeps = newTable[string, HashSet[string]]()

  info c, startPkg, "pinning lockfile: " & $lockFile

  var nc = createNimbleContext(c, c.depsDir)
  expandWithoutClone c, g, nc

  for w in toposorted(g):
    let dir = w.ondisk
    tryWithDir c, $dir:
      if not exportNimble:
        # generate atlas native lockfile entries
        genLockEntry c, lf, w
      else:
        # handle exports for Nimble; these require looking up a bit more info
        for nx in directDependencies(g, c, w):
          nimbleDeps.mgetOrPut(w.pkg.projectName,
                              initHashSet[string]()).incl(nx.pkg.projectName)
        trace c, w.pkg.projectName, "exporting nimble " & w.pkg.url
        let deps = nimbleDeps.getOrDefault(w.pkg.projectName)
        genLockEntry c, nlf, w, getCfgPath(g, w), deps

  let nimcfgPath = c.currentDir / NimCfg
  if fileExists(nimcfgPath):
    lf.nimcfg = readFile($nimcfgPath).splitLines()

  let (nimblePath, cnt) = findNimbleFile(startPkg)
  if cnt > 0 and nimblePath.string.len > 0 and nimblePath.fileExists():
    lf.nimbleFile = LockedNimbleFile(
      filename: $nimblePath.relativePath(c.currentDir),
      content: readFile($nimblePath).splitLines())

  if not exportNimble:
    write lf, $lockFile
  else:
    write nlf, $lockFile

proc pinWorkspace*(c: var AtlasContext; lockFile: Path) =
  info c, "pin", "pinning workspace: " & $c.workspace
  var g = createGraphFromWorkspace(c)
  var nc = createNimbleContext(c, c.depsDir)
  expandWithoutClone c, g, nc
  pinGraph c, g, lockFile

proc pinProject*(c: var AtlasContext; lockFile: Path, exportNimble = false) =
  ## Pin project using deps starting from the current project directory.
  ##
  info c, "pin", "pinning project"

  var g = createGraph(c, c.createUrl($c.currentDir, c.overrides))
  var nc = createNimbleContext(c, c.depsDir)
  expandWithoutClone c, g, nc
  pinGraph c, g, lockFile

proc compareVersion(c: var AtlasContext; key, wanted, got: string) =
  if wanted != got:
    warn c, key, "environment mismatch: " &
      " versions differ: previously used: " & wanted & " but now at: " & got

proc convertNimbleLock*(c: var AtlasContext; nimble: Path): LockFile =
  ## converts nimble lock file into a Atlas lockfile
  ##
  let jsonAsStr = readFile($nimble)
  let jsonTree = parseJson(jsonAsStr)

  if jsonTree.getOrDefault("version") == nil or
      "packages" notin jsonTree:
    error c, nimble, "invalid nimble lockfile"
    return

  result = newLockFile()
  for (name, info) in jsonTree["packages"].pairs:
    if name == "nim":
      result.nimVersion = info["version"].getStr
    else:
      # lookup package using url
      let pkgurl = info["url"].getStr
      info c, name, " imported "
      let u = c.createUrl(pkgurl, c.overrides)
      let dir = c.depsDir / u.projectName.Path 
      result.items[name] = LockFileEntry(
        dir: $dir.relativePath(c.projectDir),
        url: pkgurl,
        commit: info["vcsRevision"].getStr
      )

proc convertAndSaveNimbleLock*(c: var AtlasContext; nimble, lockFile: Path) =
  ## convert and save a nimble.lock into an Atlast lockfile
  let lf = convertNimbleLock(c, nimble)
  write lf, $lockFile

proc listChanged*(c: var AtlasContext; lockFile: Path) =
  ## replays the given lockfile by cloning and updating all the deps
  ##
  ## this also includes updating the nim.cfg and nimble file as well
  ## if they're included in the lockfile
  ##
  let lf = if lockFile == NimbleLockFileName:
              convertNimbleLock(c, lockFile)
           else:
              readLockFile(lockFile)

  let base = splitPath(lockFile).head

  # update the the dependencies
  for _, v in pairs(lf.items):
    let dir = base / v.dir
    if not dirExists(dir):
      warn c, dir, "repo missing!"
      continue
    withDir c, dir:
      let url = $c.getRemoteUrl()
      if v.url != url:
        warn c, v.dir, "remote URL has been changed;" &
                       " found: " & url &
                       " lockfile has: " & v.url

      let commit = gitops.getCurrentCommit()
      if commit != v.commit:
        #let info = parseNimble(c, pkg.nimble)
        warn c, dir, "commit differs;" &
                     " found: " & commit &
                     " lockfile has: " & v.commit

  if lf.hostOS == system.hostOS and lf.hostCPU == system.hostCPU:
    compareVersion c, "nim", lf.nimVersion, detectNimVersion()
    compareVersion c, "gcc", lf.gccVersion, detectGccVersion()
    compareVersion c, "clang", lf.clangVersion, detectClangVersion()

proc withoutSuffix(s, suffix: string): string =
  result = s
  if result.endsWith(suffix):
    result.setLen result.len - suffix.len

proc replay*(c: var AtlasContext; lockFile: Path) =
  ## replays the given lockfile by cloning and updating all the deps
  ##
  ## this also includes updating the nim.cfg and nimble file as well
  ## if they're included in the lockfile
  ##
  let lf = if lockFilePath == NimbleLockFileName:
              convertNimbleLock(c, lockFilePath)
           else:
              readLockFile(lockFilePath)

  #let lfBase = splitPath(lockFilePath).head
  var genCfg = CfgHere in c.flags

  # update the nim.cfg file
  if lf.nimcfg.len > 0:
    writeFile(c.currentDir / NimCfg, lf.nimcfg.join("\n"))
  else:
    genCfg = true

  # update the nimble file
  if lf.nimbleFile.filename.len > 0:
    writeFile(c.currentDir / lf.nimbleFile.filename,
              lf.nimbleFile.content.join("\n"))

  # update the the dependencies
  var paths: seq[CfgPath] = @[]
  for _, v in pairs(lf.items):
    trace c, "replay", "replaying: " & v.repr
    let dir = c.fromPrefixedPath(v.dir)
    if not dirExists(dir):
      let (status, err) = c.cloneUrl(c.createUrl(v.url, c.overrides), dir, false)
      if status != Ok:
        error c, lockFilePath, err
        continue
    withDir c, dir:
      let url = $c.getRemoteUrl()
      if url.withoutSuffix(".git") != url:
        if IgnoreUrls in c.flags:
          warn c, v.dir, "remote URL differs from expected: got: " &
            url & " but expected: " & v.url
        else:
          error c, v.dir, "remote URL has been compromised: got: " &
            url & " but wanted: " & v.url
      checkoutGitCommitFull(c, dir, v.commit, FullClones in c.flags)

      if genCfg:
        paths.add c.findCfgDir(dir)

  if genCfg:
    # this allows us to re-create a nim.cfg that uses the paths from the users workspace
    # without needing to do a `installDependencies` or `traverseLoop`
    let cfgPath = if genCfg: CfgPath c.currentDir else: findCfgDir(c)
    patchNimCfg(c, paths, cfgPath)

  if lf.hostOS == system.hostOS and lf.hostCPU == system.hostCPU:
    compareVersion c, "nim", lf.nimVersion, detectNimVersion()
    compareVersion c, "gcc", lf.gccVersion, detectGccVersion()
    compareVersion c, "clang", lf.clangVersion, detectClangVersion()
