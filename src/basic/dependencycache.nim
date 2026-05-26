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
    fqn*: string
    head*: CommitHash
    current*: CommitHash
    author*: string
    description*: string
    license*: string
    nimVersion*: Version
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
    includeTagsAndNimbleCommits*: bool
    nimbleCommitsMax*: bool
    releases*: seq[PackageReleaseCacheEntry]

const
  PackageReleaseCacheVersion* = 18

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
    field: proc (release: NimbleRelease): Path
): Path =
  for (_, release) in versions:
    if not release.isNil:
      result = field(release)
      if result.len > 0:
        return

proc firstNonEmptyMetadata(
    versions: seq[(PackageVersion, NimbleRelease)];
    field: proc (release: NimbleRelease): Version
): Version =
  for (_, release) in versions:
    if not release.isNil:
      result = field(release)
      if result != Version"":
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

proc compactLiftedReleaseMetadata*(
    releaseJson: JsonNode;
    release: NimbleRelease;
    cache: JsonNode;
    opt: ToJsonOptions = ToJsonOptions(enumMode: joptEnumString)
) =
  if releaseJson.isNil or releaseJson.kind != JObject:
    return
  if cache.isNil or cache.kind != JObject:
    return

  template removeMatching(entryKey, cacheKey: string) =
    if releaseJson.hasKey(entryKey) and cache.hasKey(cacheKey) and
        releaseJson[entryKey] == cache[cacheKey]:
      releaseJson.delete(entryKey)

  template addEmptyOverride(entryKey, cacheKey: string, value: untyped) =
    if not releaseJson.hasKey(entryKey) and cache.hasKey(cacheKey):
      releaseJson[entryKey] = toJson(value, opt)

  removeMatching("n", "name")
  removeMatching("a", "author")
  removeMatching("d", "description")
  removeMatching("l", "license")
  removeMatching("m", "nim")
  removeMatching("s", "srcDir")
  removeMatching("b", "binDir")
  removeMatching("x", "skipDirs")
  removeMatching("y", "skipFiles")
  removeMatching("z", "skipExt")
  removeMatching("i", "installDirs")
  removeMatching("j", "installFiles")
  removeMatching("k", "installExt")
  removeMatching("p", "bin")
  removeMatching("o", "namedBin")
  removeMatching("e", "backend")

  if release.isNil:
    return
  if release.binDir.len == 0:
    addEmptyOverride("b", "binDir", release.binDir)
  if release.skipDirs.len == 0:
    addEmptyOverride("x", "skipDirs", release.skipDirs)
  if release.skipFiles.len == 0:
    addEmptyOverride("y", "skipFiles", release.skipFiles)
  if release.skipExt.len == 0:
    addEmptyOverride("z", "skipExt", release.skipExt)
  if release.installDirs.len == 0:
    addEmptyOverride("i", "installDirs", release.installDirs)
  if release.installFiles.len == 0:
    addEmptyOverride("j", "installFiles", release.installFiles)
  if release.installExt.len == 0:
    addEmptyOverride("k", "installExt", release.installExt)
  if release.bin.len == 0:
    addEmptyOverride("p", "bin", release.bin)
  if release.namedBin.len == 0:
    addEmptyOverride("o", "namedBin", release.namedBin)
  if release.backend.len == 0:
    addEmptyOverride("e", "backend", release.backend)

proc toPackageReleaseCacheJson(cache: PackageReleaseCache; opt: ToJsonOptions): JsonNode =
  result = newJObject()
  result["cv"] = toJson(cache.cacheVersion, opt)
  if cache.name.len > 0:
    result["name"] = toJson(cache.name, opt)
  if cache.subdir.len > 0:
    result["subdir"] = toJson(cache.subdir, opt)
  if cache.fqn.len > 0:
    result["fqn"] = toJson(cache.fqn, opt)
  result["head"] = toJson(cache.head, opt)
  if cache.author.len > 0:
    result["author"] = toJson(cache.author, opt)
  if cache.description.len > 0:
    result["description"] = toJson(cache.description, opt)
  if cache.license.len > 0:
    result["license"] = toJson(cache.license, opt)
  if cache.nimVersion != Version"":
    result["nim"] = toJson(cache.nimVersion, opt)
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
  if cache.includeTagsAndNimbleCommits:
    result["includeTagsAndNimbleCommits"] = toJson(cache.includeTagsAndNimbleCommits, opt)
  if cache.nimbleCommitsMax:
    result["nimbleCommitsMax"] = toJson(cache.nimbleCommitsMax, opt)
  result["releases"] = newJArray()

  for entry in cache.releases:
    var releaseJson = toJsonHook(entry.release, opt)
    if releaseJson.isNil or releaseJson.kind != JObject:
      releaseJson = newJObject()
    if not entry.release.isNil:
      if releaseJson.hasKey("n"):
        releaseJson.delete("n")
      if releaseJson.hasKey("v"):
        releaseJson.delete("v")
      if releaseJson.hasKey("g"):
        releaseJson.delete("g")  # hasBin is reconstructed from bin/namedBin on load
      releaseJson.compactLiftedReleaseMetadata(entry.release, result, opt)
    var entryJson = newJObject()
    entryJson["v"] = toJson(entry.vtag, opt)
    for key, value in releaseJson:
      if key notin ["v", "vtag"]:
        entryJson[key] = value
    result["releases"].add entryJson

proc loadPackageReleaseCacheJson(cache: var PackageReleaseCache; jn: JsonNode) =
  cache.fromJson(jn, Joptions(allowMissingKeys: true, allowExtraKeys: true))
  if jn.hasKey("cv"):
    cache.cacheVersion = jn["cv"].getInt()
  if jn.hasKey("author"):
    cache.author = jn["author"].getStr()
  if jn.hasKey("description"):
    cache.description = jn["description"].getStr()
  if jn.hasKey("nim"):
    cache.nimVersion.fromJson(jn["nim"])
  cache.releases.setLen(0)
  let releasesJson =
    if jn.hasKey("releases") and jn["releases"].kind == JArray: jn["releases"]
    else: newJArray()
  if releasesJson.kind == JArray:
    for rawEntry in releasesJson:
      if rawEntry.kind != JObject or not rawEntry.hasKey("v"):
        continue
      var entry: PackageReleaseCacheEntry
      entry.vtag.fromJson(rawEntry["v"])
      entry.release.fromJsonHook(rawEntry, Joptions(allowMissingKeys: true, allowExtraKeys: true))
      if entry.release.version == Version"":
        entry.release.version = entry.vtag.version
      cache.releases.add entry
  for i, entry in mpairs(cache.releases):
    if not entry.release.isNil:
      var entryJson = releasesJson[i]
      if entry.release.author.len == 0:
        entry.release.author = cache.author
      if entry.release.name.len == 0:
        entry.release.name = cache.name
      if entry.release.description.len == 0:
        entry.release.description = cache.description
      if entry.release.license.len == 0:
        entry.release.license = cache.license
      if entry.release.nimVersion == Version"" and not entryJson.hasKey("m"):
        entry.release.nimVersion = cache.nimVersion
      if not entryJson.hasKey("s"):
        entry.release.srcDir = cache.srcDir
      if not entryJson.hasKey("b"):
        entry.release.binDir = cache.binDir
      if not entryJson.hasKey("x"):
        entry.release.skipDirs = cache.skipDirs
      if not entryJson.hasKey("y"):
        entry.release.skipFiles = cache.skipFiles
      if not entryJson.hasKey("z"):
        entry.release.skipExt = cache.skipExt
      if not entryJson.hasKey("i"):
        entry.release.installDirs = cache.installDirs
      if not entryJson.hasKey("j"):
        entry.release.installFiles = cache.installFiles
      if not entryJson.hasKey("k"):
        entry.release.installExt = cache.installExt
      if not entryJson.hasKey("p"):
        entry.release.bin = cache.bin
      if not entryJson.hasKey("o"):
        entry.release.namedBin = cache.namedBin
      if not entryJson.hasKey("e"):
        entry.release.backend = cache.backend
      entry.release.hasBin = entry.release.bin.len > 0 or entry.release.namedBin.len > 0

proc loadPackageReleaseCache*(
    pkg: Package;
    entries: var seq[PackageReleaseCacheEntry]
): (bool, string) =
  if pkg.originHead.isEmpty():
    return (false, "empty origin head")

  let cachePath = packageReleaseCachePath(pkg)
  if not fileExists($cachePath):
    return (false, "cache file missing")

  var cache: PackageReleaseCache
  try:
    cache.loadPackageReleaseCacheJson(parseFile($cachePath))
  except CatchableError as e:
    warn pkg.url.projectName, "ignoring invalid dependency cache:", $cachePath, "error:", e.msg
    return (false, "invalid cache json")

  if cache.cacheVersion != PackageReleaseCacheVersion:
    debug pkg.url.projectName, "ignoring stale dependency cache:", $cachePath,
      "version:", $cache.cacheVersion, "expected:", $PackageReleaseCacheVersion
    return (false, "stale cache version")

  var mismatches: seq[string]
  if cache.fqn.len > 0 and cache.fqn != pkg.url.fullName():
    mismatches.add("fqn cache=" & cache.fqn & " pkg=" & pkg.url.fullName())
  if cache.subdir != (if pkg.subdir.len > 0: pkg.subdir else: pkg.url.subdir()):
    let pkgSubdir = if pkg.subdir.len > 0: pkg.subdir else: pkg.url.subdir()
    mismatches.add("subdir cache=" & $cache.subdir & " pkg=" & $pkgSubdir)
  if cache.head != pkg.originHead:
    mismatches.add("originHead cache=" & cache.head.short() & "/" & $cache.head.orig & " pkg=" & pkg.originHead.short() & "/" & $pkg.originHead.orig)
  if cache.includeTagsAndNimbleCommits != includeTagsAndNimbleCommitsFlag():
    mismatches.add("includeTagsAndNimbleCommits cache=" & $cache.includeTagsAndNimbleCommits & " pkg=" & $includeTagsAndNimbleCommitsFlag())
  if cache.nimbleCommitsMax != nimbleCommitsMaxFlag():
    mismatches.add("nimbleCommitsMax cache=" & $cache.nimbleCommitsMax & " pkg=" & $nimbleCommitsMaxFlag())

  if mismatches.len > 0:
    return (false, "cache metadata mismatch: " & mismatches.join(", "))

  entries = cache.releases
  debug pkg.url.projectName, "loaded dependency cache:", $cachePath, "releases:", $entries.len
  return (true, "")

proc loadPackageReleaseCache*(
    pkg: Package;
    currentCommit: CommitHash;
    entries: var seq[PackageReleaseCacheEntry]
): bool =
  var pkgWithHead = pkg
  if pkgWithHead.originHead.isEmpty():
    pkgWithHead.originHead = currentCommit
  let (ok, _) = loadPackageReleaseCache(pkgWithHead, entries)
  ok

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
    fqn: pkg.url.fullName(),
    head: pkg.originHead,
    author: firstNonEmptyMetadata(versions, proc (release: NimbleRelease): string = release.author),
    description: firstNonEmptyMetadata(versions, proc (release: NimbleRelease): string = release.description),
    license: firstNonEmptyMetadata(versions, proc (release: NimbleRelease): string = release.license),
    nimVersion: firstNonEmptyMetadata(versions, proc (release: NimbleRelease): Version = release.nimVersion),
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
