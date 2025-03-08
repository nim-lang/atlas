import std/[paths, tables, files, os, uri, dirs, sets, strutils, unicode]
import context, packageinfos, reporters, pkgurls, gitops, compiledpatterns, deptypes

type
  NimbleContext* = object
    packageToDependency*: Table[PkgUrl, Package]
    overrides*: Patterns
    hasPackageList*: bool
    nameToUrl: Table[string, PkgUrl]
    extraNameToUrl: Table[string, PkgUrl] # for non-packages projects, e.g. url only

# proc createUrl*(nc: NimbleContext, orig: Path): PkgUrl =
#   var didReplace = false
#   let pstr = $(orig)
#   result = createUrlSkipPatterns(pstr)

proc findNimbleFile*(nimbleFile: Path): seq[Path] =
  if fileExists(nimbleFile):
    result.add nimbleFile

proc findNimbleFile*(dir: Path, projectName: string): seq[Path] =
  var nimbleFile = dir / Path(projectName & ".nimble")
  result = findNimbleFile(nimbleFile)
  if result.len() == 0:
    for file in walkFiles($dir / "*.nimble"):
      result.add Path(file)
  debug dir, "finding nimble file searching by name:", projectName, "found:", result.join(", ")

proc findNimbleFile*(info: Package): seq[Path] =
  doAssert(info.ondisk.string != "", "Package ondisk must be set before findNimbleFile can be called! Package: " & $(info))
  result = findNimbleFile(info.ondisk, info.projectName() & ".nimble")

proc lookup*(nc: NimbleContext, name: string): PkgUrl =
  if name in nc.nameToUrl:
    result = nc.nameToUrl[name]
  elif name in nc.extraNameToUrl:
    result = nc.extraNameToUrl[name]

proc put*(nc: var NimbleContext, name: string, url: Uri, isExtra = false) =
  let inNames = name in nc.nameToUrl
  let inExtra = name in nc.extraNameToUrl
  let pkgUrl = url.toPkgUriRaw()

  if not inNames and not inExtra:
    nc.nameToUrl[name] = pkgUrl
  elif inNames and nc.nameToUrl[name] != pkgUrl:
    raise newException(ValueError, "name already in the database! ")
  elif inExtra and nc.extraNameToUrl[name] != pkgUrl:
    raise newException(ValueError, "name already in the extras-database! ")

proc createUrl*(nc: NimbleContext, nameOrig: string): PkgUrl =
  ## primary point to createUrl's from a name or argument
  ## TODO: add unit tests!
  var didReplace = false
  var name = substitute(nc.overrides, nameOrig, didReplace)
  debug "createUrl", "name:", name, "orig:", nameOrig, "patterns:", $nc.overrides
  if name.isUrl():
    result = createUrlSkipPatterns(name)
  else:
    let lname = unicode.toLower(name)
    if lname in nc.nameToUrl:
      result = nc.nameToUrl[lname]
    else:
      raise newException(ValueError, "project name not found in packages database: " & $lname)
  if result.url.path.splitFile().ext == ".git":
    var url = parseUri($result.url)
    url.path.removeSuffix(".git")
    result = toPkgUriRaw(url)
  # if projectName != "":
  #   result.projectName = projectName

proc fillPackageLookupTable(c: var NimbleContext) =
  let pkgsDir = packagesDirectory()
  if not c.hasPackageList:
    c.hasPackageList = true
    if not fileExists(pkgsDir / Path"packages.json"):
      updatePackages(pkgsDir)
    let packages = getPackageInfos(pkgsDir)
    for entry in packages:
      c.nameToUrl[unicode.toLower(entry.name)] = createUrlSkipPatterns(entry.url, skipDirTest=true)

proc createUnfilledNimbleContext*(): NimbleContext =
  result = NimbleContext()
  result.overrides = context().overrides

proc createNimbleContext*(): NimbleContext =
  result = createUnfilledNimbleContext()
  fillPackageLookupTable(result)