## Breadth-first eager dependency resolution.

import std/[algorithm, deques, sequtils, sets, strutils, tables]

import basic/[context, depgraphtypes, deptypes, deptypesjson, pkgurls, reporters,
  versions]
import resolver_utils


type
  BfsRequirement = object
    url: PkgUrl
    query: VersionInterval
    depth: int
    parent: string
    features: seq[string]

  BfsSelection = object
    depth: int
    parent: string

  BfsResolverState = object
    pending: Deque[BfsRequirement]
    selections: Table[PkgUrl, BfsSelection]
    deferred: seq[Package]
    deferredUrls: HashSet[PkgUrl]
    success: bool


proc requestedDependencyFeatures(rel: NimbleRelease; url: PkgUrl): seq[string] =
  if rel.reqsByFeatures.hasKey(url):
    result = rel.reqsByFeatures[url].toSeq()
    result.sort()

proc requestedContextFeatures(pkg: Package; rel: NimbleRelease): seq[string] =
  for feature in rel.features.keys():
    if allFeaturesRequested() or
        hasRequestedFeature(pkg.url.shortName, pkg.url.projectName, feature):
      result.add feature
  result.sort()

proc enqueueRequirements(state: var BfsResolverState; pkg: Package;
                         rel: NimbleRelease; depth: int) =
  for (depUrl, query) in rel.requirements:
    state.pending.addLast BfsRequirement(
      url: depUrl,
      query: query,
      depth: depth + 1,
      parent: pkg.url.projectName,
      features: rel.requestedDependencyFeatures(depUrl)
    )

  var features = pkg.activeFeatures
  features.sort()
  for requestedFeature in features:
    let feature = rel.features.findFeature(requestedFeature)
    if feature.len == 0:
      continue
    for (depUrl, query) in rel.features[feature]:
      state.pending.addLast BfsRequirement(
        url: depUrl,
        query: query,
        depth: depth + 1,
        parent: pkg.url.projectName & "." & feature,
        features: rel.requestedDependencyFeatures(depUrl)
      )

proc enableFeatures(state: var BfsResolverState; pkg: Package;
                    features: openArray[string]; depth: int) =
  let rel = pkg.activeNimbleRelease()
  if rel.isNil:
    return

  for requestedFeature in features:
    let feature = rel.features.findFeature(requestedFeature)
    if feature.len == 0:
      warn pkg.url.projectName, "BFS ignored unknown requested feature:", requestedFeature
    elif not pkg.activeFeatures.containsFeature(feature):
      pkg.activeFeatures.addUniqueFeature(feature)
      for (depUrl, query) in rel.features[feature]:
        state.pending.addLast BfsRequirement(
          url: depUrl,
          query: query,
          depth: depth + 1,
          parent: pkg.url.projectName & "." & feature,
          features: rel.requestedDependencyFeatures(depUrl)
        )

proc selectRoot(state: var BfsResolverState; graph: var DepGraph) =
  var versions = graph.root.versions.pairs().toSeq()
  versions.sort(sortVersionsDesc)

  for (version, rel) in versions:
    if rel.status == Normal:
      graph.root.active = true
      graph.root.activeVersion = version
      graph.root.activeFeatures = graph.root.requestedContextFeatures(rel)
      state.selections[graph.root.url] = BfsSelection(depth: 0, parent: "workspace root")
      state.enqueueRequirements(graph.root, rel, 0)
      return

  error graph.root.url.projectName, "BFS could not select a valid root release"
  state.success = false

proc selectVersion(pkg: Package; query: VersionInterval): PackageVersion =
  var versions = pkg.versions.pairs().toSeq()
  versions.sort(sortVersionsDesc)
  for (version, rel) in versions:
    if rel.status == Normal and query.matchesRequirement(version, rel):
      return version

proc selectRequirement(state: var BfsResolverState; graph: var DepGraph;
                       req: BfsRequirement) =
  if req.url notin graph.pkgs:
    error req.parent, "BFS dependency was not discovered:", req.url.projectName
    state.success = false
    return

  let pkg = graph.pkgs[req.url]
  if pkg.active:
    let rel = pkg.activeNimbleRelease()
    if rel.isNil or not req.query.matchesRequirement(pkg.activeVersion, rel):
      let winner = state.selections[pkg.url]
      warn pkg.url.projectName,
        "BFS kept", $pkg.activeVersion, "selected by", winner.parent,
        "at depth", $winner.depth, "and ignored", $req.query,
        "from", req.parent, "at depth", $req.depth
    state.enableFeatures(pkg, req.features, req.depth)
    return

  if pkg.state == LazyDeferred:
    if not state.deferredUrls.containsOrIncl(pkg.url):
      state.deferred.add pkg
    return

  if pkg.state != Processed:
    error pkg.url.projectName, "BFS could not load dependency required by", req.parent,
      "in state", $pkg.state
    state.success = false
    return

  let version = pkg.selectVersion(req.query)
  if version.isNil:
    error pkg.url.projectName, "BFS found no release matching", $req.query,
      "required by", req.parent
    state.success = false
    return

  pkg.active = true
  pkg.activeVersion = version
  let rel = pkg.activeNimbleRelease()
  pkg.activeFeatures = pkg.requestedContextFeatures(rel)
  for requestedFeature in req.features:
    let feature = rel.features.findFeature(requestedFeature)
    if feature.len == 0:
      warn pkg.url.projectName, "BFS ignored unknown requested feature:", requestedFeature
    else:
      pkg.activeFeatures.addUniqueFeature(feature)
  state.selections[pkg.url] = BfsSelection(
    depth: req.depth,
    parent: req.parent
  )
  state.enqueueRequirements(pkg, rel, req.depth)

proc resolveBreadthFirst*(graph: var DepGraph; deferred: var seq[Package]): bool =
  ## Select releases eagerly in breadth-first dependency order. The first
  ## requirement for a package wins; this gives shallower requirements, then
  ## earlier declarations at the same depth, precedence over later ones.
  ## Lazy packages reached by the selected graph are returned for loading.
  for pkg in graph.pkgs.mvalues():
    pkg.active = false
    pkg.activeVersion = nil
    pkg.activeFeatures = @[]

  var state = BfsResolverState(
    pending: initDeque[BfsRequirement](),
    selections: initTable[PkgUrl, BfsSelection](),
    deferredUrls: initHashSet[PkgUrl](),
    success: true
  )
  state.selectRoot(graph)

  while state.pending.len > 0:
    state.selectRequirement(graph, state.pending.popFirst())

  deferred = state.deferred
  result = state.success

proc resolveBreadthFirst*(graph: var DepGraph): bool =
  var deferred: seq[Package]
  result = graph.resolveBreadthFirst(deferred) and deferred.len == 0

proc solveBreadthFirst*(graph: var DepGraph; rerun: var bool): bool =
  if DumpGraphs in context().flags:
    dumpJson(graph, "graph-solve-input.json")

  var deferred: seq[Package]
  result = graph.resolveBreadthFirst(deferred)
  if not result:
    return

  if deferred.len > 0:
    notice "atlas:resolved", "rerunning BFS; loading selected lazy dependencies:",
      deferred.mapIt(it.url.projectName).join(", ")
    for pkg in deferred:
      pkg.state = DoLoad
      pkg.versions.clear()
    rerun = true
    result = false
    return

  checkDuplicateModules(graph)

  if ListVersions in context().flags and ListVersionsOff notin context().flags:
    notice "atlas:resolved", "selected:"
    for pkg in graph.allActiveNodes():
      if not pkg.isRoot:
        notice "atlas:resolved",
          "[x] " & formatVersionSelection(pkg, pkg.activeVersion)
    notice "atlas:resolved", "end of selection"

  if DumpGraphs in context().flags:
    info "atlas:graph", "dumping graph after solving"
    dumpJson(graph, "graph-solved.json")

proc solveBreadthFirst*(graph: var DepGraph): bool =
  var rerun = false
  result = graph.solveBreadthFirst(rerun)
