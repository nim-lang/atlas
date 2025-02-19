import std / [sets, paths, dirs, files, tables, os, strutils, streams, json, jsonutils, algorithm]

import basic/[depgraphtypes, osutils, context, gitops, reporters, nimbleparser, pkgurls, versions]
import runners, cloner, pkgcache 

export depgraphtypes

when defined(nimAtlasBootstrap):
  import ../dist/sat/src/sat/[sat, satvars]
else:
  import sat/[sat, satvars]

type
  TraversalMode* = enum
    AllReleases,
    CurrentCommit

  CommitOrigin = enum
    FromHead, FromGitTag, FromDep, FromNimbleFile

iterator releases(path: Path,
                  mode: TraversalMode; versions: seq[DependencyVersion];
                  nimbleCommits: seq[string]): (CommitOrigin, Commit) =
  let (currentCommit, status) = exec(GitCurrentCommit, path, [])
  debug "depgraphs:releases", "currentCommit: " & $currentCommit & " status: " & $status
  if status != 0:
    yield (FromHead, Commit(h: "", v: Version"#head"))
  else:
    case mode
    of AllReleases:
      try:
        var produced = 0
        var uniqueCommits = initHashSet[string]()
        for version in versions:
          if version.version == Version"" and version.commit.len > 0 and not uniqueCommits.containsOrIncl(version.commit):
            let (_, status) = exec(GitCheckout, path, [version.commit])
            if status == 0:
              yield (FromDep, Commit(h: version.commit, v: Version""))
              inc produced
        let tags = collectTaggedVersions(path)
        for tag in tags:
          if not uniqueCommits.containsOrIncl(tag.h):
            let (_, status) = exec(GitCheckout, path, [tag.h])
            if status == 0:
              yield (FromGitTag, tag)
              inc produced
        for hash in nimbleCommits:
          if not uniqueCommits.containsOrIncl(hash):
            let (_, status) = exec(GitCheckout, path, [hash])
            if status == 0:
              yield (FromNimbleFile, Commit(h: hash, v: Version""))

        if produced == 0:
          yield (FromHead, Commit(h: "", v: Version"#head"))

      finally:
        discard exec(GitCheckout, path, [currentCommit])
    of CurrentCommit:
      yield (FromHead, Commit(h: "", v: Version"#head"))

proc traverseRelease(nimbleCtx: NimbleContext; graph: var DepGraph; idx: int;
                     origin: CommitOrigin; release: Commit; lastNimbleContents: var string) =
  let nimbleFiles = findNimbleFile(graph[idx])
  var packageVer = DependencyVersion(
    version: release.v,
    commit: release.h,
    req: EmptyReqs, v: NoVar)
  var badNimbleFile = false
  if nimbleFiles.len() != 1:
    packageVer.req = UnknownReqs
  else:
    let nimbleFile = nimbleFiles[0]
    when (NimMajor, NimMinor, NimPatch) == (2, 0, 0):
      var nimbleContents = readFile($nimbleFile)
    else:
      let nimbleContents = readFile($nimbleFile)
    if lastNimbleContents == nimbleContents:
      packageVer.req = graph[idx].versions[^1].req
    else:
      let reqResult = parseNimbleFile(nimbleCtx, nimbleFile, context().overrides)
      if origin == FromNimbleFile and packageVer.version == Version"":
        packageVer.version = reqResult.version
      let reqIdx = graph.reqsByDeps.getOrDefault(reqResult, -1)
      if reqIdx == -1:
        packageVer.req = graph.reqs.len
        graph.reqsByDeps[reqResult] = packageVer.req
        graph.reqs.add reqResult
      else:
        packageVer.req = reqIdx

      lastNimbleContents = ensureMove nimbleContents

    if graph.reqs[packageVer.req].status == Normal:
      for dep, interval in items(graph.reqs[packageVer.req].deps):
        let depIdx = graph.packageToDependency.getOrDefault(dep, -1)
        if depIdx == -1:
          graph.packageToDependency[dep] = graph.nodes.len
          graph.nodes.add Dependency(pkg: dep, versions: @[], isRoot: idx == 0, activeVersion: -1)
          enrichVersionsViaExplicitHash graph[graph.nodes.len-1].versions, interval
        else:
          graph[depIdx].isRoot = graph[depIdx].isRoot or idx == 0
          enrichVersionsViaExplicitHash graph[depIdx].versions, interval
    else:
      badNimbleFile = true

  if origin == FromNimbleFile and (packageVer.version == Version"" or badNimbleFile):
    discard "not a version we model in the dependency graph"
  else:
    graph[idx].versions.add ensureMove packageVer

proc traverseDependency*(nimbleCtx: NimbleContext;
                         graph: var DepGraph, idx: int, mode: TraversalMode) =
  var lastNimbleContents = "<invalid content>"

  let versions = move graph[idx].versions
  let nimbleVersions = collectNimbleVersions(nimbleCtx, graph[idx])
  trace "traverseDependency", "nimble versions: " & $nimbleVersions

  if graph[idx].isRoot:
    let (origin, release) = (FromHead, Commit(h: "", v: Version"#head"))
    traverseRelease nimbleCtx, graph, idx, origin, release, lastNimbleContents
  else:
    for (origin, release) in releases(graph[idx].ondisk, mode, versions, nimbleVersions):
      traverseRelease nimbleCtx, graph, idx, origin, release, lastNimbleContents

proc expand*(graph: var DepGraph; nimbleCtx: NimbleContext; mode: TraversalMode) =
  ## Expand the graph by adding all dependencies.
  trace "expand", "nodes: " & $graph.nodes
  var processed = initHashSet[PkgUrl]()
  var i = 0
  while i < graph.nodes.len:
    if not processed.containsOrIncl(graph[i].pkg):
      let (dest, todo) = pkgUrlToDirname(graph, graph[i])

      trace "expand", "todo: " & $todo & " pkg: " & graph[i].pkg.projectName & " dest: " & $dest
      # important: the ondisk path set here!
      graph[i].ondisk = dest

      case todo
      of DoClone:
        let (status, msg) =
          if graph[i].pkg.isFileProtocol:
            copyFromDisk(graph[i], dest)
          else:
            cloneUrl(graph[i].pkg, dest, false)
        if status == Ok:
          graph[i].state = Found
        else:
          graph[i].state = Error
          graph[i].errors.add $status & ":" & msg
      of DoNothing:
        if graph[i].ondisk.dirExists():
          graph[i].state = Found
        else:
          graph[i].state = Error
          graph[i].errors.add "ondisk location missing"

      if graph[i].state == Found:
        traverseDependency(nimbleCtx, graph, i, mode)
    inc i

iterator mvalidVersions*(pkg: var Dependency; graph: var DepGraph): var DependencyVersion =
  for ver in mitems pkg.versions:
    if graph.reqs[ver.req].status == Normal: yield ver

type
  SatVarInfo* = object # attached information for a SAT variable
    pkg: PkgUrl
    commit: string
    version: Version
    index: int

  Form* = object
    formula: Formular
    mapping: Table[VarId, SatVarInfo]
    idgen: int32

proc toFormular*(graph: var DepGraph; algo: ResolutionAlgorithm): Form =
  result = Form()
  var builder = Builder()
  builder.openOpr(AndForm)

  for pkg in mitems(graph.nodes):
    if pkg.versions.len == 0: continue

    pkg.versions.sort proc (a, b: DependencyVersion): int =
      (if a.version < b.version: 1
      elif a.version == b.version: 0
      else: -1)

    var verIdx = 0
    for ver in mitems pkg.versions:
      ver.v = VarId(result.idgen)
      result.mapping[ver.v] = SatVarInfo(pkg: pkg.pkg, commit: ver.commit, version: ver.version, index: verIdx)
      inc result.idgen
      inc verIdx

    doAssert pkg.state != NotInitialized

    if pkg.state == Error:
      builder.openOpr(AndForm)
      for ver in mitems pkg.versions: builder.addNegated ver.v
      builder.closeOpr # AndForm
    elif pkg.isRoot:
      builder.openOpr(ExactlyOneOfForm)
      for ver in mitems pkg.versions: builder.add ver.v
      builder.closeOpr # ExactlyOneOfForm
    else:
      builder.openOpr(ZeroOrOneOfForm)
      for ver in mitems pkg.versions: builder.add ver.v
      builder.closeOpr # ExactlyOneOfForm

  for pkg in mitems(graph.nodes):
    for ver in mvalidVersions(pkg, graph):
      if isValid(graph.reqs[ver.req].v):
        continue
      let eqVar = VarId(result.idgen)
      graph.reqs[ver.req].v = eqVar
      inc result.idgen

      if graph.reqs[ver.req].deps.len == 0: continue

      let beforeEq = builder.getPatchPos()

      builder.openOpr(OrForm)
      builder.addNegated eqVar
      if graph.reqs[ver.req].deps.len > 1: builder.openOpr(AndForm)
      var elementCount = 0
      for dep, query in items graph.reqs[ver.req].deps:
        let queryVer = if algo == SemVer: toSemVer(query) else: query
        let commit = extractSpecificCommit(queryVer)
        let availVer = graph[findDependencyForDep(graph, dep)]
        if availVer.versions.len == 0: continue

        let beforeExactlyOneOf = builder.getPatchPos()
        builder.openOpr(ExactlyOneOfForm)
        inc elementCount
        var matchCount = 0

        if commit.len > 0:
          for verIdx in countup(0, availVer.versions.len-1):
            if queryVer.matches(availVer.versions[verIdx].version) or commit == availVer.versions[verIdx].commit:
              builder.add availVer.versions[verIdx].v
              inc matchCount
              break
        elif algo == MinVer:
          for verIdx in countup(0, availVer.versions.len-1):
            if queryVer.matches(availVer.versions[verIdx].version):
              builder.add availVer.versions[verIdx].v
              inc matchCount
        else:
          for verIdx in countdown(availVer.versions.len-1, 0):
            if queryVer.matches(availVer.versions[verIdx].version):
              builder.add availVer.versions[verIdx].v
              inc matchCount
        builder.closeOpr # ExactlyOneOfForm
        if matchCount == 0:
          builder.resetToPatchPos beforeExactlyOneOf
          builder.add falseLit()

      if graph.reqs[ver.req].deps.len > 1: builder.closeOpr # AndForm
      builder.closeOpr # EqForm
      if elementCount == 0:
        builder.resetToPatchPos beforeEq

  for pkg in mitems(graph.nodes):
    for ver in mvalidVersions(pkg, graph):
      if graph.reqs[ver.req].deps.len > 0:
        builder.openOpr(OrForm)
        builder.addNegated ver.v
        builder.add graph.reqs[ver.req].v
        builder.closeOpr # OrForm

  builder.closeOpr # AndForm
  result.formula = toForm(builder)

proc toString(info: SatVarInfo): string =
  "(" & info.pkg.projectName & ", " & $info.version & ")"

proc runBuildSteps(graph: var DepGraph) =
  ## execute build steps for the dependency graph
  ##
  ## `countdown` suffices to give us some kind of topological sort:
  ##
  for i in countdown(graph.nodes.len-1, 0):
    if graph[i].active:
      let pkg = graph[i].pkg
      tryWithDir $graph[i].ondisk:
        # check for install hooks
        let activeVersion = graph[i].activeVersion
        let reqIdx = if graph[i].versions.len == 0: -1 else: graph[i].versions[activeVersion].req
        if reqIdx >= 0 and reqIdx < graph.reqs.len and graph.reqs[reqIdx].hasInstallHooks:
          let nimbleFiles = findNimbleFile(graph[i])
          if nimbleFiles.len() == 1:
            runNimScriptInstallHook nimbleFiles[0], pkg.projectName
        # check for nim script builders
        for pattern in mitems context().plugins.builderPatterns:
          let builderFile = pattern[0] % pkg.projectName
          if fileExists(builderFile):
            runNimScriptBuilder pattern, pkg.projectName

proc debugFormular(graph: var DepGraph; form: Form; solution: Solution) =
  echo "FORM: ", form.formula
  for key, value in pairs(form.mapping):
    echo "v", key.int, ": ", value
  let maxVar = maxVariable(form.formula)
  for varIdx in 0 ..< maxVar:
    if solution.isTrue(VarId(varIdx)):
      echo "v", varIdx, ": T"

proc solve*(graph: var DepGraph; form: Form) =
  let maxVar = form.idgen
  var solution = createSolution(maxVar)

  if satisfiable(form.formula, solution):
    for node in mitems graph.nodes:
      if node.isRoot: node.active = true
    for varIdx in 0 ..< maxVar:
      if solution.isTrue(VarId(varIdx)) and form.mapping.hasKey(VarId varIdx):
        let mapInfo = form.mapping[VarId varIdx]
        let i = findDependencyForDep(graph, mapInfo.pkg)
        graph[i].active = true
        assert graph[i].activeVersion == -1, "too bad: " & graph[i].pkg.url
        graph[i].activeVersion = mapInfo.index
        debug mapInfo.pkg.projectName, "package satisfiable"
        if mapInfo.commit != "" and graph[i].state == Processed:
          assert graph[i].ondisk.string.len > 0, "Missing ondisk location for: " & $(graph[i].pkg, i)
          checkoutGitCommit(graph[i].ondisk, mapInfo.commit)

    if NoExec notin context().flags:
      runBuildSteps(graph)

    if ListVersions in context().flags:
      info "../resolve", "selected:"
      for node in items graph.nodes:
        if not node.isTopLevel:
          for ver in items(node.versions):
            let item = form.mapping[ver.v]
            if solution.isTrue(ver.v):
              info item.pkg.projectName, "[x] " & toString item
            else:
              info item.pkg.projectName, "[ ] " & toString item
      info "../resolve", "end of selection"
  else:
    var notFoundCount = 0
    for pkg in mitems(graph.nodes):
      if pkg.isRoot and pkg.state != Processed:
        error context().workspace, "invalid find package: " & pkg.pkg.projectName & " in state: " & $pkg.state & " error: " & $pkg.errors
        inc notFoundCount
    if notFoundCount > 0: return
    error context().workspace, "version conflict; for more information use --showGraph"
    for pkg in mitems(graph.nodes):
      var usedVersionCount = 0
      for ver in mvalidVersions(pkg, graph):
        if solution.isTrue(ver.v): inc usedVersionCount
      if usedVersionCount > 1:
        for ver in mvalidVersions(pkg, graph):
          if solution.isTrue(ver.v):
            error pkg.pkg.projectName, string(ver.version) & " required"


proc traverseLoop*(nc: var NimbleContext; g: var DepGraph): seq[CfgPath] =
  result = @[]
  expand(g, nc, TraversalMode.AllReleases)
  let f = toFormular(g, context().defaultAlgo)
  solve(g, f)
  for w in allActiveNodes(g):
    result.add CfgPath(toDestDir(g, w) / getCfgPath(g, w).Path)
