import std / [sets, tables, sequtils, paths, files, os, strutils, json, jsonutils, algorithm]

import basic/[deptypes, versions, depgraphtypes, osutils, context, gitops, reporters, nimblecontext, pkgurls, deptypesjson]
import dependencies, runners 

export depgraphtypes, deptypesjson

when defined(nimAtlasBootstrap):
  import ../dist/sat/src/sat/[sat, satvars]
else:
  import sat/[sat, satvars]

export sat

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

template withOpenBr(b, op, blk) =
  b.openOpr(op)
  `blk`
  b.closeOpr()

proc addVersionConstraints(b: var Builder; graph: var DepGraph, pkg: Package) =
  var anyReleaseSatisfied = false

  proc checkDeps(graph: var DepGraph, ver: PackageVersion, reqs: seq[(PkgUrl, VersionInterval)]): bool =
    var allDepsCompatible = true

    # First check if all dependencies can be satisfied
    for dep, query in items(reqs):
      if dep notin graph.pkgs:
        debug pkg.url.projectName, "checking dependency for ", $ver, "not found:", $dep.projectName, "query:", $query
        allDepsCompatible = false
        continue
      debug pkg.url.projectName, "checking dependency for ", $ver, ":", $dep.projectName, "query:", $query
      let depNode = graph.pkgs[dep]

      var hasCompatible = false
      for depVer, relVer in depNode.validVersions():
        trace pkg.url.projectName, "checking dependnecy version:", $depVer, "query:", $query, "matches:", $query.matches(depVer)
        if query.matches(depVer):
          hasCompatible = true
          trace pkg.url.projectName, "version matched requirements for the dependency version:", $depVer
          break

      if not hasCompatible:
        allDepsCompatible = false
        warn pkg.url.projectName, "no versions matched requirements for the dependency:", $dep.projectName
        break

    return allDepsCompatible

  for ver, rel in validVersions(pkg):
    let allDepsCompatible = checkDeps(graph, ver, rel.requirements)

    # If any dependency can't be satisfied, make this version unsatisfiable
    if not allDepsCompatible:
      warn pkg.url.projectName, "all requirements needed for nimble release:", $ver, "were not able to be satisfied:", $rel.requirements.mapIt(it[0].projectName & " " & $it[1]).join("; ")
      b.addNegated(ver.vid)
      continue

    anyReleaseSatisfied = true

    # Add implications for each dependency
    for dep, query in items(rel.requirements):
      if dep notin graph.pkgs:
        info pkg.url.projectName, "requirement depdendency not found:", $dep.projectName, "query:", $query
        continue
      let depNode = graph.pkgs[dep]

      var compatibleVersions: seq[VarId] = @[]
      for depVer, relVer in depNode.validVersions():
        if query.matches(depVer):
          compatibleVersions.add(depVer.vid)

      # Add implication: if this version is selected, one of its compatible deps must be selected
      withOpenBr(b, OrForm):
        b.addNegated(ver.vid)  # not this version
        withOpenBr(b, OrForm):
          for compatVer in compatibleVersions:
            b.add(compatVer)

    # Add implications for each feature flagged
    for dep, flags in rel.featuresFlagged:
      if dep notin graph.pkgs:
        info pkg.url.projectName, "requirement depdendency not found:", $dep.projectName, "flags:", $flags
        continue
      let depNode = graph.pkgs[dep]

      echo "FEATURE:FLAGGED: ", flags, " DEP: ", $depNode.projectName

      for flag in flags:
        withOpenBr(b, OrForm):
          b.addNegated(ver.vid)  # not this version

          withOpenBr(b, OrForm):
            for ver, relVer in depNode.validVersions():
              if flag in relVer.features:
                let flagVarId = relVer.featureVars[flag]
                echo "FEATURE:FLAG:EQ: ", flag, " VER: ", $ver
                b.add(flagVarId)


    # Add implications for each feature requirement
    for feature, reqs in rel.features:
      let featVarId = rel.featureVars[feature]
      let allFeatDepsCompatible = checkDeps(graph, ver, reqs)

      if not allFeatDepsCompatible:
        warn pkg.url.projectName, "all requirements needed for feature:", feature, "were not able to be satisfied:", $reqs.mapIt(it[0].projectName & " " & $it[1]).join("; ")
        b.addNegated(featVarId)
        break

      for dep, query in items(reqs):
        if dep notin graph.pkgs:
          info pkg.url.projectName, "feature depdendency not found:", $dep.projectName, "query:", $query
          continue
        let depNode = graph.pkgs[dep]

        var compatibleVersions: seq[VarId] = @[]
        for depVer, relVer in depNode.validVersions():
          if query.matches(depVer):
            compatibleVersions.add(depVer.vid)

        withOpenBr(b, OrForm):
          b.addNegated(ver.vid) # not this version
          b.addNegated(featVarId) # not this feature
          withOpenBr(b, OrForm):
            for compatVer in compatibleVersions:
              b.add(compatVer)

  if not anyReleaseSatisfied:
    error pkg.url.projectName, "no versions satisfied for this package:", $pkg.url

proc toFormular*(graph: var DepGraph; algo: ResolutionAlgorithm): Form =
  result = Form()
  var b = Builder()

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
            inc result.idgen

      doAssert p.state != NotInitialized, "package not initialized: " & $p.toJson(ToJsonOptions(enumMode: joptEnumString))

      # Add constraints based on the package status
      if p.state == Error:
        # If package is broken, enforce that none of its versions can be selected
        withOpenBr(b, AndForm):
          for ver, rel in p.validVersions():
            b.addNegated ver.vid
      elif p.isRoot:
        # If it's a root package, enforce that exactly one version must be selected
        withOpenBr(b, ExactlyOneOfForm):
          for ver, rel in p.validVersions():
            b.add ver.vid
      else:
        # For non-root packages, they can either have one version selected or none at all
        withOpenBr(b, ZeroOrOneOfForm):
          for ver, rel in p.validVersions():
            b.add ver.vid
      
    # This simpler deps loop was copied from Nimble after it was first ported from Atlas :)
    # It appears to acheive the same results, but it's a lot simpler
    for pkg in graph.pkgs.mvalues():
      b.addVersionConstraints(graph, pkg)

  result.formula = toForm(b)


proc toString(info: SatVarInfo): string =
  "(" & info.pkg.url.projectName & ", " & $info.version & ")"

proc debugFormular*(graph: var DepGraph; form: Form; solution: Solution) =
  echo "FORM:\n\t", form.formula
  var keys = form.mapping.keys().toSeq()
  keys.sort(proc (a, b: VarId): int = cmp(a.int, b.int))
  for key in keys:
    let value = form.mapping[key]
    echo "\tv", key.int, ": ", value
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

proc checkDuplicateModules(graph: var DepGraph) =
  # Check for duplicate module names
  var moduleNames: Table[string, HashSet[Package]]
  for pkg in values(graph.pkgs):
    if pkg.active:
      moduleNames.mgetOrPut(pkg.url.shortName()).incl(pkg)
  moduleNames = moduleNames.pairs().toSeq().filterIt(it[1].len > 1).toTable()

  var unhandledDuplicates: seq[string]
  for name, dupePkgs in moduleNames:
    if not context().pkgOverrides.hasKey(name):
      error "atlas:resolved", "duplicate module name:", name, "with pkgs:", dupePkgs.mapIt(it.url.projectName).join(", ")
      notice "atlas:resolved", "please add an entry to `pkgOverrides` to the current project config to select one of: "
      for pkg in dupePkgs:
        notice "...", "   \"$1\": \"$2\", " % [$pkg.url.shortName(), $pkg.url]
    
      if moduleNames.len > 1:
        unhandledDuplicates.add name
        error "Invalid solution requiring duplicate module names found: " & moduleNames.keys().toSeq().join(", ")
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
  var longestPkgName = 0
  for (pkg, str) in selections:
    longestPkgName = max(longestPkgName, pkg.len)
  for (pkg, str) in selections:
    notice "atlas:resolved", str
  notice "atlas:resolved", "end of selection"

proc solve*(graph: var DepGraph; form: Form) =
  for pkg in graph.pkgs.mvalues():
    pkg.activeVersion = nil
    pkg.active = false

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
        debug pkg.url.projectName, "package satisfiable"

    checkDuplicateModules(graph)

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
    error project(), "version conflict; for more information use --showGraph"
    for pkg in mvalues(graph.pkgs):
      var usedVersionCount = 0
      for (ver, rel) in validVersions(pkg):
        if solution.isTrue(ver.vid): inc usedVersionCount
      if usedVersionCount > 1:
        for (ver, rel) in validVersions(pkg):
          if solution.isTrue(ver.vid):
            error pkg.url.projectName, string(ver.version()) & " required"
  if DumpGraphs in context().flags:
    info "atlas:graph", "dumping graph after solving"
    dumpJson(graph, "graph-solved.json")

proc loadWorkspace*(path: Path, nc: var NimbleContext, mode: TraversalMode, onClone: PackageAction, doSolve: bool): DepGraph =
  result = path.expandGraph(nc, mode, onClone)

  if doSolve:
    let form = result.toFormular(context().defaultAlgo)
    solve(result, form)


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
              info pkg.url.projectName, "Running installHook"
              runNimScriptInstallHook nimbleFiles[0], pkg.projectName
        # check for nim script bs
        for pattern in mitems context().plugins.builderPatterns:
          let bFile = pkg.ondisk / Path(pattern[0] % pkg.projectName)
          if fileExists(bFile):
            tryWithDir pkg.ondisk:
              runNimScriptBuilder pattern, pkg.projectName

proc activateGraph*(graph: DepGraph): seq[CfgPath] =
  for pkg in allActiveNodes(graph):
    if pkg.isRoot: continue
    if not pkg.activeVersion.commit().isEmpty():
      if pkg.ondisk.string.len == 0:
        error pkg.url.projectName, "Missing ondisk location for:", $(pkg.url)
      else:
        info pkg.url.projectName, "checkout git commit:", $pkg.activeVersion.commit(), "at:", pkg.ondisk.relativeToWorkspace()
        discard checkoutGitCommitFull(pkg.ondisk, pkg.activeVersion.commit())

  if NoExec notin context().flags:
    runBuildSteps(graph)

  for pkg in allActiveNodes(graph):
    if pkg.isRoot: continue
    trace pkg.url.projectName, "adding CfgPath:", $relativeToWorkspace(toDestDir(graph, pkg) / getCfgPath(graph, pkg).Path)
    result.add CfgPath(toDestDir(graph, pkg) / getCfgPath(graph, pkg).Path)
