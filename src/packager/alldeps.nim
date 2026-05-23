#
#           Atlas Package Cloner
#        (c) Copyright 2026 The Atlas contributors
#

## Generate expanded dependency metadata for harvested package release caches.

import std/[algorithm, json, locks, os, paths, sets, strutils, tables, threadpool]

import ../basic/[packageinfos, pkgurls, reporters, versions]
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

  PendingDep = object
    name: string
    releaseVersion: string

  DepUse = object
    value: string
    releaseVersions: HashSet[string]

  AllDepsSet = object
    packages: Table[string, DepUse]
    urls: Table[string, DepUse]
    unresolved: Table[string, string]

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

proc sortVersionAsc(a, b: Version): int =
  if a < b: -1
  elif a == b: 0
  else: 1

proc normalizedReleaseVersion(version: string): string =
  let parsed = toVersion(version)
  if parsed != Version"":
    result = $parsed

proc isSpecialVersion(version: Version): bool =
  version.string.len > 0 and version.string[0] == '#'

proc releaseJson(entry: JsonNode): JsonNode =
  if entry.kind != JObject:
    return
  entry

proc releaseVersion(entry: JsonNode): string =
  let release = releaseJson(entry)
  if release.kind != JObject:
    return
  let vtag = release{"v"}.getStr()
  let at = vtag.find('@')
  if at > 0:
    return normalizedReleaseVersion(vtag[0 ..< at])
  if vtag.len > 0:
    return normalizedReleaseVersion(vtag)

proc releaseEntries(releasesMetadata: JsonNode): JsonNode =
  if releasesMetadata.isNil or releasesMetadata.kind != JObject:
    return nil
  if releasesMetadata.hasKey("releases") and releasesMetadata["releases"].kind == JArray:
    result = releasesMetadata["releases"]
  else:
    return nil

proc collectRootVersions(releasesMetadata: JsonNode): seq[Version] =
  let entries = releaseEntries(releasesMetadata)
  if entries.isNil:
    return

  var seen = initHashSet[string]()
  for entry in entries:
    let version = releaseVersion(entry)
    if version.len > 0:
      let parsed = toVersion(version)
      if not parsed.isSpecialVersion and not seen.containsOrIncl(version):
        result.add parsed
  result.sort(sortVersionAsc)

proc recordDepUse(
    items: var Table[string, DepUse];
    key: string;
    value: string;
    releaseVersion: string
) =
  var depUse =
    if items.hasKey(key):
      items[key]
    else:
      DepUse(value: value, releaseVersions: initHashSet[string]())
  depUse.releaseVersions.incl releaseVersion
  items[key] = depUse

proc looksLikeUrl(value: string): bool =
  value.contains("://") or value.startsWith("git@")

proc requirementNameFromString(raw: string): string =
  var i = 0
  while i < raw.len:
    if raw[i] in Whitespace:
      var j = i
      while j < raw.len and raw[j] in Whitespace:
        inc j
      if j >= raw.len or raw[j] in {'#', '<', '=', '>', '*'} + Digits:
        return raw.substr(0, i - 1)
    inc i

  if raw.looksLikeUrl:
    result = raw
  else:
    let (name, _, _) = extractRequirementName(raw)
    result = name

proc addAllDepName(
    allDeps: var AllDepsSet;
    pending: var seq[PendingDep];
    rootPackageName: string;
    releaseVersion: string;
    depName: string;
    index: AllDepsIndex
) =
  let normalizedName = normalizedPackageName(depName)
  if normalizedName == normalizedPackageName(rootPackageName):
    return
  if index.officialByName.hasKey(normalizedName):
    let officialName = index.officialByName[normalizedName]
    let key = normalizedPackageName(officialName)
    recordDepUse(allDeps.packages, key, officialName, releaseVersion)
    pending.add PendingDep(name: officialName, releaseVersion: releaseVersion)
    return

  let normalizedUrl = normalizedPackageUrl(depName)
  if normalizedUrl.len > 0 and index.officialNameByUrl.hasKey(normalizedUrl):
    let officialName = index.officialNameByUrl[normalizedUrl]
    if normalizedPackageName(officialName) == normalizedPackageName(rootPackageName):
      return
    let key = normalizedPackageName(officialName)
    recordDepUse(allDeps.packages, key, officialName, releaseVersion)
    pending.add PendingDep(name: officialName, releaseVersion: releaseVersion)
  elif depName.looksLikeUrl:
    recordDepUse(allDeps.urls, normalizedUrl, depName, releaseVersion)
  elif normalizedName notin allDeps.unresolved:
    allDeps.unresolved[normalizedName] = depName

proc addAllDepUrl(
    allDeps: var AllDepsSet;
    pending: var seq[PendingDep];
    rootPackageName: string;
    releaseVersion: string;
    rawUrl: string;
    index: AllDepsIndex
) =
  let normalizedUrl = normalizedPackageUrl(rawUrl)
  if normalizedUrl.len == 0:
    return
  if index.officialNameByUrl.hasKey(normalizedUrl):
    let officialName = index.officialNameByUrl[normalizedUrl]
    if normalizedPackageName(officialName) == normalizedPackageName(rootPackageName):
      return
    let key = normalizedPackageName(officialName)
    recordDepUse(allDeps.packages, key, officialName, releaseVersion)
    pending.add PendingDep(name: officialName, releaseVersion: releaseVersion)
  else:
    recordDepUse(allDeps.urls, normalizedUrl, rawUrl, releaseVersion)

proc addAllDep(
    allDeps: var AllDepsSet;
    pending: var seq[PendingDep];
    rootPackageName: string;
    releaseVersion: string;
    dep: JsonNode;
    index: AllDepsIndex
) =
  if dep.isNil:
    return

  case dep.kind
  of JString:
    try:
      let depName = requirementNameFromString(dep.getStr())
      addAllDepName(allDeps, pending, rootPackageName, releaseVersion, depName, index)
    except ValueError:
      discard
  of JObject:
    if dep.hasKey("name"):
      addAllDepName(allDeps, pending, rootPackageName, releaseVersion, dep["name"].getStr(), index)
    elif dep.hasKey("url"):
      addAllDepUrl(allDeps, pending, rootPackageName, releaseVersion, dep["url"].getStr(), index)
  else:
    discard

proc collectReleaseRequirementsFromRelease(
    release: JsonNode;
    allDeps: var AllDepsSet;
    pending: var seq[PendingDep];
    rootPackageName: string;
    releaseVersion: string;
    index: AllDepsIndex
) =
  if release.kind != JObject:
    return

  let reqs = release{"r"}
  if not reqs.isNil and reqs.kind == JArray:
    for dep in reqs:
      addAllDep(allDeps, pending, rootPackageName, releaseVersion, dep, index)
  let features = release{"f"}
  if not features.isNil and features.kind == JObject:
    for _, featureDeps in features:
      if featureDeps.kind != JArray:
        continue
      for dep in featureDeps:
        addAllDep(allDeps, pending, rootPackageName, releaseVersion, dep, index)

proc collectReleaseRequirements(
    releasesMetadata: JsonNode;
    allDeps: var AllDepsSet;
    pending: var seq[PendingDep];
    rootPackageName: string;
    releaseVersion: string;
    index: AllDepsIndex
) =
  let entries = releaseEntries(releasesMetadata)
  if entries.isNil:
    return

  for entry in entries:
    collectReleaseRequirementsFromRelease(
      releaseJson(entry), allDeps, pending, rootPackageName, releaseVersion, index
    )

proc sortedValues(items: Table[string, string]): JsonNode =
  var keys: seq[string]
  for key in items.keys:
    keys.add key
  keys.sort()

  result = newJArray()
  for key in keys:
    result.add %items[key]

proc constrainedDep(value: string; depUse: DepUse; rootVersions: seq[Version]): string =
  if rootVersions.len == 0:
    return value

  var versionIndex = initTable[string, int]()
  for i, version in rootVersions:
    versionIndex[$version] = i

  var minIndex = rootVersions.len
  var maxIndex = -1
  for version in depUse.releaseVersions:
    if versionIndex.hasKey(version):
      let index = versionIndex[version]
      minIndex = min(minIndex, index)
      maxIndex = max(maxIndex, index)

  if maxIndex < 0:
    return value

  var constraints: seq[string]
  if minIndex > 0:
    constraints.add "> " & $rootVersions[minIndex - 1]
  if maxIndex < rootVersions.high:
    constraints.add "<= " & $rootVersions[maxIndex]
  if constraints.len == 0:
    result = value
  else:
    result = value & " " & constraints.join(" & ")

proc sortedConstrainedValues(items: Table[string, DepUse]; rootVersions: seq[Version]): JsonNode =
  var values: seq[string]
  for depUse in items.values:
    values.add constrainedDep(depUse.value, depUse, rootVersions)
  values.sort()

  result = newJArray()
  for value in values:
    result.add %value

proc computeAllDeps(
    packageName: string;
    releasesMetadata: JsonNode;
    index: AllDepsIndex
): JsonNode =
  let rootVersions = collectRootVersions(releasesMetadata)
  var allDeps = AllDepsSet(
    packages: initTable[string, DepUse](),
    urls: initTable[string, DepUse](),
    unresolved: initTable[string, string]()
  )
  var pending: seq[PendingDep]
  var expanded = initHashSet[string]()

  let entries = releaseEntries(releasesMetadata)
  if not entries.isNil:
    for entry in entries:
      let version = releaseVersion(entry)
      if version.len == 0:
        continue
      collectReleaseRequirementsFromRelease(
        releaseJson(entry), allDeps, pending, packageName, version, index
      )

  var next = 0
  while next < pending.len:
    let dep = pending[next]
    inc next
    let depName = dep.name
    let normalizedName = normalizedPackageName(depName)
    let expandedKey = normalizedName & "\0" & dep.releaseVersion
    if expanded.containsOrIncl(expandedKey):
      continue
    let depPath = index.allDepsPath(depName)
    if depPath.len == 0 or not fileExists($depPath):
      if normalizedName notin allDeps.unresolved:
        allDeps.unresolved[normalizedName] = depName
      continue
    try:
      let depReleasesMetadata = parseFile($depPath)
      collectReleaseRequirements(
        depReleasesMetadata, allDeps, pending, packageName, dep.releaseVersion, index
      )
    except CatchableError:
      if normalizedName notin allDeps.unresolved:
        allDeps.unresolved[normalizedName] = depName

  result = newJObject()
  result["packages"] = sortedConstrainedValues(allDeps.packages, rootVersions)
  result["urls"] = sortedConstrainedValues(allDeps.urls, rootVersions)
  result["unresolved"] = sortedValues(allDeps.unresolved)

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
