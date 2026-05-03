#
#           Atlas Package Cloner
#        (c) Copyright 2021 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std / [json, os, sets, strutils, paths, dirs, httpclient, uri]
import context, reporters, gitops, pkgurls, httpclientutils

const
  UnitTests = defined(atlasUnitTests)
  PackagesJsonUrls* = [
    "https://packages.nim-lang.org/packages.json",
    "https://raw.githubusercontent.com/nim-lang/packages/refs/heads/master/packages.json"
  ]

when UnitTests:
  proc findAtlasDir*(): string =
    result = currentSourcePath().absolutePath
    while not result.endsWith("atlas"):
      result = result.parentDir
      assert result != "", "atlas dir not found!"

type
  PackageKind* = enum
    pkPackage,
    pkAlias

  PackageInfo* = ref object
    name*: string
    case kind*: PackageKind
    of pkAlias:
      alias*: string
    of pkPackage:
      # Required fields in a PackageInfo.
      url*: string # Download location.
      license*: string
      downloadMethod*: string
      description*: string
      tags*: seq[string] # \
      # From here on, optional fields set to the empty string if not available.
      version*: string
      dvcsTag*: string
      web*: string # Info url for humans.

proc optionalField(obj: JsonNode, name: string, default = ""): string =
  if hasKey(obj, name) and obj[name].kind == JString:
    result = obj[name].str
  else:
    result = default

template requiredField(obj: JsonNode, name: string): string =
  block:
    let result = optionalField(obj, name, "")
    if result.len == 0:
      return nil
    result

proc fromJson*(obj: JsonNode): PackageInfo =
  if "alias" in obj:
    result = PackageInfo(kind: pkAlias)
    result.name = obj.requiredField("name")
    result.alias = obj.requiredField("alias")
  else:
    result = PackageInfo(kind: pkPackage)
    result.name = obj.requiredField("name")
    result.version = obj.optionalField("version")
    result.url = obj.requiredField("url")
    result.downloadMethod = obj.requiredField("method")
    result.dvcsTag = obj.optionalField("dvcs-tag")
    result.license = obj.optionalField("license")
    result.tags = @[]
    for t in obj["tags"]: result.tags.add(t.str)
    result.description = obj.requiredField("description")
    result.web = obj.optionalField("web")

proc `$`*(pkg: PackageInfo): string =
  result = pkg.name & ":\n"
  if pkg.kind == pkAlias:
    result &= "  alias:       " & pkg.alias & "\n"
    return
  result &= "  url:         " & pkg.url & " (" & pkg.downloadMethod & ")\n"
  result &= "  tags:        " & pkg.tags.join(", ") & "\n"
  result &= "  description: " & pkg.description & "\n"
  result &= "  license:     " & pkg.license & "\n"
  if pkg.web.len > 0:
    result &= "  website:     " & pkg.web & "\n"

proc toTags*(j: JsonNode): seq[string] =
  result = @[]
  if j.kind == JArray:
    for elem in items j:
      result.add elem.getStr("")

proc packageInfosFile*(cacheDir = cachesDirectory()): Path =
  cacheDir / Path"packages.json"

proc removeLegacyPackageCaches*(gitDir = packagesDirectory()) =
  let oldNimbleCachesDir = depsDir() / Path"_nimble"
  if dirExists(oldNimbleCachesDir):
    removeDir($oldNimbleCachesDir)

  if PackagesGit notin context().flags and dirExists(gitDir):
    removeDir($gitDir)

proc getPackageInfos*(cacheDir = cachesDirectory()): seq[PackageInfo] =
  result = @[]
  var uniqueNames = initHashSet[string]()
  let pkgsFile = packageInfosFile(cacheDir)
  if not fileExists($pkgsFile):
    return

  let packages = json.parseFile($pkgsFile)
  for p in packages:
    let pkg = p.fromJson()
    if pkg != nil and not uniqueNames.containsOrIncl(pkg.name):
      result.add(pkg)

proc updatePackages*(cacheDir = cachesDirectory(); gitDir = packagesDirectory()) =
  if $cacheDir == $cachesDirectory():
    removeLegacyPackageCaches(gitDir)

  if cacheDir.len > 0 and not dirExists(cacheDir):
    createDir(cacheDir)

  let pkgsFile = packageInfosFile(cacheDir)
  if PackagesGit in context().flags:
    if dirExists(gitDir):
      gitPull(gitDir)
    else:
      let pkgsUrl = parseUri "https://github.com/nim-lang/packages"
      let res = clone(pkgsUrl, gitDir)
      if res[0] != Ok:
        error DefaultPackagesSubDir, "cannot clone packages repo: " & res[1]
    copyFile($(gitDir / Path"packages.json"), $pkgsFile)
  else:
    var lastError = ""
    for url in PackagesJsonUrls:
      let client = newAtlasHttpClient()
      try:
        let contents = client.getContent(url)
        writeFile($pkgsFile, contents)
        return
      except CatchableError as e:
        lastError = url & ": " & e.msg
        warn DefaultCachesSubDir, "cannot download packages.json:", lastError
      finally:
        client.close()
    error DefaultCachesSubDir, "cannot download packages.json: " & lastError
