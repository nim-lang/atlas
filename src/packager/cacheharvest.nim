#
#           Atlas Package Cloner
#        (c) Copyright 2026 The Atlas contributors
#

## Harvest package release caches for packages in a packages.json list.

import std/[json, locks, os, paths, sets, threadpool, times]

import ../basic/[context, dependencycache, nimblecontext, packageinfos, reporters, versions]
import ../registryreleaseinfo
import ./archivehelpers

export archivehelpers

type
  HarvestSummary* = object
    packagesSeen*: int
    aliasesSkipped*: int
    packagesProcessed*: int
    packagesFailed*: int
    failures*: seq[HarvestFailure]

  PackageQueue = object
    lock: Lock
    packages: seq[PackageInfo]
    next: int

  PackageHarvestResult = object
    ok: bool
    packageName: string
    latestCommit: string
    releaseCount: int
    digest: JsonNode

  HarvestFailure* = object
    packageName*: string
    errorMessage*: string

  HarvestWorkerResult = object
    packagesProcessed: int
    packagesFailed: int
    packageResults: seq[PackageHarvestResult]
    failures: seq[HarvestFailure]

  ArchiveReleaseEntry = object
    ver: PackageVersion
    release: NimbleRelease
    isHead: bool

proc popPackage(queue: ptr PackageQueue; info: var PackageInfo): bool {.gcsafe.} =
  acquire(queue.lock)
  try:
    if queue.next < queue.packages.len:
      info = queue.packages[queue.next]
      inc queue.next
      result = true
  finally:
    release(queue.lock)

proc packageWorkspaceRoot(info: PackageInfo): Path =
  (depsDir() / Path(info.name)).absolutePath()

proc packageReleasesDir(workspaceRoot: Path): Path =
  workspaceRoot / Path"releases"

proc packageReleasesMetadataFile(workspaceRoot: Path): Path =
  workspaceRoot / Path"releases.json"

proc packageReleasesMetadataRelPath(info: PackageInfo): string =
  $Path(info.name) / "releases.json"

proc packageDigestFile(workspaceRoot: Path): Path =
  workspaceRoot / Path"digest.json"

proc packageDigestRelPath(info: PackageInfo): string =
  $Path(info.name) / "digest.json"

proc siblingTempPath(dest: Path): Path =
  let destDir = dest.parentDir()
  destDir / Path(".tmp." & dest.splitPath().tail.string)

proc writeTextFileAtomic(dest: Path; contents: string) =
  let destDir = dest.parentDir()
  if destDir.len > 0:
    createDir($destDir)

  let tmpPath = siblingTempPath(dest)
  try:
    writeFile($tmpPath, contents)
    moveFile($tmpPath, $dest)
  except:
    if fileExists($tmpPath):
      removeFile($tmpPath)
    raise

proc relativeIndexPath(baseDir: Path; path: Path): string =
  if path.isRelativeTo(baseDir):
    $(path.relativePath(baseDir))
  else:
    $path

proc cleanupClonedPackage(pkg: Package) =
  if pkg.isNil or pkg.ondisk.len == 0:
    return
  let depsRoot = depsDir()
  if pkg.ondisk != depsRoot and pkg.ondisk.isRelativeTo(depsRoot) and dirExists($pkg.ondisk):
    removeDir($pkg.ondisk)

proc loadPackageList*(packagesFile: Path): seq[PackageInfo] =
  let root = parseFile($packagesFile)
  for node in root:
    let info = packageinfos.fromJson(node)
    if info != nil:
      result.add info

proc copyPackageReleaseMetadata(pkg: Package; workspaceRoot: Path) =
  let cachePath = packageReleaseCachePath(pkg)
  if not fileExists($cachePath):
    raise newException(IOError, "missing release cache: " & $cachePath)
  createDir($workspaceRoot)
  let dest = packageReleasesMetadataFile(workspaceRoot)
  writeTextFileAtomic(dest, readFile($cachePath))

proc cleanupTransientReleaseCache(pkg: Package) =
  let cachePath = packageReleaseCachePath(pkg)
  if fileExists($cachePath):
    removeFile($cachePath)

proc headReleaseEntry(releaseInfo: PackageReleaseInfo): ArchiveReleaseEntry =
  let vtag = VersionTag(
    v: Version"#head",
    c: initCommitHash(releaseInfo.currentCommit, FromHead)
  )
  result.ver = vtag.toPkgVer()
  result.isHead = true

  for (ver, release) in releaseInfo.releases:
    if not ver.isNil and ver.vtag.commit == releaseInfo.currentCommit:
      result.release = release
      return

  result.release = NimbleRelease(version: Version"#head", status: Normal)

proc archiveReleaseEntries(releaseInfo: PackageReleaseInfo): seq[ArchiveReleaseEntry] =
  for (ver, release) in releaseInfo.releases:
    result.add ArchiveReleaseEntry(ver: ver, release: release)
  if releaseInfo.currentCommit.isEmpty():
    return

  for entry in result:
    if entry.isHead:
      return

  result.add headReleaseEntry(releaseInfo)

proc collectReleaseArchives(
    pkg: Package;
    info: PackageInfo;
    releaseInfo: PackageReleaseInfo;
    archiveDir: Path;
    compressions: openArray[ArchiveCompression];
    regenerateTarballs: bool
): JsonNode =
  result = newJArray()
  let workspaceRoot = archiveDir.parentDir()
  let existingEntries = loadExistingDigestEntries(packageDigestFile(workspaceRoot))
  createDir($archiveDir)
  var usedStems = initHashSet[string]()
  var referencedFiles = initHashSet[string]()
  for releaseEntry in archiveReleaseEntries(releaseInfo):
    let ver = releaseEntry.ver
    let release = releaseEntry.release
    if ver.isNil or ver.vtag.commit.h.len == 0:
      continue
    let baseName = archiveBaseName(pkg, info, release)
    let label = archiveReleaseLabel(ver, release, releaseEntry.isHead)
    let commitSuffix = archiveCommitLabel(ver)
    let rootSubdir = packageRootSubdir(pkg)
    let rootArchiveFiles = collectArchiveFiles(pkg, ver, info, release, rootSubdir)
    let hashStem = baseName & "-" & label & "-" & commitSuffix
    let hashTarPath = siblingTempPath(archiveDir / Path(hashStem & ".hash.tar"))
    var contentHash = ""
    try:
      writeTrackedReleaseTar(pkg, ver, hashTarPath, hashStem, rootArchiveFiles)
      contentHash = archiveContentHash(hashTarPath, hashStem & "/")
    finally:
      if fileExists($hashTarPath):
        removeFile($hashTarPath)
    let contentHashSuffix = sanitizeArchiveComponent(contentHash[0 .. 7])
    var rootStem =
      if releaseEntry.isHead:
        baseName & "-head-" & commitSuffix
      else:
        baseName & "-" & label & "-" & commitSuffix & "-" & contentHashSuffix
    if usedStems.containsOrIncl(rootStem):
      rootStem.add "-" & commitSuffix
      discard usedStems.containsOrIncl(rootStem)

    for compression in compressions:
      let compressionName = archiveCompressionName(compression)
      if not regenerateTarballs:
        let existingEntry = matchingDigestEntry(
          existingEntries,
          label,
          ver.vtag.commit.h,
          compressionName
        )
        if existingEntry != nil and "file" in existingEntry:
          let archiveFile = existingEntry["file"].getStr()
          let archivePath = archiveDir / Path(archiveFile)
          if fileExists($archivePath):
            referencedFiles.incl(archiveFile)
            result.add existingEntry
            continue

      let archiveFile = writeTrackedReleaseArchive(
        pkg, ver, archiveDir, rootStem, rootArchiveFiles, compression, siblingTempPath
      )
      let archivePath = archiveDir / Path(archiveFile)
      referencedFiles.incl(archiveFile)
      result.add initArchiveEntry(
        label,
        ver.vtag.commit.h,
        commitSuffix,
        contentHash,
        contentHashSuffix,
        compressionName,
        archiveFile,
        getFileSize($archivePath),
        rootSubdir,
        release
      )

  for kind, path in walkDir($archiveDir):
    if kind != pcFile:
      continue
    let filename = $path.Path.splitPath().tail
    if path.Path.splitFile().ext in [".gz", ".xz", ".tar"] and filename notin referencedFiles:
      removeFile(path)

proc writePackageDigest(
    workspaceRoot: Path;
    info: PackageInfo;
    latestCommit: string;
    releaseCount: int;
    digestEntries: JsonNode
) =
  var digest = newJObject()
  digest["generatedAt"] = %now().utc().format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  digest["name"] = %info.name
  digest["latestCommit"] = %latestCommit
  digest["releaseCount"] = %releaseCount
  digest["releasesPath"] = %"releases"
  digest["releasesMetadata"] = %"releases.json"
  digest["tarballs"] = digestEntries
  writeTextFileAtomic(packageDigestFile(workspaceRoot), pretty(digest))

proc writeIndex(
    metadataDir: Path;
    packagesFile: Path;
    summary: HarvestSummary;
    packages: JsonNode;
    ephemeral: bool;
    compressions: openArray[ArchiveCompression];
    packageName = "";
    packageNames: seq[string] = @[]
) =
  var index = newJObject()
  index["generatedAt"] = %now().utc().format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  index["packagesFile"] = %relativeIndexPath(metadataDir, packagesFile)
  index["releasesPath"] = %"{package}/releases"
  index["ephemeral"] = %ephemeral
  index["compressions"] = %archiveCompressionNames(compressions)
  if packageName.len > 0:
    index["package"] = %packageName
  elif packageNames.len > 0:
    index["packages"] = %(packageNames)
  index["packagesSeen"] = %summary.packagesSeen
  index["aliasesSkipped"] = %summary.aliasesSkipped
  index["packagesProcessed"] = %summary.packagesProcessed
  index["packagesFailed"] = %summary.packagesFailed
  index["packages"] = packages
  writeTextFileAtomic(metadataDir / Path("index.json"), pretty(index))

proc harvestPackage(
    nc: var NimbleContext;
    info: PackageInfo;
    metadataDir: Path;
    ephemeral: bool;
    compressions: openArray[ArchiveCompression];
    regenerateTarballs: bool
): PackageHarvestResult =
  notice "atlas:pkger", "processing package:", info.name
  let workspaceRoot = packageWorkspaceRoot(info)
  let previousContext = context()
  var packageContext = previousContext
  packageContext.depsDir = workspaceRoot
  createDir($packageContext.depsDir)
  setContext(packageContext)
  try:
    let releaseInfo = nc.loadRegistryPackageReleaseInfo(
      info,
      mode = AllReleases,
      onClone = DoClone
    )
    copyPackageReleaseMetadata(releaseInfo.package, workspaceRoot)
    let digestEntries = collectReleaseArchives(
      releaseInfo.package,
      info,
      releaseInfo.releaseInfo,
      packageReleasesDir(workspaceRoot),
      compressions,
      regenerateTarballs
    )
    result.ok = true
    result.packageName = info.name
    result.latestCommit = releaseInfo.releaseInfo.currentCommit.h
    result.releaseCount = releaseInfo.releaseInfo.releases.len
    result.digest = digestEntries
    cleanupTransientReleaseCache(releaseInfo.package)
    if ephemeral:
      cleanupClonedPackage(releaseInfo.package)
  finally:
    setContext(previousContext)

proc harvestWorker(
    queue: ptr PackageQueue;
    baseContext: AtlasContext;
    metadataDir: Path;
    ephemeral: bool;
    compressions: seq[ArchiveCompression];
    regenerateTarballs: bool
): HarvestWorkerResult {.gcsafe.} =
  setContext(baseContext)
  var nc = block:
    {.cast(gcsafe).}:
      createNimbleContext()
  var info: PackageInfo
  while popPackage(queue, info):
    try:
      let packageResult = block:
        {.cast(gcsafe).}:
          nc.harvestPackage(info, metadataDir, ephemeral, compressions, regenerateTarballs)
      if packageResult.ok:
        result.packageResults.add packageResult
        inc result.packagesProcessed
    except CatchableError as e:
      result.failures.add HarvestFailure(packageName: info.name, errorMessage: e.msg)
      inc result.packagesFailed

proc harvestRegistryCaches*(
    packagesFile: Path;
    metadataDir: Path;
    ephemeral: bool,
    pkgNames: seq[string];
    ignoredPkgNames: seq[string];
    compressions: openArray[ArchiveCompression];
    threadCount: int;
    regenerateTarballs: bool = false
): HarvestSummary =
  createDir($metadataDir)

  let packageList = loadPackageList(packagesFile)
  var packageInfoByName = initTable[string, PackageInfo]()
  var queue: PackageQueue
  initLock(queue.lock)
  var packagesIndex = newJArray()

  result.packagesSeen = packageList.len
  for info in packageList:
    packageInfoByName[info.name] = info
    if info.kind == pkAlias:
      inc result.aliasesSkipped
      continue
    elif pkgNames.len() > 0 and info.name notin pkgNames:
      continue
    elif info.name in ignoredPkgNames:
      continue

    queue.packages.add info

  let workerCount = max(1, min(threadCount, max(1, queue.packages.len)))
  let baseContext = context()
  let compressionList = @compressions
  if workerCount == 1:
    let workerResult = harvestWorker(
      addr queue,
      baseContext,
      metadataDir,
      ephemeral,
      compressionList,
      regenerateTarballs
    )
    result.packagesProcessed += workerResult.packagesProcessed
    result.packagesFailed += workerResult.packagesFailed
    for failure in workerResult.failures:
      result.failures.add failure
      error "atlas:pkger", "failed package:", failure.packageName, "error:", failure.errorMessage
    for packageResult in workerResult.packageResults:
      let info = packageInfoByName[packageResult.packageName]
      let workspaceRoot = packageWorkspaceRoot(info)
      writePackageDigest(
        workspaceRoot,
        info,
        packageResult.latestCommit,
        packageResult.releaseCount,
        packageResult.digest
      )
      var entry = newJObject()
      entry["name"] = %packageResult.packageName
      entry["latestCommit"] = %packageResult.latestCommit
      entry["releaseCount"] = %packageResult.releaseCount
      entry["digest"] = %packageDigestRelPath(info)
      entry["releasesMetadata"] = %packageReleasesMetadataRelPath(info)
      entry["processedAt"] = %now().utc().format("yyyy-MM-dd'T'HH:mm:ss'Z'")
      packagesIndex.add entry
  else:
    setMaxPoolSize(workerCount)
    var workers: seq[FlowVar[HarvestWorkerResult]]
    for _ in 0..<workerCount:
      workers.add spawn harvestWorker(
        addr queue,
        baseContext,
        metadataDir,
        ephemeral,
        compressionList,
        regenerateTarballs
      )
    for worker in workers:
      let workerResult = ^worker
      result.packagesProcessed += workerResult.packagesProcessed
      result.packagesFailed += workerResult.packagesFailed
      for failure in workerResult.failures:
        result.failures.add failure
        error "atlas:pkger", "failed package:", failure.packageName, "error:", failure.errorMessage
      for packageResult in workerResult.packageResults:
        let info = packageInfoByName[packageResult.packageName]
        let workspaceRoot = packageWorkspaceRoot(info)
        writePackageDigest(
          workspaceRoot,
          info,
          packageResult.latestCommit,
          packageResult.releaseCount,
          packageResult.digest
        )
        var entry = newJObject()
        entry["name"] = %packageResult.packageName
        entry["latestCommit"] = %packageResult.latestCommit
        entry["releaseCount"] = %packageResult.releaseCount
        entry["digest"] = %packageDigestRelPath(info)
        entry["releasesMetadata"] = %packageReleasesMetadataRelPath(info)
        entry["processedAt"] = %now().utc().format("yyyy-MM-dd'T'HH:mm:ss'Z'")
        packagesIndex.add entry
  deinitLock(queue.lock)

  writeIndex(
    metadataDir,
    packagesFile,
    result,
    packagesIndex,
    ephemeral,
    compressions,
    packageNames = pkgNames
  )
