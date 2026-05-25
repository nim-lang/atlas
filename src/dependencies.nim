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
import basic/[context, deptypes, versions, osutils, reporters, gitops, pkgurls, nimblecontext, deptypesjson, packageutils, gitprogresspool, remotecache, forgetarball, dependencycache]
import releaseinfo

export deptypes, versions, deptypesjson, releaseinfo, packageutils

type
  PackageAction* = enum
    DoNothing, DoClone

  PendingCloneJob = object
    pkgUrl: PkgUrl
    checkoutDir: Path
    progressJob: GitProgressJob

  SharedRepoSyncPlan = object
    enabled: bool
    repoDir: Path
    progressJob: GitProgressJob

proc cloneProgressJob(pkg: Package; checkoutDir: Path): GitProgressJob =
  let canonicalUrl = pkg.url.cloneUri()
  let remote = gitops.remoteNameFromGitUrl($canonicalUrl)
  let effectiveUrl = gitops.maybeUrlProxy(canonicalUrl)
  result = GitProgressJob(
    label: pkg.projectName,
    command: "git",
    args: @["clone"]
  )
  if $context().proxy == "" or DumbProxy notin context().flags:
    if ShallowClones in context().flags:
      result.args.add "--depth=1"
  if remote.len > 0:
    result.args.add "--origin"
    result.args.add remote
  result.args.add "--no-tags"
  result.args.add "--progress"
  result.args.add $effectiveUrl
  result.args.add $checkoutDir

proc sharedRepoCloneProgressJob(repoDir: Path): GitProgressJob =
  let repoUrl = packagesRepoUrl()
  let canonicalUrl = parseUri(repoUrl)
  let remote = gitops.remoteNameFromGitUrl(repoUrl)
  let effectiveUrl = gitops.maybeUrlProxy(canonicalUrl)
  result = GitProgressJob(
    label: "atlas:packages",
    command: "git",
    args: @["clone"]
  )
  if ShallowClones in context().flags:
    result.args.add "--depth=1"
  if remote.len > 0:
    result.args.add "--origin"
    result.args.add remote
  result.args.add "--no-tags"
  result.args.add "--progress"
  result.args.add $effectiveUrl
  result.args.add $repoDir

proc sharedRepoPullProgressJob(repoDir: Path): GitProgressJob =
  GitProgressJob(
    label: "atlas:packages",
    command: "git",
    args: @["pull", "--ff-only", "--progress"],
    workingDir: $repoDir
  )

proc buildSharedRepoSyncPlan(firstEpoch: bool): SharedRepoSyncPlan =
  if not firstEpoch:
    return

  createDir($atlasHomeDirectory())
  let repoDir = sharedPackagesRepoDir()
  if dirExists($repoDir):
    if not isGitDir(repoDir):
      warn "atlas:cache", "shared packages path is not a git repo:", $repoDir
      return
    result = SharedRepoSyncPlan(
      enabled: true,
      repoDir: repoDir,
      progressJob: sharedRepoPullProgressJob(repoDir)
    )
  else:
    result = SharedRepoSyncPlan(
      enabled: true,
      repoDir: repoDir,
      progressJob: sharedRepoCloneProgressJob(repoDir)
    )

proc markCloneFailure(pkg: var Package; details: string) =
  pkg.state = Error
  if details.len > 0:
    pkg.errors.add details
  else:
    pkg.errors.add "clone failed"

proc finishClonedDependency(
    nc: NimbleContext;
    pkg: var Package;
    checkoutDir: Path;
    officialUrl: PkgUrl;
    isFork: bool
) =
  pkg.completeClonedPackage(checkoutDir)
  var repo = gitops.loadRepoMetadata(pkg.ondisk, expectedCanonicalUrl = $pkg.url.cloneUri())
  if isFork:
    discard gitops.ensureRemoteForUrl(pkg.ondisk, officialUrl.cloneUri())
  discard gitops.fetchRemoteTags(repo)
  pkg.state = Found

proc processCloneEpoch(
    nc: var NimbleContext;
    root: Package;
    cloneJobs: seq[PendingCloneJob];
    sharedRepoPlan: SharedRepoSyncPlan
) =
  if cloneJobs.len == 0 and not sharedRepoPlan.enabled:
    return

  var jobs = cloneJobs.mapIt(it.progressJob)
  let packageJobCount = jobs.len
  if sharedRepoPlan.enabled:
    jobs.add sharedRepoPlan.progressJob

  notice root.projectName, "Cloning packages in parallel:", $packageJobCount
  let cloneResults = runGitProgressJobs(
    jobs,
    title = "atlas:clone",
    workerCount = context().parallelCloneWorkers
  )

  for i, job in cloneJobs:
    var pkg = nc.packageToDependency[job.pkgUrl]
    let cloneResult = cloneResults[i]
    if cloneResult.exitCode == 0 and isGitDir(job.checkoutDir):
      let officialUrl = nc.lookup(pkg.projectName())
      let isFork = pkg.isFork
      nc.finishClonedDependency(pkg, job.checkoutDir, officialUrl, isFork)
    else:
      var details = cloneResult.output.strip()
      if details.len == 0:
        details = "clone failed for " & $pkg.url.cloneUri()
      pkg.markCloneFailure(details)

  if sharedRepoPlan.enabled:
    let sharedRepoResult = cloneResults[packageJobCount]
    let ok = sharedRepoResult.exitCode == 0 and dirExists($sharedRepoPlan.repoDir)
    if not ok:
      var details = sharedRepoResult.output.strip()
      if details.len == 0:
        details = "shared packages sync failed"
      warn "atlas:cache", details

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

  # Try to seed the release cache from the shared packages repo so
  # loadPackageReleaseInfo can skip expensive tag scanning when the
  # HEAD matches.
  discard copySharedReleaseCache(pkg, sharedPackagesRepoDir())

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

  if todo == DoClone and not pkg.isLocalOnly:
    let cachePath = packageReleaseCachePath(pkg)
    if not fileExists($cachePath):
      discard downloadReleaseCache(pkg.projectName())
    if hasForgeMetadata(cachePath):
      notice pkg.url.projectName, "using forge release tarball instead of git clone"
      pkg.isForgePackage = true
      createDir($pkg.ondisk)
      todo = DoNothing
      pkg.state = Found
      let head = loadCacheHead(cachePath)
      if head.len > 0:
        pkg.originHead = initCommitHash(head, FromHead)

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
      if not pkg.isLocalOnly and not pkg.isForgePackage:
        discard gitops.loadRepoMetadata(pkg.ondisk, expectedCanonicalUrl = $pkg.url.cloneUri())
        if isFork:
          discard gitops.ensureRemoteForUrl(pkg.ondisk, officialUrl.cloneUri())
      if UpdateRepos in context().flags and not pkg.isForgePackage:
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
    deferChildDeps: bool;
    firstCloneEpoch: var bool
) =
  ## Processes all packages currently known to the context until no immediate work remains.
  ## Lazy packages are represented in the graph without loading their full release history.
  var processing = true
  while processing:
    processing = false
    let pkgUrls = nc.packageToDependency.keys().toSeq()
    var cloneJobs: seq[PendingCloneJob]

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
        if ParallelClones notin context().flags:
          nc.loadDependency(pkg, onClone)
          trace pkg.projectName, "expanded pkg:", pkg.repr
          processing = true
          continue

        if pkg.isRoot:
          nc.loadDependency(pkg, onClone)
          trace pkg.projectName, "expanded pkg:", pkg.repr
          processing = true
          continue

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

        if todo == DoClone and not pkg.isLocalOnly:
          let cachePath = packageReleaseCachePath(pkg)
          if not fileExists($cachePath):
            discard downloadReleaseCache(pkg.projectName())
          if hasForgeMetadata(cachePath):
            notice pkg.url.projectName, "using forge release tarball instead of git clone"
            pkg.isForgePackage = true
            createDir($pkg.ondisk)
            todo = DoNothing
            pkg.state = Found
            let head = loadCacheHead(cachePath)
            if head.len > 0:
              pkg.originHead = initCommitHash(head, FromHead)

        case todo
        of DoClone:
          if onClone == DoNothing:
            pkg.state = Error
            pkg.errors.add "Not found"
          elif pkg.url.isFileProtocol:
            nc.loadDependency(pkg, onClone)
            trace pkg.projectName, "expanded pkg:", pkg.repr
            processing = true
          else:
            let checkoutDir = pkg.prepareCloneCheckoutDir()
            cloneJobs.add PendingCloneJob(
              pkgUrl: pkgUrl,
              checkoutDir: checkoutDir,
              progressJob: cloneProgressJob(pkg, checkoutDir)
            )
            processing = true
        of DoNothing:
          if pkg.ondisk.dirExists():
            pkg.state = Found
            if not pkg.isLocalOnly and not pkg.isForgePackage:
              discard gitops.loadRepoMetadata(pkg.ondisk, expectedCanonicalUrl = $pkg.url.cloneUri())
              if isFork:
                discard gitops.ensureRemoteForUrl(pkg.ondisk, officialUrl.cloneUri())
            if UpdateRepos in context().flags and not pkg.isForgePackage:
              gitops.updateRepo(pkg.ondisk)
              if not pkg.isLocalOnly:
                var repo = gitops.loadRepoMetadata(pkg.ondisk, expectedCanonicalUrl = $pkg.url.cloneUri())
                discard gitops.fetchRemoteTags(repo)
            trace pkg.projectName, "expanded pkg:", pkg.repr
            processing = true
          else:
            pkg.state = Error
            pkg.errors.add "ondisk location missing"
        trace pkg.projectName, "expanded pkg:", pkg.repr
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

    let sharedRepoPlan =
      if cloneJobs.len > 0:
        buildSharedRepoSyncPlan(firstCloneEpoch)
      else:
        SharedRepoSyncPlan()
    nc.processCloneEpoch(root, cloneJobs, sharedRepoPlan)
    if cloneJobs.len > 0:
      firstCloneEpoch = false

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
  var firstCloneEpoch = true
  while graphChanged:
    graphChanged = false
    result.processPendingPackages(nc, root, mode, onClone, deferChildDeps, firstCloneEpoch)

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
