#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std / [os, strutils, tables, unicode, sets, json, hashes, algorithm]
import basic/[context, depgraphtypes, versions, osutils, nimbleparser, packageinfos, reporters, gitops, parserequires, pkgurls, compiledpatterns]

const
  DefaultPackagesSubDir* = Path "packages"

when defined(nimAtlasBootstrap):
  import ../dist/sat/src/sat/satvars
else:
  import sat/satvars

proc getPackageInfos*(depsDir: Path): seq[PackageInfo] =
  result = @[]
  var uniqueNames = initHashSet[string]()
  var jsonFiles = 0
  for kind, path in walkDir($(depsDir / DefaultPackagesSubDir)):
    if kind == pcFile and path.endsWith(".json"):
      inc jsonFiles
      let packages = json.parseFile(path)
      for p in packages:
        let pkg = p.fromJson()
        if pkg != nil and not uniqueNames.containsOrIncl(pkg.name):
          result.add(pkg)

proc updatePackages*(depsDir: Path) =
  if dirExists($(depsDir / DefaultPackagesSubDir)):
    withDir($(depsDir / DefaultPackagesSubDir)):
      gitPull(depsDir / DefaultPackagesSubDir)
  else:
    withDir $depsDir:
      let success = clone("https://github.com/nim-lang/packages", DefaultPackagesSubDir)
      if not success:
        error DefaultPackagesSubDir, "cannot clone packages repo"

proc fillPackageLookupTable(c: var NimbleContext; depsdir: Path) =
  if not c.hasPackageList:
    c.hasPackageList = true
    if not fileExists($(depsDir / DefaultPackagesSubDir / Path "packages.json")):
      updatePackages(depsdir)
    let packages = getPackageInfos(depsDir)
    for entry in packages:
      c.nameToUrl[unicode.toLower entry.name] = entry.url

proc createNimbleContext*(depsdir: Path): NimbleContext =
  result = NimbleContext()
  fillPackageLookupTable(result, depsdir)

proc collectNimbleVersions*(nc: NimbleContext; dep: Dependency): seq[string] =
  let nimbleFiles = findNimbleFile(dep)
  let dir = dep.ondisk
  doAssert(dep.ondisk.string != "", "Package ondisk must be set before collectNimbleVersions can be called! Package: " & $(dep))
  trace "collectNimbleVersions", "dep: " & dep.pkg.projectName & " at: " & $dep.ondisk
  result = @[]
  if nimbleFiles.len() == 1:
    let (outp, status) = exec(GitLog, dir, [$nimbleFiles[0]], ignoreError = true)
    if status == Ok:
      for line in splitLines(outp):
        if line.len > 0 and not line.endsWith("^{}"):
          result.add line
    result.reverse()
