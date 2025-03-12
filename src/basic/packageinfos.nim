#
#           Atlas Package Cloner
#        (c) Copyright 2021 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std / [json, os, sets, strutils, paths, files, dirs, httpclient, uri, json, jsonutils]
import context, reporters, gitops

const
  UnitTests = defined(atlasUnitTests)

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

const
  DefaultPackagesSubDir* = Path"packages"
  DefaultCachesSubDir* = Path"_caches"

proc packagesDirectory*(): Path =
  context().depsDir / DefaultPackagesSubDir

proc cachesDirectory*(): Path =
  context().depsDir / DefaultCachesSubDir

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

proc getPackageInfos*(pkgsDir = packagesDirectory()): seq[PackageInfo] =
  result = @[]
  var uniqueNames = initHashSet[string]()
  var jsonFiles = 0
  for kind, path in walkDir(pkgsDir):
    if kind == pcFile and path.string.endsWith(".json"):
      inc jsonFiles
      let packages = json.parseFile($path)
      for p in packages:
        let pkg = p.fromJson()
        if pkg != nil and not uniqueNames.containsOrIncl(pkg.name):
          result.add(pkg)

proc updatePackages*(pkgsDir = packagesDirectory()) =
  let pkgsDir = context().depsDir / DefaultPackagesSubDir
  if dirExists(pkgsDir):
    gitPull(pkgsDir)
  else:
    let res = clone(parseUri "https://github.com/nim-lang/packages", pkgsDir)
    if res[0] != Ok:
      error DefaultPackagesSubDir, "cannot clone packages repo: " & res[1]
