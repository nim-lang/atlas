#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std / [sets, paths, tables, os, strutils, streams, json, jsonutils, algorithm]

import basic/[depgraphtypes, context, gitops, reporters, nimbleparser, pkgurls, versions]
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

iterator releases(c: var AtlasContext;
                  path: Path,
                  m: TraversalMode; versions: seq[DependencyVersion];
                  nimbleCommits: seq[string]): (CommitOrigin, Commit) =
  let (cc, status) = c.exec(GitCurrentCommit, path, [])
  if status == 0:
    case m
    of AllReleases:
      try:
        var produced = 0
        var uniqueCommits = initHashSet[string]()
        for v in versions:
          if v.version == Version"" and v.commit.len > 0 and not uniqueCommits.containsOrIncl(v.commit):
            let (_, status) = c.exec(GitCheckout, path, [v.commit])
            if status == 0:
              yield (FromDep, Commit(h: v.commit, v: Version""))
              inc produced
        let tags = c.collectTaggedVersions(path)
        for t in tags:
          if not uniqueCommits.containsOrIncl(t.h):
            let (_, status) = c.exec(GitCheckout, path, [t.h])
            if status == 0:
              yield (FromGitTag, t)
              inc produced
        for h in nimbleCommits:
          if not uniqueCommits.containsOrIncl(h):
            let (_, status) = c.exec(GitCheckout, path, [h])
            if status == 0:
              yield (FromNimbleFile, Commit(h: h, v: Version""))
              #inc produced

        if produced == 0:
          yield (FromHead, Commit(h: "", v: Version"#head"))

      finally:
        discard c.exec(GitCheckout, path, [cc])
    of CurrentCommit:
      yield (FromHead, Commit(h: "", v: Version"#head"))
  else:
    yield (FromHead, Commit(h: "", v: Version"#head"))

proc traverseRelease(c: var AtlasContext; nc: NimbleContext; graph: var DepGraph; idx: int;
                     origin: CommitOrigin; r: Commit; lastNimbleContents: var string) =
  let (nimbleFile, found) = findNimbleFile(graph[idx])
  var pv = DependencyVersion(
    version: r.v,
    commit: r.h,
    req: EmptyReqs, v: NoVar)
  var badNimbleFile = false
  if found != 1:
    pv.req = UnknownReqs
  else:
    when (NimMajor, NimMinor, NimPatch) == (2, 0, 0):
      # bug #110; make it compatible with Nim 2.0.0
      # ensureMove requires mutable places when version < 2.0.2
      var nimbleContents = readFile($nimbleFile)
    else:
      let nimbleContents = readFile($nimbleFile)
    if lastNimbleContents == nimbleContents:
      pv.req = graph[idx].versions[^1].req
    else:
      let r = c.parseNimbleFile(nc, nimbleFile, c.overrides)
      if origin == FromNimbleFile and pv.version == Version"":
        pv.version = r.version
      let ridx = graph.reqsByDeps.getOrDefault(r, -1) # hasKey(r)
      if ridx == -1:
        pv.req = graph.reqs.len
        graph.reqsByDeps[r] = pv.req
        graph.reqs.add r
      else:
        pv.req = ridx

      lastNimbleContents = ensureMove nimbleContents

    if g.reqs[pv.req].status == Normal:
      for dep, interval in items(g.reqs[pv.req].deps):
        let didx = g.packageToDependency.getOrDefault(dep, -1)
        if didx == -1:
          g.packageToDependency[dep] = g.nodes.len
          g.nodes.add Dependency(pkg: dep, versions: @[], isRoot: idx == 0, activeVersion: -1)
          enrichVersionsViaExplicitHash g.nodes[g.nodes.len-1].versions, interval
        else:
          g.nodes[didx].isRoot = g.nodes[didx].isRoot or idx == 0
          enrichVersionsViaExplicitHash g.nodes[didx].versions, interval
    else:
      badNimbleFile = true

  if origin == FromNimbleFile and (pv.version == Version"" or badNimbleFile):
    discard "not a version we model in the dependency graph"
  else:
    g.nodes[idx].versions.add ensureMove pv

proc traverseDependency*(c: var AtlasContext; nc: NimbleContext;
                         g: var DepGraph, idx: int, m: TraversalMode) =
  var lastNimbleContents = "<invalid content>"

  let dir = move g.nodes[idx].ondisk
  let versions = move g.nodes[idx].versions
  let nimbleVersions = collectNimbleVersions(c, nc, g, idx)

  for (origin, r) in c.releases(path, m, versions, nimbleVersions):
    traverseRelease c, nc, g, idx, origin, r, lastNimbleContents

proc expand*(c: var AtlasContext; g: var DepGraph; nc: NimbleContext; m: TraversalMode) =
  ## Expand the graph by adding all dependencies.
  var processed = initHashSet[PkgUrl]()
  var i = 0
  while i < g.nodes.len:
    if not processed.containsOrIncl(g.nodes[i].pkg):
      let (dest, todo) = pkgUrlToDirname(c, g, g.nodes[i])

      # important: the ondisk path set here!
      g.nodes[i].ondisk = dest

      if todo == DoClone:
        let (status, _) =
          if g.nodes[i].pkg.isFileProtocol:
            copyFromDisk(c, g.nodes[i], dest)
          else:
            cloneUrl(c, g.nodes[i].pkg, dest, false)
        g.nodes[i].status = status

      if g.nodes[i].status == Ok:
        # withDir c, dest:
        traverseDependency(c, nc, g, i, m)
    inc i

iterator mvalidVersions*(p: var Dependency; g: var DepGraph): var DependencyVersion =
  for v in mitems p.versions:
    if g.reqs[v.req].status == Normal: yield v

type
  SatVarInfo* = object # attached information for a SAT variable
    pkg: PkgUrl
    commit: string
    version: Version
    index: int

  Form* = object
    f: Formular
    mapping: Table[VarId, SatVarInfo]
    idgen: int32

proc toFormular*(c: var AtlasContext; g: var DepGraph; algo: ResolutionAlgorithm): Form =
  # Key idea: use a SAT variable for every `Requirements` object, which are
  # shared.
  result = Form()
  var b = Builder()
  b.openOpr(AndForm)

  when false:
    for n in mitems g.nodes:
      n.v = VarId(result.idgen)
      inc result.idgen
      # all root nodes must be true:
      if n.isRoot: b.add n.v
      # all broken nodes must not be true:
      if n.status != Ok:
        b.addNegated n.v

  for p in mitems(g.nodes):
    # if Package p is installed, pick one of its concrete versions, but not versions
    # that are errornous:
    # A -> (exactly one of: A1, A2, A3)
    if p.versions.len == 0: continue

    p.versions.sort proc (a, b: DependencyVersion): int =
      (if a.version < b.version: 1
      elif a.version == b.version: 0
      else: -1)

    var i = 0
    for ver in mitems p.versions:
      ver.v = VarId(result.idgen)
      result.mapping[ver.v] = SatVarInfo(pkg: p.pkg, commit: ver.commit, version: ver.version, index: i)

      inc result.idgen
      inc i

    if p.status != Ok:
      # all of its versions must be `false`
      b.openOpr(AndForm)
      for ver in mitems p.versions: b.addNegated ver.v
      b.closeOpr # AndForm
    elif p.isRoot:
      b.openOpr(ExactlyOneOfForm)
      for ver in mitems p.versions: b.add ver.v
      b.closeOpr # ExactlyOneOfForm
    else:
      # Either one version is selected or none:
      b.openOpr(ZeroOrOneOfForm)
      for ver in mitems p.versions: b.add ver.v
      b.closeOpr # ExactlyOneOfForm

  # Model the dependency graph:
  for p in mitems(g.nodes):
    for ver in mvalidVersions(p, g):
      if isValid(g.reqs[ver.req].v):
        # already covered this sub-formula (ref semantics!)
        continue
      let eqVar = VarId(result.idgen)
      g.reqs[ver.req].v = eqVar
      inc result.idgen

      if g.reqs[ver.req].deps.len == 0: continue

      let beforeEq = b.getPatchPos()

      b.openOpr(OrForm)
      b.addNegated eqVar
      if g.reqs[ver.req].deps.len > 1: b.openOpr(AndForm)
      var elements = 0
      for dep, query in items g.reqs[ver.req].deps:
        let q = if algo == SemVer: toSemVer(query) else: query
        let commit = extractSpecificCommit(q)
        let av = g.nodes[findDependencyForDep(g, dep)]
        if av.versions.len == 0: continue

        let beforeExactlyOneOf = b.getPatchPos()
        b.openOpr(ExactlyOneOfForm)
        inc elements
        var matchCounter = 0

        if commit.len > 0:
          for j in countup(0, av.versions.len-1):
            if q.matches(av.versions[j].version) or commit == av.versions[j].commit:
              b.add av.versions[j].v
              inc matchCounter
              break
          #mapping.add (g.nodes[i].pkg, commit, v)
        elif algo == MinVer:
          for j in countup(0, av.versions.len-1):
            if q.matches(av.versions[j].version):
              b.add av.versions[j].v
              inc matchCounter
        else:
          for j in countdown(av.versions.len-1, 0):
            if q.matches(av.versions[j].version):
              b.add av.versions[j].v
              inc matchCounter
        b.closeOpr # ExactlyOneOfForm
        if matchCounter == 0:
          b.resetToPatchPos beforeExactlyOneOf
          b.add falseLit()
          #echo "FOUND nothing for ", q, " ", dep

      if g.reqs[ver.req].deps.len > 1: b.closeOpr # AndForm
      b.closeOpr # EqForm
      if elements == 0:
        b.resetToPatchPos beforeEq

  # Model the dependency graph:
  for p in mitems(g.nodes):
    for ver in mvalidVersions(p, g):
      if g.reqs[ver.req].deps.len > 0:
        b.openOpr(OrForm)
        b.addNegated ver.v # if this version is chosen, these are its dependencies
        b.add g.reqs[ver.req].v
        b.closeOpr # OrForm

  b.closeOpr # AndForm
  result.f = toForm(b)

proc toString(x: SatVarInfo): string =
  "(" & x.pkg.projectName & ", " & $x.version & ")"

proc runBuildSteps(c: var AtlasContext; g: var DepGraph) =
  ## execute build steps for the dependency graph
  ##
  ## `countdown` suffices to give us some kind of topological sort:
  ##
  for i in countdown(g.nodes.len-1, 0):
    if g.nodes[i].active:
      let pkg = g.nodes[i].pkg
      tryWithDir c, g.nodes[i].ondisk:
        # check for install hooks
        let activeVersion = g.nodes[i].activeVersion
        let r = if g.nodes[i].versions.len == 0: -1 else: g.nodes[i].versions[activeVersion].req
        if r >= 0 and r < g.reqs.len and g.reqs[r].hasInstallHooks:
          let (nf, found) = findNimbleFile(g, i)
          if found == 1:
            runNimScriptInstallHook c, nf, pkg.projectName
        # check for nim script builders
        for p in mitems c.plugins.builderPatterns:
          let f = p[0] % pkg.projectName
          if fileExists(f):
            runNimScriptBuilder c, p, pkg.projectName

proc debugFormular(c: var AtlasContext; g: var DepGraph; f: Form; s: Solution) =
  echo "FORM: ", f.f
  #for n in g.nodes:
  #  echo "v", n.v.int, " ", n.pkg.url
  for k, v in pairs(f.mapping):
    echo "v", k.int, ": ", v
  let m = maxVariable(f.f)
  for i in 0 ..< m:
    if s.isTrue(VarId(i)):
      echo "v", i, ": T"

proc solve*(c: var AtlasContext; g: var DepGraph; f: Form) =
  let m = f.idgen
  var s = createSolution(m)
  #debugFormular c, g, f, s

  if satisfiable(f.f, s):
    for n in mitems g.nodes:
      if n.isRoot: n.active = true
    for i in 0 ..< m:
      if s.isTrue(VarId(i)) and f.mapping.hasKey(VarId i):
        let m = f.mapping[VarId i]
        let idx = findDependencyForDep(g, m.pkg)
        #echo "setting ", idx, " to active ", g.nodes[idx].pkg.url
        g.nodes[idx].active = true
        assert g.nodes[idx].activeVersion == -1, "too bad: " & g.nodes[idx].pkg.url
        g.nodes[idx].activeVersion = m.index
        debug c, m.pkg.projectName, "package satisfiable"
        if m.commit != "" and g.nodes[idx].status == Ok:
          assert g.nodes[idx].ondisk.len > 0, $(g.nodes[idx].pkg, idx)
          withDir c, g.nodes[idx].ondisk:
            checkoutGitCommit(c, m.pkg.projectName, m.commit)

    if NoExec notin c.flags:
      runBuildSteps(c, g)
      #echo f

    if ListVersions in c.flags:
      info c, "../resolve", "selected:"
      for n in items g.nodes:
        if not n.isTopLevel:
          for v in items(n.versions):
            let item = f.mapping[v.v]
            if s.isTrue(v.v):
              info c, item.pkg.projectName, "[x] " & toString item
            else:
              info c, item.pkg.projectName, "[ ] " & toString item
      info c, "../resolve", "end of selection"
  else:
    #echo "FORM: ", f.f
    var notFound = 0
    for p in mitems(g.nodes):
      if p.isRoot and p.status != Ok:
        error c, c.workspace, "cannot find package: " & p.pkg.projectName
        inc notFound
    if notFound > 0: return
    error c, c.workspace, "version conflict; for more information use --showGraph"
    for p in mitems(g.nodes):
      var usedVersions = 0
      for ver in mvalidVersions(p, g):
        if s.isTrue(ver.v): inc usedVersions
      if usedVersions > 1:
        for ver in mvalidVersions(p, g):
          if s.isTrue(ver.v):
            error c, p.pkg.projectName, string(ver.version) & " required"
