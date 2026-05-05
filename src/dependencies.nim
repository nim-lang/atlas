#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Dependency graph expansion and package loading.
##
## This module turns a workspace root into a dependency graph by locating or
## cloning packages, loading their release metadata through `releaseinfo`, and
## registering requirements discovered in Nimble files. It also handles lazy
## dependency deferral, explicit commit requirements, and root feature
## dependencies during traversal.

import std / [os, strutils, uri, tables, sequtils, sets, paths, dirs]
import basic/[context, deptypes, versions, osutils, reporters, gitops, pkgurls, nimblecontext, deptypesjson, packageutils]
import releaseinfo

export deptypes, versions, deptypesjson, releaseinfo, packageutils

type
  PackageAction* = enum
    DoNothing, DoClone

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
      let pkgDep = nc.initPackage(pkgUrl, state)
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
        let pkgDep = nc.initPackage(pkgUrl, state)
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

proc traverseDependency*(
    nc: var NimbleContext;
    pkg: var Package,
    mode: TraversalMode;
    explicitVersions: seq[VersionTag];
    deferChildDeps = false;
) =
  ## Resolves the set of package releases for a found dependency.
  ## Release metadata is loaded separately, then enriched into traversal state.
  doAssert pkg.ondisk.dirExists() and pkg.state != NotInitialized, "Package should've been found or cloned at this point. Package: " & $pkg.url & " on disk: " & $pkg.ondisk

  let releaseInfo = nc.loadPackageReleaseInfo(pkg, mode, explicitVersions)
  if releaseInfo.repoError:
    pkg.state = Error
    return

  if releaseInfo.loadedFromCache:
    pkg.versions.clear()

  for (ver, rel) in releaseInfo.releases:
    if mode != ExplicitVersions and ver in pkg.versions:
      error pkg.url.projectName, "duplicate release found:", $ver.vtag, "new:", repr(rel)
      error pkg.url.projectName, "... existing: ", repr(pkg.versions[ver])
      error pkg.url.projectName, "duplicate release found:", $ver.vtag, "new:", repr(rel), " existing: ", repr(pkg.versions[ver])
      error pkg.url.projectName, "versions table:", $pkg.versions.keys().toSeq()
    canonicalizeReleaseUrls(nc, rel)
    pkg.versions[ver] = rel

  # Release entries are now loaded; enrichment below registers their dependencies.
  pkg.state = Processed

  nc.enrichPackageDependencies(pkg, deferChildDeps)

  if pkg.isRoot and context().features.len > 0:
    addFeatureDependencies(pkg)

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

  let officialUrl = nc.lookup(pkg.projectName())
  let isFork = pkg.isFork

  if isFork:
    info pkg.url.projectName, "package is unofficial or forked"
    let canonicalDir = officialUrl.toDirectoryPath(pkg.projectName())
    let forkDir = pkg.url.toDirectoryPath()
    if dirExists(forkDir) and not dirExists(canonicalDir) and
        forkDir.isRelativeTo(depsDir()) and canonicalDir.isRelativeTo(depsDir()):
      try:
        moveDir(forkDir.string, canonicalDir.string)
      except OSError:
        discard
    pkg.ondisk = canonicalDir
  else:
    pkg.ondisk = pkg.url.toDirectoryPath(pkg.projectName())

  pkg.isAtlasProject = pkg.url.isAtlasProject()
  pkg.isLocalOnly = pkg.url.isNimbleLink()
  var todo = if pkg.resolveExistingPackageDir(): DoNothing else: DoClone
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
      return
    else:
      clonePackage(pkg, officialUrl, isFork)
  of DoNothing:
    if pkg.ondisk.dirExists():
      pkg.state = Found
      if not pkg.isLocalOnly:
        discard gitops.loadRepoMetadata(pkg.ondisk, expectedCanonicalUrl = $pkg.url.cloneUri())
        if isFork:
          discard gitops.ensureRemoteForUrl(pkg.ondisk, officialUrl.cloneUri())
      if UpdateRepos in context().flags:
        gitops.updateRepo(pkg.ondisk)
        if not pkg.isLocalOnly:
          var repo = gitops.loadRepoMetadata(pkg.ondisk, expectedCanonicalUrl = $pkg.url.cloneUri())
          discard gitops.fetchRemoteTags(repo)
        
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
