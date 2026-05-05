import std/[paths, tables, files, os, uri, dirs, sets, strutils, unicode]
import context, packageinfos, reporters, pkgurls, gitops, compiledpatterns, deptypes, versions

type
  NimbleContext* = object
    packageToDependency*: OrderedTable[PkgUrl, Package]
    packageExtras*: OrderedTable[string, PkgUrl]
    nameToUrl: OrderedTable[string, PkgUrl]
    urlToUrl: OrderedTable[string, PkgUrl]
    urlToName: OrderedTable[PkgUrl, string]
    explicitVersions*: OrderedTable[PkgUrl, HashSet[VersionTag]]
    nameOverrides*: Patterns
    urlOverrides*: Patterns
    hasPackageList*: bool
    notFoundNames: HashSet[string]

proc findNimbleFile*(dir: Path, projectName: string = ""): seq[Path] =
  ## Finds Nimble files in `dir`.
  ##
  ## If `dir` is already a `.nimble` file, it is returned directly. Otherwise
  ## this first checks `<projectName>.nimble` when a name is supplied, then falls
  ## back to every `.nimble` file immediately under `dir`.
  if dir.splitFile().ext == "nimble":
    let nimbleFile = dir
    if fileExists(nimbleFile):
      return @[nimbleFile]
  else:
    let nimbleFile = dir / Path(projectName & ".nimble")
    if fileExists(nimbleFile):
      return @[nimbleFile]

  if result.len() == 0:
    for file in walkFiles($dir / "*.nimble"):
      result.add Path(file)
  debug dir, "finding nimble file searching by name:", projectName, "found:", result.join(", ")

proc findNimbleFile*(info: Package): seq[Path] =
  ## Finds Nimble files for a loaded package checkout.
  ##
  ## Monorepo packages search inside the package subdir. The preferred filename
  ## is based on the source URL's short name because package display names can be
  ## registry aliases.
  doAssert(info.ondisk.string != "", "Package ondisk must be set before findNimbleFile can be called! Package: " & $(info))
  # Prefer the repository's short name (e.g. 'figuro') and let the helper add '.nimble'.
  # Using projectName (which may include host/user) leads to mismatches.
  let subdir =
    if info.subdir.len > 0: info.subdir
    else: info.url.subdir()
  let searchDir =
    if subdir.len > 0: info.ondisk / subdir
    else: info.ondisk
  result = findNimbleFile(searchDir, info.url.shortName())

proc cacheNimbleFilesFromGit*(pkg: Package, commit: CommitHash): seq[Path] =
  ## Caches `.nimble` files from `pkg` at `commit` and returns their cache paths.
  ##
  ## Existing cache entries are reused. When several Nimble files exist, the one
  ## matching the package source short name is preferred so historical release
  ## parsing stays deterministic.
  proc cachedNimbleBase(p: Path): string =
    ## Returns the original Nimble filename from a commit-prefixed cache path.
    let tail = $p.splitPath().tail
    let dash = tail.find('-')
    if dash >= 0 and dash+1 < tail.len: tail.substr(dash+1) else: tail

  proc preferShortNameNimble(paths: seq[Path]; shortName: string): seq[Path] =
    ## Disambiguate a list of cached nimble files by preferring the entry whose
    ## base name matches `<shortName>.nimble`. If multiple such entries exist,
    ## return the first; otherwise return the original list.
    let want = shortName & ".nimble"
    var prefer: seq[Path]
    for p in paths:
      if cachedNimbleBase(p) == want:
        prefer.add p
    if prefer.len == 1:
      result = prefer
    elif prefer.len > 1:
      result = @[prefer[0]]
    else:
      result = paths

  # First check if we already have cached nimble files for this commit
  for file in walkFiles($nimbleCachesDirectory() / (commit.h & "-*.nimble")):
    let path = Path(file)
    let base = cachedNimbleBase(path)
    # If we find the exact matching short-name nimble, return it immediately
    if base == pkg.url.shortName() & ".nimble":
      return @[path]
    result.add path
  
  if result.len > 0:
    # Disambiguate cached entries if possible
    return preferShortNameNimble(result, pkg.url.shortName())

  let files = listFiles(pkg.ondisk, commit)
  var nimbleFiles: seq[Path]
  for file in files:
    if file.endsWith(".nimble"):
      let tail = Path(file).splitPath().tail
      # Prefer the nimble named after the repo's short name (e.g. 'figuro.nimble')
      if tail == Path(pkg.url.shortName() & ".nimble"):
        nimbleFiles = @[Path(file)]
        break
      nimbleFiles.add Path(file)

  createDir(nimbleCachesDirectory())
  for nimbleFile in nimbleFiles:
    let cachePath = nimbleCachesDirectory() / Path(commit.h & "-" & $nimbleFile.splitPath().tail)
    if not fileExists(cachePath):
      let contents = showFile(pkg.ondisk, commit, $nimbleFile)
      writeFile($cachePath, contents)
    result.add cachePath
  
  # If multiple nimble files were found, try to disambiguate by preferring the
  # one that matches the repository short name (e.g. 'figuro.nimble').
  if result.len > 1:
    result = preferShortNameNimble(result, pkg.url.shortName())

proc lookup*(nc: NimbleContext, name: string): PkgUrl =
  ## Looks up a package URL by package name or explicit extra mapping.
  ##
  ## Names are matched case-insensitively. Package extras take precedence over
  ## registry package entries so user/config overrides can shadow the registry.
  let lname = unicode.toLower(name)
  if lname in nc.packageExtras:
    result = nc.packageExtras[lname]
  elif lname in nc.nameToUrl:
    result = nc.nameToUrl[lname]

proc isForkUrl*(nc: NimbleContext; url: PkgUrl): bool =
  ## Returns true when `url` points at a non-official git remote for its package.
  ##
  ## Registry package names are used when known, which lets aliases such as
  ## `jwt` still compare against their official registry URL.
  let lookupName =
    if url in nc.urlToName: nc.urlToName[url]
    else: url.projectName()
  let officialUrl = nc.lookup(lookupName)
  let isGitUrl = url.cloneUri().scheme notin ["file", "link", "atlas"]
  result =
    isGitUrl and
    not officialUrl.isEmpty() and
    officialUrl.cloneUri().scheme notin ["file", "link", "atlas"] and
    officialUrl.cloneUri() != url.cloneUri()

proc rememberPackageName(nc: var NimbleContext; name: string; url: PkgUrl) =
  ## Remembers the registry/context package name associated with `url`.
  ##
  ## The first name wins so later aliases do not rewrite package layout names.
  if name.len == 0:
    return
  if url.isEmpty():
    return
  if url notin nc.urlToName:
    nc.urlToName[url] = name

proc hasPackageName(nc: NimbleContext; url: PkgUrl): bool =
  ## Returns true when `url` has an explicit package name in this context.
  url in nc.urlToName

proc name(nc: NimbleContext; url: PkgUrl): string =
  ## Returns the context package name for `url`, or a URL-derived fallback.
  if url in nc.urlToName:
    result = nc.urlToName[url]
  else:
    result = url.projectName()

proc initPackage*(nc: NimbleContext; url: PkgUrl; state = NotInitialized): Package =
  ## Creates a dependency package record for `url` in this context.
  ##
  ## This attaches registry package naming, URL subdir metadata, and fork
  ## detection to the package before graph traversal starts.
  Package(
    url: url,
    name: nc.name(url),
    isOfficial: nc.hasPackageName(url),
    state: state,
    subdir: url.subdir(),
    isFork: nc.isForkUrl(url)
  )

proc putImpl(nc: var NimbleContext, name: string, url: PkgUrl, isFromPath = false): bool =
  ## Adds a package-name mapping to the context extras table.
  ##
  ## Returns false when the name is already reserved by the registry or by a
  ## conflicting extra URL.
  let name = unicode.toLower(name)
  if name in nc.nameToUrl:
    result = false
  elif name notin nc.packageExtras:
    nc.packageExtras[name] = url
    nc.urlToUrl[$url.cloneUri()] = url
    nc.rememberPackageName(name, url)
    result = true
  else:
    let existingPkg = nc.packageExtras[name]
    let existingUrl = existingPkg.cloneUri()
    let url = url.cloneUri()
    if existingUrl != url:
      if existingUrl.scheme != url.scheme and existingUrl.port == url.port and
          existingUrl.path == url.path and existingUrl.hostname == url.hostname:
        info "atlas:nimblecontext", "different url schemes for the same package:", $name, "existing:", $existingUrl, "new:", $url
      else:
        # this is handled in the solver which checks for conflicts
        # but users should be aware that this is happening as they can override stuff
        warn "atlas:nimblecontext", "name already exists in packageExtras:", $name, "isFromPath:", $isFromPath, "with different url:", $nc.packageExtras[name], "and url:", $url
        result = false

proc put*(nc: var NimbleContext, name: string, url: PkgUrl): bool {.discardable.} =
  ## Adds an explicit package-name to URL mapping.
  nc.putImpl(name, url, false)

proc putFromPath*(nc: var NimbleContext, name: string, url: PkgUrl): bool =
  ## Adds a package-name mapping discovered from a local project path.
  nc.putImpl(name, url, true)

proc putPackageInfo*(nc: var NimbleContext; pkgInfo: PackageInfo): PkgUrl {.discardable.} =
  ## Adds one packages.json package entry to the context lookup tables.
  ##
  ## The returned URL includes registry metadata such as `subdir`, while the
  ## package name is tracked separately for display and dependency layout.
  doAssert pkgInfo.kind == pkPackage
  result = createUrlSkipPatterns(pkgInfo.url, skipDirTest=true)
  result = result.withSubdir(pkgInfo.subdir)
  nc.nameToUrl[unicode.toLower(pkgInfo.name)] = result
  nc.rememberPackageName(pkgInfo.name, result)
  let cloneUrl = $result.cloneUri()
  if cloneUrl in nc.urlToUrl:
    if nc.urlToUrl[cloneUrl] != result:
      nc.urlToUrl.del(cloneUrl)
  else:
    nc.urlToUrl[cloneUrl] = result

proc createUrl*(nc: var NimbleContext, nameOrig: string): PkgUrl =
  ## Resolves a package name, explicit URL, forge alias, or override into a URL.
  ##
  ## Name and URL overrides are applied first. Registry lookups are used for
  ## package names, and explicit URLs are canonicalized through known clone URLs
  ## when possible.
  doAssert not nameOrig.isAbsolute(), "createUrl does not support relative paths: " & $nameOrig

  var didReplace = false
  var name = nameOrig
  let origWasUrl = nameOrig.isUrl()
  
  # First try URL overrides if it looks like a URL
  if nameOrig.isUrl():
    name = substitute(nc.urlOverrides, nameOrig, didReplace)
  else:
    name = substitute(nc.nameOverrides, nameOrig, didReplace)
  
  if name.isUrl():
    result = createUrlSkipPatterns(name)

    let cloneUrl = $result.cloneUri()
    if cloneUrl in nc.urlToUrl:
      result = nc.urlToUrl[cloneUrl]

    # Keep explicit URLs stable. Name overrides are for package-name lookups,
    # not for remapping already explicit URL requirements (especially file://).
    if not origWasUrl and not didReplace:
      var didReplace = false
      name = substitute(nc.nameOverrides, result.projectName(), didReplace)
      if didReplace:
        result = createUrlSkipPatterns(name)
  else:
    let lname = nc.lookup(name)
    if not lname.isEmpty():
      result = lname
    else:
      let lname = unicode.toLower(name)
      if lname notin nc.notFoundNames:
        warn "atlas:nimblecontext", "name not found in packages database:", $name
        nc.notFoundNames.incl lname
      raise newException(ValueError, "project name not found in packages database: " & $lname & " original: " & $nameOrig)
  
  if not result.isEmpty():
    if nc.put(result.projectName, result):
      debug "atlas:createUrl", "created url with name:", name, "orig:",
            nameOrig, "projectName:", $result.projectName,
            "url:", $result.url

proc canonicalizeUrl*(nc: var NimbleContext; url: PkgUrl): PkgUrl =
  ## Resolves `url` through this context's package registry and overrides.
  ##
  ## This preserves already-canonical URLs and returns the original URL if it
  ## cannot be resolved. Use this for dependency URLs parsed from Nimble files,
  ## where a bare or partially known URL may need to be lifted to the canonical
  ## registry URL, including package metadata such as monorepo subdirs.
  if url.url.scheme == "error":
    return url
  if nc.lookup(url.projectName()) == url:
    return url
  try:
    result = nc.createUrl($url)
  except CatchableError:
    result = url

proc canonicalizeReleaseUrls*(nc: var NimbleContext; rel: NimbleRelease) =
  ## Canonicalizes every package URL referenced by `rel`.
  ##
  ## Requirements, feature requirements, and feature-scoped requirement flags
  ## are rewritten through `canonicalizeUrl` so all release dependency edges use
  ## the same URL identity that the traversal context would create for them.
  for req in mitems(rel.requirements):
    req[0] = canonicalizeUrl(nc, req[0])

  if rel.reqsByFeatures.len > 0:
    var reqsByFeatures = initTable[PkgUrl, HashSet[string]]()
    for url, flags in rel.reqsByFeatures:
      reqsByFeatures[canonicalizeUrl(nc, url)] = flags
    rel.reqsByFeatures = reqsByFeatures

  if rel.features.len > 0:
    var features = initTable[string, seq[(PkgUrl, VersionInterval)]]()
    for feature, reqs in rel.features:
      var fixedReqs: seq[(PkgUrl, VersionInterval)]
      for req in reqs:
        fixedReqs.add (canonicalizeUrl(nc, req[0]), req[1])
      features[feature] = fixedReqs
    rel.features = features

proc createUrlFromPath*(nc: var NimbleContext, orig: Path, isLinkPath = false): PkgUrl =
  ## Creates and registers an Atlas or link URL for a local project path.
  ##
  ## Main-project paths are represented by their Nimble file when possible, with
  ## a directory-name fallback for projects whose Nimble file does not yet exist.
  let absPath = absolutePath(orig)
  # Check if this is an Atlas project or if it's the current project
  let prefix = if isLinkPath: "link://" else: "atlas://"
  if isMainProject(absPath) or absPath == absolutePath(project()):
    if isLinkPath:
      let url = parseUri(prefix & $absPath)
      result = toPkgUriRaw(url)
    else:
      # Find nimble files in the project directory
      let nimbleFiles = findNimbleFile(absPath, "")
      if nimbleFiles.len > 0:
        # Use the first nimble file found as the project identifier
        trace "atlas:nimblecontext", "createUrlFromPath: found nimble file: ", $nimbleFiles[0]
        let url = parseUri(prefix & $nimbleFiles[0])
        result = toPkgUriRaw(url)
      else:
        # Fallback to directory name if no nimble file found
        let nimble = $(absPath.splitPath().tail) & ".nimble"
        trace "atlas:nimblecontext", "createUrlFromPath: no nimble file found, trying directory name: ", $nimble
        let url = parseUri(prefix & $absPath / nimble)
        result = toPkgUriRaw(url)
  else:
    error "atlas:nimblecontext", "createUrlFromPath: not a project: " & $absPath
  if not result.isEmpty():
    discard nc.putFromPath(result.projectName, result)

proc fillPackageLookupTable(c: var NimbleContext) =
  ## Loads packages.json into the context's registry lookup tables once.
  ##
  ## Package entries are registered before aliases so aliases can resolve through
  ## their target package names.
  if not c.hasPackageList:
    c.hasPackageList = true
    removeLegacyPackageCaches()
    if not fileExists(packageInfosFile()):
      updatePackages()
    let packages = getPackageInfos()
    var aliases: seq[PackageInfo] = @[]

    # add all packages to the lookup table
    for pkgInfo in packages:
      if pkgInfo.kind == pkAlias:
        aliases.add(pkgInfo)
      else:
        discard c.putPackageInfo(pkgInfo)

    # now we add aliases to the lookup table
    for pkgAlias in aliases:
      # first lookup the alias name
      let aliasName = unicode.toLower(pkgAlias.alias)
      let url = c.nameToUrl[aliasName]
      if url.isEmpty():
        warn "atlas:nimblecontext", "alias name not found in nameToUrl: " & $pkgAlias, "lname:", $aliasName
      else:
        c.nameToUrl[pkgAlias.name] = url

proc createUnfilledNimbleContext*(): NimbleContext =
  ## Creates a context with user/config overrides but without packages.json.
  ##
  ## Use this for tests or workflows that should avoid loading the package
  ## registry until explicitly requested.
  result = NimbleContext()
  result.nameOverrides = context().nameOverrides
  result.urlOverrides = context().urlOverrides

proc createNimbleContext*(): NimbleContext =
  ## Creates a fully populated Nimble context, including packages.json entries.
  result = createUnfilledNimbleContext()
  fillPackageLookupTable(result)
