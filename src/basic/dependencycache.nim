#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std / [os, strutils, paths, dirs]
import context, deptypes, versions, gitops, pkgurls, reporters, deptypesjson

type
  NimbleFileSource* = object
    path*: Path
    fromGit*: bool

  PackageReleaseCacheEntry* = object
    vtag*: VersionTag
    release*: NimbleRelease

  PackageReleaseCache = object
    cacheVersion*: int
    url*: PkgUrl
    subdir*: Path
    shortName*: string
    fullName*: string
    head*: CommitHash
    current*: CommitHash
    author*: string
    description*: string
    license*: string
    includeTagsAndNimbleCommits*: bool
    nimbleCommitsMax*: bool
    releases*: seq[PackageReleaseCacheEntry]

const
  PackageReleaseCacheVersion = 2

proc sanitizeCacheStem(stem: var string) =
  for c in mitems(stem):
    if c notin {'a'..'z', 'A'..'Z', '0'..'9', '.', '_', '-'}:
      c = '_'

proc packageCacheStem*(url: PkgUrl; subdir = ""): string =
  result = url.fullName()
  if result.len == 0:
    result = url.projectName()
  if result.len == 0:
    result = $url

  if subdir.len > 0:
    var subdirStem = subdir
    sanitizeCacheStem(subdirStem)
    result.add "."
    result.add subdirStem

  sanitizeCacheStem(result)

proc packageCacheStem*(pkg: Package): string =
  let subdir =
    if pkg.subdir.len > 0: pkg.subdir
    else: pkg.url.subdir()
  packageCacheStem(pkg.url, $subdir)

proc packageReleaseCachePath*(pkg: Package): Path =
  cachesDirectory() / Path(packageCacheStem(pkg) & ".json")

proc includeTagsAndNimbleCommitsFlag*(): bool =
  IncludeTagsAndNimbleCommits in context().flags

proc nimbleCommitsMaxFlag*(): bool =
  NimbleCommitsMax in context().flags

proc canUsePackageReleaseCache*(
    pkg: Package;
    mode: TraversalMode;
    explicitVersions: seq[VersionTag]
): bool =
  mode == AllReleases and
    explicitVersions.len == 0 and
    not pkg.isRoot and
    not pkg.isAtlasProject and
    not pkg.url.isNimbleLink() and
    not pkg.isLocalOnly

proc findGitNimbleFiles*(pkg: Package; commit: CommitHash): seq[NimbleFileSource] =
  let subdir =
    if pkg.subdir.len > 0: pkg.subdir
    else: pkg.url.subdir()
  let files = listFiles(pkg.ondisk, commit)
  for file in files:
    if subdir.len > 0:
      let prefix = subdir.string.strip(leading=false, trailing=true, {'/'}) & "/"
      if not file.startsWith(prefix):
        continue
    if file.endsWith(".nimble"):
      let source = NimbleFileSource(path: Path(file), fromGit: true)
      if source.path.splitPath().tail == Path(pkg.url.shortName() & ".nimble"):
        return @[source]
      result.add source

proc materializeNimbleFile*(pkg: Package; commit: CommitHash; source: NimbleFileSource): Path =
  if not source.fromGit:
    return source.path

  let tmpDir = cachesDirectory() / Path"_tmp"
  createDir(cachesDirectory())
  createDir(tmpDir)
  result = tmpDir / Path(packageCacheStem(pkg) & "-" & commit.short() & "-" & $source.path.splitPath().tail)
  writeFile($result, showFile(pkg.ondisk, commit, $source.path))

proc firstNonEmptyMetadata(
    versions: seq[(PackageVersion, NimbleRelease)];
    field: proc (release: NimbleRelease): string
): string =
  for (_, release) in versions:
    if not release.isNil:
      result = field(release)
      if result.len > 0:
        return

proc toPackageReleaseCacheJson(cache: PackageReleaseCache; opt: ToJsonOptions): JsonNode =
  result = newJObject()
  result["cacheVersion"] = toJson(cache.cacheVersion, opt)
  result["url"] = toJson(cache.url, opt)
  if cache.subdir.len > 0:
    result["subdir"] = toJson(cache.subdir, opt)
  if cache.shortName.len > 0:
    result["shortName"] = toJson(cache.shortName, opt)
  if cache.fullName.len > 0:
    result["fullName"] = toJson(cache.fullName, opt)
  result["head"] = toJson(cache.head, opt)
  result["current"] = toJson(cache.current, opt)
  if cache.author.len > 0:
    result["author"] = toJson(cache.author, opt)
  if cache.description.len > 0:
    result["description"] = toJson(cache.description, opt)
  if cache.license.len > 0:
    result["license"] = toJson(cache.license, opt)
  result["includeTagsAndNimbleCommits"] = toJson(cache.includeTagsAndNimbleCommits, opt)
  result["nimbleCommitsMax"] = toJson(cache.nimbleCommitsMax, opt)
  result["releases"] = newJArray()

  for entry in cache.releases:
    var entryJson = newJObject()
    entryJson["vtag"] = toJson(entry.vtag, opt)
    let releaseJson = toJsonHook(entry.release, opt)
    if not entry.release.isNil:
      if entry.release.author == cache.author and releaseJson.hasKey("author"):
        releaseJson.delete("author")
      if entry.release.description == cache.description and releaseJson.hasKey("description"):
        releaseJson.delete("description")
      if entry.release.license == cache.license and releaseJson.hasKey("license"):
        releaseJson.delete("license")
    entryJson["release"] = releaseJson
    result["releases"].add entryJson

proc loadPackageReleaseCacheJson(cache: var PackageReleaseCache; jn: JsonNode) =
  cache.fromJson(jn, Joptions(allowMissingKeys: true, allowExtraKeys: true))
  for entry in mitems(cache.releases):
    if not entry.release.isNil:
      if entry.release.author.len == 0:
        entry.release.author = cache.author
      if entry.release.description.len == 0:
        entry.release.description = cache.description
      if entry.release.license.len == 0:
        entry.release.license = cache.license

proc loadPackageReleaseCache*(
    pkg: Package;
    currentCommit: CommitHash;
    entries: var seq[PackageReleaseCacheEntry]
): bool =
  if pkg.originHead.isEmpty():
    return false

  let cachePath = packageReleaseCachePath(pkg)
  if not fileExists($cachePath):
    return false

  var cache: PackageReleaseCache
  try:
    cache.loadPackageReleaseCacheJson(parseFile($cachePath))
  except CatchableError as e:
    warn pkg.url.projectName, "ignoring invalid dependency cache:", $cachePath, "error:", e.msg
    return false

  if cache.cacheVersion != PackageReleaseCacheVersion:
    debug pkg.url.projectName, "ignoring stale dependency cache:", $cachePath,
      "version:", $cache.cacheVersion, "expected:", $PackageReleaseCacheVersion
    return false

  result =
    cache.url == pkg.url and
    cache.subdir == (if pkg.subdir.len > 0: pkg.subdir else: pkg.url.subdir()) and
    cache.head == pkg.originHead and
    cache.current == currentCommit and
    cache.includeTagsAndNimbleCommits == includeTagsAndNimbleCommitsFlag() and
    cache.nimbleCommitsMax == nimbleCommitsMaxFlag()

  if result:
    entries = cache.releases
    debug pkg.url.projectName, "loaded dependency cache:", $cachePath, "releases:", $entries.len

proc savePackageReleaseCache*(
    pkg: Package;
    currentCommit: CommitHash;
    versions: seq[(PackageVersion, NimbleRelease)]
) =
  if pkg.originHead.isEmpty():
    return

  var cache = PackageReleaseCache(
    cacheVersion: PackageReleaseCacheVersion,
    url: pkg.url,
    subdir: if pkg.subdir.len > 0: pkg.subdir else: pkg.url.subdir(),
    shortName: pkg.url.shortName(),
    fullName: pkg.url.fullName(),
    head: pkg.originHead,
    current: currentCommit,
    author: firstNonEmptyMetadata(versions, proc (release: NimbleRelease): string = release.author),
    description: firstNonEmptyMetadata(versions, proc (release: NimbleRelease): string = release.description),
    license: firstNonEmptyMetadata(versions, proc (release: NimbleRelease): string = release.license),
    includeTagsAndNimbleCommits: includeTagsAndNimbleCommitsFlag(),
    nimbleCommitsMax: nimbleCommitsMaxFlag()
  )
  for (ver, release) in versions:
    cache.releases.add PackageReleaseCacheEntry(vtag: ver.vtag, release: release)

  createDir(cachesDirectory())
  let cachePath = packageReleaseCachePath(pkg)
  var cacheJson = toPackageReleaseCacheJson(cache, ToJsonOptions(enumMode: joptEnumString))
  let tmpPath = cachesDirectory() / Path(packageCacheStem(pkg) & ".json.tmp")
  writeFile($tmpPath, pretty(cacheJson))
  if fileExists($cachePath):
    removeFile($cachePath)
  moveFile($tmpPath, $cachePath)
  debug pkg.url.projectName, "wrote dependency cache:", $cachePath, "releases:", $cache.releases.len
