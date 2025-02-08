#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std / [os, strutils, tables, unicode, hashes]
import versions, packagesjson, reporters, gitops, parse_requires, pkgurls, compiledpatterns

const
  DefaultPackagesSubDir* = "packages"

when defined(nimAtlasBootstrap):
  import ../dist/sat/src/sat/satvars
else:
  import sat/satvars

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

proc updatePackages*(c: var Reporter; depsDir: string) =
  if dirExists(depsDir / DefaultPackagesSubDir):
    withDir(c, depsDir / DefaultPackagesSubDir):
      gitPull(c, DefaultPackagesSubDir)
  else:
    withDir c, depsDir:
      let success = clone(c, "https://github.com/nim-lang/packages", DefaultPackagesSubDir)
      if not success:
        error c, DefaultPackagesSubDir, "cannot clone packages repo"

proc fillPackageLookupTable(c: var NimbleContext; r: var Reporter; depsdir: string) =
  if not c.hasPackageList:
    c.hasPackageList = true
    if not fileExists(depsDir / DefaultPackagesSubDir / "packages.json"):
      updatePackages(r, depsdir)
    let packages = getPackageInfos(depsDir)
    for entry in packages:
      c.nameToUrl[unicode.toLower entry.name] = entry.url

proc createNimbleContext*(r: var Reporter; depsdir: string): NimbleContext =
  result = NimbleContext()
  fillPackageLookupTable(result, r, depsdir)
