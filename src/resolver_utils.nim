## Shared resolver post-processing helpers.

import std/[algorithm, sequtils, sets, strutils, tables]

import basic/[context, depgraphtypes, deptypes, gitops, pkgurls, reporters]

proc packageFeatureName*(pkg: Package; rel: NimbleRelease): string =
  let fallbackName =
    if pkg.isRoot: pkg.url.projectName
    else: pkg.url.shortName
  let declaredName =
    if rel.isNil: ""
    else: rel.name
  result = featurePackageName(declaredName, fallbackName)

proc matchesFeaturePackageName*(pkg: Package; rel: NimbleRelease;
                                name: string): bool =
  for candidate in [pkg.url.shortName, pkg.url.projectName, rel.name]:
    if candidate.len > 0 and sameFeature(candidate, name):
      return true

proc hasContextFeature*(pkg: Package; rel: NimbleRelease;
                        feature: string): bool =
  hasRequestedFeature(pkg.url.shortName, pkg.url.projectName,
    rel.name, feature, pkg.isRoot)

proc hasContextFeature*(pkg: Package; feature: string): bool =
  ## Compatibility overload for callers without selected release metadata.
  hasRequestedFeature(pkg.url.shortName, pkg.url.projectName, feature)

proc activateRequiredDependencyFeatures*(graph: DepGraph) =
  ## Record features requested on active dependency requirements.
  ## Undeclared features still emit defines but add no requirements.
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

proc formatVersionSelection*(pkg: Package; version: PackageVersion): string =
  result = "(" & pkg.url.projectName & ", " & $version & ")"
  if version.vtag.isPinned:
    result.add " [pinned]"

proc chooseDuplicatePackage(graph: DepGraph; name: string;
                            dupePkgs: seq[Package]): Package =
  ## Select the unambiguous preferred package for a duplicate module name.
  ## Root requirements and forks take precedence; equivalent Git remotes use
  ## a deterministic project-name tie breaker. Returns `nil` if no choice is safe.
  proc sortedFirst(pkgs: seq[Package]): Package =
    if pkgs.len == 0:
      return nil
    var sortedPkgs = pkgs
    sortedPkgs.sort(
      proc (a, b: Package): int = cmp(a.url.projectName, b.url.projectName))
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
        remoteIds.incl remoteId

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
    result = sortedFirst(dupePkgs)

proc checkDuplicateModules*(graph: var DepGraph) =
  ## Resolve duplicate active module names or fail when no selection is safe.
  ## Deactivates losing packages in `graph` and honors configured overrides.
  var moduleNames: Table[string, HashSet[Package]]
  for pkg in graph.pkgs.values():
    if pkg.active:
      moduleNames.mgetOrPut(
        pkg.url.projectName(), initHashSet[Package]()).incl(pkg)
  moduleNames = moduleNames.pairs().toSeq().filterIt(it[1].len > 1).toTable()

  var unhandledDuplicates: seq[string]
  for name, dupePkgs in moduleNames:
    let dupeList = dupePkgs.toSeq()
    let preferredPkg = chooseDuplicatePackage(graph, name, dupeList)
    if not preferredPkg.isNil:
      notice "atlas:resolved", "selecting duplicate package:", name,
        "with:", preferredPkg.url.projectName
      for pkg in dupeList:
        if pkg != preferredPkg:
          notice "atlas:resolved", "deactivating duplicate package:",
            pkg.url.projectName
          pkg.active = false
    elif not context().pkgOverrides.hasKey(name):
      error "atlas:resolved", "duplicate module name:", name, "with pkgs:",
        dupePkgs.mapIt(it.url.projectName).join(", ")
      notice "atlas:resolved",
        "please add an entry to `pkgOverrides` to the current project config to select one of: "
      for pkg in dupePkgs:
        notice "...", "   \"$1\": \"$2\", " % [$pkg.url.projectName(), $pkg.url]
      unhandledDuplicates.add name
    else:
      let pkgUrl = context().pkgOverrides[name].toPkgUriRaw()
      notice "atlas:resolved", "overriding package:", name, "with:", $pkgUrl
      for pkg in dupePkgs:
        if pkg.url != pkgUrl:
          notice "atlas:resolved", "deactivating duplicate package:",
            pkg.url.projectName
          pkg.active = false
        else:
          notice "atlas:resolved", "activating duplicate package:",
            pkg.url.projectName

  if unhandledDuplicates.len > 0:
    let names = unhandledDuplicates.join(", ")
    error "Invalid solution requiring duplicate module names found: " & names
    fatal "unhandled duplicate module names found: " & names
