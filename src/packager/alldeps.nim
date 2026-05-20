#
#           Atlas Package Cloner
#        (c) Copyright 2026 The Atlas contributors
#

## Generate expanded dependency metadata for harvested package release caches.

import std/[algorithm, json, locks, os, paths, sets, strutils, tables, threadpool]

import ../basic/[packageinfos, pkgurls, reporters]
import ./cacheharvest

type
  AllDepsSummary* = object
    packagesProcessed*: int
    packagesUpdated*: int
    packagesSkipped*: int
    packagesFailed*: int

  PackageQueue = object
    lock: Lock
    packages: seq[PackageInfo]
    next: int

  AllDepsPackageResult = object
    updated: bool
    skipped: bool
    packageName: string

  AllDepsWorkerResult = object
    packagesProcessed: int
    packagesUpdated: int
    packagesSkipped: int
    packagesFailed: int

  AllDepsIndex = object
    officialByName: Table[string, string]
    officialPathByName: Table[string, Path]
    officialNameByUrl: Table[string, string]

  AllDepsSet = object
    packages: Table[string, string]
    urls: Table[string, string]
    missing: Table[string, string]

proc popPackage(queue: ptr PackageQueue; info: var PackageInfo): bool {.gcsafe.} =
  acquire(queue.lock)
  try:
    if queue.next < queue.packages.len:
      info = queue.packages[queue.next]
      inc queue.next
      result = true
  finally:
    release(queue.lock)

proc packageWorkspaceRoot(metadataDir: Path; info: PackageInfo): Path =
  (metadataDir / Path(info.name)).absolutePath()

proc packageReleasesMetadataFile(workspaceRoot: Path): Path =
  workspaceRoot / Path"releases.json"

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

proc normalizedPackageName(name: string): string =
  name.toLowerAscii()

proc normalizedPackageUrl(url: string): string =
  result = url.strip()
  if result.endsWith(".git"):
    result.setLen(result.len - 4)

proc addOfficialUrl(index: var AllDepsIndex; packageName: string; url: string) =
  let normalized = normalizedPackageUrl(url)
  if normalized.len > 0:
    index.officialNameByUrl[normalized] = packageName

proc addOfficialPackage(index: var AllDepsIndex; metadataDir: Path; info: PackageInfo) =
  let normalizedName = normalizedPackageName(info.name)
  index.officialByName[normalizedName] = info.name
  index.officialPathByName[normalizedName] = packageReleasesMetadataFile(
    packageWorkspaceRoot(metadataDir, info)
  )
  index.addOfficialUrl(info.name, info.url)
  try:
    let url = createUrlSkipPatterns(info.url, skipDirTest = true).withSubdir(info.subdir)
    index.addOfficialUrl(info.name, $url)
    index.addOfficialUrl(info.name, $url.cloneUri())
  except CatchableError:
    discard

proc buildAllDepsIndex(packageList: openArray[PackageInfo]; metadataDir: Path): AllDepsIndex =
  var aliases: seq[PackageInfo]
  for info in packageList:
    if info.kind == pkAlias:
      aliases.add info
    else:
      result.addOfficialPackage(metadataDir, info)

  for info in aliases:
    let target = normalizedPackageName(info.alias)
    if result.officialByName.hasKey(target):
      result.officialByName[normalizedPackageName(info.name)] = result.officialByName[target]

proc allDepsPath(index: AllDepsIndex; packageName: string): Path =
  let normalizedName = normalizedPackageName(packageName)
  if index.officialPathByName.hasKey(normalizedName):
    result = index.officialPathByName[normalizedName]

proc addAllDep(
    allDeps: var AllDepsSet;
    pending: var seq[string];
    rootPackageName: string;
    dep: JsonNode;
    index: AllDepsIndex
) =
  if dep.isNil or dep.kind != JObject:
    return

  if dep.hasKey("name"):
    let depName = dep["name"].getStr()
    let normalizedName = normalizedPackageName(depName)
    if normalizedName == normalizedPackageName(rootPackageName):
      return
    if not index.officialByName.hasKey(normalizedName):
      if normalizedName notin allDeps.missing:
        allDeps.missing[normalizedName] = depName
      return
    let officialName = index.officialByName[normalizedName]
    let key = normalizedPackageName(officialName)
    if key notin allDeps.packages:
      allDeps.packages[key] = officialName
      pending.add officialName
  elif dep.hasKey("url"):
    let rawUrl = dep["url"].getStr()
    let normalizedUrl = normalizedPackageUrl(rawUrl)
    if normalizedUrl.len == 0:
      return
    if index.officialNameByUrl.hasKey(normalizedUrl):
      let officialName = index.officialNameByUrl[normalizedUrl]
      if normalizedPackageName(officialName) == normalizedPackageName(rootPackageName):
        return
      let key = normalizedPackageName(officialName)
      if key notin allDeps.packages:
        allDeps.packages[key] = officialName
        pending.add officialName
    else:
      if normalizedUrl notin allDeps.urls:
        allDeps.urls[normalizedUrl] = rawUrl

proc collectReleaseRequirements(
    releasesMetadata: JsonNode;
    allDeps: var AllDepsSet;
    pending: var seq[string];
    rootPackageName: string;
    index: AllDepsIndex
) =
  if releasesMetadata.isNil or releasesMetadata.kind != JObject:
    return
  if not releasesMetadata.hasKey("releases") or releasesMetadata["releases"].kind != JArray:
    return

  for entry in releasesMetadata["releases"]:
    if entry.kind != JObject or not entry.hasKey("release"):
      continue
    let release = entry["release"]
    if release.kind != JObject:
      continue
    if release.hasKey("requirements") and release["requirements"].kind == JArray:
      for dep in release["requirements"]:
        addAllDep(allDeps, pending, rootPackageName, dep, index)
    if release.hasKey("features") and release["features"].kind == JObject:
      for _, featureDeps in release["features"]:
        if featureDeps.kind != JArray:
          continue
        for dep in featureDeps:
          addAllDep(allDeps, pending, rootPackageName, dep, index)

proc sortedValues(items: Table[string, string]): JsonNode =
  var keys: seq[string]
  for key in items.keys:
    keys.add key
  keys.sort()

  result = newJArray()
  for key in keys:
    result.add %items[key]

proc computeAllDeps(
    packageName: string;
    releasesMetadata: JsonNode;
    index: AllDepsIndex
): JsonNode =
  var allDeps = AllDepsSet(
    packages: initTable[string, string](),
    urls: initTable[string, string](),
    missing: initTable[string, string]()
  )
  var pending: seq[string]
  var expanded = initHashSet[string]()

  collectReleaseRequirements(releasesMetadata, allDeps, pending, packageName, index)

  var next = 0
  while next < pending.len:
    let depName = pending[next]
    inc next
    let normalizedName = normalizedPackageName(depName)
    if expanded.containsOrIncl(normalizedName):
      continue
    let depPath = index.allDepsPath(depName)
    if depPath.len == 0 or not fileExists($depPath):
      if normalizedName notin allDeps.missing:
        allDeps.missing[normalizedName] = depName
      continue
    try:
      let depReleasesMetadata = parseFile($depPath)
      collectReleaseRequirements(depReleasesMetadata, allDeps, pending, packageName, index)
    except CatchableError:
      if normalizedName notin allDeps.missing:
        allDeps.missing[normalizedName] = depName

  result = newJObject()
  result["packages"] = sortedValues(allDeps.packages)
  result["urls"] = sortedValues(allDeps.urls)
  result["missing"] = sortedValues(allDeps.missing)

proc updatePackageAllDeps(
    info: PackageInfo;
    metadataDir: Path;
    index: AllDepsIndex
): AllDepsPackageResult =
  result.packageName = info.name
  let releasesMetadataPath = packageReleasesMetadataFile(packageWorkspaceRoot(metadataDir, info))
  if not fileExists($releasesMetadataPath):
    result.skipped = true
    return

  var releasesMetadata = parseFile($releasesMetadataPath)
  if releasesMetadata.isNil or releasesMetadata.kind != JObject:
    raise newException(ValueError, "invalid releases metadata: " & $releasesMetadataPath)

  let allDeps = computeAllDeps(info.name, releasesMetadata, index)
  let previousAllDeps =
    if releasesMetadata.hasKey("allDeps"): releasesMetadata["allDeps"]
    else: newJNull()
  if previousAllDeps != allDeps:
    releasesMetadata["allDeps"] = allDeps
    writeTextFileAtomic(releasesMetadataPath, pretty(releasesMetadata))
    result.updated = true
    notice "atlas:pkger", "updated allDeps:", $releasesMetadataPath

proc allDepsWorker(
    queue: ptr PackageQueue;
    packagesFile: Path;
    metadataDir: Path;
): AllDepsWorkerResult {.gcsafe.} =
  let packageList = loadPackageList(packagesFile)
  let index = block:
    {.cast(gcsafe).}:
      buildAllDepsIndex(packageList, metadataDir)
  var info: PackageInfo
  while popPackage(queue, info):
    try:
      let packageResult = block:
        {.cast(gcsafe).}:
          updatePackageAllDeps(info, metadataDir, index)
      if packageResult.skipped:
        inc result.packagesSkipped
      else:
        inc result.packagesProcessed
      if packageResult.updated:
        inc result.packagesUpdated
    except CatchableError as e:
      block:
        {.cast(gcsafe).}:
          error "atlas:pkger",
            "stopped updating allDeps:",
            info.name,
            "reason:",
            e.msg
      inc result.packagesFailed

proc updatePackageAllDeps*(
    packagesFile: Path;
    metadataDir: Path;
    pkgNames: seq[string];
    ignoredPkgNames: seq[string];
    threadCount: int
): AllDepsSummary =
  let packageList = loadPackageList(packagesFile)
  var queue: PackageQueue
  initLock(queue.lock)
  for info in packageList:
    if info.kind == pkAlias:
      continue
    if pkgNames.len > 0 and info.name notin pkgNames:
      continue
    if info.name in ignoredPkgNames:
      continue
    queue.packages.add info
  queue.packages.sort(proc (a, b: PackageInfo): int = cmp(a.name, b.name))

  let workerCount = max(1, min(threadCount, max(1, queue.packages.len)))
  if workerCount == 1:
    let workerResult = allDepsWorker(addr queue, packagesFile, metadataDir)
    result.packagesProcessed += workerResult.packagesProcessed
    result.packagesUpdated += workerResult.packagesUpdated
    result.packagesSkipped += workerResult.packagesSkipped
    result.packagesFailed += workerResult.packagesFailed
  else:
    setMaxPoolSize(workerCount)
    var workers: seq[FlowVar[AllDepsWorkerResult]]
    for _ in 0..<workerCount:
      workers.add spawn allDepsWorker(addr queue, packagesFile, metadataDir)
    for worker in workers:
      let workerResult = ^worker
      result.packagesProcessed += workerResult.packagesProcessed
      result.packagesUpdated += workerResult.packagesUpdated
      result.packagesSkipped += workerResult.packagesSkipped
      result.packagesFailed += workerResult.packagesFailed
  deinitLock(queue.lock)
