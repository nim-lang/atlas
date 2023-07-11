#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Lockfile implementation.

import std / [strutils, algorithm, tables, os, json, jsonutils, sha1]
import context, gitops, osutils, traversal, compilerversions, nameresolver

type
  LockFileEntry* = object
    dir*: string
    url*: string
    commit*: string

  LockedNimbleFile* = object
    filename*, content*: string

  LockFile* = object # serialized as JSON
    items*: OrderedTable[string, LockFileEntry]
    nimcfg*: string
    nimbleFile*: LockedNimbleFile
    hostOS*, hostCPU*: string
    nimVersion*, gccVersion*, clangVersion*: string

proc readLockFile(filename: string): LockFile =
  let jsonAsStr = readFile(filename)
  let jsonTree = parseJson(jsonAsStr)
  result = jsonTo(jsonTree, LockFile,
    Joptions(allowExtraKeys: true, allowMissingKeys: true))

proc write(lock: LockFile; lockFilePath: string) =
  writeFile lockFilePath, toJson(lock).pretty

proc genLockEntry(c: var AtlasContext; lf: var LockFile; dir: string) =
  let url = getRemoteUrl()
  let commit = getCurrentCommit()
  let name = dir.lastPathComponent
  lf.items[name] = LockFileEntry(dir: dir, url: $url, commit: commit)

proc genLockEntriesForDir(c: var AtlasContext; lf: var LockFile; dir: string) =
  for k, f in walkDir(dir):
    if k == pcDir and dirExists(f / ".git"):
      withDir c, f:
        genLockEntry c, lf, f.relativePath(dir, '/')

const
  NimCfg = "nim.cfg"

proc newLockFile(): LockFile =
  result = LockFile(items: initOrderedTable[string, LockFileEntry](),
    hostOS: system.hostOS, hostCPU: system.hostCPU,
    nimVersion: detectNimVersion(),
    gccVersion: detectGccVersion(),
    clangVersion: detectClangVersion())

proc pinWorkspace*(c: var AtlasContext; lockFilePath: string) =
  var lf = newLockFile()
  genLockEntriesForDir(c, lf, c.workspace)
  if c.workspace != c.depsDir and c.depsDir.len > 0:
    genLockEntriesForDir c, lf, c.depsDir

  let nimcfgPath = c.workspace / NimCfg
  if fileExists(nimcfgPath):
    lf.nimcfg = readFile(nimcfgPath)

  let nimblePath = c.workspace / c.workspace.lastPathComponent & ".nimble"
  if fileExists nimblePath:
    lf.nimbleFile = LockedNimbleFile(
      filename: c.workspace.lastPathComponent & ".nimble",
      content: readFile(nimblePath))

  write lf, lockFilePath

proc pinProject*(c: var AtlasContext; lockFilePath: string) =
  var lf = newLockFile()

  let start = resolvePackage(c, "file://" & c.currentDir)
  let url = getRemoteUrl()
  var g = createGraph(c, start)

  info c, start, "pinning lockfile: " & lockFilePath

  var i = 0
  while i < g.nodes.len:
    let w = g.nodes[i]

    info c, w.pkg, "pinning..."

    if not w.pkg.exists:
      error c, w.pkg, "dependency does not exist"
    else:
      # assume this is the selected version, it might get overwritten later:
      selectNode c, g, w
      discard collectNewDeps(c, g, i, w)
    inc i

  if c.errors == 0:
    # topo-sort:
    for i in countdown(g.nodes.len-1, 1):
      if g.nodes[i].active:
        let w = g.nodes[i]
        let dir = w.pkg.path.string
        tryWithDir c, dir:
          genLockEntry c, lf, dir.relativePath(c.currentDir, '/')

    let nimcfgPath = c.currentDir / NimCfg
    if fileExists(nimcfgPath):
      lf.nimcfg = readFile(nimcfgPath)

    let nimblePath = c.currentDir / c.currentDir.lastPathComponent & ".nimble"
    if fileExists nimblePath:
      lf.nimbleFile = LockedNimbleFile(
        filename: c.currentDir.lastPathComponent & ".nimble",
        content: readFile(nimblePath))

    write lf, lockFilePath

proc compareVersion(c: var AtlasContext; key, wanted, got: string) =
  if wanted != got:
    warn c, toRepo(key), "environment mismatch: " &
      " versions differ: previously used: " & wanted & " but now at: " & got

proc convertNimbleLock*(c: var AtlasContext; nimblePath: string): LockFile =
  ## converts nimble lock file into a Atlas lockfile
  ## 
  let jsonAsStr = readFile(nimblePath)
  let jsonTree = parseJson(jsonAsStr)

  if jsonTree.getOrDefault("version") == nil or
      "packages" notin jsonTree:
    error c, toRepo(nimblePath), "invalid nimble lockfile"
    return

  result = newLockFile()
  for (name, pkg) in jsonTree["packages"].pairs:
    info c, toRepo(name), " imported "
    let dir = c.depsDir / name
    result.items[name] = LockFileEntry(
      dir: dir,
      url: pkg["url"].getStr,
      commit: pkg["vcsRevision"].getStr,
    )

proc updateSecureHash(
    checksum: var Sha1State,
    c: var AtlasContext;
    pkg: Package,
    name: string
) =
  let path = pkg.path.string / name
  if not path.fileExists(): return
  checksum.update(name)

  if symlinkExists(path):
    # checksum file path (?)
    try:
      let path = expandSymlink(path)
      checksum.update(path)
    except OSError:
      error c, pkg, "cannot follow symbolic link " & path
  else:
    # checksum file contents
    var file: File
    try:
      file = path.open(fmRead)
      const bufferSize = 8192
      var buffer = newString(bufferSize)
      while true:
        var bytesRead = readChars(file, buffer)
        if bytesRead == 0: break
        checksum.update(buffer.toOpenArray(0, bytesRead - 1))
    except IOError:
      error c, pkg, "error opening file " & path
    finally:
      file.close()

proc nimbleChecksum*(c: var AtlasContext, pkg: Package, cfg: CfgPath): string =
  ## calculate a nimble style checksum from a `CfgPath`.
  ##
  ## Useful for exporting a Nimble sync file.
  ##
  let res = c.listFiles(pkg)
  if res.isNone:
    error c, pkg, "couldn't list files"
  else:
    var files = res.get().sorted()
    var checksum = newSha1State()
    for file in files:
      checksum.updateSecureHash(c, pkg, file)
    result = toLowerAscii($SecureHash(checksum.finalize()))

proc convertAndSaveNimbleLock*(c: var AtlasContext; nimblePath, lockFilePath: string) =
  ## convert and save a nimble.lock into an Atlast lockfile
  let lf = convertNimbleLock(c, nimblePath)
  write lf, lockFilePath

proc replay*(c: var AtlasContext; lockFilePath: string) =
  ## replays the given lockfile by cloning and updating all the deps
  ## 
  ## this also includes updating the nim.cfg and nimble file as well
  ## if they're included in the lockfile
  ## 
  let lf = if lockFilePath == "nimble.lock": convertNimbleLock(c, lockFilePath)
           else: readLockFile(lockFilePath)

  let base = splitPath(lockFilePath).head
  # update the nim.cfg file
  if lf.nimcfg.len > 0:
    writeFile(base / NimCfg, lf.nimcfg)
  # update the nimble file
  if lf.nimbleFile.filename.len > 0:
    writeFile(base / lf.nimbleFile.filename, lf.nimbleFile.content)
  # update the the dependencies
  for _, v in pairs(lf.items):
    let dir = base / v.dir
    if not dirExists(dir):
      let (status, err) = c.cloneUrl(getUrl v.url, dir, false)
      if status != Ok:
        error c, toRepo(lockFilePath), err
        continue
    withDir c, dir:
      let url = $getRemoteUrl()
      if v.url != url:
        error c, toRepo(v.dir), "remote URL has been compromised: got: " &
            url & " but wanted: " & v.url
      checkoutGitCommit(c, toRepo(dir), v.commit)

  if lf.hostOS == system.hostOS and lf.hostCPU == system.hostCPU:
    compareVersion c, "nim", lf.nimVersion, detectNimVersion()
    compareVersion c, "gcc", lf.gccVersion, detectGccVersion()
    compareVersion c, "clang", lf.clangVersion, detectClangVersion()
