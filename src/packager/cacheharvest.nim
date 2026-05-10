#
#           Atlas Package Cloner
#        (c) Copyright 2026 The Atlas contributors
#

## Harvest package release caches for packages in a packages.json list.

import std/[json, os, osproc, paths, sequtils, sets, strutils, times]

import ../basic/[context, dependencycache, nimblecontext, packageinfos, pkgurls, reporters]
import ../registryreleaseinfo

type
  HarvestSummary* = object
    packagesSeen*: int
    aliasesSkipped*: int
    packagesProcessed*: int
    packagesFailed*: int

proc packageWorkspaceRoot(info: PackageInfo): Path =
  (depsDir() / Path(info.name)).absolutePath()

proc packageReleasesDir(workspaceRoot: Path): Path =
  workspaceRoot / Path"releases"

proc packageReleasesMetadataFile(workspaceRoot: Path): Path =
  workspaceRoot / Path"releases.json"

proc packageReleasesMetadataRelPath(info: PackageInfo): string =
  $Path(info.name) / "releases.json"

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

proc findPackageInfo(
    packageList: seq[PackageInfo];
    packageName: string
): PackageInfo =
  for info in packageList:
    if info.kind == pkPackage and cmpIgnoreCase(info.name, packageName) == 0:
      return info
  raise newException(ValueError, "package not found in packages list: " & packageName)

proc findPackageInfos(
    packageList: seq[PackageInfo];
    packageNames: seq[string]
): seq[PackageInfo] =
  for packageName in packageNames:
    result.add findPackageInfo(packageList, packageName)

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
    archiveSubdir: Path
): string =
  if ver.isNil or ver.vtag.commit.h.len == 0:
    raise newException(ValueError, "release is missing a commit for archiving")

  createDir($archiveDir)
  var archivePath = archiveDir / Path(archiveStem & ".tar.gz")
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
  let (_, gzipExitCode) = execCmdEx(
    "gzip " & ["-9", "-f", $tarPath].mapIt(quoteShell(it)).join(" ")
  )
  if gzipExitCode != 0 or not fileExists($archivePath):
    if fileExists($tarPath):
      removeFile($tarPath)
    if fileExists($archivePath):
      removeFile($archivePath)
    raise newException(IOError, "failed to gzip release archive " & $archivePath)
  result = $archivePath.splitPath().tail

proc writeReleaseArchives(
    pkg: Package;
    info: PackageInfo;
    releaseInfo: PackageReleaseInfo;
    archiveDir: Path
): JsonNode =
  result = newJArray()
  createDir($archiveDir)
  for kind, path in walkDir($archiveDir):
    if kind == pcFile and path.Path.splitFile().ext in [".gz", ".tar"]:
      removeFile(path)
  var usedStems = initHashSet[string]()
  for (ver, release) in releaseInfo.releases:
    if ver.isNil or ver.vtag.commit.h.len == 0:
      continue
    let baseName = archiveBaseName(pkg, info, release)
    let label = archiveReleaseLabel(ver, release)
    let commitSuffix = sanitizeArchiveComponent(ver.vtag.commit.short())
    let rootSubdir = packageRootSubdir(pkg)
    let hasDedicatedSrcArchive =
      not release.isNil and release.srcDir.len > 0 and release.srcDir != Path"."
    let srcSubdir =
      if hasDedicatedSrcArchive: archiveSrcSubdir(pkg, release)
      else: rootSubdir
    var archiveEntry = newJObject()
    archiveEntry["version"] = %archiveReleaseLabel(ver, release)
    archiveEntry["commit"] = %ver.vtag.commit.h
    var rootStem = baseName & "-" & label
    if usedStems.containsOrIncl(rootStem):
      rootStem.add "-" & commitSuffix
      discard usedStems.containsOrIncl(rootStem)
    archiveEntry["file"] = %writeReleaseArchive(pkg, info, ver, release, archiveDir, rootStem, rootSubdir)
    archiveEntry["archiveRoot"] = %"package"
    if rootSubdir.len > 0:
      archiveEntry["packageSubdir"] = %($rootSubdir)
    if not release.isNil and release.name.len > 0:
      archiveEntry["name"] = %release.name
    if not release.isNil and release.srcDir.len > 0:
      archiveEntry["srcDir"] = %($release.srcDir)
    if hasDedicatedSrcArchive:
      var srcStem = baseName & "-" & label & "-src"
      if usedStems.containsOrIncl(srcStem):
        srcStem.add "-" & commitSuffix
        discard usedStems.containsOrIncl(srcStem)
      archiveEntry["srcFile"] = %writeReleaseArchive(pkg, info, ver, release, archiveDir, srcStem, srcSubdir)
      archiveEntry["srcArchiveRoot"] = %"srcDir"
      archiveEntry["resolvedSrcDir"] = %($srcSubdir)
    result.add archiveEntry

proc writeIndex(
    metadataDir: Path;
    packagesFile: Path;
    summary: HarvestSummary;
    copiedFiles: JsonNode;
    packageName = "";
    packageNames: seq[string] = @[]
) =
  var index = newJObject()
  index["generatedAt"] = %now().utc().format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  index["packagesFile"] = %($packagesFile)
  if packageName.len > 0:
    index["package"] = %packageName
  elif packageNames.len > 0:
    index["packages"] = %(packageNames)
  index["packagesSeen"] = %summary.packagesSeen
  index["aliasesSkipped"] = %summary.aliasesSkipped
  index["packagesProcessed"] = %summary.packagesProcessed
  index["packagesFailed"] = %summary.packagesFailed
  index["files"] = copiedFiles
  writeFile($(metadataDir / Path("index.json")), pretty(index))

proc harvestPackage(
    nc: var NimbleContext;
    info: PackageInfo;
    metadataDir: Path;
    summary: var HarvestSummary;
    copiedFiles: JsonNode;
    ephemeral: bool
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
      packageReleasesDir(workspaceRoot)
    )

    var entry = newJObject()
    entry["name"] = %info.name
    entry["cacheFile"] = %packageReleasesMetadataRelPath(info)
    entry["loadedFromCache"] = %releaseInfo.releaseInfo.loadedFromCache
    entry["releaseCount"] = %releaseInfo.releaseInfo.releases.len
    entry["archives"] = archives
    copiedFiles.add entry
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
    pkgNames: seq[string]
): HarvestSummary =
  createDir($metadataDir)

  var nc = createNimbleContext()
  let packageList = loadPackageList(packagesFile)
  var copiedFiles = newJArray()

  result.packagesSeen = packageList.len
  for info in packageList:
    if info.kind == pkAlias:
      inc result.aliasesSkipped
      continue
    elif pkgNames.len() > 0 and info.name notin pkgNames:
      continue

    try:
      nc.harvestPackage(info, metadataDir, result, copiedFiles, ephemeral)
    except CatchableError as e:
      error "atlas:pkger", "failed package:", info.name, "error:", e.msg
      inc result.packagesFailed

  writeIndex(metadataDir, packagesFile, result, copiedFiles)

