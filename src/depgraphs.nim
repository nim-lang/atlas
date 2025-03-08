import std / [sets, tables, sequtils, paths, dirs, files, tables, os, strutils, streams, json, jsonutils, algorithm]

import basic/[deptypes, versions, depgraphtypes, osutils, context, gitops, reporters, nimbleparser, pkgurls, versions]
import dependencies, runners 

import std/[json, jsonutils]

export depgraphtypes

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
    # index*: int

  Form* = object
    formula*: Formular
    mapping*: Table[VarId, SatVarInfo]
    idgen: int32

template withOpenBr(b, op, blk) =
  b.openOpr(op)
  `blk`
  b.closeOpr()

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
      var i = 0
      for ver, rel in p.validVersions():
        ver.vid = VarId(result.idgen)
        # Map the SAT variable to package information for result interpretation
        result.mapping[ver.vid] = SatVarInfo( pkg: p, version: ver, release: rel)
        inc result.idgen
        inc i

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
      for ver, rel in validVersions(pkg):
        var allDepsCompatible = true

        # First check if all dependencies can be satisfied
        for dep, query in items(rel.requirements):
          let depNode = graph.pkgs[dep]

          var hasCompatible = false
          for depVer, relVer in depNode.validVersions():
            if query.matches(depVer.version()):
              hasCompatible = true
              break

          if not hasCompatible:
            allDepsCompatible = false
            error pkg.url.projectName, "no versions matched requirements for this dep", $dep.projectName
            break

        # If any dependency can't be satisfied, make this version unsatisfiable
        if not allDepsCompatible:
          error pkg.url.projectName, "all requirements needed were not matched", $rel.requirements
          b.addNegated(ver.vid)
          continue

        # Add implications for each dependency
        # for dep, q in items graph.reqs[ver.req].deps:
        for dep, query in items(rel.requirements):
          let depNode = graph.pkgs[dep]

          var compatibleVersions: seq[VarId] = @[]
          for depVer, relVer in depNode.validVersions():
            if query.matches(depVer.version()):
              compatibleVersions.add(depVer.vid)

          # Add implication: if this version is selected, one of its compatible deps must be selected
          withOpenBr(b, OrForm):
            b.addNegated(ver.vid)  # not A
            withOpenBr(b, OrForm):
              for compatVer in compatibleVersions:
                b.add(compatVer)

    when false:
      # Note this original ran, but seems to have problems now with minver...
      #
      # Original Atlas version ported to the new Package graph layout
      # However the Nimble version appears to accomplish the same with less work
      # Going to keep this here however, could be things we'll need to re-add later
      # like handline the explicit commits, which were broken already anyways...
      # 
      # This loop sets up the dependency relationships in the SAT formula
      # It creates constraints for each package's requirements
      #
      for pkg in graph.pkgs.mvalues():
        for ver, rel in validVersions(pkg):
          # Skip if this requirement has already been processed
          if isValid(rel.rid): continue
          # Assign a unique SAT variable to this requirement set
          let eqVar = VarId(result.idgen)
          rel.rid = eqVar
          inc result.idgen
          # Skip empty requirement sets
          if rel.requirements.len == 0: continue
          let beforeEq = b.getPatchPos()
          # Create a constraint: if this requirement is true, then all its dependencies must be satisfied
          b.openOpr(OrForm)
          b.addNegated eqVar
          if rel.requirements.len > 1:
            b.openOpr(AndForm)
          var elementCount = 0
          # For each dependency in the requirement, create version matching constraints
          for dep, query in items rel.requirements:
            let queryVer = if algo == SemVer: toSemVer(query) else: query
            let commit = extractSpecificCommit(queryVer)
            let availVer = graph.pkgs[dep]
            if availVer.versions.len == 0:
              continue
            let beforeExactlyOneOf = b.getPatchPos()
            b.openOpr(ExactlyOneOfForm)
            inc elementCount
            var matchCount = 0
            var availVers = availVer.versions.keys().toSeq()
            info pkg.url.projectName, "version keys:", $dep.projectName, "availVers:", $availVers
            if not commit.isEmpty():
              info pkg.url.projectName, "adding requirements selections by specific commit:", $dep.projectName, "commit:", $commit
              # Match by specific commit if specified
              for depVer in availVers:
                if queryVer.matches(depVer.version()) or commit == depVer.commit():
                  b.add depVer.vid
                  inc matchCount
                  break
            elif algo == MinVer:
              # For MinVer algorithm, try to find the minimum version that satisfies the requirement
              info pkg.url.projectName, "adding requirements selections by MinVer:", $dep.projectName
              for depVer in availVers:
                if queryVer.matches(depVer.version()):
                  b.add depVer.vid
                  inc matchCount
            else:
              # For other algorithms (like SemVer), try to find the maximum version that satisfies
              info pkg.url.projectName, "adding requirements selections by SemVer:", $dep.projectName, "vers:", $availVers
              availVers.reverse()
              for depVer in availVers:
                if queryVer.matches(depVer.version()):
                  info pkg.url.projectName, "matched requirement selections by SemVer:", $queryVer, "depVer:", $depVer
                  b.add depVer.vid
                  inc matchCount
            b.closeOpr() # ExactlyOneOfForm
            # If no matching version was found, add a false literal to make the formula unsatisfiable
            if matchCount == 0:
              b.resetToPatchPos beforeExactlyOneOf
              b.add falseLit()
          if rel.requirements.len > 1:
            b.closeOpr() # AndForm
          b.closeOpr() # EqForm
          # If no dependencies were processed, reset the formula position
          if elementCount == 0:
            b.resetToPatchPos beforeEq

      # This final loop links package versions to their requirements
      # It enforces that if a version is selected, its requirements must be satisfied
      for pkg in mvalues(graph.pkgs):
        for ver, rel in validVersions(pkg):
          if rel.requirements.len > 0:
            info pkg.url.projectName, "adding package requirements restraint:", $ver, "vid: ", $ver.vid.int, "rel:", $rel.rid.int
            b.openOpr(OrForm)
            b.addNegated ver.vid
            b.add rel.rid
            b.closeOpr() # OrForm
          else:
            info pkg.url.projectName, "not adding pacakge requirements restraint:", $ver

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

proc solve*(graph: var DepGraph; form: Form) =
  for pkg in graph.pkgs.mvalues():
    pkg.activeVersion = nil
    pkg.active = false

  let maxVar = form.idgen
  if context().dumpGraphs:
    dumpJson(graph, "graph-solve-input.json")

  var solution = createSolution(maxVar)

  if context().dumpFormular:
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
        let ver = mapInfo.version
        pkg.active = true
        assert not pkg.isNil, "too bad: " & $pkg.url
        assert not mapInfo.release.isNil, "too bad: " & $pkg.url
        pkg.activeVersion = mapInfo.version
        debug pkg.url.projectName, "package satisfiable"

    if ListVersions in context().flags:
      warn "Resolved", "selected:"
      for pkg in values(graph.pkgs):
        if not pkg.isRoot:
          for ver, rel in pkg.versions:
            if ver.vid in form.mapping:
              let item = form.mapping[ver.vid]
              doAssert pkg.url == item.pkg.url
              if solution.isTrue(ver.vid):
                warn item.pkg.url.projectName, "[x] " & toString item
              else:
                warn item.pkg.url.projectName, "[ ] " & toString item
            else:
              warn pkg.url.projectName, "[!] " & "(" & $rel.status & "; pkg: " & pkg.url.projectName & ", " & $ver & ")"
      warn "Resolved", "end of selection"
  else:
    var notFoundCount = 0
    for pkg in values(graph.pkgs):
      if pkg.isRoot and pkg.state != Processed:
        error context().workspace, "invalid find package: " & pkg.url.projectName & " in state: " & $pkg.state & " error: " & $pkg.errors
        inc notFoundCount
    if notFoundCount > 0:
      return
    error context().workspace, "version conflict; for more information use --showGraph"
    for pkg in mvalues(graph.pkgs):
      var usedVersionCount = 0
      for (ver, rel) in validVersions(pkg):
        if solution.isTrue(ver.vid): inc usedVersionCount
      if usedVersionCount > 1:
        for (ver, rel) in validVersions(pkg):
          if solution.isTrue(ver.vid):
            error pkg.url.projectName, string(ver.version()) & " required"
  if context().dumpGraphs:
    dumpJson(graph, "graph-solved.json")

proc loadWorkspaceConfigs*(path: Path, nc: var NimbleContext): seq[CfgPath] =
  result = @[]
  var graph = path.expand(nc, TraversalMode.AllReleases, notFoundAction=DoClone)
  let form = graph.toFormular(context().defaultAlgo)
  
  solve(graph, form)


proc runBuildSteps*(graph: DepGraph) =
  ## execute build steps for the dependency graph
  ##
  ## `countdown` suffices to give us some kind of topological sort:
  ##
  var revPkgs = graph.pkgs.values().toSeq()
  revPkgs.reverse()

  # for i in countdown(graph.pkgs.len-1, 0):
  for pkg in revPkgs:
    if pkg.active:
      doAssert pkg != nil
      tryWithDir $pkg.ondisk:
        # check for install hooks
        if not pkg.activeNimbleRelease.isNil and
            pkg.activeNimbleRelease.hasInstallHooks:
          let nimbleFiles = findNimbleFile(pkg)
          if nimbleFiles.len() == 1:
            info pkg.url.projectName, "Running installHook"
            runNimScriptInstallHook nimbleFiles[0], pkg.projectName
        # check for nim script bs
        for pattern in mitems context().plugins.builderPatterns:
          let bFile = pattern[0] % pkg.projectName
          if fileExists(bFile):
            runNimScriptBuilder pattern, pkg.projectName

proc activateGraph*(graph: DepGraph): seq[CfgPath] =
  for pkg in allActiveNodes(graph):
    if not pkg.activeVersion.commit().isEmpty():
      if pkg.ondisk.string.len == 0:
        error pkg.url.projectName, "Missing ondisk location for:", $(pkg.url)
      else:
        let res = checkoutGitCommit(pkg.ondisk, pkg.activeVersion.commit())

  if NoExec notin context().flags:
    runBuildSteps(graph)

  for pkg in allActiveNodes(graph):
    debug pkg.url.projectName, "adding CfgPath:", $(toDestDir(graph, pkg) / getCfgPath(graph, pkg).Path)
    result.add CfgPath(toDestDir(graph, pkg) / getCfgPath(graph, pkg).Path)