import std / [sets, tables, sequtils, paths, files, os, strutils, json, jsonutils, algorithm]

import basic/[deptypes, versions, depgraphtypes, osutils, context, gitops, reporters, nimblecontext, pkgurls, deptypesjson, sattypes]
import dependencies, runners 

export depgraphtypes, deptypesjson

export sat

when not compiles(newSeq[int]().addUnique(1)):
  proc addUnique*[T](s: var seq[T]; item: T) =
    if item notin s:
      s.add(item)

iterator directDependencies*(graph: DepGraph; pkg: Package): lent Package =
  if pkg.activeNimbleRelease != nil:
    for (durl, _) in pkg.activeNimbleRelease.requirements:
      # let idx = findDependencyForDep(graph, dep[0])
      yield graph.pkgs[durl]

iterator validVersions*(pkg: Package): (PackageVersion, NimbleRelease) =
  for ver, rel in mpairs(pkg.versions):
    if rel.status == Normal:
      yield (ver, rel)

type
  SatVarInfo* = object # attached information for a SAT variable
    pkg*: Package
    version*: PackageVersion
    release*: NimbleRelease
    feature*: string

  Form* = object
    formula*: Formular
    mapping*: Table[VarId, SatVarInfo]
    idgen: int32
    noVersionsFound: seq[string]

  NoVersionIssues = ref object
    messages: seq[string]
    seen: HashSet[string]

template withOpenBr(b, op, blk) =
  b.openOpr(op)
  `blk`
  b.closeOpr()

proc addAtMostOneOf(b: var Builder; vars: seq[VarId]) =
  for i in 0 ..< vars.len:
    for j in (i + 1) ..< vars.len:
      withOpenBr(b, OrForm):
        b.addNegated(vars[i])
        b.addNegated(vars[j])

proc addAtLeastOneOf(b: var Builder; vars: seq[VarId]) =
  if vars.len == 1:
    b.add vars[0]
  else:
    withOpenBr(b, OrForm):
      for v in vars:
        b.add v

proc addCompatibleVersionChoice(
    b: var Builder;
    compatibleVersions: seq[VarId];
    featureVersions: Table[VarId, seq[VarId]]) =
  template addCompatibleVersion(compatVer: VarId) =
    block:
      if featureVersions.hasKey(compatVer):
        withOpenBr(b, AndForm):
          b.add(compatVer)
          for featureVer in featureVersions[compatVer]:
            b.add(featureVer)
      else:
        b.add(compatVer)

  if compatibleVersions.len == 0:
    b.add falseLit()
  elif compatibleVersions.len == 1:
    addCompatibleVersion(compatibleVersions[0])
  else:
    withOpenBr(b, ExactlyOneOfForm):
      for compatVer in compatibleVersions:
        addCompatibleVersion(compatVer)

proc addCompatibleVersionChoice(b: var Builder; compatibleVersions: seq[VarId]) =
  var featureVersions: Table[VarId, seq[VarId]]
  b.addCompatibleVersionChoice(compatibleVersions, featureVersions)

proc packageFeatureName(pkg: Package; rel: NimbleRelease): string =
  let fallbackName =
    if pkg.name.len > 0: pkg.name
    elif pkg.isRoot: pkg.url.projectName
    else: pkg.url.shortName
  let declaredName =
    if rel.isNil: ""
    else: rel.name
  result = featurePackageName(declaredName, fallbackName)

proc matchesFeaturePackageName(pkg: Package; rel: NimbleRelease;
                               name: string): bool =
  for candidate in [pkg.url.shortName, pkg.url.projectName, rel.name, pkg.name]:
    if candidate.len > 0 and sameFeature(candidate, name):
      return true

proc activateRequiredDependencyFeatures(graph: DepGraph) =
  ## Records every feature requested on an active dependency requirement.
  ## Nimble emits the define even when the selected dependency does not declare
  ## the feature; only declared features contribute additional requirements.
  for pkg in allActiveNodes(graph):
    let rel = pkg.activeNimbleRelease()
    if not rel.isNil:
      for depUrl, requestedFeatures in rel.reqsByFeatures:
        if depUrl in graph.pkgs:
          let depPkg = graph.pkgs[depUrl]
          if depPkg.active and not depPkg.activeVersion.isNil:
            let depRel = depPkg.activeNimbleRelease()
            if not depRel.isNil:
              for requestedFeature in requestedFeatures:
                let declaredFeature = depRel.features.findFeature(requestedFeature)
                let feature =
                  if declaredFeature.len > 0: declaredFeature
                  else: requestedFeature
                depPkg.activeFeatures.addUniqueFeature(feature)

proc canonicalFeatureDefine(graph: DepGraph; feature: string): string =
  if not feature.startsWith(FeatureDefinePrefix):
    if graph.root.isNil or graph.root.activeNimbleRelease().isNil:
      return feature
    return FeatureDefinePrefix &
      graph.root.packageFeatureName(graph.root.activeNimbleRelease()) & "." & feature

  let parts = feature.split(".")
  if parts.len < 3:
    return feature
  let requestedPackage = parts[1]
  let requestedFeature = parts[2..^1].join(".")
  for pkg in allActiveNodes(graph):
    let rel = pkg.activeNimbleRelease()
    if rel.isNil:
      continue
    if pkg.matchesFeaturePackageName(rel, requestedPackage):
      let declaredFeature = rel.features.findFeature(requestedFeature)
      let featureName =
        if declaredFeature.len > 0: declaredFeature
        else: requestedFeature
      return FeatureDefinePrefix & pkg.packageFeatureName(rel) & "." & featureName
  result = feature

proc hasContextFeature(pkg: Package; rel: NimbleRelease; feature: string): bool =
  result = hasRequestedFeature(pkg.url.shortName, pkg.url.projectName,
                               rel.name, pkg.name, feature, pkg.isRoot)

proc requirementMatches*(query: VersionInterval; depVer: PackageVersion; depRel: NimbleRelease): bool =
  ## Match semver constraints against nimble-declared release versions, while
  ## preserving special ref semantics (#head/#branch/#commit) on package tags.
  if query.isSpecial:
    result = query.matches(depVer)
  else:
    result = query.matches(depRel.version)

proc effectiveRequirement(graph: DepGraph; owner: Package; dep: PkgUrl;
                          query: VersionInterval): VersionInterval =
  ## A root commit pin takes precedence over a transitive moving #head.
  ## Other constraints, including concrete transitive refs, remain binding.
  result = query
  if owner.isRoot or not query.isSpecial or not query.isHead or
      graph.root.isNil:
    return
  var rootRelease: NimbleRelease
  for _, rel in graph.root.validVersions():
    if not rootRelease.isNil:
      # Alternative root releases cannot impose unconditional overrides.
      return
    rootRelease = rel
  if rootRelease.isNil:
    return

  for (url, requirement) in rootRelease.requirements:
    if url == dep and requirement.isSpecial and Version($requirement).isCommit:
      return requirement
  for feature, reqs in rootRelease.features:
    if hasContextFeature(graph.root, rootRelease, feature):
      for (url, requirement) in reqs:
        if url == dep and requirement.isSpecial and Version($requirement).isCommit:
          return requirement

type
  RequiredDependency = tuple[url: PkgUrl, query: VersionInterval, source: string,
                             features: seq[string], requestedQuery: VersionInterval]

proc requiredDependencies(graph: DepGraph; pkg: Package; ver: PackageVersion;
                          rel: NimbleRelease;
                          requestedFeatures: seq[string] = @[]): seq[RequiredDependency] =
  let source = pkg.url.projectName & " " & $ver & (if pkg.isRoot: " (root)" else: "")
  for (dep, query) in rel.requirements:
    result.add (dep, graph.effectiveRequirement(pkg, dep, query), source,
                rel.reqsByFeatures.getOrDefault(dep).toSeq(), query)
  for feature, reqs in rel.features:
    if hasContextFeature(pkg, rel, feature) or requestedFeatures.containsFeature(feature):
      for (dep, query) in reqs:
        result.add (dep, graph.effectiveRequirement(pkg, dep, query),
                    source & " feature " & feature,
                    rel.reqsByFeatures.getOrDefault(dep).toSeq(), query)

proc requirementDescription(req: RequiredDependency): string =
  result = req.source & " requires " & req.url.projectName & " " & $req.requestedQuery
  if $req.query != $req.requestedQuery:
    result.add " (using root pin " & $req.query & ")"

proc loadedVersionSummary(graph: DepGraph; url: PkgUrl): string =
  if url notin graph.pkgs:
    return "package is not loaded"
  let pkg = graph.pkgs[url]
  if pkg.state == Error:
    return "package could not be loaded: " & $pkg.errors
  var versions: seq[string]
  for ver, rel in pkg.validVersions():
    versions.add $ver
  versions.sort()
  if versions.len == 0:
    return "no usable releases are loaded"
  result = "loaded releases: " & versions[0 ..< min(versions.len, 5)].join(", ")
  if versions.len > 5:
    result.add " (and " & $(versions.len - 5) & " more)"

proc findDependencyConflict*(graph: DepGraph): seq[string] =
  ## Explains a proven conflict reachable from the root without running SAT.
  ## Only mandatory requirements restrict choices. Alternative releases and
  ## lazy dependencies remain possible until they can safely be ruled out.
  if graph.root.isNil or graph.root.state != Processed:
    return
  var choices: Table[PkgUrl, seq[PackageVersion]]
  for url, pkg in graph.pkgs:
    choices[url] = @[]
    if pkg.state != Error:
      for ver, rel in pkg.validVersions():
        choices[url].add ver
  var required: OrderedTable[PkgUrl, seq[string]]
  required[graph.root.url] = @[graph.root.url.projectName & " is the root package"]
  var requestedFeatures: Table[PkgUrl, seq[string]]
  var expanded: HashSet[string]
  var changed = true
  while changed:
    changed = false
    for url in required.keys.toSeq():
      if url in graph.pkgs and graph.pkgs[url].state == LazyDeferred:
        continue
      var remaining: seq[PackageVersion]
      var rejected: seq[string]
      var conflictUrl = url
      for ver in choices.getOrDefault(url):
        let pkg = graph.pkgs[url]
        var reason: seq[string]
        for req in requiredDependencies(graph, pkg, ver, pkg.versions[ver],
                                        requestedFeatures.getOrDefault(url)):
          if req.url in graph.pkgs and graph.pkgs[req.url].state == LazyDeferred:
            continue
          var matches = false
          for candidate in choices.getOrDefault(req.url):
            if requirementMatches(req.query, candidate, graph.pkgs[req.url].versions[candidate]):
              matches = true
              break
          if not matches:
            if choices[url].len == 1:
              conflictUrl = req.url
            reason.add requirementDescription(req)
            reason.add required.getOrDefault(req.url)
            reason.add req.url.projectName & ": " & loadedVersionSummary(graph, req.url)
            break
        if reason.len == 0:
          remaining.add ver
        elif rejected.len < 12:
          for line in reason:
            rejected.addUnique line
      if remaining.len == 0:
        result = @["dependency conflict: no compatible release of " & conflictUrl.projectName]
        result.add required[url]
        result.add rejected
        if rejected.len == 0:
          result.add loadedVersionSummary(graph, url)
        return
      if remaining.len != choices.getOrDefault(url).len:
        choices[url] = remaining
        changed = true
      if remaining.len == 1:
        let pkg = graph.pkgs[url]
        let ver = remaining[0]
        for req in requiredDependencies(graph, pkg, ver, pkg.versions[ver],
                                        requestedFeatures.getOrDefault(url)):
          if expanded.containsOrIncl(requirementDescription(req)):
            continue
          changed = true
          required.mgetOrPut(req.url, @[]).addUnique requirementDescription(req)
          for feature in req.features:
            requestedFeatures.mgetOrPut(req.url, @[]).addUniqueFeature(feature)
          if req.url in graph.pkgs and graph.pkgs[req.url].state == LazyDeferred:
            continue
          var compatible: seq[PackageVersion]
          for candidate in choices.getOrDefault(req.url):
            if requirementMatches(req.query, candidate, graph.pkgs[req.url].versions[candidate]):
              compatible.add candidate
          choices[req.url] = compatible
          if compatible.len == 0:
            result = @["dependency conflict: no compatible release of " & req.url.projectName]
            result.add required[req.url]
            result.add loadedVersionSummary(graph, req.url)
            return

proc hasSatisfiedFeatureDeps(graph: DepGraph; pkg: Package;
                            rel: NimbleRelease; featName: string): bool =
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
    if depRel.isNil:
      return false
    if not requirementMatches(graph.effectiveRequirement(pkg, depUrl, query),
                               depPkg.activeVersion, depRel):
      return false

  true

proc collectUnsatisfiedContextFeatures(graph: DepGraph): seq[string] =
  ## Compare requested `--feature` flags with SAT-selected package features.
  var requested: seq[string]
  if allFeaturesRequested():
    for pkg in allActiveNodes(graph):
      let rel = pkg.activeNimbleRelease()
      if rel.isNil:
        continue
      for featName in rel.features.keys():
        requested.addUnique(FeatureDefinePrefix & pkg.packageFeatureName(rel) & "." & featName)
  else:
    requested = context().features.toSeq()
    if not graph.root.isNil:
      let rel = graph.root.activeNimbleRelease()
      if not rel.isNil:
        for feature in ["dev", "patch"]:
          if feature in rel.features:
            requested.addUnique(FeatureDefinePrefix &
              graph.root.packageFeatureName(rel) & "." & feature)
  requested.sort()
  for raw in requested:
    let qualified =
      if raw.startsWith(FeatureDefinePrefix):
        raw
      elif not graph.root.isNil and not graph.root.activeNimbleRelease().isNil:
        FeatureDefinePrefix &
          graph.root.packageFeatureName(graph.root.activeNimbleRelease()) & "." & raw
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
      if rel.isNil:
        continue
      if pkg.matchesFeaturePackageName(rel, pkgName):
        matchedPkg = true
        let declaredFeature = rel.features.findFeature(featName)
        if declaredFeature.len > 0:
          declaredInNimble = true
          if pkg.activeFeatures.containsFeature(declaredFeature) or
              hasSatisfiedFeatureDeps(graph, pkg, rel, declaredFeature):
            featureSatisfied = true
            break

    # Ignore features that are not declared in the selected nimble release.
    if not matchedPkg:
      result.add(qualified & " (no active package matched '" & pkgName & "')")
    elif declaredInNimble and not featureSatisfied:
      result.add qualified

proc trackNoVersionsFound(issues: NoVersionIssues; issue: string) =
  if issue notin issues.seen:
    issues.seen.incl issue
    issues.messages.add issue

proc addVersionConstraints(
    b: var Builder;
    graph: var DepGraph;
    pkg: Package;
    issues: NoVersionIssues
) =
  var hasValidRelease = false

  proc checkDeps(graph: var DepGraph, ver: PackageVersion, reqs: seq[(PkgUrl, VersionInterval)]): tuple[allDepsCompatible: bool, unmatchedDeps: seq[string]] =
    result.allDepsCompatible = true

    # First check if all dependencies can be satisfied
    for dep, requestedQuery in items(reqs):
      let query = graph.effectiveRequirement(pkg, dep, requestedQuery)
      if dep notin graph.pkgs:
        debug pkg.url.projectName, "checking dependency for ", $ver, "not found:", $dep
        result.allDepsCompatible = false
        result.unmatchedDeps.add($dep.projectName & " " & $query & " (not found)")
        issues.trackNoVersionsFound(
          pkg.url.projectName & ": no versions matched requirements for the dependency: " &
          $dep.projectName & " " & $query & " (not found)"
        )
        continue
      debug pkg.url.projectName, "checking dependency for ", $ver, ":", $dep.projectName, "query:", $query
      let depNode = graph.pkgs[dep]

      if depNode.state == LazyDeferred:
        debug pkg.url.projectName, "dependency:", $dep.projectName, "is lazily deferred and not loaded"
        continue

      var hasCompatible = false
      for depVer, relVer in depNode.validVersions():
        let depMatches = requirementMatches(query, depVer, relVer)
        trace pkg.url.projectName, "checking dependency version:", $depVer, "query:", $query, "matches:", $depMatches
        if depMatches:
          hasCompatible = true
          trace pkg.url.projectName, "version matched requirements for the dependency version:", $depVer
          break

      if not hasCompatible:
        result.allDepsCompatible = false
        result.unmatchedDeps.add($dep.projectName & " " & $query)
        issues.trackNoVersionsFound(
          pkg.url.projectName & ": no versions matched requirements for the dependency: " &
          $dep.projectName & " " & $query
        )
      else:
        debug pkg.url.projectName, "a compatible version matched requirements for the dependency version:", $depNode.url.projectName

  for ver, rel in validVersions(pkg):
    hasValidRelease = true
    let depCheck = checkDeps(graph, ver, rel.requirements)

    # If any dependency can't be satisfied, make this version unsatisfiable
    if not depCheck.allDepsCompatible:
      b.addNegated(ver.vid)
      continue

    # Add implications for each dependency
    for dep, requestedQuery in items(rel.requirements):
      let query = graph.effectiveRequirement(pkg, dep, requestedQuery)
      if dep notin graph.pkgs:
        info pkg.url.projectName, "requirement depdendency not found:", $dep.projectName, "query:", $query
        continue
      let depNode = graph.pkgs[dep]
      if depNode.state == LazyDeferred:
        debug pkg.url.projectName, "skipping deferred dependency implication:", $dep.projectName
        continue
        
      var flags: seq[string]
      if dep in rel.reqsByFeatures:
        flags = rel.reqsByFeatures[dep].toSeq()
      
      debug pkg.url.projectName, "version constraints for requirement depdendency", "dep:", $dep, "flags:", flags.mapIt($it).join(", "), "reqsByFeatures:", rel.reqsByFeatures.values().toSeq().mapIt($it).join(", ")

      var compatibleVersions: seq[VarId]
      var featureVersions: Table[VarId, seq[VarId]]
      for depVer, nimbleRelease in depNode.validVersions():
        let depMatches = requirementMatches(query, depVer, nimbleRelease)
        trace pkg.url.projectName, "checking dependency:", depNode.url.projectName, "version:", $depVer, "query:", $query, "matches:", $depMatches
        if depMatches:
          compatibleVersions.add(depVer.vid)
        for feature in flags:
          let declaredFeature = nimbleRelease.features.findFeature(feature)
          if declaredFeature.len > 0:
            let featureVarId = nimbleRelease.featureVars[declaredFeature]
            featureVersions.mgetOrPut(depVer.vid, @[]).add(featureVarId)

      # Add implication: if this version is selected, one of its compatible deps must be selected
      withOpenBr(b, OrForm):
        b.addNegated(ver.vid)  # not this version
        b.addCompatibleVersionChoice(compatibleVersions, featureVersions)

    # Add implications for each feature requirement
    for feature, reqs in rel.features:
      let featureVarId = rel.featureVars[feature]
      let featDepCheck = checkDeps(graph, ver, reqs)
      let qualifiedFeature = FeatureDefinePrefix & pkg.url.projectName & "." & feature

      debug pkg.url.projectName, "checking feature dep:", $feature, "query:", $reqs, "compat versions:", $featDepCheck.allDepsCompatible
      if not featDepCheck.allDepsCompatible:
        issues.trackNoVersionsFound(
          pkg.url.projectName & ": all requirements needed for feature " &
          qualifiedFeature & " were not able to be satisfied: " &
          $reqs.mapIt(it[0].projectName & " " & $it[1]).join("; ") &
          "; deps with no matching releases: " &
          featDepCheck.unmatchedDeps.join("; ")
        )
        b.addNegated(featureVarId)
        continue

      if hasContextFeature(pkg, rel, feature):
        # A requested feature must be selected whenever this package version
        # is selected. This preserves separate feature variables when
        # several requested features share a dependency.
        withOpenBr(b, OrForm):
          b.addNegated(ver.vid)
          b.add(featureVarId)

      for dep, requestedQuery in items(reqs):
        let query = graph.effectiveRequirement(pkg, dep, requestedQuery)
        if dep notin graph.pkgs:
          info pkg.url.projectName, "feature depdendency not found:", $dep.projectName, "query:", $query
          continue
        let depNode = graph.pkgs[dep]
        if depNode.state == LazyDeferred:
          debug pkg.url.projectName, "skipping deferred feature dependency implication:", $dep.projectName, "feature:", $feature
          continue

        var compatibleVersions: seq[VarId] = @[]
        for depVer, relVer in depNode.validVersions():
          if requirementMatches(query, depVer, relVer):
            compatibleVersions.add(depVer.vid)
          elif depVer == toVersionTag("*@head").toPkgVer:
            compatibleVersions.add(depVer.vid)
        debug pkg.url.projectName, "checking feature req:", $dep.projectName, "query:", $query, "compat versions:", $compatibleVersions.mapIt($it).join(", "), "from versions:", $depNode.validVersions().toSeq().mapIt(it[0].version()).join(", ")

        withOpenBr(b, OrForm):
          b.addNegated(featureVarId) # not this feature
          b.addCompatibleVersionChoice(compatibleVersions)
          debug pkg.url.projectName, "added compatVer feature dep variables:", $compatibleVersions.mapIt($it).join(", ")
        
        # Add implictations for globally set features
        if hasContextFeature(pkg, rel, feature):
          debug pkg.url.projectName, "checking global feature:", $feature, "in version:", $ver, "context().features:", $context().features.toSeq().mapIt($it).join(", ")
          var featureVersions: Table[VarId, seq[VarId]]
          for depVer, nimbleRelease in depNode.validVersions():
            trace pkg.url.projectName, "checking global feature dependency:", depNode.url.projectName, "version:", $depVer
            let declaredFeature = nimbleRelease.features.findFeature(feature)
            if declaredFeature.len > 0:
              let featureVarId = nimbleRelease.featureVars[declaredFeature]
              featureVersions.mgetOrPut(depVer.vid, @[]).add(featureVarId)

          # Add implication: if this version is selected, one of its compatible deps must be selected
          if true:
            withOpenBr(b, OrForm):
              b.addNegated(ver.vid)  # not this version
              b.addCompatibleVersionChoice(compatibleVersions, featureVersions)

  if not hasValidRelease:
    issues.trackNoVersionsFound(
      pkg.url.projectName & ": no versions satisfied for this package: " & $pkg.url
    )

proc reportNoVersionsFound(form: Form) =
  var issues = form.noVersionsFound
  issues.sort()
  for idx, issue in issues:
    if idx < 10:
      warn "atlas:resolved", issue
    else:
      debug "atlas:resolved", issue
  if issues.len > 10:
    notice "atlas:resolved", $(issues.len - 10),
      "more release mismatches; use --verbosity=debug to see them"

proc reportRootRequirements(graph: DepGraph) =
  if not graph.root.isNil:
    var requirements: seq[string]
    for ver, rel in graph.root.validVersions():
      for req in requiredDependencies(graph, graph.root, ver, rel):
        var matches: seq[string]
        if req.url in graph.pkgs:
          for candidate, depRel in graph.pkgs[req.url].validVersions():
            if requirementMatches(req.query, candidate, depRel):
              matches.add $candidate
        matches.sort()
        let candidates =
          if matches.len == 0: "no matching loaded releases"
          elif matches.len <= 3: matches.join(", ")
          else: matches[0..2].join(", ") & " (and " & $(matches.len - 3) & " more)"
        requirements.add requirementDescription(req) & "; matches: " & candidates
    requirements.sort()
    notice "atlas:resolved", "root requirements and matching loaded releases:"
    for requirement in requirements:
      notice "atlas:resolved", requirement

proc toFormular*(graph: var DepGraph; algo: ResolutionAlgorithm): Form =
  result = Form()
  var b = Builder()
  let issues = NoVersionIssues(seen: initHashSet[string]())

  withOpenBr(b, AndForm):

    # First pass: Assign variables and encode version selection constraints
    for p in mvalues(graph.pkgs):
      if p.versions.len == 0:
        debug p.url.projectName, "skipping adding package variable as it has no versions"
        continue

      # # Sort versions in descending order (newer versions first)

      case algo
      of MinVer: p.versions.sort(sortVersionsDesc)
      of SemVer, MaxVer: p.versions.sort(sortVersionsAsc)

      # Assign a unique SAT variable to each version of the package
      for ver, rel in p.validVersions():
        ver.vid = VarId(result.idgen)
        # Map the SAT variable to package information for result interpretation
        result.mapping[ver.vid] = SatVarInfo(pkg: p, version: ver, release: rel)
        inc result.idgen
      
        # Add feature VarIds - these are not version variables, but are used to track feature selection
        for feature in rel.features.keys():
          if feature notin rel.featureVars:
            let featureVarId = VarId(result.idgen)
            rel.featureVars[feature] = featureVarId
            # Map the SAT variable to package information for result interpretation
            result.mapping[featureVarId] = SatVarInfo(pkg: p, version: ver, release: rel, feature: feature)
            debug p.url.projectName, "adding feature var:", feature, "id:", $(featureVarId), " result: ", $result.mapping[featureVarId]
            inc result.idgen

      doAssert p.state != NotInitialized, "package not initialized: " & $p.toJson(ToJsonOptions(enumMode: joptEnumString))

      # Add constraints based on the package status
      var versionVars: seq[VarId]
      for ver, rel in p.validVersions():
        versionVars.add ver.vid

      if p.state == Error:
        # If package is broken, enforce that none of its versions can be selected
        for vid in versionVars:
          b.addNegated vid
      elif p.isRoot:
        # If it's a root package, enforce exactly one selected version:
        # (v1 OR v2 OR ...) AND pairwise-not-both.
        if versionVars.len == 0:
          b.add falseLit()
        else:
          for ver, rel in p.validVersions():
            debug p.url.projectName, "adding root package version:", $ver, "vid:", $ver.vid
          b.addAtLeastOneOf(versionVars)
          b.addAtMostOneOf(versionVars)
      else:
        # For non-root packages, at most one version can be selected.
        b.addAtMostOneOf(versionVars)
      
    # This simpler deps loop was copied from Nimble after it was first ported from Atlas :)
    # It appears to acheive the same results, but it's a lot simpler
    for pkg in graph.pkgs.mvalues():
      b.addVersionConstraints(graph, pkg, issues)

  result.formula = toForm(b)
  result.noVersionsFound = issues.messages


proc formatVersionSelection*(pkg: Package; version: PackageVersion): string =
  result = "(" & pkg.url.projectName & ", " & $version & ")"
  if version.vtag.isPinned:
    result.add " [pinned]"

proc toString(info: SatVarInfo): string =
  formatVersionSelection(info.pkg, info.version)

proc debugFormular*(graph: var DepGraph; form: Form; solution: Solution) =
  echo "FORM:\n\t", form.formula
  var keys = form.mapping.keys().toSeq()
  keys.sort(proc (a, b: VarId): int = cmp(a.int, b.int))
  for key in keys:
    let value = form.mapping[key]
    echo "\tv", key.int, ": ", value.pkg.url.projectName, ", ", $value.version, ", f: ", value.feature
  let maxVar = maxVariable(form.formula)
  echo "solutions:"
  for varIdx in 0 ..< maxVar:
    if solution.isTrue(VarId(varIdx)):
      echo "\tv", varIdx, ": T"
  echo ""

proc toPretty*(v: uint64): string = 
  if v == DontCare: "X"
  elif v == SetToTrue: "T"
  elif v == SetToFalse: "F"
  elif v == IsInvalid: "!"
  else: ""

proc chooseDuplicatePackage(graph: DepGraph; name: string; dupePkgs: seq[Package]): Package =
  proc sortedFirst(pkgs: seq[Package]): Package =
    if pkgs.len == 0:
      return nil
    var sortedPkgs = pkgs
    sortedPkgs.sort(proc (a, b: Package): int = cmp(a.url.projectName, b.url.projectName))
    sortedPkgs[0]

  proc isRootRequested(url: PkgUrl): bool =
    if graph.root.isNil:
      return false

    let rel = graph.root.activeNimbleRelease()
    if rel.isNil:
      return false

    for (depUrl, _) in rel.requirements:
      if depUrl == url:
        return true

    for feature in graph.root.activeFeatures:
      let declaredFeature = rel.features.findFeature(feature)
      if declaredFeature.len > 0:
        for (depUrl, _) in rel.features[declaredFeature]:
          if depUrl == url:
            return true

  var rootMatches: seq[Package]
  var explicitRootMatches: seq[Package]
  var explicitMatches: seq[Package]
  var remoteIds: HashSet[string]
  var allSameRemote = true

  for pkg in dupePkgs:
    if isRootRequested(pkg.url):
      rootMatches.add pkg

    explicitMatches.add pkg

    if pkg.url.cloneUri().scheme in ["file", "link", "atlas", "error"]:
      allSameRemote = false
    else:
      let remoteId = remoteNameFromGitUrl($pkg.url.cloneUri())
      if remoteId.len == 0:
        allSameRemote = false
      else:
        remoteIds.incl(remoteId)

  explicitRootMatches = rootMatches.filterIt(it.isFork)
  if explicitRootMatches.len == 1:
    return explicitRootMatches[0]
  if rootMatches.len == 1:
    return rootMatches[0]

  if allSameRemote and remoteIds.len == 1:
    result = sortedFirst(explicitRootMatches)
    if not result.isNil:
      return
    result = sortedFirst(rootMatches)
    if not result.isNil:
      return
    result = sortedFirst(explicitMatches)
    if not result.isNil:
      return
    return sortedFirst(dupePkgs)

proc checkDuplicateModules(graph: var DepGraph) =
  # Check for duplicate module names
  var moduleNames: Table[string, HashSet[Package]]
  for pkg in values(graph.pkgs):
    if pkg.active:
      moduleNames.mgetOrPut(pkg.url.projectName(), initHashSet[Package]()).incl(pkg)
  moduleNames = moduleNames.pairs().toSeq().filterIt(it[1].len > 1).toTable()

  var unhandledDuplicates: seq[string]
  for name, dupePkgs in moduleNames:
    let dupeList = dupePkgs.toSeq()
    let preferredPkg = chooseDuplicatePackage(graph, name, dupeList)
    if not preferredPkg.isNil:
      notice "atlas:resolved", "selecting duplicate package:", name, "with:", preferredPkg.url.projectName
      for pkg in dupeList:
        if pkg != preferredPkg:
          notice "atlas:resolved", "deactivating duplicate package:", pkg.url.projectName
          pkg.active = false
      continue

    if not context().pkgOverrides.hasKey(name):
      error "atlas:resolved", "duplicate module name:", name, "with pkgs:", dupePkgs.mapIt(it.url.projectName).join(", ")
      notice "atlas:resolved", "please add an entry to `pkgOverrides` to the current project config to select one of: "
      for pkg in dupePkgs:
        notice "...", "   \"$1\": \"$2\", " % [$pkg.url.projectName(), $pkg.url]
    
      unhandledDuplicates.add name
    else:
      let pkgUrl = context().pkgOverrides[name].toPkgUriRaw()
      notice "atlas:resolved", "overriding package:", name, "with:", $pkgUrl
      for pkg in dupePkgs:
        if pkg.url != pkgUrl:
          notice "atlas:resolved", "deactivating duplicate package:", pkg.url.projectName
          pkg.active = false
        else:
          notice "atlas:resolved", "activating duplicate package:", pkg.url.projectName
  
  if unhandledDuplicates.len > 0:
    error "Invalid solution requiring duplicate module names found: " & unhandledDuplicates.join(", ")
    fatal "unhandled duplicate module names found: " & unhandledDuplicates.join(", ")

proc printVersionSelections(graph: DepGraph, solution: Solution, form: Form) =
  var inactives: seq[string]
  for pkg in values(graph.pkgs):
    if not pkg.isRoot and not pkg.active:
      inactives.add pkg.url.projectName

  if inactives.len > 0:
    notice "atlas:resolved", "inactive packages:", inactives.join(", ")

  notice "atlas:resolved", "selected:"
  var selections: seq[(string, string)]
  for pkg in allActiveNodes(graph):
    if not pkg.isRoot:
      var versions = pkg.versions.pairs().toSeq()
      versions.sort(sortVersionsAsc)
      var selectedIdx = -1
      for idx, (ver, rel) in versions:
        if ver.vid in form.mapping:
          if solution.isTrue(ver.vid):
            selectedIdx = idx
            break
      if selectedIdx == -1:
        continue

      let startIdx = max(0, selectedIdx - 1)
      let endIdx = min(versions.len - 1, selectedIdx + 1)
      var idxs = (startIdx .. endIdx).toSeq() 
      idxs.addUnique(0)
      idxs.addUnique(versions.len - 1)

      for idx in idxs:
        if idx < 0 or idx >= versions.len: continue
        let (ver, rel) = versions[idx]
        if ver.vid in form.mapping:
          let item = form.mapping[ver.vid]
          doAssert pkg.url == item.pkg.url
          if solution.isTrue(ver.vid):
            selections.add((item.pkg.url.projectName, "[x] " & toString item))
          else:
            selections.add((item.pkg.url.projectName, "[ ] " & toString item))
        else:
          selections.add((pkg.url.projectName, "[!] " & "(" & $rel.status & "; pkg: " & pkg.url.projectName & ", " & $ver & ")"))
  selections.sort(proc (a, b: (string, string)): int = cmpIgnoreCase(a[0], b[0]))
  for (pkg, str) in selections:
    notice "atlas:resolved", str
  notice "atlas:resolved", "end of selection"

proc solve*(graph: var DepGraph; form: Form, rerun: var bool) =
  for pkg in graph.pkgs.mvalues():
    pkg.activeVersion = nil
    pkg.activeFeatures = @[]
    pkg.active = false

  let conflict = findDependencyConflict(graph)
  if conflict.len > 0:
    error project(), conflict[0]
    for line in conflict[1..^1]:
      warn "atlas:resolved", line
    notice "atlas:resolved", "check the requirements above in the listed packages' Nimble files; SAT was not run"
    return

  let maxVar = form.idgen
  if DumpGraphs in context().flags:
    dumpJson(graph, "graph-solve-input.json")

  var solution = createSolution(maxVar)

  if DumpFormular in context().flags:
    debugFormular graph, form, solution

  if satisfiable(form.formula, solution):
    graph.root.active = true

    for varIdx in 0 ..< maxVar:
      let vid = VarId varIdx
      if vid in form.mapping:
        let mapInfo = form.mapping[vid]
        trace mapInfo.pkg.projectName, "v" & $varIdx & " sat var: " & $solution.getVar(vid).toPretty()

      if solution.isTrue(VarId(varIdx)) and form.mapping.hasKey(VarId varIdx):
        let mapInfo = form.mapping[VarId varIdx]
        let pkg = mapInfo.pkg
        pkg.active = true
        assert not pkg.isNil, "too bad: " & $pkg.url
        assert not mapInfo.release.isNil, "too bad: " & $pkg.url
        pkg.activeVersion = mapInfo.version
        if mapInfo.feature.len > 0:
          pkg.activeFeatures.addUniqueFeature(mapInfo.feature)
          debug pkg.url.projectName, "package satisfiable", "feature: ", mapInfo.feature
        else:
          debug pkg.url.projectName, "package satisfiable"

    checkDuplicateModules(graph)

    var lazyDefersNeeded: seq[Package]
    var lazyDeferUrls: HashSet[PkgUrl]

    template includeLazyDeps(reqs: untyped, reason: string) =
      for req in reqs:
        let depUrl = req[0]
        if depUrl in graph.pkgs and graph.pkgs[depUrl].state == LazyDeferred:
          if not lazyDeferUrls.containsOrIncl(depUrl):
            lazyDefersNeeded.add graph.pkgs[depUrl]
            debug graph.pkgs[depUrl].url.projectName, "lazy deferred package selected for load:", reason

    for pkg in graph.pkgs.values():
      if not pkg.active or pkg.activeVersion.isNil or pkg.activeVersion notin pkg.versions:
        continue
      let rel = pkg.versions[pkg.activeVersion]
      includeLazyDeps(rel.requirements, $pkg.url.projectName & ":" & $pkg.activeVersion)

      for feature, reqs in rel.features:
        var isFeatureEnabled = false
        if hasContextFeature(pkg, rel, feature):
          isFeatureEnabled = true
        elif feature in rel.featureVars and solution.isTrue(rel.featureVars[feature]):
          isFeatureEnabled = true

        if isFeatureEnabled:
          includeLazyDeps(reqs, $pkg.url.projectName & ":" & feature)

    if lazyDefersNeeded.len > 0:
      notice "atlas:resolved", "rerunning SAT; found lazy deferred packages:", lazyDefersNeeded.mapIt(it.url.projectName).join(", ")
      for pkg in lazyDefersNeeded:
        pkg.state = DoLoad
        pkg.versions.clear()

      rerun = true
      return

    graph.activateRequiredDependencyFeatures()

    if ListVersions in context().flags and ListVersionsOff notin context().flags:
      printVersionSelections(graph, solution, form)

  else:
    var notFoundCount = 0
    for pkg in values(graph.pkgs):
      if pkg.isRoot and pkg.state != Processed:
        error project(), "invalid find package: " & pkg.url.projectName & " in state: " & $pkg.state & " error: " & $pkg.errors
        inc notFoundCount
    if notFoundCount > 0:
      return

    # Deferred dependency implications are omitted from this formula. Loading
    # them can only restrict its solutions, so it cannot repair UNSAT. Only a
    # satisfiable selection above can justify loading more release metadata.
    error project(), "dependency conflict: no combination satisfies all required versions and features"
    reportRootRequirements(graph)
    reportNoVersionsFound(form)
    notice "atlas:resolved", "use --showGraph to inspect transitive requirements, or --verbosity=debug for release details"

  if DumpGraphs in context().flags:
    info "atlas:graph", "dumping graph after solving"
    dumpJson(graph, "graph-solved.json")

proc solve*(graph: var DepGraph; form: Form) =
  var rerun = false
  solve(graph, form, rerun)

proc loadWorkspace*(path: Path, nc: var NimbleContext, mode: TraversalMode, onClone: PackageAction, doSolve: bool): DepGraph =
  let deferChildDeps = doSolve and mode == AllReleases and NoLazyDeps notin context().flags
  result = path.expandGraph(nc, mode, onClone, deferChildDeps=deferChildDeps)

  if doSolve:
    let form = result.toFormular(context().defaultAlgo)
    var rerun = false
    solve(result, form, rerun)

    if rerun:
      for pkg in result.pkgs.values():
        for ver, rel in pkg.validVersions():
          ver.vid = NoVar
          rel.featureVars.clear()

      result = loadWorkspace(path, nc, mode, onClone, doSolve)


proc runBuildSteps*(graph: DepGraph) =
  ## execute build steps for the dependency graph
  ##
  for pkg in toposorted(graph):
    if pkg.active:
      doAssert pkg != nil
      block:
        # check for install hooks
        if not pkg.activeNimbleRelease.isNil and
            pkg.activeNimbleRelease.hasInstallHooks:
          tryWithDir pkg.ondisk:
            let nimbleFiles = findNimbleFile(pkg)
            if nimbleFiles.len() == 1:
              notice pkg.url.projectName, "Running installHook"
              runNimScriptInstallHook nimbleFiles[0], pkg.projectName
        # check for nim script bs
        for pattern in mitems context().plugins.builderPatterns:
          let bFile = pkg.ondisk / Path(pattern[0] % pkg.projectName)
          if fileExists(bFile):
            tryWithDir pkg.ondisk:
              runNimScriptBuilder pattern, pkg.projectName

proc activateGraph*(graph: DepGraph): tuple[paths: seq[CfgPath], features: seq[string]] =
  notice "atlas:graph", "Activating project deps for resolved dependency graph"
  for pkg in allActiveNodes(graph):
    if pkg.isRoot: continue
    if not pkg.activeVersion.commit().isEmpty():
      if pkg.ondisk.string.len == 0:
        error pkg.url.projectName, "Missing ondisk location for:", $(pkg.url)
      else:
        if pkg.url.isNimbleLink():
          continue
        let pkgUri = pkg.url.cloneUri()
        if pkgUri.scheme notin ["file", "link", "atlas"]:
          discard gitops.ensureCanonicalOrigin(pkg.ondisk, pkgUri)
        info pkg.url.projectName, "Checked out to:", $pkg.activeVersion.commit().short(), "at:", pkg.ondisk.relativeToWorkspace()
        discard checkoutGitCommitFull(pkg.ondisk, pkg.activeVersion.commit())

  let unsatisfiedFeatures = collectUnsatisfiedContextFeatures(graph)
  if unsatisfiedFeatures.len > 0:
    error "atlas:graph", "requested feature(s) were not able to be satisfied:", unsatisfiedFeatures.join(", ")

  if NoExec notin context().flags:
    notice "atlas:graph", "Running build steps"
    runBuildSteps(graph)

  notice "atlas:graph", "Wrote nim.cfg!"

  # Add feature defines for --feature:FOO flags (root project features without prefix)
  for feature in context().features:
    result.features.addUniqueFeature graph.canonicalFeatureDefine(feature)

  # Apply global feature flags to activeFeatures for introspection/tests.
  for pkg in graph.pkgs.values():
    if not pkg.active:
      continue
    let rel = pkg.activeNimbleRelease()
    if rel.isNil:
      continue
    for featName in rel.features.keys():
      if hasContextFeature(pkg, rel, featName) and
          hasSatisfiedFeatureDeps(graph, pkg, rel, featName):
        pkg.activeFeatures.addUniqueFeature(featName)

  if not graph.root.isNil and graph.root.active:
    let rel = graph.root.activeNimbleRelease()
    for feature in graph.root.activeFeatures:
      result.features.addUniqueFeature FeatureDefinePrefix &
        graph.root.packageFeatureName(rel) & "." & feature

  for pkg in allActiveNodes(graph):
    if pkg.isRoot: continue
    trace pkg.url.projectName, "adding CfgPath:", $relativeToWorkspace(toDestDir(graph, pkg) / getCfgPath(graph, pkg).Path)
    result.paths.add CfgPath(toDestDir(graph, pkg) / getCfgPath(graph, pkg).Path)
    let rel = pkg.activeNimbleRelease()
    for feature in pkg.activeFeatures:
      result.features.addUniqueFeature FeatureDefinePrefix &
        pkg.packageFeatureName(rel) & "." & feature

  result.paths.sort(proc (a, b: CfgPath): int =
    cmp(a.string, b.string)
  )
