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
    name*: string
    url*: PkgUrl
    subdir*: Path
    fullName*: string
    head*: CommitHash
    current*: CommitHash
    author*: string
    description*: string
    license*: string
    srcDir*: Path
    binDir*: Path
    skipDirs*: seq[string]
    skipFiles*: seq[string]
    skipExt*: seq[string]
    installDirs*: seq[string]
    installFiles*: seq[string]
    installExt*: seq[string]
    bin*: seq[string]
    namedBin*: Table[string, string]
    backend*: string
    hasBin*: bool
    includeTagsAndNimbleCommits*: bool
    nimbleCommitsMax*: bool
    releases*: seq[PackageReleaseCacheEntry]

const
  PackageReleaseCacheVersion = 5
  PackageReleaseCacheVersion = 4

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

proc firstNonEmptyMetadata(
    versions: seq[(PackageVersion, NimbleRelease)];
    field: proc (release: NimbleRelease): seq[string]
): seq[string] =
  for (_, release) in versions:
    if not release.isNil:
      result = field(release)
      if result.len > 0:
        return

proc firstNonEmptyMetadata(
    versions: seq[(PackageVersion, NimbleRelease)];
    field: proc (release: NimbleRelease): Table[string, string]
): Table[string, string] =
  for (_, release) in versions:
    if not release.isNil:
      result = field(release)
      if result.len > 0:
        return

proc firstTrueMetadata(
    versions: seq[(PackageVersion, NimbleRelease)];
    field: proc (release: NimbleRelease): bool
): bool =
  for (_, release) in versions:
    if not release.isNil and field(release):
      return true

proc toPackageReleaseCacheJson(cache: PackageReleaseCache; opt: ToJsonOptions): JsonNode =
  result = newJObject()
  result["cacheVersion"] = toJson(cache.cacheVersion, opt)
  if cache.name.len > 0:
    result["name"] = toJson(cache.name, opt)
  result["url"] = toJson($(cache.url))
  if cache.subdir.len > 0:
    result["subdir"] = toJson(cache.subdir, opt)
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
  if cache.srcDir.len > 0:
    result["srcDir"] = toJson(cache.srcDir, opt)
  if cache.binDir.len > 0:
    result["binDir"] = toJson(cache.binDir, opt)
  if cache.skipDirs.len > 0:
    result["skipDirs"] = toJson(cache.skipDirs, opt)
  if cache.skipFiles.len > 0:
    result["skipFiles"] = toJson(cache.skipFiles, opt)
  if cache.skipExt.len > 0:
    result["skipExt"] = toJson(cache.skipExt, opt)
  if cache.installDirs.len > 0:
    result["installDirs"] = toJson(cache.installDirs, opt)
  if cache.installFiles.len > 0:
    result["installFiles"] = toJson(cache.installFiles, opt)
  if cache.installExt.len > 0:
    result["installExt"] = toJson(cache.installExt, opt)
  if cache.bin.len > 0:
    result["bin"] = toJson(cache.bin, opt)
  if cache.namedBin.len > 0:
    result["namedBin"] = toJson(cache.namedBin, opt)
  if cache.backend.len > 0:
    result["backend"] = toJson(cache.backend, opt)
  if cache.hasBin:
    result["hasBin"] = toJson(cache.hasBin, opt)
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
      if entry.release.srcDir == cache.srcDir and releaseJson.hasKey("srcDir"):
        releaseJson.delete("srcDir")
      elif entry.release.srcDir.len == 0 and cache.srcDir.len > 0:
        releaseJson["srcDir"] = toJson(entry.release.srcDir, opt)
      if entry.release.binDir == cache.binDir and releaseJson.hasKey("binDir"):
        releaseJson.delete("binDir")
      elif entry.release.binDir.len == 0 and cache.binDir.len > 0:
        releaseJson["binDir"] = toJson(entry.release.binDir, opt)
      if entry.release.skipDirs == cache.skipDirs and releaseJson.hasKey("skipDirs"):
        releaseJson.delete("skipDirs")
      elif entry.release.skipDirs.len == 0 and cache.skipDirs.len > 0:
        releaseJson["skipDirs"] = toJson(entry.release.skipDirs, opt)
      if entry.release.skipFiles == cache.skipFiles and releaseJson.hasKey("skipFiles"):
        releaseJson.delete("skipFiles")
      elif entry.release.skipFiles.len == 0 and cache.skipFiles.len > 0:
        releaseJson["skipFiles"] = toJson(entry.release.skipFiles, opt)
      if entry.release.skipExt == cache.skipExt and releaseJson.hasKey("skipExt"):
        releaseJson.delete("skipExt")
      elif entry.release.skipExt.len == 0 and cache.skipExt.len > 0:
        releaseJson["skipExt"] = toJson(entry.release.skipExt, opt)
      if entry.release.installDirs == cache.installDirs and releaseJson.hasKey("installDirs"):
        releaseJson.delete("installDirs")
      elif entry.release.installDirs.len == 0 and cache.installDirs.len > 0:
        releaseJson["installDirs"] = toJson(entry.release.installDirs, opt)
      if entry.release.installFiles == cache.installFiles and releaseJson.hasKey("installFiles"):
        releaseJson.delete("installFiles")
      elif entry.release.installFiles.len == 0 and cache.installFiles.len > 0:
        releaseJson["installFiles"] = toJson(entry.release.installFiles, opt)
      if entry.release.installExt == cache.installExt and releaseJson.hasKey("installExt"):
        releaseJson.delete("installExt")
      elif entry.release.installExt.len == 0 and cache.installExt.len > 0:
        releaseJson["installExt"] = toJson(entry.release.installExt, opt)
      if entry.release.bin == cache.bin and releaseJson.hasKey("bin"):
        releaseJson.delete("bin")
      elif entry.release.bin.len == 0 and cache.bin.len > 0:
        releaseJson["bin"] = toJson(entry.release.bin, opt)
      if entry.release.namedBin == cache.namedBin and releaseJson.hasKey("namedBin"):
        releaseJson.delete("namedBin")
      elif entry.release.namedBin.len == 0 and cache.namedBin.len > 0:
        releaseJson["namedBin"] = toJson(entry.release.namedBin, opt)
      if entry.release.backend == cache.backend and releaseJson.hasKey("backend"):
        releaseJson.delete("backend")
      elif entry.release.backend.len == 0 and cache.backend.len > 0:
        releaseJson["backend"] = toJson(entry.release.backend, opt)
      if entry.release.hasBin == cache.hasBin and releaseJson.hasKey("hasBin"):
        releaseJson.delete("hasBin")
      elif not entry.release.hasBin and cache.hasBin:
        releaseJson["hasBin"] = toJson(entry.release.hasBin, opt)
    entryJson["release"] = releaseJson
    result["releases"].add entryJson

proc loadPackageReleaseCacheJson(cache: var PackageReleaseCache; jn: JsonNode) =
  cache.fromJson(jn, Joptions(allowMissingKeys: true, allowExtraKeys: true))
  for i, entry in mpairs(cache.releases):
    if not entry.release.isNil:
      let releaseJson = jn["releases"][i]["release"]
      if entry.release.author.len == 0:
        entry.release.author = cache.author
      if entry.release.description.len == 0:
        entry.release.description = cache.description
      if entry.release.license.len == 0:
        entry.release.license = cache.license
      if not releaseJson.hasKey("srcDir"):
        entry.release.srcDir = cache.srcDir
      if not releaseJson.hasKey("binDir"):
        entry.release.binDir = cache.binDir
      if not releaseJson.hasKey("skipDirs"):
        entry.release.skipDirs = cache.skipDirs
      if not releaseJson.hasKey("skipFiles"):
        entry.release.skipFiles = cache.skipFiles
      if not releaseJson.hasKey("skipExt"):
        entry.release.skipExt = cache.skipExt
      if not releaseJson.hasKey("installDirs"):
        entry.release.installDirs = cache.installDirs
      if not releaseJson.hasKey("installFiles"):
        entry.release.installFiles = cache.installFiles
      if not releaseJson.hasKey("installExt"):
        entry.release.installExt = cache.installExt
      if not releaseJson.hasKey("bin"):
        entry.release.bin = cache.bin
      if not releaseJson.hasKey("namedBin"):
        entry.release.namedBin = cache.namedBin
      if not releaseJson.hasKey("backend"):
        entry.release.backend = cache.backend
      if not releaseJson.hasKey("hasBin"):
        entry.release.hasBin = cache.hasBin

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
    name: firstNonEmptyMetadata(versions, proc (release: NimbleRelease): string = release.name),
    url: pkg.url,
    subdir: if pkg.subdir.len > 0: pkg.subdir else: pkg.url.subdir(),
    fullName: pkg.url.fullName(),
    head: pkg.originHead,
    current: currentCommit,
    author: firstNonEmptyMetadata(versions, proc (release: NimbleRelease): string = release.author),
    description: firstNonEmptyMetadata(versions, proc (release: NimbleRelease): string = release.description),
    license: firstNonEmptyMetadata(versions, proc (release: NimbleRelease): string = release.license),
    srcDir: firstNonEmptyMetadata(versions, proc (release: NimbleRelease): Path = release.srcDir),
    binDir: firstNonEmptyMetadata(versions, proc (release: NimbleRelease): Path = release.binDir),
    skipDirs: firstNonEmptyMetadata(versions, proc (release: NimbleRelease): seq[string] = release.skipDirs),
    skipFiles: firstNonEmptyMetadata(versions, proc (release: NimbleRelease): seq[string] = release.skipFiles),
    skipExt: firstNonEmptyMetadata(versions, proc (release: NimbleRelease): seq[string] = release.skipExt),
    installDirs: firstNonEmptyMetadata(versions, proc (release: NimbleRelease): seq[string] = release.installDirs),
    installFiles: firstNonEmptyMetadata(versions, proc (release: NimbleRelease): seq[string] = release.installFiles),
    installExt: firstNonEmptyMetadata(versions, proc (release: NimbleRelease): seq[string] = release.installExt),
    bin: firstNonEmptyMetadata(versions, proc (release: NimbleRelease): seq[string] = release.bin),
    namedBin: firstNonEmptyMetadata(versions, proc (release: NimbleRelease): Table[string, string] = release.namedBin),
    backend: firstNonEmptyMetadata(versions, proc (release: NimbleRelease): string = release.backend),
    hasBin: firstTrueMetadata(versions, proc (release: NimbleRelease): bool = release.hasBin),
    includeTagsAndNimbleCommits: includeTagsAndNimbleCommitsFlag(),
    nimbleCommitsMax: nimbleCommitsMaxFlag()
  )
  if cache.name.len == 0:
    cache.name = pkg.url.shortName()
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
