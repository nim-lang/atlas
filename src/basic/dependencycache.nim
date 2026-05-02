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
    head*: CommitHash
    current*: CommitHash
    includeTagsAndNimbleCommits*: bool
    nimbleCommitsMax*: bool
    releases*: seq[PackageReleaseCacheEntry]

const PackageReleaseCacheVersion = 1

proc packageCacheStem*(url: PkgUrl): string =
  result = url.fullName()
  if result.len == 0:
    result = url.projectName()
  if result.len == 0:
    result = $url

  for c in mitems(result):
    if c notin {'a'..'z', 'A'..'Z', '0'..'9', '.', '_', '-'}:
      c = '_'

proc packageReleaseCachePath*(pkg: Package): Path =
  cachesDirectory() / Path(packageCacheStem(pkg.url) & ".json")

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
  let files = listFiles(pkg.ondisk, commit)
  for file in files:
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
  result = tmpDir / Path(packageCacheStem(pkg.url) & "-" & commit.short() & "-" & $source.path.splitPath().tail)
  writeFile($result, showFile(pkg.ondisk, commit, $source.path))

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
    cache.fromJson(parseFile($cachePath), Joptions(allowMissingKeys: true, allowExtraKeys: true))
  except CatchableError as e:
    warn pkg.url.projectName, "ignoring invalid dependency cache:", $cachePath, "error:", e.msg
    return false

  result =
    cache.cacheVersion == PackageReleaseCacheVersion and
    cache.url == pkg.url and
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
    head: pkg.originHead,
    current: currentCommit,
    includeTagsAndNimbleCommits: includeTagsAndNimbleCommitsFlag(),
    nimbleCommitsMax: nimbleCommitsMaxFlag()
  )
  for (ver, release) in versions:
    cache.releases.add PackageReleaseCacheEntry(vtag: ver.vtag, release: release)

  createDir(cachesDirectory())
  let cachePath = packageReleaseCachePath(pkg)
  writeFile($cachePath, pretty(toJson(cache, ToJsonOptions(enumMode: joptEnumString))))
  debug pkg.url.projectName, "wrote dependency cache:", $cachePath, "releases:", $cache.releases.len
