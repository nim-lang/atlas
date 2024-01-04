#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std / [sets, tables, os, strutils]

import context, sat, gitops, runners, reporters, nimbleparser, pkgurls, cloner

type
  DependencyVersion* = object  # Represents a specific version of a project.
    version*: Version
    commit*: string
    req*: Requirements
    v: VarId

  Dependency* = object
    pkg*: PkgUrl
    versions*: seq[DependencyVersion]
    v: VarId
    active*: bool
    activeVersion*: int
    status: CloneStatus
    ondisk*: string

  SatVarInfo* = object # attached information for a SAT variable
    pkg: PkgUrl
    commit: string
    version: Version
    index: int

  DepGraph* = object
    nodes: seq[Dependency]
    idgen: int32
    startNodesLen: int
    mapping: Table[VarId, SatVarInfo]
    packageToDependency: Table[PkgUrl, int]

proc createGraph*(c: var AtlasContext; startSet: openArray[PkgUrl]): DepGraph =
  result = DepGraph(nodes: @[], idgen: 0'i32, startNodesLen: startSet.len)
  for s in startSet:
    result.packageToDependency[s] = result.nodes.len
    result.nodes.add Dependency(pkg: s, versions: @[], v: VarId(result.idgen))
    inc result.idgen

proc createGraph*(c: var AtlasContext; s: PkgUrl): DepGraph =
  result = DepGraph(nodes: @[], idgen: 0'i32, startNodesLen: 1)
  result.packageToDependency[s] = result.nodes.len
  result.nodes.add Dependency(pkg: s, versions: @[], v: VarId(result.idgen))
  inc result.idgen

proc createGraphFromWorkspace*(c: var AtlasContext): DepGraph =
  result = DepGraph(nodes: @[], idgen: 0'i32, startNodesLen: 0)

type
  TraversalMode* = enum
    AllReleases,
    CurrentCommit

iterator releases(c: var AtlasContext; m: TraversalMode): Commit =
  let (cc, status) = exec(c, GitCurrentCommit, [])
  if status == 0:
    case m
    of AllReleases:
      try:
        let tags = collectTaggedVersions(c)
        for t in tags:
          let (_, status) = exec(c, GitCheckout, [t.h])
          if status != 0:
            yield t
      finally:
        discard exec(c, GitCheckout, [cc])
    of CurrentCommit:
      yield Commit(h: cc, v: Version"#head")
  else:
    yield Commit(h: "", v: Version"#head")

proc findNimbleFile(g: DepGraph; idx: int): (string, int) =
  var nimbleFile = g.nodes[idx].pkg.projectName & ".nimble"
  var found = 0
  if fileExists(nimbleFile):
    inc found
  else:
    for file in walkFiles("*.nimble"):
      nimbleFile = file
      inc found
  result = (ensureMove nimbleFile, found)

proc traverseDependency(c: var AtlasContext; nc: NimbleContext; g: var DepGraph; idx: int;
                        processed: var HashSet[PkgUrl];
                        m: TraversalMode) =
  var lastNimbleContents = "<invalid content>"

  for r in releases(c, m):
    let (nimbleFile, found) = findNimbleFile(g, idx)
    var pv = DependencyVersion(
      version: r.v,
      commit: r.h,
      req: Requirements(deps: @[], v: NoVar))
    if found != 1:
      pv.req = Requirements(status: HasUnknownNimbleFile)
    else:
      let nimbleContents = readFile(nimbleFile)
      if lastNimbleContents == nimbleContents:
        pv.req = g.nodes[idx].versions[^1].req
      else:
        pv.req = parseNimbleFile(nc, nimbleFile)
        lastNimbleContents = ensureMove nimbleContents

      if pv.req.status == Normal:
        for dep, _ in items(pv.req.deps):
          if not processed.contains(dep):
            g.packageToDependency[dep] = g.nodes.len
            g.nodes.add Dependency(pkg: dep, versions: @[])

    g.nodes[idx].versions.add ensureMove pv

const
  FileWorkspace = "file://./"

proc copyFromDisk(c: var AtlasContext; w: Dependency; destDir: string): (CloneStatus, string) =
  var dir = w.pkg.url
  if dir.startsWith(FileWorkspace): dir = c.workspace / dir.substr(FileWorkspace.len)
  #template selectDir(a, b: string): string =
  #  if dirExists(a): a else: b

  #let dir = selectDir(u & "@" & w.commit, u)
  if dirExists(dir):
    copyDir(dir, destDir)
    result = (Ok, "")
  else:
    result = (NotFound, dir)
  #writeFile destDir / ThisVersion, w.commit
  #echo "WRITTEN ", destDir / ThisVersion

type
  PackageAction = enum
    DoNothing, DoClone

proc pkgUrlToDirname(g: var DepGraph; u: PkgUrl): (string, PackageAction) =
  # XXX implement namespace support here
  let n = u.projectName
  result = (n, if dirExists(n): DoNothing else: DoClone)

proc toDestDir*(g: DepGraph; d: Dependency): string =
  # XXX Use lookup table here
  result = d.pkg.projectName

proc expand*(c: var AtlasContext; g: var DepGraph; nc: NimbleContext; m: TraversalMode) =
  ## Expand the graph by adding all dependencies.
  var processed = initHashSet[PkgUrl]()
  var i = 0
  while i < g.nodes.len:
    let w {.cursor.} = g.nodes[i]

    if not processed.containsOrIncl(w.pkg):
      let (dirName, todo) = pkgUrlToDirname(g, w.pkg)
      if todo == DoClone:
        let depsDir = if i < g.startNodesLen: c.workspace else: c.depsDir
        info(c, dirName, "cloning: " & w.pkg.url)
        g.nodes[i].ondisk = depsDir / dirName
        let (status, _) =
          if w.pkg.isFileProtocol:
            copyFromDisk(c, w, g.nodes[i].ondisk)
          else:
            cloneUrl(c, w.pkg, g.nodes[i].ondisk, false)

        g.nodes[i].status = status

      withDir c, dirName:
        traverseDependency(c, nc, g, i, processed, m)
    inc i

proc findDependencyForDep(g: DepGraph; dep: PkgUrl): int {.inline.} =
  assert g.packageToDependency.hasKey(dep), $(dep, g.packageToDependency)
  result = g.packageToDependency.getOrDefault(dep)

iterator mvalidVersions*(p: var Dependency): var DependencyVersion =
  for v in mitems p.versions:
    if v.req.status == Normal: yield v

proc toFormular*(g: var DepGraph; algo: ResolutionAlgorithm): Formular =
  # Key idea: use a SAT variable for every `Requirements` object, which are
  # shared.
  var b = Builder()
  b.openOpr(AndForm)

  # all active nodes must be true:
  for i in 0 ..< g.startNodesLen:
    b.add g.nodes[i].v

  for p in mitems(g.nodes):
    # if Package p is installed, pick one of its concrete versions, but not versions
    # that are errornous:
    # A -> (exactly one of: A1, A2, A3)
    if p.versions.len == 0: continue
    b.openOpr(OrForm)
    b.addNegated p.v

    b.openOpr(ExactlyOneOfForm)
    var i = 0
    for ver in mitems p.versions:
      ver.v = VarId(g.idgen)
      g.mapping[ver.v] = SatVarInfo(pkg: p.pkg, commit: ver.commit, version: ver.version, index: i)

      inc g.idgen
      b.add ver.v
      inc i

    b.closeOpr # ExactlyOneOfForm
    b.closeOpr # OrForm

  # Model the dependency graph:
  for p in mitems(g.nodes):
    for ver in mvalidVersions p:
      if isValid(ver.req.v):
        # already covered this sub-formula (ref semantics!)
        continue
      ver.req.v = VarId(g.idgen)
      inc g.idgen

      b.openOpr(EqForm)
      b.add ver.req.v
      b.openOpr(AndForm)

      for dep, query in items ver.req.deps:
        b.openOpr(ExactlyOneOfForm)
        let q = if algo == SemVer: toSemVer(query) else: query
        let commit = extractSpecificCommit(q)
        let av = g.nodes[findDependencyForDep(g, dep)]
        if commit.len > 0:
          var v = Version("#" & commit)
          for j in countup(0, av.versions.len-1):
            if q.matches(av.versions[j].version):
              v = av.versions[j].version
              b.add av.versions[j].v
              break
          #mapping.add (g.nodes[i].pkg, commit, v)
        elif algo == MinVer:
          for j in countup(0, av.versions.len-1):
            if q.matches(av.versions[j].version):
              b.add av.versions[j].v
        else:
          for j in countdown(av.versions.len-1, 0):
            if q.matches(av.versions[j].version):
              b.add av.versions[j].v
        b.closeOpr # ExactlyOneOfForm

      b.closeOpr # AndForm
      b.closeOpr # EqForm

  # Model the dependency graph:
  for p in mitems(g.nodes):
    for ver in mvalidVersions p:
      if ver.req.deps.len > 0:
        b.openOpr(OrForm)
        b.addNegated ver.v # if this version is chosen, these are its dependencies
        b.add ver.req.v
        b.closeOpr # OrForm

  b.closeOpr
  result = toForm(b)

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
        if g.nodes[i].versions[activeVersion].req.hasInstallHooks:
          let (nf, found) = findNimbleFile(g, i)
          if found == 1:
            runNimScriptInstallHook c, nf, pkg.projectName
        # check for nim script builders
        for p in mitems c.plugins.builderPatterns:
          let f = p[0] % pkg.projectName
          if fileExists(f):
            runNimScriptBuilder c, p, pkg.projectName

proc solve*(c: var AtlasContext; g: var DepGraph; f: Formular) =
  var s = newSeq[BindingKind](g.idgen)
  if satisfiable(f, s):
    for i in 0 ..< g.startNodesLen:
      g.nodes[i].active = true
    for i in 0 ..< s.len:
      if s[i] == setToTrue and g.mapping.hasKey(VarId i):
        let m = g.mapping[VarId i]
        let idx = findDependencyForDep(g, m.pkg)
        g.nodes[idx].active = true
        g.nodes[idx].activeVersion = m.index
        debug c, m.pkg.projectName, "package satisfiable"
        if m.commit != "":
          withDir c, g.nodes[idx].ondisk:
            checkoutGitCommit(c, m.pkg.projectName, m.commit, FullClones in c.flags)

    if NoExec notin c.flags:
      runBuildSteps(c, g)
      #echo f

    if ListVersions in c.flags:
      info c, "../resolve", "selected:"
      for i in g.startNodesLen ..< g.nodes.len:
        for v in mitems(g.nodes[i].versions):
          let item = g.mapping[v.v]
          if s[int v.v] == setToTrue:
            info c, item.pkg.projectName, "[x] " & toString item
          else:
            info c, item.pkg.projectName, "[ ] " & toString item
      info c, "../resolve", "end of selection"
  else:
    error c, c.workspace, "version conflict; for more information use --showGraph"
    for p in mitems(g.nodes):
      var usedVersions = 0
      for ver in mvalidVersions p:
        if s[ver.v.int] == setToTrue: inc usedVersions
      if usedVersions > 1:
        for ver in mvalidVersions p:
          if s[ver.v.int] == setToTrue:
            error c, p.pkg.projectName, string(ver.version) & " required"

proc expandWithoutClone*(c: var AtlasContext; g: var DepGraph; nc: NimbleContext) =
  ## Expand the graph by adding all dependencies.
  var processed = initHashSet[PkgUrl]()
  var i = 0
  while i < g.nodes.len:
    let w {.cursor.} = g.nodes[i]

    if not processed.containsOrIncl(w.pkg):
      let (dirName, todo) = pkgUrlToDirname(g, w.pkg)
      if todo == DoNothing:
        withDir c, dirName:
          traverseDependency(c, nc, g, i, processed, CurrentCommit)
    inc i

iterator allNodes*(g: DepGraph): lent Dependency =
  for i in 0 ..< g.nodes.len: yield g.nodes[i]

iterator allActiveNodes*(g: DepGraph): lent Dependency =
  for i in 0 ..< g.nodes.len:
    if g.nodes[i].active:
      yield g.nodes[i]

iterator toposorted*(g: DepGraph): lent Dependency =
  for i in countdown(g.nodes.len-1, 0): yield g.nodes[i]

iterator directDependencies*(g: DepGraph; d: Dependency): lent Dependency =
  if d.activeVersion < d.versions.len:
    let deps {.cursor.} = d.versions[d.activeVersion].req.deps
    for dep in deps:
      let idx = findDependencyForDep(g, dep[0])
      yield g.nodes[idx]

proc getCfgPath*(g: DepGraph; d: Dependency): lent CfgPath =
  result = CfgPath d.versions[d.activeVersion].req.srcDir

proc commit*(d: Dependency): string =
  result =
    if d.activeVersion < d.versions.len: d.versions[d.activeVersion].commit
    else: ""

proc bestNimVersion*(g: DepGraph): Version =
  result = Version""
  for n in allNodes(g):
    if n.active and n.versions[n.activeVersion].req.nimVersion != Version"":
      let v = n.versions[n.activeVersion].req.nimVersion
      if v > result: result = v
