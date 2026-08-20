import std/[algorithm, files, os, paths, sequtils, sets, strutils, tables]

import basic/[context, depgraphtypes, deptypes, deptypesjson, gitops,
  nimblecontext, osutils, pkgurls, reporters, sattypes, versions]
import dependencies, eagerresolver, resolverutils, runners, satresolver

export depgraphtypes, deptypesjson, resolverutils, satresolver


when not compiles(newSeq[int]().addUnique(1)):
  proc addUnique*[T](s: var seq[T]; item: T) =
    if item notin s:
      s.add(item)

iterator directDependencies*(graph: DepGraph; pkg: Package): lent Package =
  if pkg.activeNimbleRelease != nil:
    for (depUrl, _) in pkg.activeNimbleRelease.requirements:
      yield graph.pkgs[depUrl]

proc hasSatisfiedFeatureDeps(graph: DepGraph; rel: NimbleRelease;
                             featName: string): bool =
  let declaredFeature = rel.features.findFeature(featName)
  if declaredFeature.len == 0:
    return false

  let reqs = rel.features[declaredFeature]
  if reqs.len == 0:
    return true

  for depReq in items(reqs):
    let (depUrl, query) = depReq
    if depUrl notin graph.pkgs:
      return false
    let depPkg = graph.pkgs[depUrl]
    if not depPkg.active or depPkg.activeVersion.isNil:
      return false
    let depRel = depPkg.activeNimbleRelease()
    if depRel.isNil or not query.matchesRequirement(depPkg.activeVersion, depRel):
      return false

  true

proc collectUnsatisfiedContextFeatures(graph: DepGraph): seq[string] =
  ## Compare requested `--feature` flags with resolver-selected package features.
  var requested: seq[string]
  if allFeaturesRequested():
    for pkg in allActiveNodes(graph):
      let rel = pkg.activeNimbleRelease()
      if rel.isNil:
        continue
      for featName in rel.features.keys():
        requested.addUnique("feature." & pkg.url.projectName & "." & featName)
  else:
    requested = context().features.toSeq()
  requested.sort()

  for raw in requested:
    let qualified =
      if raw.startsWith("feature."):
        raw
      elif not graph.root.isNil:
        "feature." & graph.root.url.projectName & "." & raw
      else:
        "feature." & raw

    let parts = qualified.split(".")
    if parts.len < 3:
      continue

    let pkgName = parts[1]
    let featName = parts[2 .. ^1].join(".")
    var matchedPkg = false
    var declaredInNimble = false
    var featureSatisfied = false
    for pkg in allActiveNodes(graph):
      if pkg.url.shortName == pkgName or pkg.url.projectName == pkgName:
        matchedPkg = true
        let rel = pkg.activeNimbleRelease()
        if rel.isNil:
          continue
        let declaredFeature = rel.features.findFeature(featName)
        if declaredFeature.len > 0:
          declaredInNimble = true
          if pkg.activeFeatures.containsFeature(declaredFeature) or
              hasSatisfiedFeatureDeps(graph, rel, declaredFeature):
            featureSatisfied = true
            break

    if not matchedPkg:
      result.add(qualified & " (no active package matched '" & pkgName & "')")
    elif declaredInNimble and not featureSatisfied:
      result.add qualified

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

proc loadWorkspace*(path: Path; nc: var NimbleContext; mode: TraversalMode;
                    onClone: PackageAction; doSolve: bool): DepGraph =
  let useBfs = doSolve and context().defaultAlgo == Bfs
  let deferChildDeps = doSolve and not useBfs and
    mode == AllReleases and NoLazyDeps notin context().flags
  result = path.expandGraph(nc, mode, onClone, deferChildDeps = deferChildDeps)

  if doSolve:
    if useBfs:
      var rerun = false
      discard result.solveBreadthFirst(rerun)
      if rerun:
        result = loadWorkspace(path, nc, mode, onClone, doSolve)
    else:
      let form = result.toFormular(context().defaultAlgo)
      var rerun = false
      solveSat(result, form, rerun)

      if rerun:
        for pkg in result.pkgs.values():
          for ver, rel in pkg.validVersions():
            ver.vid = NoVar
            rel.featureVars.clear()

        result = loadWorkspace(path, nc, mode, onClone, doSolve)

proc runBuildSteps*(graph: DepGraph) =
  ## Execute build steps for the dependency graph.
  for pkg in toposorted(graph):
    if pkg.active:
      doAssert pkg != nil
      block:
        if not pkg.activeNimbleRelease.isNil and
            pkg.activeNimbleRelease.hasInstallHooks:
          tryWithDir pkg.ondisk:
            let nimbleFiles = findNimbleFile(pkg)
            if nimbleFiles.len() == 1:
              notice pkg.url.projectName, "Running installHook"
              runNimScriptInstallHook nimbleFiles[0], pkg.projectName
        for pattern in mitems context().plugins.builderPatterns:
          let bFile = pkg.ondisk / Path(pattern[0] % pkg.projectName)
          if fileExists(bFile):
            tryWithDir pkg.ondisk:
              runNimScriptBuilder pattern, pkg.projectName

proc activateGraph*(graph: DepGraph):
    tuple[paths: seq[CfgPath], features: seq[string]] =
  notice "atlas:graph", "Activating project deps for resolved dependency graph"
  for pkg in allActiveNodes(graph):
    if pkg.isRoot:
      continue
    if not pkg.activeVersion.commit().isEmpty():
      if pkg.ondisk.string.len == 0:
        error pkg.url.projectName, "Missing ondisk location for:", $(pkg.url)
      elif not pkg.url.isNimbleLink():
        let pkgUri = pkg.url.cloneUri()
        if pkgUri.scheme notin ["file", "link", "atlas"]:
          discard gitops.ensureCanonicalOrigin(pkg.ondisk, pkgUri)
        notice pkg.url.projectName, "Checked out to:",
          $pkg.activeVersion.commit().short(), "at:",
          pkg.ondisk.relativeToWorkspace()
        discard checkoutGitCommitFull(pkg.ondisk, pkg.activeVersion.commit())

  let unsatisfiedFeatures = collectUnsatisfiedContextFeatures(graph)
  if unsatisfiedFeatures.len > 0:
    error "atlas:graph", "requested feature(s) were not able to be satisfied:",
      unsatisfiedFeatures.join(", ")

  if NoExec notin context().flags:
    notice "atlas:graph", "Running build steps"
    runBuildSteps(graph)

  notice "atlas:graph", "Wrote nim.cfg!"

  for feature in context().features:
    if feature.startsWith("feature."):
      result.features.addUniqueFeature feature
    else:
      result.features.addUniqueFeature(
        "feature." & graph.root.url.projectName & "." & feature)

  for pkg in graph.pkgs.values():
    if not pkg.active:
      continue
    let rel = pkg.activeNimbleRelease()
    if rel.isNil:
      continue
    for featName in rel.features.keys():
      if hasContextFeature(pkg, featName) and
          hasSatisfiedFeatureDeps(graph, rel, featName):
        pkg.activeFeatures.addUniqueFeature(featName)

  if not graph.root.isNil and graph.root.active:
    for feature in graph.root.activeFeatures:
      result.features.addUniqueFeature(
        "feature." & graph.root.url.projectName & "." & feature)

  for pkg in allActiveNodes(graph):
    if pkg.isRoot:
      continue
    let cfgPath = toDestDir(graph, pkg) / getCfgPath(graph, pkg).Path
    trace pkg.url.projectName, "adding CfgPath:",
      $relativeToWorkspace(cfgPath)
    result.paths.add CfgPath(cfgPath)
    for feature in pkg.activeFeatures:
      result.features.addUniqueFeature(
        "feature." & pkg.url.shortName & "." & feature)

  result.paths.sort(proc (a, b: CfgPath): int = cmp(a.string, b.string))
