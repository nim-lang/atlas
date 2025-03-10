import std/[paths, tables, files, os, uri, dirs, sets, strutils, unicode]
import context, packageinfos, reporters, pkgurls, gitops, compiledpatterns, deptypes

type
  NimbleContext* = object
    packageToDependency*: Table[PkgUrl, Package]
    overrides*: Patterns
    hasPackageList*: bool
    nameToUrl: Table[string, PkgUrl]
    extraNameToUrl: Table[string, PkgUrl] # for non-packages projects, e.g. url only
    urlToNames: Table[Uri, string]

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

proc lookup*(nc: NimbleContext, url: Uri): string =
  if url in nc.urlToNames:
    result = nc.urlToNames[url]

proc lookup*(nc: NimbleContext, url: PkgUrl): string =
  if url.url in nc.urlToNames:
    result = nc.urlToNames[url.url]

proc put*(nc: var NimbleContext, name: string, url: Uri, isExtra = false) =
  let inNames = name in nc.nameToUrl
  let inExtra = name in nc.extraNameToUrl
  let pkgUrl = url.toPkgUriRaw()

  if isExtra and not inNames and not inExtra:
    nc.extraNameToUrl[name] = pkgUrl
  if not inNames and not inExtra:
    nc.nameToUrl[name] = pkgUrl
  elif inNames and nc.nameToUrl[name] != pkgUrl:
    raise newException(ValueError, "name already in the database! ")
  elif inExtra and nc.extraNameToUrl[name] != pkgUrl:
    raise newException(ValueError, "name already in the extras-database! ")

  nc.urlToNames[url] = name

proc createUrl*(nc: var NimbleContext, nameOrig: string): PkgUrl =
  ## primary point to createUrl's from a name or argument
  ## TODO: add unit tests!
  doAssert not nameOrig.isAbsolute(), "createUrl does not support absolute paths: " & $nameOrig

  if nameOrig.isUrl():
    let url = createUrlSkipPatterns(nameOrig)
    let name = nc.lookup(url)
    if name != "":
      result = nc.lookup(name)

  var didReplace = false
  var name = substitute(nc.overrides, nameOrig, didReplace)
  debug "atlas:createUrl", "name:", name, "orig:", nameOrig, "patterns:", $nc.overrides
  if name.isUrl():
    trace "atlas:createUrl", "name is url:", name
    result = createUrlSkipPatterns(name)
  else:
    let lname = unicode.toLower(name)
    if lname in nc.nameToUrl:
      trace "atlas:createUrl", "name is in nameToUrl:", lname
      result = nc.nameToUrl[lname]
    else:
      warn "atlas:createUrl", "name is not in nameToUrl:", lname
      raise newException(ValueError, "project name not found in packages database: " & $lname)
  if result.url.path.splitFile().ext == ".git":
    var url = parseUri($result.url)
    url.path.removeSuffix(".git")
    result = toPkgUriRaw(url)

  if not nc.lookup(result.shortName()).isEmpty():
    result.hasShortName = true

  if didReplace and nameOrig.isUrl():
    result.hasShortName = true

  debug "atlas:createUrl", "name:", name, "orig:", nameOrig, "projectName:", $result.projectName, "hasShortName:", $result.hasShortName, "url:", $result.url 
  if not result.isEmpty():
    nc.put(result.projectName, result.url)

proc createUrlFromPath*(nc: var NimbleContext, orig: Path): PkgUrl =
  let absPath = absolutePath(orig)
  # Check if this is an Atlas workspace or if it's the current workspace
  if isWorkspace(absPath) or absPath == absolutePath(workspace()):
    # Find nimble files in the workspace directory
    let nimbleFiles = findNimbleFile(absPath, "")
    if nimbleFiles.len > 0:
      # Use the first nimble file found as the workspace identifier
      let url = parseUri("atlas://workspace/" & $nimbleFiles[0].splitPath().tail)
      result = toPkgUriRaw(url)
    else:
      # Fallback to directory name if no nimble file found
      let url = parseUri("atlas://workspace/" & $orig.splitPath().tail)
      result = toPkgUriRaw(url)
  else:
    let fileUrl = "file://" & $absPath
    result = createUrlSkipPatterns(fileUrl)
  if not result.isEmpty():
    nc.put(result.projectName, result.url)

proc fillPackageLookupTable(c: var NimbleContext) =
  let pkgsDir = packagesDirectory()
  if not c.hasPackageList:
    c.hasPackageList = true
    if not fileExists(pkgsDir / Path"packages.json"):
      updatePackages(pkgsDir)
    let packages = getPackageInfos(pkgsDir)
    for entry in packages:
      c.nameToUrl[unicode.toLower(entry.name)] = createUrlSkipPatterns(entry.url, skipDirTest=true)
      c.urlToNames[entry.url.parseUri] = entry.name

proc createUnfilledNimbleContext*(): NimbleContext =
  result = NimbleContext()
  result.overrides = context().overrides

proc createNimbleContext*(): NimbleContext =
  result = createUnfilledNimbleContext()
  fillPackageLookupTable(result)