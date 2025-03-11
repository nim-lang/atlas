import std/[paths, tables, files, os, uri, sequtils, dirs, sets, strutils, unicode]
import context, packageinfos, reporters, pkgurls, gitops, compiledpatterns, deptypes

type
  NimbleContext* = object
    packageToDependency*: Table[PkgUrl, Package]
    packageExtras*: Table[string, PkgUrl]
    nameOverrides*: Patterns
    urlOverrides*: Patterns
    hasPackageList*: bool
    nameToUrl: Table[string, PkgUrl]
    urlToNames: Table[Uri, string]
    notFoundNames: HashSet[string]

proc findNimbleFile*(nimbleFile: Path): seq[Path] =
  if fileExists(nimbleFile):
    result.add nimbleFile

proc findNimbleFile*(dir: Path, projectName: string): seq[Path] =
  var nimbleFile = dir / Path(projectName & ".nimble")
  result = findNimbleFile(nimbleFile)
  if result.len() == 0:
    for file in walkFiles($dir / "*.nimble"):
      result.add Path(file)
  trace dir, "finding nimble file searching by name:", projectName, "found:", result.join(", ")

proc findNimbleFile*(info: Package): seq[Path] =
  doAssert(info.ondisk.string != "", "Package ondisk must be set before findNimbleFile can be called! Package: " & $(info))
  result = findNimbleFile(info.ondisk, info.projectName() & ".nimble")

proc lookup*(nc: NimbleContext, name: string): PkgUrl =
  let lname = unicode.toLower(name)
  if lname in nc.packageExtras:
    result = nc.packageExtras[lname]
  elif lname in nc.nameToUrl:
    result = nc.nameToUrl[lname]

proc lookup*(nc: NimbleContext, url: Uri): string =
  if url in nc.urlToNames:
    result = nc.urlToNames[url]

proc lookup*(nc: NimbleContext, url: PkgUrl): string =
  if url.url in nc.urlToNames:
    result = nc.urlToNames[url.url]

proc put*(nc: var NimbleContext, name: string, url: PkgUrl, isFromPath = false) =
  let name = unicode.toLower(name)
  if name notin nc.packageExtras:
    nc.packageExtras[name] = url
  else:
    if nc.packageExtras[name] != url:
      # TODO: need to handle this better, the user needs to choose which url to use
      #       if the solver can't resolve the conflict
      error "atlas:nimblecontext", "name already exists in packageExtras:", $name, "isFromPath:", $isFromPath, "with different url:", $nc.packageExtras[name], "and url:", $url

proc createUrl*(nc: var NimbleContext, nameOrig: string): PkgUrl =
  ## primary point to createUrl's from a name or argument
  ## TODO: add unit tests!
  doAssert not nameOrig.isAbsolute(), "createUrl does not support absolute paths: " & $nameOrig

  var didReplace = false
  var name = nameOrig
  
  # First try URL overrides if it looks like a URL
  if nameOrig.isUrl():
    name = substitute(nc.urlOverrides, nameOrig, didReplace)
  else:
    name = substitute(nc.nameOverrides, nameOrig, didReplace)
  
  trace "atlas:createUrl", "name:", name, "orig:", nameOrig, "isUrl:", $name.isUrl()
  
  if name.isUrl():
    # trace "atlas:createUrl", "name is url:", name
    result = createUrlSkipPatterns(name)
  else:
    let lname = nc.lookup(name)
    if not lname.isEmpty():
      # trace "atlas:createUrl", "name is in nameToUrl:", $lname
      result = lname
    else:
      let lname = unicode.toLower(name)
      if lname notin nc.notFoundNames:
        error "atlas:nimblecontext", "name not found in nameToUrl: " & $name, "lname:", $lname
        nc.notFoundNames.incl lname
      # error "atlas:createUrl", "name is not in nameToUrl:", $name, "result:", repr(result)
      # error "atlas:createUrl", "nameToUrl:", $nc.nameToUrl.keys().toSeq().join(", ")
      raise newException(ValueError, "project name not found in packages database: " & $lname)
  
  if result.url.path.splitFile().ext == ".git":
    var url = parseUri($result.url)
    url.path.removeSuffix(".git")
    result = toPkgUriRaw(url)

  if not nc.lookup(result.shortName()).isEmpty():
    result.hasShortName = true

  if not result.isEmpty():
    nc.put(result.projectName, result)

  trace "atlas:createUrl", "created url with name:", name, "orig:", nameOrig, "projectName:", $result.projectName, "hasShortName:", $result.hasShortName, "url:", $result.url

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
    nc.put(result.projectName, result, isFromPath=true)

proc fillPackageLookupTable(c: var NimbleContext) =
  let pkgsDir = packagesDirectory()
  if not c.hasPackageList:
    c.hasPackageList = true
    if not fileExists(pkgsDir / Path"packages.json"):
      updatePackages(pkgsDir)
    let packages = getPackageInfos(pkgsDir)
    for pkgInfo in packages:
      var pkgUrl = createUrlSkipPatterns(pkgInfo.url, skipDirTest=true)
      pkgUrl.hasShortName = true
      pkgUrl.qualifiedName.name = pkgInfo.name
      c.nameToUrl[unicode.toLower(pkgInfo.name)] = pkgUrl
      c.urlToNames[pkgUrl.url] = pkgInfo.name

proc createUnfilledNimbleContext*(): NimbleContext =
  result = NimbleContext()
  result.nameOverrides = context().nameOverrides
  result.urlOverrides = context().urlOverrides
  # for key, val in context().packageNameOverrides: 
  #   let url = createUrlSkipPatterns($val)
  #   result.packageExtras[key] = url
  #   result.urlToNames[url.url()] = key

proc createNimbleContext*(): NimbleContext =
  result = createUnfilledNimbleContext()
  fillPackageLookupTable(result)