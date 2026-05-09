#
#           Atlas Package Cloner
#        (c) Copyright 2026 The Atlas contributors
#

## Harvest package release caches for packages in a packages.json list.

import std/[json, os, paths, strutils, times]

import ../basic/[context, dependencycache, nimblecontext, packageinfos, reporters]
import ../registryreleaseinfo

type
  HarvestSummary* = object
    packagesSeen*: int
    aliasesSkipped*: int
    packagesProcessed*: int
    packagesFailed*: int

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

proc copyReleaseCache(pkg: Package; metadataDir: Path): string =
  let cachePath = packageReleaseCachePath(pkg)
  if not fileExists($cachePath):
    raise newException(IOError, "missing release cache: " & $cachePath)
  result = $cachePath.splitPath().tail

proc writeIndex(
    metadataDir: Path;
    packagesFile: Path;
    summary: HarvestSummary;
    copiedFiles: JsonNode;
    packageName = ""
) =
  var index = newJObject()
  index["generatedAt"] = %now().utc().format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  index["packagesFile"] = %($packagesFile)
  if packageName.len > 0:
    index["package"] = %packageName
  index["packagesSeen"] = %summary.packagesSeen
  index["aliasesSkipped"] = %summary.aliasesSkipped
  index["packagesProcessed"] = %summary.packagesProcessed
  index["packagesFailed"] = %summary.packagesFailed
  index["files"] = copiedFiles
  writeFile($(metadataDir / Path("index.json")), pretty(index))

proc harvestOnePackage(
    nc: var NimbleContext;
    info: PackageInfo;
    metadataDir: Path;
    summary: var HarvestSummary;
    copiedFiles: JsonNode;
    ephemeral: bool
) =
  notice "atlas:pkger", "processing package:", info.name
  let releaseInfo = nc.loadRegistryPackageReleaseInfo(
    info,
    mode = AllReleases,
    onClone = DoClone
  )
  let copiedFile = copyReleaseCache(releaseInfo.package, metadataDir)

  var entry = newJObject()
  entry["name"] = %info.name
  entry["cacheFile"] = %copiedFile
  entry["loadedFromCache"] = %releaseInfo.releaseInfo.loadedFromCache
  entry["releaseCount"] = %releaseInfo.releaseInfo.releases.len
  copiedFiles.add entry
  inc summary.packagesProcessed
  if ephemeral:
    cleanupClonedPackage(releaseInfo.package)

proc harvestRegistryCaches*(
    packagesFile: Path;
    metadataDir: Path;
    ephemeral = false
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

    try:
      nc.harvestOnePackage(info, metadataDir, result, copiedFiles, ephemeral)
    except CatchableError as e:
      error "atlas:pkger", "failed package:", info.name, "error:", e.msg
      inc result.packagesFailed

  writeIndex(metadataDir, packagesFile, result, copiedFiles)

proc harvestRegistryCacheForPackage*(
    packagesFile: Path;
    metadataDir: Path;
    packageName: string;
    ephemeral = false
): HarvestSummary =
  createDir($metadataDir)

  var nc = createNimbleContext()
  let packageList = loadPackageList(packagesFile)
  let info = findPackageInfo(packageList, packageName)
  var copiedFiles = newJArray()

  result.packagesSeen = packageList.len
  try:
    nc.harvestOnePackage(info, metadataDir, result, copiedFiles, ephemeral)
  except CatchableError as e:
    error "atlas:pkger", "failed package:", info.name, "error:", e.msg
    inc result.packagesFailed

  writeIndex(metadataDir, packagesFile, result, copiedFiles, packageName = info.name)
