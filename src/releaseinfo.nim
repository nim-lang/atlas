#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Release metadata loading for Atlas packages.
##
## This module discovers the Nimble releases available for a package from git
## tags, Nimble-file history, explicit commit requirements, or the release
## cache. It only loads and normalizes release information; dependency graph
## enrichment is handled by `dependencies`.

import std / [os, strutils, tables, sequtils, sets, algorithm, paths]
import basic/[context, deptypes, versions, nimbleparser, reporters, gitops, pkgurls, nimblecontext, dependencycache]

type
  VersionRun = tuple[version: Version, base: CommitHash]

  PackageReleaseInfo* = object
    currentCommit*: CommitHash
    expandedExplicitVersions*: seq[VersionTag]
    releases*: seq[(PackageVersion, NimbleRelease)]
    loadedFromCache*: bool
    repoError*: bool

proc collectNimbleVersions*(nc: NimbleContext; pkg: Package; repo: RepoMetadata): seq[VersionTag] =
  ## Collects commits that modified the package's Nimble file.
  ## These commits are used as fallback release candidates when tags are absent.
  let nimbleFiles = findNimbleFile(pkg)
  doAssert(pkg.ondisk.string != "", "Package ondisk must be set before collectNimbleVersions can be called! Package: " & $(pkg))
  result = @[]
  if nimbleFiles.len() == 1:
    result = collectFileCommits(repo, nimbleFiles[0])
    result.reverse()
    trace pkg, "collectNimbleVersions commits:", mapIt(result, it.c.short()).join(", "), "nimble:", $nimbleFiles[0]

proc collectNimbleVersions*(nc: NimbleContext; pkg: Package): seq[VersionTag] =
  let repo = loadRepoMetadata(pkg.ondisk, isLocalOnly = pkg.isLocalOnly)
  nc.collectNimbleVersions(pkg, repo)

proc processNimbleRelease*(
    nc: var NimbleContext;
    pkg: Package,
    release: VersionTag;
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

proc addRelease(
    versions: var seq[(PackageVersion, NimbleRelease)],
    nc: var NimbleContext;
    pkg: Package,
    vtag: VersionTag;
): bool =
  ## Parses one release candidate and appends it to the pending version list.
  ## The returned release version is normalized against tag or Nimble-file metadata.
  var pkgver = vtag.toPkgVer()
  pkgver.vtag.isPinned = vtag.v.isCommit()
  trace pkg.url.projectName, "Adding Nimble version:", $vtag
  try:
    let release = nc.processNimbleRelease(pkg, vtag)

    if vtag.v.string == "" or
        ((vtag.v.isHead() or vtag.v.isCommit()) and not pkg.isRoot and
          release.version.string != ""):
      pkgver.vtag.v = release.version
      if vtag.v.isHead():
        pkgver.vtag.isTip = true
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

proc addCommitDistance(
    pkg: Package;
    versionBase: CommitHash;
    version: PackageVersion
) =
  let distance = commitDistance(pkg.ondisk, versionBase, version.commit)
  if distance > 0:
    version.vtag.v = version.vtag.v.withCommitDistance(Natural(distance))

proc loadInferredReleases(
    nc: var NimbleContext;
    pkg: Package;
    commits: seq[VersionTag];
    versionBases: var Table[string, CommitHash];
    versionRuns: var seq[VersionRun]
): seq[(PackageVersion, NimbleRelease)] =
  ## Loads Nimble-file commits in chronological order and records the commit
  ## where each run of an exact version string began.
  var previousVersion = ""
  var versionBase: CommitHash
  for commit in commits:
    var release: seq[(PackageVersion, NimbleRelease)]
    if release.addRelease(nc, pkg, commit):
      let version = release[0][1].version.string
      if result.len == 0 or version != previousVersion:
        versionBase = commit.c
        versionBases[version] = versionBase
        versionRuns.add((release[0][1].version, versionBase))
      addCommitDistance(pkg, versionBase, release[0][0])
      result.add(release[0])
      previousVersion = version

proc loadInferredReleases(
    nc: var NimbleContext;
    pkg: Package;
    commits: seq[VersionTag];
    versionBases: var Table[string, CommitHash]
): seq[(PackageVersion, NimbleRelease)] =
  var versionRuns: seq[VersionRun]
  result = nc.loadInferredReleases(pkg, commits, versionBases, versionRuns)

proc findVersionBase(
    pkg: Package;
    versionRuns: openArray[VersionRun];
    version: Version;
    target: CommitHash
): CommitHash =
  ## Finds the nearest run of `version` that is an ancestor of `target`.
  var nearestDistance = high(int)
  for run in versionRuns:
    if run.version == version:
      let distance = commitDistance(pkg.ondisk, run.base, target)
      if distance >= 0 and distance < nearestDistance:
        nearestDistance = distance
        result = run.base

proc deduplicateReleases(
    pkg: Package;
    versions: seq[(PackageVersion, NimbleRelease)]
): seq[(PackageVersion, NimbleRelease)] =
  ## Makes identical NimbleReleases share the same ref object.
  var uniqueReleases: Table[NimbleRelease, NimbleRelease]
  for (ver, rel) in versions:
    if rel notin uniqueReleases:
      uniqueReleases[rel] = rel
    else:
      trace pkg.url.projectName, "found duplicate release requirements at:", $ver.vtag

  info pkg.url.projectName, "unique versions found:", uniqueReleases.values().toSeq().mapIt($it.version).join(", ")
  for (ver, rel) in versions:
    result.add((ver, uniqueReleases[rel]))

proc loadPackageReleaseInfo*(
    nc: var NimbleContext;
    pkg: var Package,
    mode: TraversalMode;
    explicitVersions: seq[VersionTag]
): PackageReleaseInfo =
  ## Loads release metadata for a package without enriching dependency graph state.
  ## Results may come from cache, git tags, Nimble-file history, or explicit commits.
  result.expandedExplicitVersions = explicitVersions

  var repo = loadRepoMetadata(
    pkg.ondisk,
    expectedCanonicalUrl = if pkg.isLocalOnly: "" else: $pkg.url.cloneUri(),
    errorReportLevel = Warning,
    isLocalOnly = pkg.isLocalOnly
  )
  result.currentCommit = repo.currentCommit
  pkg.originHead = repo.originTip.commit()
  let tagRefs = tagRefsSnapshot(repo)

  if canUsePackageReleaseCache(pkg, mode, result.expandedExplicitVersions):
    var cachedReleases: seq[PackageReleaseCacheEntry]
    if loadPackageReleaseCache(pkg, result.currentCommit, cachedReleases, tagRefs):
      for entry in cachedReleases:
        result.releases.add((entry.vtag.toPkgVer(), entry.release))
      result.loadedFromCache = true
      return

  if mode == CurrentCommit and result.currentCommit.isEmpty():
    discard
  elif result.currentCommit.isEmpty():
    warn pkg.url.projectName, "traversing dependency unable to find git current version at ", $pkg.ondisk
    let vtag = VersionTag(v: Version"#head", c: initCommitHash("", FromHead))
    result.releases.add((vtag.toPkgVer, NimbleRelease(version: vtag.version, status: HasBrokenRepo)))
    result.repoError = true
    return
  else:
    trace pkg.url.projectName, "traversing dependency current commit:", $result.currentCommit

  case mode
  of CurrentCommit:
    trace pkg.url.projectName, "traversing dependency for only current commit"
    let vtag = VersionTag(v: Version"#head", c: initCommitHash(result.currentCommit, FromHead))
    discard result.releases.addRelease(nc, pkg, vtag)

  of ExplicitVersions:
    debug pkg.url.projectName, "traversing dependency found explicit versions:", $result.expandedExplicitVersions

    # Expand short hashes, branches, and #head before loading explicit releases.
    for version in mitems(result.expandedExplicitVersions):
      let vtag = gitops.expandSpecial(repo, vtag = version)
      version = vtag
      debug pkg.url.projectName, "explicit version:", $version, "vtag:", repr vtag

    var versionBases: Table[string, CommitHash]
    var versionRuns: seq[VersionRun]
    if result.expandedExplicitVersions.anyIt(it.isTip or it.version.isCommit()):
      let nimbleCommits = nc.collectNimbleVersions(pkg, repo)
      discard nc.loadInferredReleases(pkg, nimbleCommits, versionBases, versionRuns)

    for version in result.expandedExplicitVersions:
      debug pkg.url.projectName, "check explicit version:", repr version
      if version.commit.isEmpty():
        warn pkg.url.projectName, "explicit version has empty commit:", $version
      elif version.toPkgVer() notin pkg.versions:
        debug pkg.url.projectName, "add explicit version:", $version
        var releases: seq[(PackageVersion, NimbleRelease)]
        if releases.addRelease(nc, pkg, version):
          let releaseVersion = releases[0][1].version.string
          if version.isTip and versionBases.hasKey(releaseVersion):
            addCommitDistance(pkg, versionBases[releaseVersion], releases[0][0])
          elif version.version.isCommit():
            let versionBase = findVersionBase(
              pkg, versionRuns, releases[0][1].version, version.commit)
            if not versionBase.isEmpty():
              addCommitDistance(pkg, versionBase, releases[0][0])
          result.releases.add(releases[0])

  of AllReleases:
    try:
      var uniqueCommits: HashSet[CommitHash]
      var nimbleVersions: HashSet[Version]
      let nimbleCommits = nc.collectNimbleVersions(pkg, repo)

      debug pkg.url.projectName, "nimble explicit versions:", $explicitVersions
      for version in explicitVersions:
        var vtag = gitops.expandSpecial(repo, vtag = version)
        if not vtag.commit.isEmpty() and not uniqueCommits.containsOrIncl(vtag.commit):
          discard result.releases.addRelease(nc, pkg, vtag)

      # Prefer tagged versions over versions inferred from Nimble-file history.
      let tags = collectTaggedVersions(repo)
      debug pkg.url.projectName, "nimble tags:", $tags
      for tag in tags:
        if not uniqueCommits.containsOrIncl(tag.c):
          discard result.releases.addRelease(nc, pkg, tag)
          assert tag.commit.orig == FromGitTag, "maybe this needs to be overriden like before: " & $tag.commit.orig

      if tags.len() == 0 or IncludeTagsAndNimbleCommits in context().flags:
        # Use Nimble-file commit versions only when tags are absent or explicitly requested.
        # Otherwise deleted tags could be reintroduced as inferred releases.
        var versionBases: Table[string, CommitHash]
        var inferredReleases = nc.loadInferredReleases(pkg, nimbleCommits, versionBases)
        if NimbleCommitsMax in context().flags:
          # Reverse the order so the newest commit is preferred for each version.
          inferredReleases.reverse()

        debug pkg.url.projectName, "nimble commits:", $inferredReleases.mapIt(it[0].vtag)
        for inferred in inferredReleases:
          if not uniqueCommits.containsOrIncl(inferred[0].commit):
            if not nimbleVersions.containsOrIncl(inferred[1].version):
              result.releases.add(inferred)
          else:
            error pkg.url.projectName, "traverseDependency skipping nimble commit:",
              $inferred[0].vtag, "uniqueCommits:",
              $(inferred[0].commit in uniqueCommits), "nimbleVersions:",
              $(inferred[1].version in nimbleVersions)

        if not result.currentCommit.isEmpty() and not uniqueCommits.containsOrIncl(result.currentCommit):
          # Existing checkouts can be detached or on a non-default branch.
          # Include their current nimble version when remote-tip traversal misses it.
          var vers: seq[(PackageVersion, NimbleRelease)]
          let currentTag = VersionTag(v: Version"", c: result.currentCommit)
          let added = vers.addRelease(nc, pkg, currentTag)
          if added:
            let currentVersion = vers[0][1].version
            if versionBases.hasKey(currentVersion.string):
              addCommitDistance(pkg, versionBases[currentVersion.string], vers[0][0])
            if not nimbleVersions.containsOrIncl(currentVersion):
              result.releases.add(vers)

      if result.releases.len() == 0:
        let vtag = VersionTag(v: Version"#head", c: initCommitHash(result.currentCommit, FromHead))
        debug pkg.url.projectName, "traverseDependency no versions found, using default #head", "at", $pkg.ondisk
        discard result.releases.addRelease(nc, pkg, vtag)

    finally:
      if not checkoutGitCommit(pkg.ondisk, result.currentCommit, result.currentCommit, Warning):
        info pkg.url.projectName, "traverseDependency error loading versions reverting to ", $result.currentCommit

  result.releases = deduplicateReleases(pkg, result.releases)

  if canUsePackageReleaseCache(pkg, mode, result.expandedExplicitVersions):
    savePackageReleaseCache(pkg, result.currentCommit, result.releases, tagRefsSnapshot(repo))
