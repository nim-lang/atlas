#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std / [os, strutils, uri, tables, sequtils, sets, hashes, algorithm, paths, dirs]
import basic/[context, deptypes, versions, osutils, nimbleparser, reporters, gitops, pkgurls, nimblecontext, deptypesjson, dependencycache, packageutils]

export deptypes, versions, deptypesjson

proc childDependencyState(pkg: Package; deferChildDeps: bool): PackageState =
  ## Returns the initial state for newly discovered child dependencies.
  ## Non-root children are marked lazy when `deferChildDeps` is enabled.
  if deferChildDeps and not pkg.isRoot: LazyDeferred
  else: NotInitialized

proc registerReleaseDependencies(
    nc: var NimbleContext;
    pkg: Package;
    release: NimbleRelease;
    deferChildDeps: bool
) =
  ## Registers dependency edges discovered in a loaded Nimble release.
  ## This also records explicit commit requirements for later traversal.
  if release.status != Normal:
    return

  for pkgUrl, interval in items(release.requirements):
    if interval.isSpecial:
      let commit = interval.extractSpecificCommit()
      nc.explicitVersions.mgetOrPut(pkgUrl, initHashSet[VersionTag]()).incl(VersionTag(v: Version($(interval)), c: commit))

    let state = childDependencyState(pkg, deferChildDeps)
    if pkgUrl notin nc.packageToDependency:
      debug pkg.url.projectName, "Found new pkg:", pkgUrl.projectName, "url:", $pkgUrl.url, "projectName:", $pkgUrl.projectName, "state:", $state
      let pkgDep = Package(url: pkgUrl, state: state, isFork: isForkUrl(nc, pkgUrl))
      nc.packageToDependency[pkgUrl] = pkgDep
    else:
      if nc.packageToDependency[pkgUrl].state == LazyDeferred and state != LazyDeferred:
        warn pkg.url.projectName, "Changing LazyDeferred pkg to DoLoad:", $pkgUrl.url
        nc.packageToDependency[pkgUrl].state = DoLoad

  for feature, rq in release.features:
    for pkgUrl, interval in items(rq):
      if interval.isSpecial:
        let commit = interval.extractSpecificCommit()
        nc.explicitVersions.mgetOrPut(pkgUrl, initHashSet[VersionTag]()).incl(VersionTag(v: Version($(interval)), c: commit))
      if pkgUrl notin nc.packageToDependency:
        let state =
          if feature notin context().features: LazyDeferred
          else: childDependencyState(pkg, deferChildDeps)
        debug pkg.url.projectName, "Found new feature pkg:", pkgUrl.projectName, "url:", $pkgUrl.url, "projectName:", $pkgUrl.projectName, "state:", $state
        let pkgDep = Package(url: pkgUrl, state: state, isFork: isForkUrl(nc, pkgUrl))
        nc.packageToDependency[pkgUrl] = pkgDep
      elif feature in context().features and nc.packageToDependency[pkgUrl].state == LazyDeferred and childDependencyState(pkg, deferChildDeps) != LazyDeferred:
        warn pkg.url.projectName, "Changing LazyDeferred feature pkg to DoLoad:", $pkgUrl.url
        nc.packageToDependency[pkgUrl].state = DoLoad

proc enrichPackageDependencies(
    nc: var NimbleContext;
    pkg: Package;
    deferChildDeps: bool
) =
  ## Enriches the traversal context from already-loaded package release info.
  ## This is intentionally separate from release parsing/cache loading.
  for _, release in pkg.versions:
    nc.registerReleaseDependencies(pkg, release, deferChildDeps)

proc collectNimbleVersions*(nc: NimbleContext; pkg: Package): seq[VersionTag] =
  ## Collects commits that modified the package's Nimble file.
  ## These commits are used as fallback release candidates when tags are absent.
  let nimbleFiles = findNimbleFile(pkg)
  let dir = pkg.ondisk
  doAssert(pkg.ondisk.string != "", "Package ondisk must be set before collectNimbleVersions can be called! Package: " & $(pkg))
  result = @[]
  if nimbleFiles.len() == 1:
    result = collectFileCommits(dir, nimbleFiles[0], isLocalOnly = pkg.isLocalOnly)
    result.reverse()
    trace pkg, "collectNimbleVersions commits:", mapIt(result, it.c.short()).join(", "), "nimble:", $nimbleFiles[0]

type
  PackageAction* = enum
    DoNothing, DoClone

proc processNimbleRelease(
    nc: var NimbleContext;
    pkg: Package,
    release: VersionTag;
    deferChildDeps: bool
): NimbleRelease =
  ## Loads and parses the Nimble file for a specific package release candidate.
  ## Historical releases are read from git contents and materialized only temporarily.
  trace pkg.url.projectName, "Processing release:", $release

  var nimbleFiles: seq[NimbleFileSource]
  if release.version == Version"#head":
    trace pkg.url.projectName, "processRelease using current commit"
    nimbleFiles = findNimbleFile(pkg).mapIt(NimbleFileSource(path: it, fromGit: false))
  elif release.commit.isEmpty():
    warn pkg.url.projectName, "processRelease missing commit ", $release, "at:", $pkg.ondisk
    result = NimbleRelease(status: HasBrokenRelease, err: "no commit")
    return
  else:
    nimbleFiles = findGitNimbleFiles(pkg, release.commit)

  if nimbleFiles.len() == 0:
    info "processRelease", "skipping release: missing nimble file:", $release
    result = NimbleRelease(status: HasUnknownNimbleFile, err: "missing nimble file")
  elif nimbleFiles.len() > 1:
    info "processRelease", "skipping release: ambiguous nimble file:", $release, "files:", $(nimbleFiles.mapIt($it.path.splitPath().tail).join(", "))
    result = NimbleRelease(status: HasUnknownNimbleFile, err: "ambiguous nimble file")
  else:
    let source = nimbleFiles[0]
    let nimbleFile = materializeNimbleFile(pkg, release.commit, source)
    try:
      result = nc.parseNimbleFile(nimbleFile)
    finally:
      if source.fromGit and fileExists($nimbleFile):
        removeFile($nimbleFile)

proc addFeatureDependencies(pkg: Package) =
  ## Marks root package feature requirements as active when requested by context flags.
  ## This can reopen root processing so newly enabled feature dependencies are traversed.

  var featuresAdded = false
  warn pkg.url.projectName, "adding feature dependencies for root package; features:", $(context().features.toSeq().join(", ")), "versions:", $(pkg.versions.keys().toSeq().mapIt($it).join(", "))
  for flag in items(context().features):
    for ver, rel in pkg.versions:
      info pkg.url.projectName, "checking feature:", $flag, "in version:", $rel.version
      if flag in rel.features:
        let fdep = rel.features[flag]
        for pkgUrl, interval in items(fdep):
          info pkg.url.projectName, "adding feature reqsByFeatures:", $flag, "for:", $pkgUrl.url
          withValue(rel.reqsByFeatures, pkgUrl, reqsByFeatures):
            if flag notin reqsByFeatures[]:
              reqsByFeatures[].incl(flag)
              featuresAdded = true
          do:
            rel.reqsByFeatures[pkgUrl] = initHashSet[string]()
            rel.reqsByFeatures[pkgUrl].incl(flag)
      else:
        info pkg.url.projectName, "feature:", $flag, "not found for:", $rel.version
  
  if featuresAdded:
    warn pkg.url.projectName, "feature dependencies added"
    pkg.state = Found

proc addRelease(
    versions: var seq[(PackageVersion, NimbleRelease)],
    nc: var NimbleContext;
    pkg: Package,
    vtag: VersionTag;
    deferChildDeps: bool
): bool =
  ## Parses one release candidate and appends it to the pending version list.
  ## The returned release version is normalized against tag or Nimble-file metadata.
  var pkgver = vtag.toPkgVer()
  trace pkg.url.projectName, "Adding Nimble version:", $vtag
  try:
    let release = nc.processNimbleRelease(pkg, vtag, deferChildDeps)

    if vtag.v.string == "":
      pkgver.vtag.v = release.version
      trace pkg.url.projectName, "updating release tag information:", $pkgver.vtag
    elif release.version.string == "":
      warn pkg.url.projectName, "nimble file missing version information:", $pkgver.vtag
      release.version = vtag.version
    elif vtag.v != release.version and not pkg.isRoot:
      info pkg.url.projectName, "version mismatch between version tag:", $vtag.v, "and nimble version:", $release.version
    
    versions.add((pkgver, release))

    result = true
  except CatchableError as e:
    info pkg.url.projectName, "error processing nimble release:", $vtag, "error:", $e.msg
    return false

proc traverseDependency*(
    nc: var NimbleContext;
    pkg: var Package,
    mode: TraversalMode;
    explicitVersions: seq[VersionTag];
    deferChildDeps = false;
) =
  ## Resolves the set of package releases for a found dependency.
  ## Results are enriched into traversal state and may be loaded from or saved to cache.
  doAssert pkg.ondisk.dirExists() and pkg.state != NotInitialized, "Package should've been found or cloned at this point. Package: " & $pkg.url & " on disk: " & $pkg.ondisk

  var versions: seq[(PackageVersion, NimbleRelease)]
  var expandedExplicitVersions = explicitVersions

  let currentCommit = currentGitCommit(pkg.ondisk, Warning)
  if not pkg.isLocalOnly:
    discard gitops.ensureCanonicalOrigin(pkg.ondisk, pkg.url.toUri)
  pkg.originHead = gitops.findOriginTip(pkg.ondisk, errorReportLevel = Warning, isLocalOnly = pkg.isLocalOnly).commit()

  if canUsePackageReleaseCache(pkg, mode, expandedExplicitVersions):
    var cachedReleases: seq[PackageReleaseCacheEntry]
    if loadPackageReleaseCache(pkg, currentCommit, cachedReleases):
      pkg.versions.clear()
      for entry in cachedReleases:
        pkg.versions[entry.vtag.toPkgVer()] = entry.release
      pkg.state = Processed
      nc.enrichPackageDependencies(pkg, deferChildDeps)
      return

  if mode == CurrentCommit and currentCommit.isEmpty():
    discard
  elif currentCommit.isEmpty():
    warn pkg.url.projectName, "traversing dependency unable to find git current version at ", $pkg.ondisk
    let vtag = VersionTag(v: Version"#head", c: initCommitHash("", FromHead))
    versions.add((vtag.toPkgVer, NimbleRelease(version: vtag.version, status: HasBrokenRepo)))
    pkg.state = Error
    return
  else:
    trace pkg.url.projectName, "traversing dependency current commit:", $currentCommit

  case mode
  of CurrentCommit:
    trace pkg.url.projectName, "traversing dependency for only current commit"
    let vtag = VersionTag(v: Version"#head", c: initCommitHash(currentCommit, FromHead))
    discard versions.addRelease(nc, pkg, vtag, deferChildDeps)

  of ExplicitVersions:
    debug pkg.url.projectName, "traversing dependency found explicit versions:", $expandedExplicitVersions

    var uniqueCommits: HashSet[CommitHash]
    for ver in pkg.versions.keys():
      uniqueCommits.incl(ver.vtag.c)

    # Expand short hashes, branches, and #head before loading explicit releases.
    for version in mitems(expandedExplicitVersions):
      let vtag = gitops.expandSpecial(pkg.ondisk, vtag = version)
      version = vtag
      debug pkg.url.projectName, "explicit version:", $version, "vtag:", repr vtag

    for version in expandedExplicitVersions:
      debug pkg.url.projectName, "check explicit version:", repr version
      if version.commit.isEmpty():
        warn pkg.url.projectName, "explicit version has empty commit:", $version
      elif not uniqueCommits.containsOrIncl(version.commit):
        debug pkg.url.projectName, "add explicit version:", $version
        discard versions.addRelease(nc, pkg, version, deferChildDeps)

  of AllReleases:
    try:
      var uniqueCommits: HashSet[CommitHash]
      var nimbleVersions: HashSet[Version]
      var nimbleCommits = nc.collectNimbleVersions(pkg)

      debug pkg.url.projectName, "nimble explicit versions:", $explicitVersions
      for version in explicitVersions:
        var vtag = gitops.expandSpecial(pkg.ondisk, vtag = version)
        if not vtag.commit.isEmpty() and not uniqueCommits.containsOrIncl(vtag.commit):
          discard versions.addRelease(nc, pkg, vtag, deferChildDeps)

      # Prefer tagged versions over versions inferred from Nimble-file history.
      let tags = collectTaggedVersions(pkg.ondisk, isLocalOnly = pkg.isLocalOnly)
      debug pkg.url.projectName, "nimble tags:", $tags
      for tag in tags:
        if not uniqueCommits.containsOrIncl(tag.c):
          discard versions.addRelease(nc, pkg, tag, deferChildDeps)
          assert tag.commit.orig == FromGitTag, "maybe this needs to be overriden like before: " & $tag.commit.orig

      if tags.len() == 0 or IncludeTagsAndNimbleCommits in context().flags:
        # Use Nimble-file commit versions only when tags are absent or explicitly requested.
        # Otherwise deleted tags could be reintroduced as inferred releases.
        if NimbleCommitsMax in context().flags:
          # Reverse the order so the newest commit is preferred for each version.
          nimbleCommits.reverse()

        debug pkg.url.projectName, "nimble commits:", $nimbleCommits
        for tag in nimbleCommits:
          if not uniqueCommits.containsOrIncl(tag.c):
            var vers: seq[(PackageVersion, NimbleRelease)]
            let added = vers.addRelease(nc, pkg, tag, deferChildDeps)
            if added and not nimbleVersions.containsOrIncl(vers[0][0].vtag.v):
              versions.add(vers)
          else:
            error pkg.url.projectName, "traverseDependency skipping nimble commit:", $tag, "uniqueCommits:", $(tag.c in uniqueCommits), "nimbleVersions:", $(tag.v in nimbleVersions)

        if not currentCommit.isEmpty() and not uniqueCommits.containsOrIncl(currentCommit):
          # Existing checkouts can be detached or on a non-default branch.
          # Include their current nimble version when remote-tip traversal misses it.
          var vers: seq[(PackageVersion, NimbleRelease)]
          let currentTag = VersionTag(v: Version"", c: currentCommit)
          let added = vers.addRelease(nc, pkg, currentTag, deferChildDeps)
          if added and not nimbleVersions.containsOrIncl(vers[0][0].vtag.v):
            versions.add(vers)

      if versions.len() == 0:
        let vtag = VersionTag(v: Version"#head", c: initCommitHash(currentCommit, FromHead))
        debug pkg.url.projectName, "traverseDependency no versions found, using default #head", "at", $pkg.ondisk
        discard versions.addRelease(nc, pkg, vtag, deferChildDeps)

    finally:
      if not checkoutGitCommit(pkg.ondisk, currentCommit, Warning):
        info pkg.url.projectName, "traverseDependency error loading versions reverting to ", $currentCommit

  # Make identical NimbleReleases share the same ref object.
  var uniqueReleases: Table[NimbleRelease, NimbleRelease]
  for (ver, rel) in versions:
    if rel notin uniqueReleases:
      uniqueReleases[rel] = rel
    else:
      trace pkg.url.projectName, "found duplicate release requirements at:", $ver.vtag

  info pkg.url.projectName, "unique versions found:", uniqueReleases.values().toSeq().mapIt($it.version).join(", ")
  for (ver, rel) in versions:
    if mode != ExplicitVersions and ver in pkg.versions:
      error pkg.url.projectName, "duplicate release found:", $ver.vtag, "new:", repr(rel)
      error pkg.url.projectName, "... existing: ", repr(pkg.versions[ver])
      error pkg.url.projectName, "duplicate release found:", $ver.vtag, "new:", repr(rel), " existing: ", repr(pkg.versions[ver])
      error pkg.url.projectName, "versions table:", $pkg.versions.keys().toSeq()
    pkg.versions[ver] = uniqueReleases[rel]

  # Release entries are now loaded; enrichment below registers their dependencies.
  pkg.state = Processed

  nc.enrichPackageDependencies(pkg, deferChildDeps)

  if pkg.isRoot and context().features.len > 0:
    addFeatureDependencies(pkg)

  if canUsePackageReleaseCache(pkg, mode, expandedExplicitVersions):
    savePackageReleaseCache(pkg, currentCommit, pkg.versions.pairs().toSeq())


proc loadDependency*(
    nc: NimbleContext,
    pkg: var Package,
    onClone: PackageAction = DoClone,
) = 
  ## Ensures a package has an on-disk location and marks it ready for traversal.
  ## Depending on URL and policy this may clone, copy, reuse, update, or defer the package.
  if pkg.isRoot:
    pkg.ondisk = project()
    pkg.isAtlasProject = true
    pkg.isLocalOnly = true
    if pkg.state != Found:
      pkg.state = Found
    return

  doAssert pkg.ondisk.string == ""

  let officialUrl = nc.lookup(pkg.url.shortName())
  let isFork = pkg.isFork

  if isFork:
    info pkg.url.projectName, "package is unofficial or forked"
    let canonicalDir = officialUrl.toDirectoryPath()
    let forkDir = pkg.url.toDirectoryPath()
    if dirExists(forkDir) and not dirExists(canonicalDir) and
        forkDir.isRelativeTo(depsDir()) and canonicalDir.isRelativeTo(depsDir()):
      try:
        moveDir(forkDir.string, canonicalDir.string)
      except OSError:
        discard
    pkg.ondisk = canonicalDir
  else:
    pkg.ondisk = pkg.url.toDirectoryPath()

  var todo = if dirExists(pkg.ondisk): DoNothing else: DoClone
  pkg.isAtlasProject = pkg.url.isAtlasProject()
  pkg.isLocalOnly = pkg.url.isNimbleLink()
  if pkg.isLocalOnly:
    todo = DoNothing
  if pkg.state == LazyDeferred:
    todo = DoNothing

  debug pkg.url.projectName, "loading dependency todo:", $todo, "ondisk:", $pkg.ondisk, "isLinked:", $pkg.url.isFileProtocol, "isLazyDeferred:", $(pkg.state == LazyDeferred)
  case todo
  of DoClone:
    if onClone == DoNothing:
      pkg.state = Error
      pkg.errors.add "Not found"
    else:
      let (status, msg) =
        if pkg.url.isFileProtocol:
          pkg.isLocalOnly = true
          copyFromDisk(pkg, pkg.ondisk)
        else:
          gitops.clone(pkg.url.toUri, pkg.ondisk)
      if status == Ok:
        if not pkg.isLocalOnly:
          discard gitops.ensureCanonicalOrigin(pkg.ondisk, pkg.url.toUri)
          discard gitops.resolveRemoteName(pkg.ondisk)
          if isFork:
            discard gitops.ensureRemoteForUrl(pkg.ondisk, officialUrl.toUri)
          discard gitops.fetchRemoteTags(pkg.ondisk)
        pkg.state = Found
      else:
        pkg.state = Error
        pkg.errors.add $status & ": " & msg
  of DoNothing:
    if pkg.ondisk.dirExists():
      pkg.state = Found
      if not pkg.isLocalOnly:
        discard gitops.ensureCanonicalOrigin(pkg.ondisk, pkg.url.toUri)
        discard gitops.resolveRemoteName(pkg.ondisk)
        if isFork:
          discard gitops.ensureRemoteForUrl(pkg.ondisk, officialUrl.toUri)
      if UpdateRepos in context().flags:
        gitops.updateRepo(pkg.ondisk)
        if not pkg.isLocalOnly:
          discard gitops.fetchRemoteTags(pkg.ondisk)
        
    else:
      pkg.state = Error
      pkg.errors.add "ondisk location missing"

proc processPendingPackages(
    graph: var DepGraph;
    nc: var NimbleContext;
    root: Package;
    traversalMode: TraversalMode;
    onClone: PackageAction;
    deferChildDeps: bool
) =
  ## Processes all packages currently known to the context until no immediate work remains.
  ## Lazy packages are represented in the graph without loading their full release history.
  var processing = true
  while processing:
    processing = false
    let pkgUrls = nc.packageToDependency.keys().toSeq()

    # Build concise package lists for progress logging.
    var initializingPkgs: seq[string]
    var processingPkgs: seq[string]
    for pkgUrl in pkgUrls:
      var pkg = nc.packageToDependency[pkgUrl]
      case pkg.state:
      of NotInitialized:
        initializingPkgs.add pkg.projectName
      of Found:
        processingPkgs.add pkg.projectName
      else:
        discard
    if initializingPkgs.len() > 0:
      notice root.projectName, "Initializing packages:", initializingPkgs.join(", ")
    if processingPkgs.len() > 0:
      notice root.projectName, "Processing packages:", processingPkgs.join(", ")

    # Process a stable snapshot so newly discovered packages are handled on the next loop.
    debug "atlas:expandGraph", "Processing package count: ", $pkgUrls.len()
    for pkgUrl in pkgUrls:
      var pkg = nc.packageToDependency[pkgUrl]
      case pkg.state:
      of NotInitialized, DoLoad:
        info pkg.projectName, "Initializing package:", $pkg.url
        nc.loadDependency(pkg, onClone)
        trace pkg.projectName, "expanded pkg:", pkg.repr
        processing = true
      of LazyDeferred:
        if pkgUrl notin graph.pkgs:
          graph.pkgs[pkgUrl] = pkg
          pkg.versions[VersionTag(v: Version"*", c: initCommitHash("#head", FromHead)).toPkgVer] = NimbleRelease(version: Version"#head", status: Normal)
          graph.pkgs[pkgUrl] = pkg
          info pkg.projectName, "Adding lazy deferred package to pkgs list:", $pkg.url
        else:
          trace pkg.projectName, "Skipping lazy deferred package:", $pkg.url
        pkg.state = LazyDeferred
      of Found:
        info pkg.projectName, "Processing package at:", pkg.ondisk.relativeToWorkspace()
        let effectiveMode =
          if pkg.isRoot or pkg.isAtlasProject or pkg.url.isNimbleLink():
            CurrentCommit
          else:
            traversalMode
        let selectedExplicitVersions =
          if effectiveMode == ExplicitVersions:
            nc.explicitVersions[pkgUrl].toSeq()
          else:
            @[]
        nc.traverseDependency(pkg, effectiveMode, selectedExplicitVersions, deferChildDeps=deferChildDeps)
        trace pkg.projectName, "processed pkg:", $pkg
        processing = true
        if pkgUrl notin graph.pkgs:
          graph.pkgs[pkgUrl] = pkg
      of Processed:
        if pkgUrl notin graph.pkgs:
          graph.pkgs[pkgUrl] = pkg
      else:
        discard
        info pkg.projectName, "Skipping package:", $pkg.url, "state:", $pkg.state

proc expandGraph*(
    path: Path,
    nc: var NimbleContext;
    mode: TraversalMode,
    onClone: PackageAction,
    isLinkPath = false,
    deferChildDeps = false
): DepGraph =
  ## Expands a workspace root into a dependency graph.
  ## Explicit commit requirements can add new work, so processing repeats to a fixed point.
  
  doAssert path.string != "."
  let url = nc.createUrlFromPath(path, isLinkPath)
  notice url.projectName, "expanding root package at:", $path, "url:", $url
  var root = Package(url: url, isRoot: true, isFork: isForkUrl(nc, url))

  result = DepGraph(root: root, mode: mode)
  nc.packageToDependency[root.url] = root

  notice "atlas:expand", "Expanding packages for:", $root.projectName

  # Explicit-version traversal can discover additional dependencies.
  # Re-run package processing until no new packages are introduced.
  var graphChanged = true
  while graphChanged:
    graphChanged = false
    result.processPendingPackages(nc, root, mode, onClone, deferChildDeps)

    let pkgCountBeforeExplicit = nc.packageToDependency.len
    let explicitCountBeforeExplicit = nc.explicitVersions.len
    debug "atlas:expandGraph", "Processing explicit versions count: ", $nc.explicitVersions.len()
    for pkgUrl in nc.explicitVersions.keys().toSeq():
      let versions = nc.explicitVersions[pkgUrl]
      info pkgUrl.projectName, "explicit versions: ", versions.toSeq().mapIt($it).join(", ")
      if pkgUrl in nc.packageToDependency:
        var pkg = nc.packageToDependency[pkgUrl]
        if pkg.state == Processed:
          nc.traverseDependency(pkg, ExplicitVersions, versions.toSeq(), deferChildDeps=deferChildDeps)

    graphChanged = nc.packageToDependency.len != pkgCountBeforeExplicit or
      nc.explicitVersions.len != explicitCountBeforeExplicit

  info "atlas:expand", "Finished expanding packages for:", $root.projectName
