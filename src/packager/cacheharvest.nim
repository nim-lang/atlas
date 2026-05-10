#
#           Atlas Package Cloner
#        (c) Copyright 2026 The Atlas contributors
#

## Harvest package release caches for packages in a packages.json list.

import std/[json, os, osproc, paths, sequtils, sets, strutils, symlinks, times]

import ../basic/[context, dependencycache, nimblecontext, packageinfos, pkgurls, reporters]
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

proc packageWorkspaceRoot(info: PackageInfo): Path =
  (depsDir() / Path(info.name)).absolutePath()

proc packageReleasesDir(workspaceRoot: Path): Path =
  workspaceRoot / Path"releases"

proc packageReleasesMetadataFile(workspaceRoot: Path): Path =
  workspaceRoot / Path"releases.json"

proc packageReleasesMetadataRelPath(info: PackageInfo): string =
  $Path(info.name) / "releases.json"

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
  writeFile($dest, readFile($cachePath))

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

proc archiveCompressionName*(compression: ArchiveCompression): string =
  case compression
  of acGzip: "gzip"
  of acXz: "xz"

proc needsFullArchive(release: NimbleRelease): bool =
  not release.isNil and (
    release.hasInstallHooks or
    release.bin.len > 0 or
    release.namedBin.len > 0
  )

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

proc packageRootSubdir(pkg: Package): Path =
  let packageSubdir =
    if pkg.subdir.len > 0: pkg.subdir
    else: pkg.url.subdir()
  result = packageSubdir

proc archiveSrcSubdir(pkg: Package; release: NimbleRelease): Path =
  let packageSubdir = packageRootSubdir(pkg)
  if release.isNil or release.srcDir.len == 0 or release.srcDir == Path".":
    result = packageSubdir
  elif packageSubdir.len > 0:
    result = packageSubdir / release.srcDir
  else:
    result = release.srcDir

proc archiveTreeish(commit: CommitHash; subdir: Path): string =
  result = commit.h
  if subdir.len > 0:
    result.add ":"
    result.add $subdir

proc writeReleaseArchive(
    pkg: Package;
    info: PackageInfo;
    ver: PackageVersion;
    release: NimbleRelease;
    archiveDir: Path;
    archiveStem: string;
    archiveSubdir: Path;
    compression: ArchiveCompression
): string =
  if ver.isNil or ver.vtag.commit.h.len == 0:
    raise newException(ValueError, "release is missing a commit for archiving")

  createDir($archiveDir)
  let archivePath = archiveDir / Path(archiveStem & archiveCompressionExtension(compression))
  if fileExists($archivePath):
    removeFile($archivePath)

  let prefix = archiveStem & "/"
  let tarPath = archiveDir / Path(archiveStem & ".tar")
  let args = [
    "-C", $pkg.ondisk,
    "archive",
    "--format=tar",
    "--prefix=" & prefix,
    "-o", $tarPath,
    archiveTreeish(ver.vtag.commit, archiveSubdir)
  ]
  if fileExists($tarPath):
    removeFile($tarPath)
  let (_, exitCode) = execCmdEx("git " & args.mapIt(quoteShell(it)).join(" "))
  if exitCode != 0 or not fileExists($tarPath):
    if fileExists($tarPath):
      removeFile($tarPath)
    raise newException(IOError, "failed to archive release to " & $archivePath)
  let (compressor, compressorArgs) =
    case compression
    of acGzip: ("gzip", @["-9", "-f", $tarPath])
    of acXz: ("xz", @["-9", "-f", $tarPath])
  let (_, compressExitCode) = execCmdEx(
    compressor & " " & compressorArgs.mapIt(quoteShell(it)).join(" ")
  )
  if compressExitCode != 0 or not fileExists($archivePath):
    if fileExists($tarPath):
      removeFile($tarPath)
    if fileExists($archivePath):
      removeFile($archivePath)
    raise newException(IOError, "failed to compress release archive " & $archivePath)
  result = $archivePath.splitPath().tail

proc writeArchiveSymlink(
    archiveDir: Path;
    linkStem: string;
    targetFile: string;
    compression: ArchiveCompression
): string =
  let linkPath = archiveDir / Path(linkStem & archiveCompressionExtension(compression))
  if fileExists($linkPath) or symlinkExists(linkPath):
    removeFile($linkPath)
  createSymlink(Path(targetFile), linkPath)
  result = $linkPath.splitPath().tail

proc writeReleaseArchives(
    pkg: Package;
    info: PackageInfo;
    releaseInfo: PackageReleaseInfo;
    archiveDir: Path;
    compression: ArchiveCompression
): JsonNode =
  result = newJArray()
  createDir($archiveDir)
  for kind, path in walkDir($archiveDir):
    if kind == pcFile and path.Path.splitFile().ext in [".gz", ".xz", ".tar"]:
      removeFile(path)
  var usedStems = initHashSet[string]()
  for (ver, release) in releaseInfo.releases:
    if ver.isNil or ver.vtag.commit.h.len == 0:
      continue
    let baseName = archiveBaseName(pkg, info, release)
    let label = archiveReleaseLabel(ver, release)
    let commitSuffix = sanitizeArchiveComponent(ver.vtag.commit.short())
    let rootSubdir = packageRootSubdir(pkg)
    let hasFullArchive = needsFullArchive(release)
    let srcMatchesPackageRoot =
      not release.isNil and release.srcDir == Path"."
    let srcSubdir = archiveSrcSubdir(pkg, release)
    var archiveEntry = newJObject()
    archiveEntry["version"] = %archiveReleaseLabel(ver, release)
    archiveEntry["commit"] = %ver.vtag.commit.h
    var rootStem = baseName & "-" & label & "-full"
    if usedStems.containsOrIncl(rootStem):
      rootStem.add "-" & commitSuffix
      discard usedStems.containsOrIncl(rootStem)
    archiveEntry["archiveRoot"] = %"package"
    archiveEntry["compression"] = %archiveCompressionName(compression)
    if rootSubdir.len > 0:
      archiveEntry["packageSubdir"] = %($rootSubdir)
    if not release.isNil and release.name.len > 0:
      archiveEntry["name"] = %release.name
    if not release.isNil and release.srcDir.len > 0:
      archiveEntry["srcDir"] = %($release.srcDir)
    var srcStem = baseName & "-" & label & "-src"
    if usedStems.containsOrIncl(srcStem):
      srcStem.add "-" & commitSuffix
      discard usedStems.containsOrIncl(srcStem)
    let srcFile =
      writeReleaseArchive(pkg, info, ver, release, archiveDir, srcStem, srcSubdir, compression)
    archiveEntry["srcFile"] = %srcFile
    archiveEntry["srcArchiveRoot"] =
      if not release.isNil and release.srcDir.len > 0: %"srcDir"
      else: %"package"
    archiveEntry["resolvedSrcDir"] = %($srcSubdir)
    if hasFullArchive:
      if srcMatchesPackageRoot:
        archiveEntry["file"] = %writeArchiveSymlink(archiveDir, rootStem, srcFile, compression)
        archiveEntry["fileIsSymlink"] = %true
      else:
        archiveEntry["file"] = %writeReleaseArchive(pkg, info, ver, release, archiveDir, rootStem, rootSubdir, compression)
      archiveEntry["archiveRoot"] = %"package"
    result.add archiveEntry

proc writeIndex(
    metadataDir: Path;
    packagesFile: Path;
    summary: HarvestSummary;
    packageStatuses: JsonNode;
    packageName = "";
    packageNames: seq[string] = @[]
) =
  var index = newJObject()
  index["generatedAt"] = %now().utc().format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  index["packagesFile"] = %relativeIndexPath(metadataDir, packagesFile)
  if packageName.len > 0:
    index["package"] = %packageName
  elif packageNames.len > 0:
    index["packages"] = %(packageNames)
  index["packagesSeen"] = %summary.packagesSeen
  index["aliasesSkipped"] = %summary.aliasesSkipped
  index["packagesProcessed"] = %summary.packagesProcessed
  index["packagesFailed"] = %summary.packagesFailed
  index["packagesStatus"] = packageStatuses
  writeFile($(metadataDir / Path("index.json")), pretty(index))

proc harvestPackage(
    nc: var NimbleContext;
    info: PackageInfo;
    metadataDir: Path;
    summary: var HarvestSummary;
    packageStatuses: JsonNode;
    ephemeral: bool;
    compression: ArchiveCompression
) =
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
    let archives = writeReleaseArchives(
      releaseInfo.package,
      info,
      releaseInfo.releaseInfo,
      packageReleasesDir(workspaceRoot),
      compression
    )

    var entry = newJObject()
    entry["name"] = %info.name
    entry["latestCommit"] = %releaseInfo.releaseInfo.currentCommit.h
    entry["processedAt"] = %now().utc().format("yyyy-MM-dd'T'HH:mm:ss'Z'")
    packageStatuses.add entry
    inc summary.packagesProcessed
    cleanupTransientReleaseCache(releaseInfo.package)
    if ephemeral:
      cleanupClonedPackage(releaseInfo.package)
  finally:
    setContext(previousContext)

proc harvestRegistryCaches*(
    packagesFile: Path;
    metadataDir: Path;
    ephemeral: bool,
    pkgNames: seq[string];
    compression: ArchiveCompression
): HarvestSummary =
  createDir($metadataDir)

  var nc = createNimbleContext()
  let packageList = loadPackageList(packagesFile)
  var packageStatuses = newJArray()

  result.packagesSeen = packageList.len
  for info in packageList:
    if info.kind == pkAlias:
      inc result.aliasesSkipped
      continue
    elif pkgNames.len() > 0 and info.name notin pkgNames:
      continue

    try:
      nc.harvestPackage(info, metadataDir, result, packageStatuses, ephemeral, compression)
    except CatchableError as e:
      error "atlas:pkger", "failed package:", info.name, "error:", e.msg
      inc result.packagesFailed

  writeIndex(metadataDir, packagesFile, result, packageStatuses)
