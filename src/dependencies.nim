#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std / [os, strutils, uri, tables, unicode, sequtils, sets, json, hashes, algorithm, paths, files, dirs]
import basic/[context, deptypes, versions, osutils, nimbleparser, packageinfos, reporters, gitops, parse_requires, pkgurls, compiledpatterns, sattypes, nimblecontext]

export deptypes, versions

type
  TraversalMode* = enum
    AllReleases,
    CurrentCommit

when defined(nimAtlasBootstrap):
  import ../dist/sat/src/sat/satvars
else:
  import sat/satvars

proc collectNimbleVersions*(nc: NimbleContext; pkg: Package): seq[VersionTag] =
  let nimbleFiles = findNimbleFile(pkg)
  let dir = pkg.ondisk
  doAssert(pkg.ondisk.string != "", "Package ondisk must be set before collectNimbleVersions can be called! Package: " & $(pkg))
  result = @[]
  if nimbleFiles.len() == 1:
    result = collectFileCommits(dir, nimbleFiles[0])
    result.reverse()
    trace pkg, "collectNimbleVersions commits:", mapIt(result, it.c.short()).join(", "), "nimble:", $nimbleFiles[0]

type
  PackageAction* = enum
    DoNothing, DoClone

proc copyFromDisk*(pkg: Package; destDir: Path): (CloneStatus, string) =
  var dir = Path $pkg.url.url
  if pkg.url.url.scheme == "file":
    dir = workspace() / Path(dir.string.substr(FileWorkspace.len))
  #template selectDir(a, b: string): string =
  #  if dirExists(a): a else: b

  #let dir = selectDir(u & "@" & w.commit, u)
  if pkg.isRoot:
    trace dir, "copyFromDisk isTopLevel", $dir
    result = (Ok, $dir)
  elif dirExists(dir):
    trace dir, "copyFromDisk cloning:", $dir
    copyDir($dir, $destDir)
    result = (Ok, "")
  else:
    error dir, "copyFromDisk not found:", $dir
    result = (NotFound, $dir)
  #writeFile destDir / ThisVersion, w.commit
  #echo "WRITTEN ", destDir / ThisVersion

proc processNimbleRelease(
    nc: var NimbleContext;
    pkg: Package,
    release: VersionTag
): NimbleRelease =
  info pkg.url.projectName, "Processing release:", $release

  if release.version == Version"#head":
    trace pkg.url.projectName, "processRelease using current commit"
  elif release.commit.isEmpty():
    error pkg.url.projectName, "processRelease missing commit ", $release, "at:", $pkg.ondisk
    result = NimbleRelease(status: HasBrokenRelease, err: "no commit")
    return
  elif not checkoutGitCommit(pkg.ondisk, release.commit, Error):
    warn pkg.url.projectName, "processRelease unable to checkout commit ", $release, "at:", $pkg.ondisk
    result = NimbleRelease(status: HasBrokenRelease, err: "error checking out release")
    return

  let nimbleFiles = findNimbleFile(pkg)
  var badNimbleFile = false
  if nimbleFiles.len() == 0:
    info "processRelease", "skipping release: missing nimble file:", $release
    result = NimbleRelease(status: HasUnknownNimbleFile, err: "missing nimble file")
  elif nimbleFiles.len() > 1:
    info "processRelease", "skipping release: ambiguous nimble file:", $release, "files:", $(nimbleFiles.mapIt(it.splitPath().tail).join(", "))
    result = NimbleRelease(status: HasUnknownNimbleFile, err: "ambiguous nimble file")
  else:
    let nimbleFile = nimbleFiles[0]
    result = nc.parseNimbleFile(nimbleFile, context().overrides)

    if result.status == Normal:
      for pkgUrl, interval in items(result.requirements):
        # var pkgDep = pkgs.packageToDependency.getOrDefault(pkgUrl, nil)
        if pkgUrl notin nc.packageToDependency:
          debug pkg, "Found new pkg:", pkgUrl.projectName, "url:", $pkgUrl.url
          let pkgDep = Package(url: pkgUrl, state: NotInitialized)
          nc.packageToDependency[pkgUrl] = pkgDep
          # TODO: enrich versions with hashes when added
          # enrichVersionsViaExplicitHash graph[depIdx].versions, interval

proc addRelease(
    versions: var seq[(PackageVersion, NimbleRelease)],
    # pkg: var Package,
    nc: var NimbleContext;
    pkg: Package,
    vtag: VersionTag
) =
  var pkgver = vtag.toPkgVer()
  warn pkg.url.projectName, "Adding Nimble version:", $vtag
  let release = nc.processNimbleRelease(pkg, vtag)

  if vtag.v.string == "":
    pkgver.vtag.v = release.version
    debug pkg.url.projectName, "updating release tag information:", $pkgver.vtag
  elif release.version.string == "":
    warn pkg.url.projectName, "nimble file missing version information:", $pkgver.vtag
    release.version = vtag.version
  elif vtag.v != release.version:
    warn pkg.url.projectName, "version mismatch between:", $vtag.v, "nimble version:", $release.version
  
  versions.add((pkgver, release,))

proc traverseDependency*(
    nc: var NimbleContext;
    pkg: var Package,
    mode: TraversalMode;
    explicitVersions: seq[VersionTag];
) =
  doAssert pkg.ondisk.dirExists() and pkg.state != NotInitialized, "Package should've been found or cloned at this point"

  var versions: seq[(PackageVersion, NimbleRelease)]

  let currentCommit = currentGitCommit(pkg.ondisk, Warning)
  if mode == CurrentCommit and currentCommit.isEmpty():
    # let vtag = VersionTag(v: Version"#head", c: initCommitHash("", FromHead))
    # versions.add((vtag, NimbleRelease(version: vtag.version, status: Normal)))
    # pkg.state = Processed
    # info pkg.url.projectName, "traversing dependency using current commit:", $vtag
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
    versions.addRelease(nc, pkg, vtag)

  of AllReleases:
    try:
      var uniqueCommits: HashSet[CommitHash]
      let nimbleCommits = nc.collectNimbleVersions(pkg)

      info pkg.url.projectName, "traverseDependency nimble explicit versions:", $explicitVersions
      for version in explicitVersions:
        if version.version == Version"" and
            not version.commit.isEmpty() and
            not uniqueCommits.containsOrIncl(version.commit):
            let vtag = VersionTag(v: Version"", c: version.commit)
            assert vtag.commit.orig == FromDep, "maybe this needs to be overriden like before: " & $vtag.commit.orig
            versions.addRelease(nc, pkg, vtag)

      ## Note: always prefer tagged versions
      let tags = collectTaggedVersions(pkg.ondisk)
      info pkg.url.projectName, "traverseDependency nimble tags:", $tags
      for tag in tags:
        if not uniqueCommits.containsOrIncl(tag.c):
          versions.addRelease(nc, pkg, tag)
          assert tag.commit.orig == FromGitTag, "maybe this needs to be overriden like before: " & $tag.commit.orig

      if tags.len() == 0 or context().includeTagsAndNimbleCommits:
        ## Note: skip nimble commit versions unless explicitly enabled
        ## package maintainers may delete a tag to skip a versions, which we'd override here
        info pkg.url.projectName, "traverseDependency nimble commits:", $nimbleCommits
        for tag in nimbleCommits:
          if not uniqueCommits.containsOrIncl(tag.c):
            versions.addRelease(nc, pkg, tag)

      if versions.len() == 0:
        let vtag = VersionTag(v: Version"#head", c: initCommitHash(currentCommit, FromHead))
        info pkg.url.projectName, "traverseDependency no versions found, using default #head", "at", $pkg.ondisk
        versions.addRelease(nc, pkg, vtag)

    finally:
      if not checkoutGitCommit(pkg.ondisk, currentCommit, Warning):
        info pkg.url.projectName, "traverseDependency error loading versions reverting to ", $currentCommit

  # make sure identicle NimbleReleases refer to the same ref
  var uniqueReleases: Table[NimbleRelease, NimbleRelease]
  for (ver, rel) in versions:
    if rel notin uniqueReleases:
      trace pkg.url.projectName, "found unique release requirements at:", $ver.vtag
      uniqueReleases[rel] = rel
    else:
      trace pkg.url.projectName, "found duplicate release requirements at:", $ver.vtag

  info pkg.url.projectName, "unique versions found:", uniqueReleases.values().toSeq().mapIt($it.version).join(", ")
  for (ver, rel) in versions:
    if ver in pkg.versions:
      error pkg.url.projectName, "duplicate release found:", $ver.vtag, "new:", repr(rel)
      error pkg.url.projectName, "... existing: ", repr(pkg.versions[ver])
      error pkg.url.projectName, "duplicate release found:", $ver.vtag, "new:", repr(rel), " existing: ", repr(pkg.versions[ver])
      error pkg.url.projectName, "versions table:", $pkg.versions.keys().toSeq()
    pkg.versions[ver] = uniqueReleases[rel]
  
  # TODO: filter by unique versions first?
  pkg.state = Processed

proc loadDependency*(
    nc: NimbleContext,
    pkg: var Package,
    onClone: PackageAction = DoClone,
) = 
  doAssert pkg.ondisk.string == ""
  pkg.ondisk = pkg.url.toDirectoryPath()
  let todo = if dirExists(pkg.ondisk): DoNothing else: DoClone

  debug pkg.url.projectName, "loading dependency todo:", $todo, "dest:", $pkg.ondisk
  case todo
  of DoClone:
    if onClone == DoNothing:
      pkg.state = Error
      pkg.errors.add "Not found"
    else:
      let (status, msg) =
        if pkg.url.isFileProtocol:
          copyFromDisk(pkg, pkg.ondisk)
        else:
          gitops.clone(pkg.url.toUri, pkg.ondisk)
      if status == Ok:
        pkg.state = Found
      else:
        pkg.state = Error
        pkg.errors.add $status & ": " & msg
  of DoNothing:
    if pkg.ondisk.dirExists():
      pkg.state = Found
    else:
      pkg.state = Error
      pkg.errors.add "ondisk location missing"

proc expand*(path: Path, nc: var NimbleContext; mode: TraversalMode, onClone: PackageAction): DepGraph =
  ## Expand the graph by adding all dependencies.
  
  doAssert path.string != "."
  let url = nc.createUrlFromPath(path)
  warn url.projectName, "expanding root package at:", $path, "url:", $url
  var root = Package(url: url, isRoot: true)
  # nc.loadDependency(pkg)

  var processed = initHashSet[PkgUrl]()
  result = DepGraph(root: root)
  nc.packageToDependency[root.url] = root

  var processing = true
  while processing:
    processing = false
    let pkgUrls = nc.packageToDependency.keys().toSeq()
    info "Expand", "Expanding packages for:", $root.projectName
    for pkgUrl in pkgUrls:
      var pkg = nc.packageToDependency[pkgUrl]
      case pkg.state:
      of NotInitialized:
        info pkg.projectName, "Initializing at:", $pkg
        nc.loadDependency(pkg, onClone)
        debug pkg.projectName, "expanded pkg:", pkg.repr
        processing = true
      of Found:
        info pkg.projectName, "Processing at:", $pkg.ondisk
        # processing = true
        let mode = if pkg.isRoot: CurrentCommit else: mode
        nc.traverseDependency(pkg, mode, @[])
        # debug pkg.projectName, "processed pkg:", $pkg
        for vtag, reqs in pkg.versions:
          debug pkg.projectName, "pkg version:", $vtag, "reqs:", $(toJsonHook(reqs))
        processing = true
        result.pkgs[pkgUrl] = pkg
      else:
        discard

  # for pkg in pkgs.pkgsToSpecs:
  #   info pkg.url.projectName, "Processed:", $pkg.url.url
  #   for vtag, reqs in pkg.versions:
  #     info pkg.url.projectName, "pkg version:", $vtag, "reqs:", reqs.deps.mapIt($(it[0].projectName) & " " & $(it[1])).join(", "), "status:", $reqs.status


  # if context().dumpGraphs:
  #   dumpJson(graph, "graph-expanded.json")
