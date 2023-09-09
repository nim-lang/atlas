#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Lockfile implementation.

import std / [sequtils, strutils, algorithm, tables, os, json, jsonutils, sha1]
import context, gitops, osutils, traversal, compilerversions, nameresolver, configutils

type
  LockFileEntry* = object
    dir*: string
    url*: string
    commit*: string
    version*: string

  LockedNimbleFile* = object
    filename*: string
    content*: seq[string]

  LockFile* = object # serialized as JSON
    items*: OrderedTable[string, LockFileEntry]
    nimcfg*: seq[string]
    nimbleFile*: LockedNimbleFile
    hostOS*, hostCPU*: string
    nimVersion*, gccVersion*, clangVersion*: string

proc convertKeyToArray(jsonTree: var JsonNode, path: varargs[string]) =
  var parent: JsonNode
  var content: JsonNode = jsonTree
  for key in path:
    if content.hasKey(key):
      parent = content
      content = parent[key]
    else:
      return 

  if content.kind == JString:
    var contents = newJArray()
    for line in content.getStr.split("\n"):
      contents.add(% line)
    parent[path[^1]] = contents

proc readLockFile(filename: string): LockFile =
  let jsonAsStr = readFile(filename)
  var jsonTree = parseJson(jsonAsStr)

  # convert older non-array file contents to JArray
  jsonTree.convertKeyToArray("nimcfg")
  jsonTree.convertKeyToArray("nimbleFile", "content")
  result = jsonTo(jsonTree, LockFile,
    Joptions(allowExtraKeys: true, allowMissingKeys: true))

proc write(lock: LockFile; lockFilePath: string) =
  writeFile lockFilePath, toJson(lock).pretty

proc prefixedPath*(c: var AtlasContext, path: string): string =
  let parts = path.splitPath
  if path.isRelativeTo(c.depsDir):
    return "$deps" / parts.tail
  elif path.isRelativeTo(c.workspace):
    return "$workspace" / parts.tail
  else:
    return path

proc fromPrefixedPath*(c: var AtlasContext, path: string): string =
  var path = path
  if path.startsWith("$deps"):
    path.removePrefix("$deps")
    return c.depsDir / path
  elif path.startsWith("$workspace"):
    path.removePrefix("$workspace")
    return c.workspace / path
  else:
    return c.depsDir / path

proc genLockEntry(c: var AtlasContext; lf: var LockFile; pkg: Package) =
  let info = extractRequiresInfo(pkg.nimble.string)
  let url = getRemoteUrl()
  let commit = getCurrentCommit()
  let name = pkg.name.string
  let pth = c.prefixedPath(pkg.path.string)
  lf.items[name] = LockFileEntry(dir: pth, url: $url, commit: commit, version: info.version)

proc genLockEntriesForDir(c: var AtlasContext; lf: var LockFile; dir: string) =
  for k, f in walkDir(dir):
    if k == pcDir and dirExists(f / ".git"):
      if f.absolutePath == c.workspace / "packages":
        # skipping this gives us the locking behavior for a project
        # TODO: is this what we want?
        # we could just create a fake Package item here
        continue
      withDir c, f:
        let path = "file://" & f
        debug c, toRepo("genLocKEntries"), "using pkg: " & path
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
                  pkg: Package,
                  cfg: CfgPath,
                  deps: HashSet[PackageName]) =
  let info = extractRequiresInfo(pkg.nimble.string)
  let url = getRemoteUrl()
  let commit = getCurrentCommit()
  let name = pkg.name.string
  infoNow c, pkg, "calculating nimble checksum"
  let chk = c.nimbleChecksum(pkg, cfg)
  lf.packages[name] = NimbleLockFileEntry(
    version: info.version,
    vcsRevision: commit,
    url: $url,
    downloadMethod: "git",
    dependencies: deps.mapIt(it.string),
    checksums: {"sha1": chk}.toTable
  )

const
  NimCfg = "nim.cfg"

proc pinWorkspace*(c: var AtlasContext; lockFilePath: string) =
  info c, toRepo("pin"), "pinning workspace: " & $c.workspace
  var lf = newLockFile()
  genLockEntriesForDir(c, lf, c.workspace)
  if c.workspace != c.depsDir and c.depsDir.len > 0:
    genLockEntriesForDir c, lf, c.depsDir

  let nimcfgPath = c.workspace / NimCfg
  if fileExists(nimcfgPath):
    lf.nimcfg = readFile(nimcfgPath).splitLines()

  let nimblePath = c.workspace / c.workspace.lastPathComponent & ".nimble"
  if fileExists nimblePath:
    lf.nimbleFile = LockedNimbleFile(
      filename: nimblePath.relativePath(c.workspace),
      content: readFile(nimblePath).splitLines())

  write lf, lockFilePath

proc pinProject*(c: var AtlasContext; lockFilePath: string, exportNimble = false) =
  ## Pin project using deps starting from the current project directory. 
  ##
  info c, toRepo("pin"), "pinning project"
  var lf = newLockFile()
  let startPkg = resolvePackage(c, "file://" & c.currentDir)
  var g = createGraph(c, startPkg)

  # only used for exporting nimble locks
  var nlf = newNimbleLockFile()
  var nimbleDeps = newTable[PackageName, HashSet[PackageName]]()
  var cfgs = newTable[PackageName, CfgPath]()

  info c, startPkg, "pinning lockfile: " & lockFilePath
  var i = 0
  while i < g.nodes.len:
    let w = g.nodes[i]

    info c, w.pkg, "pinning: " & $w.pkg

    if not w.pkg.exists:
      error c, w.pkg, "dependency does not exist"
    else:
      # assume this is the selected version, it might get overwritten later:
      selectNode c, g, w
      let cfgPath = collectNewDeps(c, g, i, w)
      cfgs[w.pkg.name] = cfgPath
    inc i

  if c.errors == 0:
    # topo-sort:
    for i in countdown(g.nodes.len-1, 1):
      if g.nodes[i].active:
        let w = g.nodes[i]
        let dir = w.pkg.path.string
        tryWithDir c, dir:
          if not exportNimble:
            # generate atlas native lockfile entries
            genLockEntry c, lf, w.pkg
          else:
            # handle exports for Nimble; these require lookig up a bit more info
            for nx in g.nodes: # expensive, but eh
              if nx.active and i in nx.parents:
                nimbleDeps.mgetOrPut(w.pkg.name,
                                    initHashSet[PackageName]()).incl(nx.pkg.name)
            trace c, w.pkg, "exporting nimble " & w.pkg.name.string
            let name = w.pkg.name
            let deps = nimbleDeps.getOrDefault(name)
            genLockEntry c, nlf, w.pkg, cfgs[name], deps

    let nimcfgPath = c.currentDir / NimCfg
    if fileExists(nimcfgPath):
      lf.nimcfg = readFile(nimcfgPath).splitLines()

    let nimblePath = startPkg.nimble.string
    if nimblePath.len() > 0 and nimblePath.fileExists():
      lf.nimbleFile = LockedNimbleFile(
        filename: nimblePath.relativePath(c.currentDir),
        content: readFile(nimblePath).splitLines())

    if not exportNimble:
      write lf, lockFilePath
    else:
      write nlf, lockFilePath

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
  for (name, info) in jsonTree["packages"].pairs:
    if name == "nim":
      result.nimVersion = info["version"].getStr
      continue
    # lookup package using url
    let pkg = c.resolvePackage(info["url"].getStr)
    info c, toRepo(name), " imported "
    let dir = c.depsDir / pkg.repo.string
    result.items[name] = LockFileEntry(
      dir: dir.relativePath(c.projectDir),
      url: $pkg.url,
      commit: info["vcsRevision"].getStr,
    )


proc convertAndSaveNimbleLock*(c: var AtlasContext; nimblePath, lockFilePath: string) =
  ## convert and save a nimble.lock into an Atlast lockfile
  let lf = convertNimbleLock(c, nimblePath)
  write lf, lockFilePath

proc listChanged*(c: var AtlasContext; lockFilePath: string) =
  ## replays the given lockfile by cloning and updating all the deps
  ## 
  ## this also includes updating the nim.cfg and nimble file as well
  ## if they're included in the lockfile
  ## 
  let lf = if lockFilePath == "nimble.lock": convertNimbleLock(c, lockFilePath)
           else: readLockFile(lockFilePath)

  let base = splitPath(lockFilePath).head

  # update the the dependencies
  for _, v in pairs(lf.items):
    let dir = base / v.dir
    if not dirExists(dir):
      warn c, toRepo(dir), "repo missing!"
      continue
    withDir c, dir:
      let url = $getRemoteUrl()
      if v.url != url:
        warn c, toRepo(v.dir), "remote URL has been changed;" &
                                  " found: " & url &
                                  " lockfile has: " & v.url
      
      let commit = gitops.getCurrentCommit()
      if commit != v.commit:
        let pkg = c.resolvePackage("file://" & dir)
        c.resolveNimble(pkg)
        let info = parseNimble(c, pkg.nimble)
        warn c, toRepo(dir), "commit differs;" &
                                            " found: " & commit &
                                            " (" & info.version & ")" &
                                            " lockfile has: " & v.commit

  if lf.hostOS == system.hostOS and lf.hostCPU == system.hostCPU:
    compareVersion c, "nim", lf.nimVersion, detectNimVersion()
    compareVersion c, "gcc", lf.gccVersion, detectGccVersion()
    compareVersion c, "clang", lf.clangVersion, detectClangVersion()

proc replay*(c: var AtlasContext; lockFilePath: string) =
  ## replays the given lockfile by cloning and updating all the deps
  ## 
  ## this also includes updating the nim.cfg and nimble file as well
  ## if they're included in the lockfile
  ## 
  let lf = if lockFilePath == "nimble.lock": convertNimbleLock(c, lockFilePath)
           else: readLockFile(lockFilePath)

  let lfBase = splitPath(lockFilePath).head
  var genCfg = true

  # update the nim.cfg file
  if lf.nimcfg.len > 0:
    writeFile(lfBase / NimCfg, lf.nimcfg.join("\n"))
    genCfg = false
  # update the nimble file
  if lf.nimbleFile.filename.len > 0:
    writeFile(lfBase / lf.nimbleFile.filename,
              lf.nimbleFile.content.join("\n"))
  
  genCfg = CfgHere in c.flags or genCfg
    # info c, toRepo("replay"), "setting up nim.cfg"
    # let nimbleFile = findCurrentNimble()
    # trace c, toRepo("replay"), "using nimble file: " & nimbleFile
    # installDependencies(c, nimbleFile, startIsDep = true)

  # update the the dependencies
  for _, v in pairs(lf.items):
    trace c, toRepo("replay"), "replaying: " & v.repr
    let dir = c.fromPrefixedPath(v.dir)
    if not dirExists(dir):
      let (status, err) = c.cloneUrl(getUrl v.url, dir, false)
      if status != Ok:
        error c, toRepo(lockFilePath), err
        continue
    withDir c, dir:
      let url = $getRemoteUrl()
      if $v.url.getUrl() != url:
        error c, toRepo(v.dir), "remote URL has been compromised: got: " &
            url & " but wanted: " & v.url
      checkoutGitCommit(c, toRepo(dir), v.commit)

      # parseNimble()
      # nimbleInfo.srcDir

  # let cfgPath = if genCfg: CfgPath c.currentDir else: findCfgDir(c)
  # patchNimCfg(c, paths, cfgPath)

  if lf.hostOS == system.hostOS and lf.hostCPU == system.hostCPU:
    compareVersion c, "nim", lf.nimVersion, detectNimVersion()
    compareVersion c, "gcc", lf.gccVersion, detectGccVersion()
    compareVersion c, "clang", lf.clangVersion, detectClangVersion()
