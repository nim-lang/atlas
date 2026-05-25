#
#           Atlas Package Cloner
#        (c) Copyright 2026 The Atlas contributors
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Forge release tarball download and extraction.
##
## Parses ``forge`` metadata from release caches, downloads source tarballs
## from GitHub/GitLab releases into ``~/.atlas/caches/forge/``, and extracts
## them into the package's on-disk location as a git-clone replacement.

import std / [json, os, paths, strutils, uri, httpclient, streams, options, osproc]
import context, deptypes, httpclientutils, pkgurls, reporters, versions

type
  ForgeMetadata* = object
    archives*: Table[string, string]
    releases*: seq[string]
    tagVersions*: Table[string, string]
    latest*: string
    prerelease*: seq[string]

proc parseForgeMetadata*(jn: JsonNode): Option[ForgeMetadata] =
  if jn.isNil or jn.kind != JObject:
    return none(ForgeMetadata)

  var fm: ForgeMetadata
  if jn.hasKey("archives") and jn["archives"].kind == JObject:
    for key, val in jn["archives"]:
      fm.archives[$key] = val.getStr()
  if jn.hasKey("releases") and jn["releases"].kind == JArray:
    for entry in jn["releases"]:
      if entry.kind == JString:
        fm.releases.add entry.getStr()
  if jn.hasKey("tagVersions") and jn["tagVersions"].kind == JObject:
    for key, val in jn["tagVersions"]:
      fm.tagVersions[$key] = val.getStr()
  if jn.hasKey("latest"):
    fm.latest = jn["latest"].getStr()
  if jn.hasKey("prerelease") and jn["prerelease"].kind == JArray:
    for entry in jn["prerelease"]:
      if entry.kind == JString:
        fm.prerelease.add entry.getStr()

  if fm.archives.len == 0 or fm.releases.len == 0:
    return none(ForgeMetadata)

  result = some(fm)

proc resolveTagFromVersion*(forge: ForgeMetadata; version: Version): string =
  ## Find the forge tag name for a normalized version string.
  ## Checks tagVersions first, then falls back to matching in releases.
  ## Returns ``forge.latest`` when the version is ``#head``.
  let verStr = $version
  if verStr == "#head":
    return forge.latest
  for tag, ver in forge.tagVersions:
    if ver == verStr:
      return tag
  for tag in forge.releases:
    let normalized = tag.strip(chars={'v', 'V'})
    if normalized == verStr:
      return tag
  for tag in forge.releases:
    if tag == verStr:
      return tag

proc buildTarballUrl*(forge: ForgeMetadata; baseUrl: string; tagName: string;
    archiveType = "tar.gz"): string =
  ## Construct the full tarball URL from the base repo URL, archive template, and tag.
  let tmpl = forge.archives.getOrDefault(archiveType)
  if tmpl.len == 0:
    return ""
  result = baseUrl.strip(chars={'/'}) & tmpl.replace("{tag}", tagName)

proc forgeTarballCacheDir*(packageName: string): Path =
  ## Directory for cached forge tarballs under ~/.atlas/caches/forge/<pkgname>/.
  result = Path(getHomeDir()) / Path".atlas" / Path"caches" / Path"forge" / Path(packageName)

proc loadCacheHead*(cachePath: Path): string =
  ## Extract the head commit hash from a release cache JSON file.
  if not fileExists($cachePath):
    return ""
  try:
    let jn = parseFile($cachePath)
    result = jn{"head"}.getStr()
  except CatchableError:
    result = ""

proc hasForgeMetadata*(cachePath: Path): bool =
  ## Quick check: does the cache JSON contain a valid forge key?
  if not fileExists($cachePath):
    return false
  try:
    let jn = parseFile($cachePath)
    result = jn.hasKey("forge") and jn["forge"].kind == JObject and
             jn["forge"].hasKey("archives") and jn["forge"].hasKey("releases")
  except CatchableError:
    result = false

proc loadForgeMetadata*(cachePath: Path): Option[ForgeMetadata] =
  ## Load forge metadata from a release cache JSON file.
  if not fileExists($cachePath):
    return none(ForgeMetadata)
  try:
    let jn = parseFile($cachePath)
    if jn.hasKey("forge"):
      result = parseForgeMetadata(jn["forge"])
  except CatchableError:
    result = none(ForgeMetadata)

proc downloadForgeTarball*(url: string; destPath: Path): bool =
  ## Download a forge release tarball from ``url`` to ``destPath``.
  ## Writes atomically via .tmp + rename.
  if url.len == 0:
    return false

  createDir($destPath.parentDir())

  let client = newAtlasHttpClient()
  try:
    notice "forge tarball", "downloading:", url
    let response = client.get(url)
    if response.code.is4xx or response.code.is5xx:
      warn "forge tarball", "HTTP error:", $response.code, "url:", url
      return false

    let contents = response.bodyStream.readAll()
    if contents.len == 0:
      warn "forge tarball", "empty response body for:", url
      return false

    let tmpPath = destPath.parentDir() / Path(".tmp." & $destPath.splitPath().tail)
    writeFile($tmpPath, contents)
    if fileExists($destPath):
      removeFile($destPath)
    moveFile($tmpPath, $destPath)

    return true

  except CatchableError as e:
    warn "forge tarball", "download failed:", e.msg, "url:", url
    return false
  finally:
    client.close()

proc extractForgeTarball*(tarballPath: Path; destDir: Path): bool =
  ## Extract a .tar.gz tarball into ``destDir``, stripping the top-level component.
  if not fileExists($tarballPath):
    return false

  createDir($destDir)

  let cmd = "tar xzf " & quoteShell($tarballPath) &
            " -C " & quoteShell($destDir) &
            " --strip-components=1"
  let (outp, status) = execCmdEx(cmd)
  if status != 0:
    warn "forge tarball", "extraction failed:", outp, "cmd:", cmd
    return false
  notice "forge tarball", "extracted to:", $destDir
  return true

proc installForgePackage*(
    pkg: Package;
    forge: ForgeMetadata;
    tagName: string;
    destDir: Path;
    archiveType = "tar.gz"
): bool =
  ## Download (if not cached) and extract a forge release tarball into ``destDir``.
  let cacheDir = forgeTarballCacheDir(pkg.url.projectName())
  let cachePath = cacheDir / Path(tagName & "." & archiveType)
  let baseUrl = $pkg.url.cloneUri()
  let tarballUrl = buildTarballUrl(forge, baseUrl, tagName, archiveType)
  if tarballUrl.len == 0:
    warn pkg.url.projectName, "forge tarball: no archive URL template for:", archiveType
    return false

  if not fileExists($cachePath):
    if not downloadForgeTarball(tarballUrl, cachePath):
      warn pkg.url.projectName, "forge tarball: download failed for tag:", tagName
      return false

  createDir($destDir)

  if not extractForgeTarball(cachePath, destDir):
    warn pkg.url.projectName, "forge tarball: extraction failed for:", $cachePath
    return false

  notice pkg.url.projectName, "installed from forge tarball:", tagName, "at:", $destDir
  return true
