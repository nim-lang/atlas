import std/[algorithm, files, os, paths, sequtils, sets, strutils, tables]

import basic/[context, depgraphtypes, deptypes, deptypesjson, gitops,
  nimblecontext, osutils, pkgurls, reporters, sattypes, versions]
import dependencies, resolver_sat, resolver_utils, runners
from resolver_eager import solveBreadthFirst

export depgraphtypes, deptypesjson, resolver_sat, resolver_utils
export solveBreadthFirst


when not compiles(newSeq[int]().addUnique(1)):
  proc addUnique*[T](s: var seq[T]; item: T) =
    if item notin s:
      s.add(item)

iterator directDependencies*(graph: DepGraph; pkg: Package): lent Package =
  if pkg.activeNimbleRelease != nil:
    for (depUrl, _) in pkg.activeNimbleRelease.requirements:
      yield graph.pkgs[depUrl]

proc requirementMatches*(query: VersionInterval; depVer: PackageVersion;
                         depRel: NimbleRelease): bool =
  ## Compatibility wrapper for dependency requirement matching.
  query.matchesRequirement(depVer, depRel)

proc canonicalFeatureDefine(graph: DepGraph; feature: string): string =
  if not feature.startsWith(FeatureDefinePrefix):
    if graph.root.isNil or graph.root.activeNimbleRelease().isNil:
      return feature
    let rel = graph.root.activeNimbleRelease()
    return FeatureDefinePrefix & graph.root.packageFeatureName(rel) & "." & feature

  let parts = feature.split(".")
  if parts.len < 3:
    return feature
  let requestedPackage = parts[1]
  let requestedFeature = parts[2..^1].join(".")
  for pkg in allActiveNodes(graph):
    let rel = pkg.activeNimbleRelease()
    if not rel.isNil and pkg.matchesFeaturePackageName(rel, requestedPackage):
      let declaredFeature = rel.features.findFeature(requestedFeature)
      let featureName =
        if declaredFeature.len > 0: declaredFeature
        else: requestedFeature
      return FeatureDefinePrefix & pkg.packageFeatureName(rel) & "." & featureName
  result = feature

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
        requested.addUnique(
          FeatureDefinePrefix & pkg.packageFeatureName(rel) & "." & featName)
  else:
    requested = context().features.toSeq()
    if not graph.root.isNil:
      let rel = graph.root.activeNimbleRelease()
      if not rel.isNil:
        for feature in ["dev", "patch"]:
          if feature in rel.features:
            requested.addUnique(
              FeatureDefinePrefix & graph.root.packageFeatureName(rel) &
              "." & feature)
  requested.sort()

  for raw in requested:
    let qualified =
      if raw.startsWith(FeatureDefinePrefix):
        raw
      elif not graph.root.isNil and not graph.root.activeNimbleRelease().isNil:
        FeatureDefinePrefix & graph.root.packageFeatureName(
          graph.root.activeNimbleRelease()) & "." & raw
      else:
        FeatureDefinePrefix & raw

    if not qualified.startsWith(FeatureDefinePrefix):
      continue

    let parts = qualified.split(".")
    if parts.len < 3:
      continue

    let pkgName = parts[1]
    let featName = parts[2 .. ^1].join(".")
    var matchedPkg = false
    var declaredInNimble = false
    var featureSatisfied = false
    for pkg in allActiveNodes(graph):
      let rel = pkg.activeNimbleRelease()
      if not rel.isNil and pkg.matchesFeaturePackageName(rel, pkgName):
        matchedPkg = true
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
    result.features.addUniqueFeature graph.canonicalFeatureDefine(feature)

  for pkg in graph.pkgs.values():
    if not pkg.active:
      continue
    let rel = pkg.activeNimbleRelease()
    if rel.isNil:
      continue
    for featName in rel.features.keys():
      if hasContextFeature(pkg, rel, featName) and
          hasSatisfiedFeatureDeps(graph, rel, featName):
        pkg.activeFeatures.addUniqueFeature(featName)

  if not graph.root.isNil and graph.root.active:
    let rel = graph.root.activeNimbleRelease()
    for feature in graph.root.activeFeatures:
      result.features.addUniqueFeature FeatureDefinePrefix &
        graph.root.packageFeatureName(rel) & "." & feature

  for pkg in allActiveNodes(graph):
    if pkg.isRoot:
      continue
    let cfgPath = toDestDir(graph, pkg) / getCfgPath(graph, pkg).Path
    trace pkg.url.projectName, "adding CfgPath:",
      $relativeToWorkspace(cfgPath)
    result.paths.add CfgPath(cfgPath)
    let rel = pkg.activeNimbleRelease()
    for feature in pkg.activeFeatures:
      result.features.addUniqueFeature FeatureDefinePrefix &
        pkg.packageFeatureName(rel) & "." & feature

  result.paths.sort(proc (a, b: CfgPath): int = cmp(a.string, b.string))
