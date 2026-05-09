#
#           Atlas Package Cloner
#        (c) Copyright 2026 The Atlas contributors
#

## Harvest package release caches for every package in a packages.json list.

import std/[json, os, paths, times]

import basic/[context, dependencycache, nimblecontext, packageinfos, reporters]
import registryreleaseinfo

type
  HarvestSummary* = object
    packagesSeen*: int
    aliasesSkipped*: int
    packagesProcessed*: int
    packagesFailed*: int

proc loadPackageList*(packagesFile: Path): seq[PackageInfo] =
  let root = parseFile($packagesFile)
  for node in root:
    let info = packageinfos.fromJson(node)
    if info != nil:
      result.add info

proc copyReleaseCache(pkg: Package; metadataDir: Path): string =
  let cachePath = packageReleaseCachePath(pkg)
  if not fileExists($cachePath):
    raise newException(IOError, "missing release cache: " & $cachePath)

  let targetPath = metadataDir / cachePath.splitPath().tail
  copyFile($cachePath, $targetPath)
  result = $targetPath.splitPath().tail

proc writeIndex(
    metadataDir: Path;
    packagesFile: Path;
    summary: HarvestSummary;
    copiedFiles: JsonNode
) =
  var index = newJObject()
  index["generatedAt"] = %now().utc().format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  index["packagesFile"] = %($packagesFile)
  index["packagesSeen"] = %summary.packagesSeen
  index["aliasesSkipped"] = %summary.aliasesSkipped
  index["packagesProcessed"] = %summary.packagesProcessed
  index["packagesFailed"] = %summary.packagesFailed
  index["files"] = copiedFiles
  writeFile($(metadataDir / Path("index.json")), pretty(index))

proc harvestRegistryCaches*(
    packagesFile: Path;
    metadataDir: Path
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
      inc result.packagesProcessed
    except CatchableError as e:
      error "atlas:pkger", "failed package:", info.name, "error:", e.msg
      inc result.packagesFailed

  writeIndex(metadataDir, packagesFile, result, copiedFiles)
