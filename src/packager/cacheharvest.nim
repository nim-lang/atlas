#
#           Atlas Package Cloner
#        (c) Copyright 2026 The Atlas contributors
#

## Harvest package release caches for packages in a packages.json list.

import std/[json, locks, os, osproc, paths, sequtils, sets, strutils, threadpool, times]

import ../basic/[context, dependencycache, gitops, nimblechecksums, nimblecontext, packageinfos, pkgurls, reporters]
import ../registryreleaseinfo

type
  HarvestSummary* = object
    packagesSeen*: int
    aliasesSkipped*: int
    packagesProcessed*: int
    packagesFailed*: int

  ArchiveCompression* = enum
    acGzip
    acXz

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

  HarvestFailure = object
    packageName: string
    errorMessage: string

  HarvestWorkerResult = object
    packagesProcessed: int
    packagesFailed: int
    packageResults: seq[PackageHarvestResult]
    failures: seq[HarvestFailure]

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

proc sanitizeArchiveComponent(value: string): string =
  result = value
  for c in mitems(result):
    if c notin {'a'..'z', 'A'..'Z', '0'..'9', '.', '_', '-'}:
      c = '-'
  while result.contains("--"):
    result = result.replace("--", "-")
  result = result.strip(chars = {'-', '.'})

proc archiveCompressionExtension*(compression: ArchiveCompression): string =
  case compression
  of acGzip: ".tar.gz"
  of acXz: ".tar.xz"

proc compressionTempPath(tarPath: Path; compression: ArchiveCompression): Path =
  case compression
  of acGzip: tarPath.parentDir() / Path(tarPath.splitPath().tail.string & ".gz")
  of acXz: tarPath.parentDir() / Path(tarPath.splitPath().tail.string & ".xz")

proc archiveCompressionName*(compression: ArchiveCompression): string =
  case compression
  of acGzip: "gzip"
  of acXz: "xz"

proc archiveCompressionNames*(compressions: openArray[ArchiveCompression]): seq[string] =
  for compression in compressions:
    result.add archiveCompressionName(compression)

proc archiveBaseName(pkg: Package; info: PackageInfo; release: NimbleRelease): string =
  result = info.name
  if not release.isNil and release.name.len > 0:
    result = release.name
  elif pkg.name.len > 0:
    result = pkg.name
  elif pkg.projectName.len > 0:
    result = pkg.projectName
  result = sanitizeArchiveComponent(result)
  if result.len == 0:
    result = "package"

proc archiveReleaseLabel(ver: PackageVersion; release: NimbleRelease): string =
  if not release.isNil and release.version.string.len > 0 and release.version.string != "#head":
    result = release.version.string
  elif ver.vtag.version.string.len > 0 and ver.vtag.version.string != "#head":
    result = ver.vtag.version.string
  elif ver.vtag.commit.h.len > 0:
    result = ver.vtag.commit.short()
  else:
    result = "head"
  result = sanitizeArchiveComponent(result)
  if result.len == 0:
    result = "head"

proc archiveCommitLabel(ver: PackageVersion): string =
  result = sanitizeArchiveComponent(ver.vtag.commit.short())
  if result.len == 0:
    result = "unknown"

proc octalField(value: string): int =
  for c in value:
    if c in {'0'..'7'}:
      result = result * 8 + ord(c) - ord('0')

proc tarEntryName(header: string): string =
  result = header[0 ..< 100].strip(chars = {'\0'})
  let prefix = header[345 ..< 500].strip(chars = {'\0'})
  if prefix.len > 0:
    result = prefix & "/" & result

proc archiveContentHash(tarPath: Path; archivePrefix: string): string =
  let tar = readFile($tarPath)
  var offset = 0
  var entries: seq[(string, string)] = @[]
  while offset + 512 <= tar.len:
    let header = tar[offset ..< offset + 512]
    if header.allIt(it == '\0'):
      break

    var name = tarEntryName(header)
    if name.startsWith(archivePrefix):
      name = name[archivePrefix.len .. ^1]
    let size = octalField(header[124 ..< 136])
    let kind = header[156]
    let dataOffset = offset + 512
    case kind
    of '\0', '0':
      entries.add((name, tar[dataOffset ..< dataOffset + size]))
    of '2':
      entries.add((name, header[157 ..< 257].strip(chars = {'\0'})))
    else:
      discard

    offset = dataOffset + ((size + 511) div 512) * 512
  result = nimbleChecksumForEntries(entries)

proc packageRootSubdir(pkg: Package): Path =
  let packageSubdir =
    if pkg.subdir.len > 0: pkg.subdir
    else: pkg.url.subdir()
  result = packageSubdir

proc archiveTrackedFiles(pkg: Package; commit: CommitHash; subdir: Path): seq[string] =
  let subdirPrefix =
    if subdir.len > 0: $subdir & "/"
    else: ""

  for file in listFiles(pkg.ondisk, commit):
    if file.len == 0:
      continue
    if subdirPrefix.len == 0 or file == $subdir or file.startsWith(subdirPrefix):
      result.add file

proc runArchiveCommand(command: string): int =
  var process = startProcess(command, options = {poParentStreams, poUsePath, poEvalCommand})
  result = waitForExit(process)
  close(process)

proc runArchiveCommand(command: string; args: openArray[string]): int =
  var process = startProcess(command, args = args, options = {poParentStreams, poUsePath})
  result = waitForExit(process)
  close(process)

proc writeTrackedReleaseTar(
    pkg: Package;
    ver: PackageVersion;
    tarPath: Path;
    archiveStem: string;
    archiveFiles: openArray[string]
) =
  let prefix = archiveStem & "/"
  var args = @[
    "-C", $pkg.ondisk,
    "archive",
    "--format=tar",
    "--prefix=" & prefix,
    "-o", $tarPath,
    ver.vtag.commit.h
  ]
  for file in archiveFiles:
    args.add file

  if fileExists($tarPath):
    removeFile($tarPath)
  let exitCode = runArchiveCommand("git " & args.mapIt(quoteShell(it)).join(" "))
  if exitCode != 0 or not fileExists($tarPath):
    if fileExists($tarPath):
      removeFile($tarPath)
    raise newException(IOError, "failed to archive release to " & $tarPath)

proc writeTrackedReleaseArchive(
    pkg: Package;
    ver: PackageVersion;
    archiveDir: Path;
    archiveStem: string;
    archiveFiles: openArray[string];
    compression: ArchiveCompression
): string =
  if ver.isNil or ver.vtag.commit.h.len == 0:
    raise newException(ValueError, "release is missing a commit for archiving")
  if archiveFiles.len == 0:
    raise newException(IOError, "release archive has no tracked files to package")

  createDir($archiveDir)
  let archivePath = archiveDir / Path(archiveStem & archiveCompressionExtension(compression))
  let tmpArchivePath = siblingTempPath(archivePath)

  let tarPath = siblingTempPath(archiveDir / Path(archiveStem & ".tar"))
  if fileExists($tmpArchivePath):
    removeFile($tmpArchivePath)
  writeTrackedReleaseTar(pkg, ver, tarPath, archiveStem, archiveFiles)
  let compressor =
    case compression
    of acGzip: "gzip"
    of acXz: "xz"
  let compressedTarPath = compressionTempPath(tarPath, compression)
  if fileExists($compressedTarPath):
    removeFile($compressedTarPath)
  let compressExitCode = runArchiveCommand(compressor, ["-9", "-f", $tarPath])
  if fileExists($tarPath):
    removeFile($tarPath)
  if compressExitCode == 0 and fileExists($compressedTarPath):
    moveFile($compressedTarPath, $tmpArchivePath)
  if compressExitCode != 0 or not fileExists($tmpArchivePath):
    if fileExists($tarPath):
      removeFile($tarPath)
    if fileExists($compressedTarPath):
      removeFile($compressedTarPath)
    if fileExists($tmpArchivePath):
      removeFile($tmpArchivePath)
    raise newException(IOError, "failed to compress release archive " & $archivePath)
  moveFile($tmpArchivePath, $archivePath)
  result = $archivePath.splitPath().tail

proc loadExistingDigestEntries(workspaceRoot: Path): JsonNode =
  let digestPath = packageDigestFile(workspaceRoot)
  if not fileExists($digestPath):
    return newJArray()
  try:
    let digest = parseFile($digestPath)
    if "tarballs" in digest and digest["tarballs"].kind == JArray:
      return digest["tarballs"]
  except CatchableError:
    discard
  newJArray()

proc matchingDigestEntry(
    entries: JsonNode;
    versionLabel: string;
    gitSha: string;
    compression: string
): JsonNode =
  if entries.kind != JArray:
    return nil
  for entry in entries:
    if entry.kind != JObject:
      continue
    if entry{"version"}.getStr() == versionLabel and
        entry{"gitSha"}.getStr() == gitSha and
        entry{"compression"}.getStr() == compression:
      return entry
  nil

proc collectReleaseArchives(
    pkg: Package;
    info: PackageInfo;
    releaseInfo: PackageReleaseInfo;
    archiveDir: Path;
    compressions: openArray[ArchiveCompression]
): JsonNode =
  result = newJArray()
  let workspaceRoot = archiveDir.parentDir()
  let existingEntries = loadExistingDigestEntries(workspaceRoot)
  createDir($archiveDir)
  var usedStems = initHashSet[string]()
  var referencedFiles = initHashSet[string]()
  for (ver, release) in releaseInfo.releases:
    if ver.isNil or ver.vtag.commit.h.len == 0:
      continue
    let baseName = archiveBaseName(pkg, info, release)
    let label = archiveReleaseLabel(ver, release)
    let commitSuffix = archiveCommitLabel(ver)
    let rootSubdir = packageRootSubdir(pkg)
    let rootArchiveFiles = archiveTrackedFiles(pkg, ver.vtag.commit, rootSubdir)
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
    var rootStem = baseName & "-" & label & "-" & commitSuffix & "-" & contentHashSuffix
    if usedStems.containsOrIncl(rootStem):
      rootStem.add "-" & commitSuffix
      discard usedStems.containsOrIncl(rootStem)

    for compression in compressions:
      let compressionName = archiveCompressionName(compression)
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
        pkg, ver, archiveDir, rootStem, rootArchiveFiles, compression
      )
      let archivePath = archiveDir / Path(archiveFile)
      referencedFiles.incl(archiveFile)
      var archiveEntry = newJObject()
      archiveEntry["version"] = %label
      archiveEntry["createdAt"] = %now().utc().format("yyyy-MM-dd'T'HH:mm:ss'Z'")
      archiveEntry["gitSha"] = %ver.vtag.commit.h
      archiveEntry["gitShortSha"] = %commitSuffix
      archiveEntry["contentSha"] = %contentHash
      archiveEntry["contentShortSha"] = %contentHashSuffix
      archiveEntry["archiveRoot"] = %"package"
      archiveEntry["compression"] = %compressionName
      archiveEntry["file"] = %archiveFile
      archiveEntry["size"] = %getFileSize($archivePath)
      if rootSubdir.len > 0:
        archiveEntry["packageSubdir"] = %($rootSubdir)
      if not release.isNil and release.name.len > 0:
        archiveEntry["name"] = %release.name
      if not release.isNil and release.srcDir.len > 0:
        archiveEntry["srcDir"] = %($release.srcDir)
      archiveEntry["archiveRoot"] = %"package"
      result.add archiveEntry

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
    compressions: openArray[ArchiveCompression]
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
      compressions
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
    compressions: seq[ArchiveCompression]
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
          nc.harvestPackage(info, metadataDir, ephemeral, compressions)
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
    compressions: openArray[ArchiveCompression];
    threadCount: int
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

    queue.packages.add info

  let workerCount = max(1, min(threadCount, max(1, queue.packages.len)))
  let baseContext = context()
  let compressionList = @compressions
  if workerCount == 1:
    let workerResult = harvestWorker(addr queue, baseContext, metadataDir, ephemeral, compressionList)
    result.packagesProcessed += workerResult.packagesProcessed
    result.packagesFailed += workerResult.packagesFailed
    for failure in workerResult.failures:
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
        compressionList
      )
    for worker in workers:
      let workerResult = ^worker
      result.packagesProcessed += workerResult.packagesProcessed
      result.packagesFailed += workerResult.packagesFailed
      for failure in workerResult.failures:
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
