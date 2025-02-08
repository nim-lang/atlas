#
#           Atlas Package Cloner
#        (c) Copyright 2021 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std / [json, os, sets, strutils, httpclient, uri]
import context, reporters

const
  UnitTests = defined(atlasUnitTests)
  DefaultPackagesSubDir* = "packages"

when UnitTests:
  proc findAtlasDir*(): string =
    result = currentSourcePath().absolutePath
    while not result.endsWith("atlas"):
      result = result.parentDir
      assert result != "", "atlas dir not found!"

type
  PackageInfo* = ref object
    # Required fields in a PackageInfo.
    name*: string
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

proc requiredField(obj: JsonNode, name: string): string =
  result = optionalField(obj, name, "")

proc fromJson*(obj: JSonNode): PackageInfo =
  result = PackageInfo()
  result.name = obj.requiredField("name")
  if result.name.len == 0: return nil
  result.version = obj.optionalField("version")
  result.url = obj.requiredField("url")
  if result.url.len == 0: return nil
  result.downloadMethod = obj.requiredField("method")
  if result.downloadMethod.len == 0: return nil
  result.dvcsTag = obj.optionalField("dvcs-tag")
  result.license = obj.optionalField("license")
  result.tags = @[]
  for t in obj["tags"]:
    result.tags.add(t.str)
  result.description = obj.requiredField("description")
  result.web = obj.optionalField("web")

proc getPackageInfos*(depsDir: string): seq[PackageInfo] =
  result = @[]
  var uniqueNames = initHashSet[string]()
  var jsonFiles = 0
  for kind, path in walkDir(depsDir / DefaultPackagesSubDir):
    if kind == pcFile and path.endsWith(".json"):
      inc jsonFiles
      let packages = json.parseFile(path)
      for p in packages:
        let pkg = p.fromJson()
        if pkg != nil and not uniqueNames.containsOrIncl(pkg.name):
          result.add(pkg)

proc `$`*(pkg: PackageInfo): string =
  result = pkg.name & ":\n"
  result &= "  url:         " & pkg.url & " (" & pkg.downloadMethod & ")\n"
  result &= "  tags:        " & pkg.tags.join(", ") & "\n"
  result &= "  description: " & pkg.description & "\n"
  result &= "  license:     " & pkg.license & "\n"
  if pkg.web.len > 0:
    result &= "  website:     " & pkg.web & "\n"

proc toTags(j: JsonNode): seq[string] =
  result = @[]
  if j.kind == JArray:
    for elem in items j:
      result.add elem.getStr("")
