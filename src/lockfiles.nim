#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Lockfile implementation.

import std / [sequtils, paths, dirs, files, strutils, tables, sets, os, json, jsonutils]
import basic/[lockfiletypes, context, osutils, gitops, nimblechecksums, compilerversions,
  configutils, depgraphtypes, reporters, nimbleparser, pkgurls]
import depgraphs, dependencies

const
  NimbleLockFileName* = Path "nimble.lock"


proc prefixedPath*(path: Path): Path =
  let parts = splitPath($path)
  if path.isRelativeTo(context().depsDir):
    return Path("$deps" / parts.tail)
  elif path.isRelativeTo(context().workspace):
    return Path("$workspace" / parts.tail)
  else:
    return Path($path)

proc fromPrefixedPath*(path: Path): Path =
  var path = path
  if path.string.startsWith("$deps"):
    path.string.removePrefix("$deps")
    return context().depsDir / path
  elif path.string.startsWith("$workspace"):
    path.string.removePrefix("$workspace")
    return context().workspace / path
  else:
    return context().depsDir / path

proc genLockEntry(lf: var LockFile; w: Package) =
  lf.items[w.url.projectName] = LockFileEntry(
    dir: prefixedPath(w.ondisk),
    url: w.url.url,
    commit: $currentGitCommit(w.ondisk),
    version: ""
  )

when false:
  proc genLockEntriesForDir(lf: var LockFile; dir: string) =
    for k, f in walkDir(dir):
      if k == pcDir and dirExists(f / ".git"):
        if f.absolutePath == context().depsDir / "packages":
          # skipping this gives us the locking behavior for a project
          # TODO: is this what we want?
          # we could just create a fake Package item here
          continue
        withDir f:
          let path = "file://" & f
          debug "genLockEntries", "using pkg: " & path
          let pkg = resolvePackage(path)
          genLockEntry(lf, pkg)

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
  writeFile lockFilePath, pretty(toJson(lock))

proc genLockEntry(
                  lf: var NimbleLockFile;
                  w: Package,
                  cfg: CfgPath,
                  deps: HashSet[string]) =
  let nimbleFiles = findNimbleFile(w)
  let nimbleFile =
    if nimbleFiles.len() == 1:
      nimbleFiles[0]
    else:
      error w.url.projectName, "Couldn't find nimble file at " & $w.ondisk
      return

  let info = extractRequiresInfo(nimbleFile)
  let commit = currentGitCommit(w.ondisk)
  infoNow w.url.projectName, "calculating nimble checksum"
  let chk = nimbleChecksum(w.url.projectName, w.ondisk)
  lf.packages[w.url.projectName] = NimbleLockFileEntry(
    version: info.version,
    vcsRevision: $commit,
    url: w.url.url,
    downloadMethod: "git",
    dependencies: deps.mapIt(it),
    checksums: {"sha1": chk}.toTable
  )

const
  NimCfg = Path "nim.cfg"

proc pinGraph*(g: var DepGraph; lockFile: Path; exportNimble = false) =
  info "pin", "pinning project"
  var lf = newLockFile()
  let workspace = context().workspace # resolvePackage("file://" & context().currentDir)

  # only used for exporting nimble locks
  var nlf = newNimbleLockFile()
  var nimbleDeps = newTable[string, HashSet[string]]()

  info workspace, "pinning lockfile: " & $lockFile

  var nc = createNimbleContext()
  var graph = workspace.expand(nc, CurrentCommit, notFoundAction=DoNothing)

  for w in toposorted(g):
    let dir = w.ondisk
    tryWithDir $dir:
      if not exportNimble:
        # generate atlas native lockfile entries
        genLockEntry lf, w
      else:
        # handle exports for Nimble; these require looking up a bit more info
        for nx in directDependencies(g, w):
          nimbleDeps.mgetOrPut(w.url.projectName,
                              initHashSet[string]()).incl(nx.url.projectName)
        trace w.url.projectName, "exporting nimble " & w.url.url
        let deps = nimbleDeps.getOrDefault(w.url.projectName)
        genLockEntry nlf, w, getCfgPath(g, w), deps

  let nimcfgPath = workspace / NimCfg
  if fileExists(nimcfgPath):
    lf.nimcfg = readFile($nimcfgPath).splitLines()

  let nimblePaths = findNimbleFile(workspace)
  if nimblePaths.len() == 1 and nimblePaths[0].string.len > 0 and nimblePaths[0].fileExists():
    lf.nimbleFile = LockedNimbleFile(
      filename: nimblePaths[0].relativePath(workspace),
      content: readFile($nimblePaths[0]).splitLines())

  if not exportNimble:
    write lf, $lockFile
  else:
    write nlf, $lockFile

proc pinWorkspace*(lockFile: Path) =
  info "pin", "pinning workspace: " & $context().workspace
  var g = createGraphFromWorkspace(context().workspace)
  var nc = createNimbleContext()
  expandWithoutClone g, nc
  pinGraph g, lockFile

proc pinProject*(lockFile: Path, exportNimble = false) =
  ## Pin project using deps starting from the current project directory.
  ##
  info "pin", "pinning project"

  var g = createGraph(createUrl($context().currentDir, context().overrides))
  var nc = createNimbleContext()
  expandWithoutClone g, nc
  pinGraph g, lockFile

proc compareVersion(key, wanted, got: string) =
  if wanted != got:
    warn key, "environment mismatch: " &
      " versions differ: previously used: " & wanted & " but now at: " & got

proc convertNimbleLock*(nimble: Path): LockFile =
  ## converts nimble lock file into a Atlas lockfile
  ##
  let jsonAsStr = readFile($nimble)
  let jsonTree = parseJson(jsonAsStr)

  if jsonTree.getOrDefault("version") == nil or
      "packages" notin jsonTree:
    error nimble, "invalid nimble lockfile"
    return

  result = newLockFile()
  for (name, info) in jsonTree["packages"].pairs:
    if name == "nim":
      result.nimVersion = info["version"].getStr
    else:
      # lookup package using url
      let pkgurl = info["url"].getStr
      info name, " imported "
      let u = createUrl(pkgurl, context().overrides)
      let dir = context().depsDir / u.projectName.Path 
      result.items[name] = LockFileEntry(
        dir: dir.relativePath(context().projectDir),
        url: pkgurl,
        commit: info["vcsRevision"].getStr
      )

proc convertAndSaveNimbleLock*(nimble, lockFile: Path) =
  ## convert and save a nimble.lock into an Atlast lockfile
  let lf = convertNimbleLock(nimble)
  write lf, $lockFile

proc listChanged*(lockFile: Path) =
  ## replays the given lockfile by cloning and updating all the deps
  ##
  ## this also includes updating the nim.cfg and nimble file as well
  ## if they're included in the lockfile
  ##
  let lf = if lockFile == NimbleLockFileName:
              convertNimbleLock(lockFile)
           else:
              readLockFile(lockFile)

  let base = splitPath(lockFile).head

  # update the the dependencies
  for _, v in pairs(lf.items):
    let dir = base / v.dir
    if not dirExists(dir):
      warn dir, "repo missing!"
      continue
    withDir $dir:
      let url = $getRemoteUrl(dir)
      if v.url != url:
        warn v.dir, "remote URL has been changed;" &
                       " found: " & url &
                       " lockfile has: " & v.url

      let commit = currentGitCommit(dir)
      if commit != v.commit:
        #let info = parseNimble(pkg.nimble)
        warn dir, "commit differs;" &
                     " found: " & commit &
                     " lockfile has: " & v.commit

  if lf.hostOS == system.hostOS and lf.hostCPU == system.hostCPU:
    compareVersion "nim", lf.nimVersion, detectNimVersion()
    compareVersion "gcc", lf.gccVersion, detectGccVersion()
    compareVersion "clang", lf.clangVersion, detectClangVersion()

proc withoutSuffix(s, suffix: string): string =
  result = s
  if result.endsWith(suffix):
    result.setLen result.len - suffix.len

proc replay*(lockFile: Path) =
  ## replays the given lockfile by cloning and updating all the deps
  ##
  ## this also includes updating the nim.cfg and nimble file as well
  ## if they're included in the lockfile
  ##
  let lf = if lockFile == NimbleLockFileName:
              convertNimbleLock(lockFile)
           else:
              readLockFile(lockFile)

  #let lfBase = splitPath(lockFilePath).head
  var genCfg = CfgHere in context().flags

  # update the nim.cfg file
  if lf.nimcfg.len > 0:
    writeFile($(context().currentDir / NimCfg), lf.nimcfg.join("\n"))
  else:
    genCfg = true

  # update the nimble file
  if lf.nimbleFile.filename.string.len > 0:
    writeFile($(context().currentDir / lf.nimbleFile.filename),
              lf.nimbleFile.content.join("\n"))

  # update the the dependencies
  var paths: seq[CfgPath] = @[]
  for _, v in pairs(lf.items):
    trace "replay", "replaying: " & v.repr
    let dir = fromPrefixedPath(v.dir)
    if not dirExists(dir):
      let (status, err) = cloneUrl(createUrl(v.url, context().overrides), dir, false)
      if status != Ok:
        error lockFile, err
        continue
    withDir $dir:
      let url = $getRemoteUrl(dir)
      if url.withoutSuffix(".git") != url:
        if IgnoreUrls in context().flags:
          warn v.dir, "remote URL differs from expected: got: " &
            url & " but expected: " & v.url
        else:
          error v.dir, "remote URL has been compromised: got: " &
            url & " but wanted: " & v.url
      checkoutGitCommitFull(dir, v.commit, FullClones in context().flags)

      if genCfg:
        paths.add findCfgDir(dir)

  if genCfg:
    # this allows us to re-create a nim.cfg that uses the paths from the users workspace
    # without needing to do a `installDependencies` or `traverseLoop`
    let cfgPath = if genCfg: CfgPath context().currentDir else: findCfgDir()
    patchNimCfg(paths, cfgPath)

  if lf.hostOS == system.hostOS and lf.hostCPU == system.hostCPU:
    compareVersion "nim", lf.nimVersion, detectNimVersion()
    compareVersion "gcc", lf.gccVersion, detectGccVersion()
    compareVersion "clang", lf.clangVersion, detectClangVersion()
