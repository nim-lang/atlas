#
#           Atlas Package Cloner
#        (c) Copyright 2026 The Atlas contributors
#

## Shared package release cache support.
##
## Locates a harvested packages repo under ``~/.atlas/packages`` and copies
## per-package ``releases.json`` files into a project's ``deps/.cache``.
## Atlas still validates the copied cache against the cloned repo HEAD, so
## stale mirrored caches fall back to the normal regeneration path.

import std / [json, os, paths, strutils, uri, httpclient, streams]
import context, dependencycache, deptypes, httpclientutils, reporters

const
  DefaultRemotePackagesRepo* = "https://github.com/elcritch/nim-packages"
  ## Default base URL for the remote packages metadata repo.

proc packagesRepoUrl*(): string =
  ## Return the configured packages repo URL, or the default.
  if context().packagesRepoUrl.len > 0:
    context().packagesRepoUrl
  else:
    DefaultRemotePackagesRepo

proc atlasHomeDirectory*(): Path =
  Path(getHomeDir()) / Path".atlas"

proc sharedPackagesRepoDir*(): Path =
  atlasHomeDirectory() / Path"packages"

proc sharedPackageReleasePath*(packageName: string; repoDir: Path): Path =
  if packageName.len == 0:
    return Path""
  let bucket = $packageName[0].toLowerAscii()
  repoDir / Path"pkgs" / Path(bucket) / Path(packageName) / Path"releases.json"

proc sharedPackageReleaseHeadPath*(packageName: string; repoDir: Path): Path =
  if packageName.len == 0:
    return Path""
  let bucket = $packageName[0].toLowerAscii()
  repoDir / Path"pkgs" / Path(bucket) / Path(packageName) / Path"release-head.json"

proc addHeadRelease(cacheJson: JsonNode; headJson: JsonNode) =
  if cacheJson.isNil or cacheJson.kind != JObject:
    return
  if headJson.isNil or headJson.kind != JObject or not headJson.hasKey("v"):
    return
  if not cacheJson.hasKey("releases") or cacheJson["releases"].kind != JArray:
    cacheJson["releases"] = newJArray()

  proc isHeadVtag(value: JsonNode): bool =
    case value.kind
    of JString:
      value.getStr().startsWith("#head@") or value.getStr() == "#head"
    of JObject:
      value{"v"}.getStr() == "#head"
    else:
      false

  if not isHeadVtag(headJson["v"]):
    return
  for entry in cacheJson["releases"]:
    if entry.kind == JObject and entry.hasKey("v") and isHeadVtag(entry["v"]):
      return
  cacheJson["releases"].add headJson

proc copySharedReleaseCache*(pkg: Package; repoDir: Path): bool =
  ## Copy the per-package releases.json from a shared packages repo into the
  ## project's deps/.cache directory. Only applies to official (packages.json)
  ## packages that are not forks, local links, or the project root.
  ##
  ## Returns true when the cache file was created or already exists.
  let packageName = pkg.projectName()
  if pkg.isRoot:
    return false
  elif not pkg.isOfficial or pkg.isFork or pkg.isLocalOnly:
    warn packageName, "shared release cache miss", "unofficial", $(not pkg.isOfficial), "fork", $pkg.isFork, "local", $pkg.isLocalOnly
    return false

  let sourcePath = sharedPackageReleasePath(packageName, repoDir)
  if sourcePath.len == 0 or not fileExists($sourcePath):
    warn packageName, "shared release cache missing"
    return false

  try:
    var cacheJson = parseFile($sourcePath)
    if not cacheJson.hasKey("releases") or cacheJson["releases"].kind != JArray:
      warn packageName, "shared release cache missing 'releases' array:", $sourcePath
      return false
    let headPath = sharedPackageReleaseHeadPath(packageName, repoDir)
    if fileExists($headPath):
      try:
        cacheJson.addHeadRelease(parseFile($headPath))
      except CatchableError as e:
        warn packageName, "shared release head cache invalid:", $headPath, "error:", e.msg

    createDir($cachesDirectory())
    let cachePath = packageReleaseCachePath(pkg)
    let contents = pretty(cacheJson)
    if fileExists($cachePath) and readFile($cachePath) == contents:
      return true

    let tmpPath = cachesDirectory() / Path(packageCacheStem(pkg) & ".json.tmp")
    writeFile($tmpPath, contents)
    if fileExists($cachePath):
      removeFile($cachePath)
    moveFile($tmpPath, $cachePath)
    return true
  except CatchableError as e:
    warn packageName, "failed to seed shared release cache:", e.msg
    return false

proc remoteReleaseCacheUrl*(packageName: string; baseUrl = ""): string =
  ## Build the raw.githubusercontent.com URL for a package's releases.json.
  ##
  ## The remote repo layout is: ``pkgs/<bucket>/<packageName>/releases.json``
  ## where ``bucket`` is the first character of the package name (lowercase).
  if packageName.len == 0:
    return ""
  let bucket = $packageName[0].toLowerAscii()

  # Convert github.com URLs to raw.githubusercontent.com for direct download.
  # e.g. https://github.com/elcritch/nim-packages → raw.githubusercontent.com/elcritch/nim-packages/main
  var rawBase = if baseUrl.len > 0: baseUrl else: packagesRepoUrl()
  if rawBase.contains("github.com") and not rawBase.contains("raw.githubusercontent.com"):
    rawBase = rawBase.replace("github.com", "raw.githubusercontent.com")
    if not rawBase.endsWith("/main") and not rawBase.endsWith("/refs/heads/main"):
      # Extract owner/repo from URL.
      var url = parseUri(rawBase)
      let pathParts = url.path.strip(chars={'/'}).split('/')
      if pathParts.len >= 2:
        url.hostname = "raw.githubusercontent.com"
        url.path = "/" & pathParts[0] & "/" & pathParts[1] & "/main"
      rawBase = $url

  result = rawBase.strip(chars={'/'}) & "/pkgs/" & bucket & "/" & packageName & "/releases.json"

proc remoteReleaseHeadCacheUrl*(packageName: string; baseUrl = ""): string =
  ## Build the raw URL for a package's release-head.json.
  if packageName.len == 0:
    return ""
  let releasesUrl = remoteReleaseCacheUrl(packageName, baseUrl)
  if releasesUrl.len == 0:
    return ""
  result = releasesUrl.replace("/releases.json", "/release-head.json")

proc cacheStemFromPackageName*(packageName: string): string =
  ## Build a plausible cache stem from just a package name.
  ## This is a best-effort approximation of ``packageCacheStem`` from
  ## ``dependencycache.nim``, used when we don't have a Package object yet.
  ##
  ## For official packages where we only know the short name, the stem is
  ## just the sanitized package name. For full fidelity, use
  ## ``packageCacheStem(pkg)`` once the Package object is available.
  result = packageName
  for c in mitems(result):
    if c notin {'a'..'z', 'A'..'Z', '0'..'9', '.', '_', '-'}:
      c = '_'

proc downloadReleaseCache*(packageName: string): bool =
  ## Download the remote releases.json for ``packageName`` and write it to
  ## ``deps/.cache/<stem>.json``.
  ##
  ## Returns ``true`` if the download succeeded. Failures are logged as
  ## warnings and the caller falls through to normal clone/processing.
  let cacheDir = cachesDirectory()
  if cacheDir.len == 0 or not dirExists($cacheDir):
    createDir($cacheDir)

  let url = remoteReleaseCacheUrl(packageName)
  if url.len == 0:
    return false

  # Compute a plausible cache path from the package name alone.
  let stem = cacheStemFromPackageName(packageName)
  let cachePath = cacheDir / Path(stem & ".json")

  # If cache already exists with a valid version, skip download.
  if fileExists($cachePath):
    try:
      let existing = parseFile($cachePath)
      if existing.hasKey("cv") and existing["cv"].getInt() == PackageReleaseCacheVersion:
        return true
    except CatchableError:
      discard

  let client = newAtlasHttpClient()
  try:
    info packageName, "downloading release cache from:", url
    let response = client.get(url)
    if response.code.is4xx or response.code.is5xx:
      return false

    let contents = response.bodyStream.readAll()
    if contents.len == 0:
      return false

    # Validate that it's parseable JSON and has a "releases" array.
    var jn: JsonNode
    try:
      jn = parseJson(contents)
    except CatchableError as e:
      warn packageName, "invalid JSON in release cache:", e.msg
      return false

    if not jn.hasKey("releases") or jn["releases"].kind != JArray:
      warn packageName, "release cache missing 'releases' array"
      return false

    let headUrl = remoteReleaseHeadCacheUrl(packageName)
    if headUrl.len > 0:
      try:
        let headResponse = client.get(headUrl)
        if not headResponse.code.is4xx and not headResponse.code.is5xx:
          let headContents = headResponse.bodyStream.readAll()
          if headContents.len > 0:
            jn.addHeadRelease(parseJson(headContents))
      except CatchableError as e:
        debug packageName, "failed to download release head cache:", e.msg

    # Ensure cv field is present for cache version validation.
    if not jn.hasKey("cv"):
      jn["cv"] = %PackageReleaseCacheVersion

    # Extract a head field from the releases if not already present.
    if not jn.hasKey("head") or jn["head"].getStr().len == 0:
      var headCommit = ""
      for entry in jn["releases"]:
        if entry.kind != JObject or not entry.hasKey("v"):
          continue
        let v = entry["v"].getStr()
        if v.startsWith("#head@"):
          headCommit = v.substr(6)  # strip "#head@"
          break
      if headCommit.len > 0:
        jn["head"] = %headCommit

    let tmpPath = cachePath.parentDir() / Path(".tmp." & stem & ".json")
    createDir($cachePath.parentDir())
    writeFile($tmpPath, pretty(jn))
    if fileExists($cachePath):
      removeFile($cachePath)
    moveFile($tmpPath, $cachePath)

    return true

  except CatchableError as e:
    warn packageName, "failed to download release cache:", e.msg
    return false
  finally:
    client.close()
