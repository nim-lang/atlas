#
#           Atlas Package Cloner
#        (c) Copyright 2026 The Atlas contributors
#

## Harvest package release caches for packages in a packages.json list.

import std/[algorithm, json, jsonutils, locks, os, paths, sets, strutils, tables, threadpool, times]

import ../basic/[context, dependencycache, deptypesjson, gitops, nimblecontext, packageinfos, pkgurls, reporters, versions]
import ../registryreleaseinfo
import ./archivehelpers

export archivehelpers

type
  HarvestSummary* = object
    packagesSeen*: int
    aliasesSkipped*: int
    packagesProcessed*: int
    packagesFailed*: int
    taggedPackages*: int
    untaggedPackages*: int
    taggedReleases*: int
    untaggedReleases*: int
    releaseCounts*: seq[int]
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
    hasGitTags: bool
    releaseVtags: HashSet[string]
    tarballs: JsonNode

  HarvestFailure* = object
    packageName*: string
    errorMessage*: string

  PackageForgeMetadata* = object
    tags*: bool
    forgeReleases*: JsonNode

  HarvestWorkerResult = object
    packagesProcessed: int
    packagesFailed: int
    taggedPackages: int
    untaggedPackages: int
    taggedReleases: int
    untaggedReleases: int
    releaseCounts: seq[int]
    packageResults: seq[PackageHarvestResult]
    failures: seq[HarvestFailure]

  ArchiveReleaseEntry = object
    ver: PackageVersion
    release: NimbleRelease
    isHead: bool

  RetainedPackageIndexState = object
    latestCommit: string
    lastUpdate: string
    releaseVtags: HashSet[string]

  RetainedIndexMetadata = object
    releaseCacheVersion: int
    packages: Table[string, RetainedPackageIndexState]

proc popPackage(queue: ptr PackageQueue; info: var PackageInfo): bool {.gcsafe.} =
  acquire(queue.lock)
  try:
    if queue.next < queue.packages.len:
      info = queue.packages[queue.next]
      inc queue.next
      result = true
  finally:
    release(queue.lock)

proc packageBucketDir*(packageName: string): Path =
  if packageName.len == 0:
    return Path"_"
  Path($toLowerAscii(packageName[0]))

proc matchesPackageFilters*(
    packageName: string;
    packageNames: openArray[string];
    packagePrefixes: openArray[string]
): bool =
  let matchesNames = packageNames.len == 0 or packageName in packageNames
  if not matchesNames:
    return false

  if packagePrefixes.len == 0:
    return true

  for prefix in packagePrefixes:
    if packageName.startsWith(prefix):
      return true
  false

proc shouldUpdatePackageRepo*(
    updateRepos: bool;
    skipRepoUpdatePackages: HashSet[string];
    packageName: string
): bool =
  updateRepos and packageName notin skipRepoUpdatePackages

proc packageWorkspaceRoot(harvestRoot: Path; info: PackageInfo): Path =
  (harvestRoot / packageBucketDir(info.name) / Path(info.name)).absolutePath()

proc resolvePackageWorkspaceRoot*(
    harvestRoot: Path;
    info: PackageInfo
): Path =
  packageWorkspaceRoot(harvestRoot, info)

proc packageReleasesDir(workspaceRoot: Path): Path =
  workspaceRoot / Path"releases"

proc packageReleasesMetadataFile(workspaceRoot: Path): Path =
  workspaceRoot / Path"releases.json"

proc packageReleasesMetadataRelPath(info: PackageInfo): string =
  $(packageBucketDir(info.name) / Path(info.name) / Path"releases.json")

proc packageDigestFile(workspaceRoot: Path): Path =
  workspaceRoot / Path"digest.json"

proc packageRepoMirrorPath(workspaceRoot: Path; info: PackageInfo): Path =
  workspaceRoot / Path(info.name & ".git")

proc packageRepoLegacyMirrorPath(workspaceRoot: Path; info: PackageInfo): Path =
  workspaceRoot / Path(info.name)

proc packageRepoWorktreePath(workspaceRoot: Path): Path =
  workspaceRoot / Path".worktree"

proc errorsIndexPath(metadataDir: Path): Path =
  metadataDir / Path"index-errors.json"

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

proc relativeToCurrentDir*(path: Path): string =
  let cwd = os.getCurrentDir().Path
  let absolutePath = path.absolutePath()
  if absolutePath.isRelativeTo(cwd):
    $(absolutePath.relativePath(cwd))
  else:
    $absolutePath

proc loadReleaseVtags(releasesPath: Path): HashSet[string] =
  if not fileExists($releasesPath):
    return
  try:
    let root = parseFile($releasesPath)
    let releases =
      if root.hasKey("releases") and root["releases"].kind == JArray: root["releases"]
      else: nil
    if releases.isNil:
      return
    for entry in releases:
      let vtag = entry{"v"}.getStr()
      if vtag.len > 0 and not vtag.startsWith("#head@"):
        result.incl vtag
  except CatchableError:
    discard

proc loadRetainedPackageIndexState(metadataDir: Path): RetainedIndexMetadata =
  let indexPath = metadataDir / Path"index.json"
  if not fileExists($indexPath):
    return
  try:
    let index = parseFile($indexPath)
    result.releaseCacheVersion = index{"releaseCacheVersion"}.getInt()
    if "packages" notin index or index["packages"].kind != JArray:
      return
    for entry in index["packages"]:
      if entry.kind != JObject or "name" notin entry:
        continue
      let packageName = entry["name"].getStr()
      if packageName.len == 0:
        continue
      let releasesMetadataPath = entry{"releasesMetadata"}.getStr()
      result.packages[packageName] = RetainedPackageIndexState(
        latestCommit: entry{"latestCommit"}.getStr(),
        lastUpdate: entry{"lastUpdate"}.getStr(),
        releaseVtags:
          if releasesMetadataPath.len > 0:
            loadReleaseVtags(metadataDir / Path(releasesMetadataPath))
          else:
            initHashSet[string]()
      )
  except CatchableError:
    discard

proc cleanupMirroredPackage(repoPath, worktreePath: Path; removeRepo: bool) =
  if isGitDir(repoPath):
    removeWorktreeFromBareRepo(repoPath, worktreePath)
  elif dirExists($worktreePath):
    removeDir($worktreePath)
  if removeRepo and dirExists($repoPath):
    removeDir($repoPath)

proc prepareMirroredPackageRepo(
    pkg: var Package;
    info: PackageInfo;
    workspaceRoot: Path;
    updateRepos: bool
) =
  let repoPath = packageRepoMirrorPath(workspaceRoot, info)
  let legacyRepoPath = packageRepoLegacyMirrorPath(workspaceRoot, info)
  let worktreePath = packageRepoWorktreePath(workspaceRoot)
  template cloneFreshBareRepo() =
    createDir($workspaceRoot)
    if dirExists($repoPath):
      removeDir($repoPath)
    let (status, msg) = cloneBareSingleBranch(pkg.url.cloneUri(), repoPath)
    if status != Ok:
      if dirExists($repoPath):
        removeDir($repoPath)
      let err =
        if msg.len > 0: $status & ": " & msg
        else: $status
      raise newException(IOError, "cannot clone mirrored repo: " & err)

  template recloneBareRepo(reason: string) =
    warn "atlas:pkger",
      reason,
      info.name,
      "path:",
      $repoPath
    cloneFreshBareRepo()

  if not dirExists($repoPath) and dirExists($legacyRepoPath):
    createDir($workspaceRoot)
    if isBareGitRepo(legacyRepoPath):
      notice "atlas:pkger",
        "renaming legacy bare repo cache:",
        $legacyRepoPath,
        "to:",
        $repoPath
      moveDir($legacyRepoPath, $repoPath)
    elif isGitDir(legacyRepoPath):
      warn "atlas:pkger",
        "legacy repo cache is not bare; recloning bare repo:",
        info.name,
        "path:",
        $legacyRepoPath
      removeDir($legacyRepoPath)
      cloneFreshBareRepo()
    else:
      warn "atlas:pkger",
        "legacy repo cache is not a git repo; recloning bare repo:",
        info.name,
        "path:",
        $legacyRepoPath
      removeDir($legacyRepoPath)
      cloneFreshBareRepo()
  elif dirExists($repoPath) and dirExists($legacyRepoPath):
    removeDir($legacyRepoPath)

  if dirExists($repoPath):
    if not isBareGitRepo(repoPath):
      recloneBareRepo("existing repo cache is not bare; recloning bare repo:")
    elif not isUsableBareGitRepo(repoPath):
      recloneBareRepo("existing bare repo is unusable; recloning bare repo:")
    if updateRepos and not updateBareRepoDefaultBranch(repoPath):
      if not isUsableBareGitRepo(repoPath):
        recloneBareRepo("could not update unusable mirrored repo; recloning bare repo:")
      else:
        raise newException(IOError, "could not update mirrored repo")
  else:
    cloneFreshBareRepo()

  cleanupMirroredPackage(repoPath, worktreePath, removeRepo = false)
  if not addWorktreeFromBareRepo(repoPath, worktreePath):
    recloneBareRepo("could not create worktree from mirrored repo; recloning bare repo:")
    cleanupMirroredPackage(repoPath, worktreePath, removeRepo = false)
    if not addWorktreeFromBareRepo(repoPath, worktreePath):
      raise newException(IOError, "could not create worktree from mirrored repo")
  pkg.ondisk = worktreePath
  pkg.state = Found

proc loadPackageList*(packagesFile: Path): seq[PackageInfo] =
  let root = parseFile($packagesFile)
  for node in root:
    let info = packageinfos.fromJson(node)
    if info != nil:
      result.add info

proc addHeadToRetainedReleaseMetadata(
    retained: var JsonNode;
    releaseInfo: PackageReleaseInfo
) =
  if retained.isNil or retained.kind != JObject:
    return
  if releaseInfo.currentCommit.isEmpty():
    return
  let releases =
    if retained.hasKey("releases") and retained["releases"].kind == JArray: retained["releases"]
    else: nil
  if releases.isNil:
    return

  var matchingReleaseJson: JsonNode
  for entry in releases:
    if entry.kind != JObject or not entry.hasKey("v"):
      continue
    var vtag: VersionTag
    try:
      vtag.fromJson(entry["v"])
    except CatchableError:
      continue
    if vtag.version == Version"#head":
      return
    if matchingReleaseJson.isNil and vtag.commit == releaseInfo.currentCommit:
      matchingReleaseJson = entry.copy()

  var headRelease: NimbleRelease
  if matchingReleaseJson.isNil:
    for (ver, release) in releaseInfo.releases:
      if not ver.isNil and ver.vtag.commit == releaseInfo.currentCommit:
        headRelease = release
        break
    if headRelease.isNil:
      headRelease = NimbleRelease(version: Version"#head", status: Normal)
    matchingReleaseJson = toJsonHook(headRelease, ToJsonOptions(enumMode: joptEnumString))

  let headVtag = VersionTag(v: Version"#head", c: initCommitHash(releaseInfo.currentCommit, FromHead))
  var headEntry = newJObject()
  headEntry["v"] = toJson(headVtag, ToJsonOptions(enumMode: joptEnumString))
  for key, value in matchingReleaseJson:
    if key != "v":
      headEntry[key] = value.copy()
  releases.add headEntry

proc loadPackageReleaseMetadata(pkg: Package; releaseInfo: PackageReleaseInfo): JsonNode =
  let cachePath = packageReleaseCachePath(pkg)
  if not fileExists($cachePath):
    raise newException(IOError, "missing release cache: " & $cachePath)
  result = parseFile($cachePath)
  result.addHeadToRetainedReleaseMetadata(releaseInfo)

proc primeReleaseCacheFromRetainedMetadata(pkg: Package; workspaceRoot: Path) =
  let retainedPath = packageReleasesMetadataFile(workspaceRoot)
  if not fileExists($retainedPath):
    return
  let cachePath = packageReleaseCachePath(pkg)
  writeTextFileAtomic(cachePath, readFile($retainedPath))

proc cleanupTransientReleaseCache(pkg: Package) =
  if pkg.isNil:
    return
  let cachePath = packageReleaseCachePath(pkg)
  if fileExists($cachePath):
    removeFile($cachePath)

proc cleanupDanglingReleaseCaches(metadataDir: Path) =
  var removed = 0
  for kind, path in walkDir($metadataDir):
    if kind != pcFile:
      continue
    let tail = $path.Path.splitPath().tail
    if tail in ["packages.json", "index.json", "index-errors.json"]:
      continue
    if path.Path.splitFile().ext == ".json":
      removeFile(path)
      inc removed
  if removed > 0:
    notice "atlas:pkger", "cleaned dangling release caches:", $removed

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
  result = newJObject()
  let workspaceRoot = archiveDir.parentDir()
  let existingEntries = loadExistingArchiveEntries(packageReleasesMetadataFile(workspaceRoot))
  createDir($archiveDir)
  var usedStems = initHashSet[string]()
  var referencedFiles = initHashSet[string]()

  proc addTarballEntry(tarballs: JsonNode; versionLabel: string; entry: JsonNode) =
    if not tarballs.hasKey(versionLabel) or tarballs[versionLabel].kind != JArray:
      tarballs[versionLabel] = newJArray()
    tarballs[versionLabel].add entry

  for releaseEntry in archiveReleaseEntries(releaseInfo):
    let ver = releaseEntry.ver
    let release = releaseEntry.release
    if ver.isNil or ver.vtag.commit.h.len == 0:
      continue
    try:
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
            compressionName,
            contentHash
          )
          if existingEntry != nil and "f" in existingEntry:
            let archiveFile = existingEntry["f"].getStr()
            let archivePath = archiveDir / Path(archiveFile)
            if fileExists($archivePath):
              referencedFiles.incl(archiveFile)
              addTarballEntry result, label, initArchiveEntry(
                label,
                contentHash,
                archiveFile,
                rootSubdir,
                release
              )
              notice "atlas:pkger", "tarball:", relativeToCurrentDir(archivePath)
              continue

        let archiveFile = writeTrackedReleaseArchive(
          pkg, ver, archiveDir, rootStem, rootArchiveFiles, compression, siblingTempPath
        )
        let archivePath = archiveDir / Path(archiveFile)
        referencedFiles.incl(archiveFile)
        addTarballEntry result, label, initArchiveEntry(
          label,
          contentHash,
          archiveFile,
          rootSubdir,
          release
        )
        notice "atlas:pkger", "tarball:", relativeToCurrentDir(archivePath)
    except CatchableError as e:
      warn "atlas:pkger",
        "skipping release archive:",
        info.name,
        archiveReleaseLabel(ver, release, releaseEntry.isHead),
        ver.vtag.commit.short(),
        "reason:",
        e.msg

  for kind, path in walkDir($archiveDir):
    if kind != pcFile:
      continue
    let filename = $path.Path.splitPath().tail
    if path.Path.splitFile().ext in [".gz", ".xz", ".zip", ".tar"] and filename notin referencedFiles:
      removeFile(path)

proc metadataField(metadata: JsonNode; key: string): JsonNode =
  if metadata.kind == JObject and metadata.hasKey(key):
    result = metadata[key]
  else:
    result = newJNull()

proc comparableTarballEntry(entry: JsonNode): JsonNode =
  result = newJObject()
  if entry.kind != JObject:
    return entry.copy()
  for key, value in entry:
    if key notin ["generatedAt", "version", "size"]:
      result[key] = value.copy()

proc tarballSortKey(entry: JsonNode): string =
  if entry.kind != JObject:
    return $entry
  entry{"s"}.getStr() & "\t" & entry{"f"}.getStr()

proc metadataFieldAny(node: JsonNode; keys: openArray[string]): JsonNode =
  for key in keys:
    let value = node.metadataField(key)
    if not value.isNil:
      return value
  newJNull()

proc comparableTarballs(tarballs: JsonNode): JsonNode =
  if tarballs.kind != JObject:
    return tarballs.copy()

  var byRelease = initTable[string, seq[JsonNode]]()
  for version, value in tarballs:
    if value.kind == JArray:
      for entry in value:
        byRelease.mgetOrPut(version, @[]).add comparableTarballEntry(entry)
    elif value.kind == JObject:
      byRelease.mgetOrPut(version, @[]).add comparableTarballEntry(value)

  var versions: seq[string]
  for version in byRelease.keys:
    versions.add version
  versions.sort(cmp)

  result = newJObject()
  for version in versions:
    var entries = byRelease[version]
    entries.sort do (a, b: JsonNode) -> int:
      cmp(tarballSortKey(a), tarballSortKey(b))
    result[version] = newJArray()
    for entry in entries:
      result[version].add entry

proc canonicalForgeReleaseTag(entry: JsonNode): string =
  case entry.kind
  of JString:
    entry.getStr()
  of JObject:
    let tag = entry{"t"}.getStr()
    if tag.len > 0: tag
    else: entry{"v"}.getStr()
  else:
    $entry

proc forgeReleaseVersion(entry: JsonNode): string =
  case entry.kind
  of JString:
    ""
  of JObject:
    let tag = entry{"t"}.getStr()
    let version =
      if entry.hasKey("v"): entry["v"].getStr()
      else: tag
    if version.len > 0 and version != tag:
      version
    else:
      ""
  else:
    ""

proc comparableForgeReleases(forgeReleases: JsonNode): JsonNode =
  if forgeReleases.kind != JObject:
    return forgeReleases.copy()

  result = newJObject()
  let archives = forgeReleases.metadataField("archives")
  result["archives"] =
    if archives.isNil:
      newJNull()
    else:
      archives.copy()

  let releases = forgeReleases.metadataField("releases")
  let tagVersions = forgeReleases.metadataField("tagVersions")
  if releases.kind != JArray:
    result["releases"] = releases.copy()
    if tagVersions.kind == JObject:
      var normalizedTagVersions = newJObject()
      var tags: seq[string]
      for tag, version in tagVersions:
        let normalizedVersion = version.getStr()
        if tag.len > 0 and normalizedVersion.len > 0 and normalizedVersion != tag:
          tags.add tag
      tags.sort(cmp)
      for tag in tags:
        normalizedTagVersions[tag] = %tagVersions[tag].getStr()
      if normalizedTagVersions.len > 0:
        result["tagVersions"] = normalizedTagVersions
    elif not tagVersions.isNil:
      result["tagVersions"] = tagVersions.copy()
    let latest = forgeReleases.metadataField("latest")
    if not latest.isNil:
      result["latest"] = latest.copy()
    let prerelease = forgeReleases.metadataField("prerelease")
    if prerelease.kind == JArray:
      var tags: seq[string]
      for entry in prerelease:
        if entry.kind == JString:
          tags.add entry.getStr()
      tags.sort(cmp)
      result["prerelease"] = %tags
    elif not prerelease.isNil:
      result["prerelease"] = prerelease.copy()
    return

  var releaseTags: seq[string]
  var normalizedTagVersions = newJObject()
  var latestTag = forgeReleases{"latest"}.getStr()
  var prereleaseTags: seq[string]
  if tagVersions.kind == JObject:
    for tag, version in tagVersions:
      let normalizedVersion = version.getStr()
      if tag.len > 0 and normalizedVersion.len > 0 and normalizedVersion != tag:
        normalizedTagVersions[tag] = %normalizedVersion
  let prerelease = forgeReleases.metadataField("prerelease")
  if prerelease.kind == JArray:
    for entry in prerelease:
      if entry.kind == JString:
        prereleaseTags.add entry.getStr()
  for entry in releases:
    let tag = canonicalForgeReleaseTag(entry)
    if tag.len == 0:
      continue
    if entry.kind == JObject and entry{"latest"}.getBool():
      latestTag = tag
    if entry.kind == JObject and entry{"prerelease"}.getBool():
      prereleaseTags.add tag
    let version = forgeReleaseVersion(entry)
    if version.len > 0:
      normalizedTagVersions[tag] = %version
    releaseTags.add tag
  releaseTags.sort(cmp)
  var uniqueReleaseTags: seq[string]
  for tag in releaseTags:
    if uniqueReleaseTags.len == 0 or uniqueReleaseTags[^1] != tag:
      uniqueReleaseTags.add tag

  result["releases"] = newJArray()
  for tag in uniqueReleaseTags:
    result["releases"].add %tag
  if normalizedTagVersions.len > 0:
    var sortedTagVersions = newJObject()
    for tag in uniqueReleaseTags:
      if normalizedTagVersions.hasKey(tag):
        sortedTagVersions[tag] = normalizedTagVersions[tag]
    if sortedTagVersions.len > 0:
      result["tagVersions"] = sortedTagVersions
  if latestTag.len > 0:
    result["latest"] = %latestTag
  if prereleaseTags.len > 0:
    prereleaseTags.sort(cmp)
    var uniqueTags: seq[string]
    for tag in prereleaseTags:
      if uniqueTags.len == 0 or uniqueTags[^1] != tag:
        uniqueTags.add tag
    result["prerelease"] = %uniqueTags

proc comparableReleaseMetadata*(metadata: JsonNode): JsonNode =
  ## Normalize package release metadata down to the harvested fields that
  ## should trigger a releases.json rewrite on subsequent packager runs.
  result = newJObject()
  result["name"] = metadata.metadataField("name").copy()
  result["releases"] = metadata.metadataField("releases").copy()
  let tags = metadata.metadataField("tags")
  result["tags"] =
    if tags.isNil: newJNull()
    else: tags.copy()
  let tarballs = metadata.metadataField("tarballs")
  result["tarballs"] =
    if tarballs.isNil: newJNull()
    else: comparableTarballs(tarballs)
  let forge = metadataFieldAny(metadata, ["forge", "forgeReleases"])
  result["forge"] =
    if forge.isNil: newJNull()
    else: comparableForgeReleases(forge)

proc metadataChangeReason(
    hadExistingMetadata: bool;
    existingMetadata: JsonNode;
    metadata: JsonNode
): string =
  if not hadExistingMetadata:
    return "initial metadata"

  var reasons: seq[string]
  for field in [
      ("name", "name"),
      ("releases", "releases"),
      ("tags", "tags"),
      ("tarballs", "tarballs"),
      ("forge", "forge releases")
  ]:
    let key = field[0]
    let label = field[1]
    if existingMetadata.metadataField(key) != metadata.metadataField(key):
      reasons.add label & " changed"

  if reasons.len == 0:
    result = "metadata changed"
  else:
    result = reasons.join(", ")

proc mergePackageReleaseMetadata*(
    workspaceRoot: Path;
    info: PackageInfo;
    releaseMetadata: JsonNode;
    tarballEntries: JsonNode;
    tags: bool = false;
    forgeReleases: JsonNode = nil
) =
  let releasesMetadataPath = packageReleasesMetadataFile(workspaceRoot)
  createDir($workspaceRoot)
  var hadExistingMetadata = fileExists($releasesMetadataPath)
  var existingMetadata =
    try:
      parseFile($releasesMetadataPath)
    except CatchableError:
      hadExistingMetadata = false
      newJObject()
  if existingMetadata.isNil or existingMetadata.kind != JObject:
    existingMetadata = newJObject()

  var metadata =
    if releaseMetadata.isNil or releaseMetadata.kind != JObject:
      newJObject()
    else:
      releaseMetadata.copy()
  metadata["name"] = %info.name
  metadata["tags"] = %tags
  if tarballEntries.isNil or tarballEntries.kind == JNull:
    if metadata.hasKey("tarballs"):
      metadata.delete("tarballs")
  else:
    metadata["tarballs"] = tarballEntries
  if not forgeReleases.isNil:
    if forgeReleases.kind == JNull:
      if metadata.hasKey("forge"):
        metadata.delete("forge")
      if metadata.hasKey("forgeReleases"):
        metadata.delete("forgeReleases")
    else:
      if metadata.hasKey("forgeReleases"):
        metadata.delete("forgeReleases")
      metadata["forge"] = comparableForgeReleases(forgeReleases)

  let existingComparable = comparableReleaseMetadata(existingMetadata)
  let metadataComparable = comparableReleaseMetadata(metadata)

  let metadataChanged = metadataComparable != existingComparable
  if metadataChanged:
    let reason = metadataChangeReason(
      hadExistingMetadata,
      existingComparable,
      metadataComparable
    )
    metadata["generatedAt"] = %now().utc().format("yyyy-MM-dd'T'HH:mm:ss'Z'")
    writeTextFileAtomic(releasesMetadataPath, $metadata)
    notice "atlas:pkger",
      "updated metadata:",
      relativeToCurrentDir(releasesMetadataPath),
      "reason:",
      reason
  let digestPath = packageDigestFile(workspaceRoot)
  if fileExists($digestPath):
    removeFile($digestPath)

proc mergePackageForgeReleaseMetadata*(
    workspaceRoot: Path;
    info: PackageInfo;
    tags: bool;
    forgeReleases: JsonNode
) =
  let releasesMetadataPath = packageReleasesMetadataFile(workspaceRoot)
  if not fileExists($releasesMetadataPath):
    return

  var existingMetadata =
    try:
      parseFile($releasesMetadataPath)
    except CatchableError:
      return
  if existingMetadata.isNil or existingMetadata.kind != JObject:
    return

  mergePackageReleaseMetadata(
    workspaceRoot,
    info,
    existingMetadata,
    existingMetadata.metadataField("tarballs"),
    tags,
    forgeReleases
  )

proc summarizeErrorLine(message: string): string =
  result = message.replace('\n', ' ').replace('\r', ' ')
  while "  " in result:
    result = result.replace("  ", " ")
  result = result.strip()

proc classifyHarvestError(message: string): string =
  let normalized = summarizeErrorLine(message).toLowerAscii()
  if
      "terminal prompts disabled" in normalized or
      "could not read username" in normalized or
      "repository not found" in normalized or
      "unable to access" in normalized or
      "failed to connect" in normalized or
      "could not resolve host" in normalized or
      "permission denied" in normalized or
      "access denied" in normalized or
      "authentication failed" in normalized or
      "not a valid remote name" in normalized or
      "unable to read askpass response" in normalized:
    return "missing"
  if "clone" in normalized:
    return "clone"
  if "archive" in normalized or "tarball" in normalized or "compress" in normalized:
    return "archive"
  if "checksum" in normalized or "hash" in normalized:
    return "checksum"
  if "release cache" in normalized or "releases.json" in normalized:
    return "release"
  if "nimble" in normalized:
    return "nimble"
  if "fetch" in normalized or "remote" in normalized or "git" in normalized:
    return "git"
  if "permission" in normalized or "access" in normalized:
    return "access"
  if "timeout" in normalized:
    return "timeout"
  if "not found" in normalized or "missing" in normalized:
    return "missing"
  "unknown"

proc buildErrorsIndex(failures: openArray[HarvestFailure]): JsonNode =
  result = newJObject()
  for failure in failures:
    let detail = summarizeErrorLine(failure.errorMessage)
    let errorType = classifyHarvestError(detail)
    if errorType notin result or result[errorType].kind != JObject:
      result[errorType] = newJObject()
    var entry = newJObject()
    if detail.len > 0:
      entry["details"] = %detail
    result[errorType][failure.packageName] = entry

proc loadExistingErrorsIndex(metadataDir: Path): JsonNode =
  let errorsPath = errorsIndexPath(metadataDir)
  if fileExists($errorsPath):
    try:
      result = parseFile($errorsPath)
    except CatchableError:
      discard
  if result.isNil or result.kind != JObject:
    result = newJObject()

proc writeErrorsIndex(
    metadataDir: Path;
    failures: openArray[HarvestFailure];
    succeededPackages: openArray[string]
) =
  var errors = loadExistingErrorsIndex(metadataDir)
  let currentFailures = buildErrorsIndex(failures)
  for errorType, packages in mpairs(errors):
    if packages.kind != JObject:
      continue
    for packageName in succeededPackages:
      if packages.hasKey(packageName):
        packages.delete(packageName)
  for errorType, packages in currentFailures:
    if errorType notin errors or errors[errorType].kind != JObject:
      errors[errorType] = newJObject()
    for packageName, errInfo in packages:
      errors[errorType][packageName] = errInfo
  var emptyTypes: seq[string]
  for errorType, packages in errors:
    if packages.kind != JObject or packages.len == 0:
      emptyTypes.add errorType
  for errorType in emptyTypes:
    errors.delete(errorType)
  writeTextFileAtomic(errorsIndexPath(metadataDir), pretty(errors))

proc writeIndex(
    metadataDir: Path;
    packagesFile: Path;
    summary: HarvestSummary;
    packages: JsonNode;
    succeededPackages: seq[string];
    ephemeral: bool;
    compressions: openArray[ArchiveCompression];
    packageName = "";
    packageNames: seq[string] = @[];
    packagePrefixes: seq[string] = @[]
) =
  var index = newJObject()
  index["generatedAt"] = %now().utc().format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  index["releaseCacheVersion"] = %PackageReleaseCacheVersion
  index["packagesFile"] = %relativeIndexPath(metadataDir, packagesFile)
  index["releasesPath"] = %"{package}/releases"
  index["ephemeral"] = %ephemeral
  index["compressions"] = %archiveCompressionNames(compressions)
  if packageName.len > 0:
    index["package"] = %packageName
  elif packageNames.len > 0:
    index["packages"] = %(packageNames)
  if packagePrefixes.len > 0:
    index["packagePrefixes"] = %(packagePrefixes)
  index["packagesSeen"] = %summary.packagesSeen
  index["aliasesSkipped"] = %summary.aliasesSkipped
  index["packagesProcessed"] = %summary.packagesProcessed
  index["packagesFailed"] = %summary.packagesFailed
  index["taggedPackages"] = %summary.taggedPackages
  index["untaggedPackages"] = %summary.untaggedPackages
  index["taggedReleases"] = %summary.taggedReleases
  index["untaggedReleases"] = %summary.untaggedReleases
  if summary.releaseCounts.len > 0:
    var counts = summary.releaseCounts
    counts.sort()
    var totalReleases = 0
    for count in counts:
      totalReleases += count
    let average = totalReleases.float / counts.len.float
    let median =
      if counts.len mod 2 == 1:
        counts[counts.len div 2].float
      else:
        (counts[counts.len div 2 - 1].float + counts[counts.len div 2].float) / 2.0
    index["releasesPerPackageAvg"] = %formatFloat(average, ffDecimal, 2)
    index["releasesPerPackageMedian"] = %formatFloat(median, ffDecimal, 2)
  index["errorsPath"] = %"index-errors.json"
  index["packages"] = packages
  writeErrorsIndex(metadataDir, summary.failures, succeededPackages)
  writeTextFileAtomic(metadataDir / Path("index.json"), pretty(index))

proc harvestPackage(
    nc: var NimbleContext;
    info: PackageInfo;
    metadataDir: Path;
    ephemeral: bool;
    updateRepos: bool;
    skipRepoUpdatePackages: HashSet[string];
    packageForgeMetadata: Table[string, PackageForgeMetadata];
    compressions: openArray[ArchiveCompression];
    harvestRoot: Path;
    regenerateTarballs: bool;
    createTarballs: bool
): PackageHarvestResult =
  notice "atlas:pkger", "processing package:", info.name
  let workspaceRoot = resolvePackageWorkspaceRoot(harvestRoot, info)
  let previousContext = context()
  var packageContext = previousContext
  var pkg: Package
  let repoPath = packageRepoMirrorPath(workspaceRoot, info)
  let worktreePath = packageRepoWorktreePath(workspaceRoot)
  packageContext.depsDir = workspaceRoot
  createDir($packageContext.depsDir)
  setContext(packageContext)
  try:
    pkg = nc.initRegistryPackage(info)
    primeReleaseCacheFromRetainedMetadata(pkg, workspaceRoot)
    prepareMirroredPackageRepo(
      pkg,
      info,
      workspaceRoot,
      shouldUpdatePackageRepo(updateRepos, skipRepoUpdatePackages, info.name)
    )

    let releaseInfo = nc.loadPackageReleaseInfo(pkg, AllReleases, @[])
    let releaseMetadata = loadPackageReleaseMetadata(pkg, releaseInfo)
    let tarballEntries =
      if createTarballs:
        collectReleaseArchives(
          pkg,
          info,
          releaseInfo,
          packageReleasesDir(workspaceRoot),
          compressions,
          regenerateTarballs
        )
      else:
        newJNull()
    var releaseCount = 0
    var hasGitTags = false
    for (ver, _) in releaseInfo.releases:
      if ver.isNil or ver.vtag.version == Version"#head":
        continue
      inc releaseCount
      result.releaseVtags.incl $ver.vtag
      if ver.vtag.commit.orig == FromGitTag:
        hasGitTags = true
    mergePackageReleaseMetadata(
      workspaceRoot,
      info,
      releaseMetadata,
      tarballEntries,
      hasGitTags
    )
    if packageForgeMetadata.hasKey(info.name):
      let forgeMetadata = packageForgeMetadata[info.name]
      mergePackageForgeReleaseMetadata(
        workspaceRoot,
        info,
        forgeMetadata.tags,
        forgeMetadata.forgeReleases
      )
    result.ok = true
    result.packageName = info.name
    result.latestCommit = releaseInfo.currentCommit.h
    result.releaseCount = releaseCount
    result.hasGitTags = hasGitTags
    result.tarballs = tarballEntries
  finally:
    cleanupTransientReleaseCache(pkg)
    cleanupMirroredPackage(repoPath, worktreePath, removeRepo = ephemeral)
    setContext(previousContext)

proc harvestWorker(
    queue: ptr PackageQueue;
    baseContext: AtlasContext;
    metadataDir: Path;
    ephemeral: bool;
    updateRepos: bool;
    skipRepoUpdatePackages: HashSet[string];
    packageForgeMetadata: Table[string, PackageForgeMetadata];
    compressions: seq[ArchiveCompression];
    regenerateTarballs: bool;
    createTarballs: bool
): HarvestWorkerResult {.gcsafe.} =
  setContext(baseContext)
  let harvestRoot = baseContext.depsDir().absolutePath()
  var nc = block:
    {.cast(gcsafe).}:
      createNimbleContext()
  var info: PackageInfo
  while popPackage(queue, info):
    try:
      let packageResult = block:
        {.cast(gcsafe).}:
          nc.harvestPackage(
            info,
            metadataDir,
            ephemeral,
            updateRepos,
            skipRepoUpdatePackages,
            packageForgeMetadata,
            compressions,
            harvestRoot,
            regenerateTarballs,
            createTarballs
          )
      if packageResult.ok:
        result.packageResults.add packageResult
        inc result.packagesProcessed
        result.releaseCounts.add packageResult.releaseCount
        if packageResult.hasGitTags:
          inc result.taggedPackages
          result.taggedReleases += packageResult.releaseCount
        else:
          inc result.untaggedPackages
          result.untaggedReleases += packageResult.releaseCount
    except CatchableError as e:
      block:
        {.cast(gcsafe).}:
          error "atlas:pkger",
            "stopped processing package:",
            info.name,
            "reason:",
            e.msg
      result.failures.add HarvestFailure(packageName: info.name, errorMessage: e.msg)
      inc result.packagesFailed

proc harvestRegistryCaches*(
    packagesFile: Path;
    metadataDir: Path;
    ephemeral: bool,
    updateRepos: bool,
    skipRepoUpdatePackages: HashSet[string];
    packageForgeMetadata: Table[string, PackageForgeMetadata];
    pkgNames: seq[string];
    pkgPrefixes: seq[string];
    ignoredPkgNames: seq[string];
    compressions: openArray[ArchiveCompression];
    threadCount: int;
    regenerateTarballs: bool = false;
    createTarballs: bool = true
): HarvestSummary =
  createDir($metadataDir)
  cleanupDanglingReleaseCaches(metadataDir)

  let packageList = loadPackageList(packagesFile)
  var packageInfoByName = initTable[string, PackageInfo]()
  var queue: PackageQueue
  initLock(queue.lock)
  var packagesIndex = newJArray()
  var succeededPackages: seq[string]
  let retainedIndexMetadata = loadRetainedPackageIndexState(metadataDir)

  result.packagesSeen = packageList.len
  for info in packageList:
    packageInfoByName[info.name] = info
    if info.kind == pkAlias:
      inc result.aliasesSkipped
      continue
    elif not matchesPackageFilters(info.name, pkgNames, pkgPrefixes):
      continue
    elif info.name in ignoredPkgNames:
      continue

    queue.packages.add info
  queue.packages.sort(proc (a, b: PackageInfo): int = cmp(a.name, b.name))

  let workerCount = max(1, min(threadCount, max(1, queue.packages.len)))
  let baseContext = context()
  let compressionList = @compressions
  if workerCount == 1:
    let workerResult = harvestWorker(
      addr queue,
      baseContext,
      metadataDir,
      ephemeral,
      updateRepos,
      skipRepoUpdatePackages,
      packageForgeMetadata,
      compressionList,
      regenerateTarballs,
      createTarballs
    )
    result.packagesProcessed += workerResult.packagesProcessed
    result.packagesFailed += workerResult.packagesFailed
    result.taggedPackages += workerResult.taggedPackages
    result.untaggedPackages += workerResult.untaggedPackages
    result.taggedReleases += workerResult.taggedReleases
    result.untaggedReleases += workerResult.untaggedReleases
    result.releaseCounts.add workerResult.releaseCounts
    for failure in workerResult.failures:
      result.failures.add failure
      error "atlas:pkger", "failed package:", failure.packageName, "error:", failure.errorMessage
    for packageResult in workerResult.packageResults:
      let info = packageInfoByName[packageResult.packageName]
      succeededPackages.add packageResult.packageName
      let processedAt = now().utc().format("yyyy-MM-dd'T'HH:mm:ss'Z'")
      let retained =
        if retainedIndexMetadata.packages.hasKey(packageResult.packageName):
          retainedIndexMetadata.packages[packageResult.packageName]
        else:
          RetainedPackageIndexState()
      let changed =
        retained.lastUpdate.len == 0 or
        retained.latestCommit != packageResult.latestCommit or
        retained.releaseVtags != packageResult.releaseVtags
      var entry = newJObject()
      entry["name"] = %packageResult.packageName
      entry["latestCommit"] = %packageResult.latestCommit
      entry["releasesMetadata"] = %packageReleasesMetadataRelPath(info)
      entry["processedAt"] = %processedAt
      entry["lastUpdate"] =
        %(if changed: processedAt else: retained.lastUpdate)
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
        updateRepos,
        skipRepoUpdatePackages,
        packageForgeMetadata,
        compressionList,
        regenerateTarballs,
        createTarballs
      )
    for worker in workers:
      let workerResult = ^worker
      result.packagesProcessed += workerResult.packagesProcessed
      result.packagesFailed += workerResult.packagesFailed
      result.taggedPackages += workerResult.taggedPackages
      result.untaggedPackages += workerResult.untaggedPackages
      result.taggedReleases += workerResult.taggedReleases
      result.untaggedReleases += workerResult.untaggedReleases
      result.releaseCounts.add workerResult.releaseCounts
      for failure in workerResult.failures:
        result.failures.add failure
        error "atlas:pkger", "failed package:", failure.packageName, "error:", failure.errorMessage
      for packageResult in workerResult.packageResults:
        let info = packageInfoByName[packageResult.packageName]
        succeededPackages.add packageResult.packageName
        let processedAt = now().utc().format("yyyy-MM-dd'T'HH:mm:ss'Z'")
        let retained =
          if retainedIndexMetadata.packages.hasKey(packageResult.packageName):
            retainedIndexMetadata.packages[packageResult.packageName]
          else:
            RetainedPackageIndexState()
        let changed =
          retained.lastUpdate.len == 0 or
          retained.latestCommit != packageResult.latestCommit or
          retained.releaseVtags != packageResult.releaseVtags
        var entry = newJObject()
        entry["name"] = %packageResult.packageName
        entry["latestCommit"] = %packageResult.latestCommit
        entry["releasesMetadata"] = %packageReleasesMetadataRelPath(info)
        entry["processedAt"] = %processedAt
        entry["lastUpdate"] =
          %(if changed: processedAt else: retained.lastUpdate)
        packagesIndex.add entry
  deinitLock(queue.lock)

  writeIndex(
    metadataDir,
    packagesFile,
    result,
    packagesIndex,
    succeededPackages,
    ephemeral,
    compressions,
    packageNames = pkgNames,
    packagePrefixes = pkgPrefixes
  )
  cleanupDanglingReleaseCaches(metadataDir)
