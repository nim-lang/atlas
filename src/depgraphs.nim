#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std / [sets, tables, os, strutils, streams, json, jsonutils]

import context, sat, gitops, runners, reporters, nimbleparser, pkgurls, cloner

type
  DependencyVersion* = object  # Represents a specific version of a project.
    version*: Version
    commit*: string
    req*: int # index into graph.reqs so that it can be shared between versions
    v: VarId

  Dependency* = object
    pkg*: PkgUrl
    versions*: seq[DependencyVersion]
    v: VarId
    active*: bool
    isRoot*: bool
    isTopLevel*: bool
    status: CloneStatus
    activeVersion*: int
    ondisk*: string

  DepGraph* = object
    nodes: seq[Dependency]
    reqs: seq[Requirements]
    idgen: int32
    startNodesLen: int
    packageToDependency: Table[PkgUrl, int]

const
  EmptyReqs = 0
  UnknownReqs = 1

proc defaultReqs(): seq[Requirements] =
  @[Requirements(deps: @[], v: NoVar), Requirements(status: HasUnknownNimbleFile)]

proc createGraph*(c: var AtlasContext; startSet: openArray[PkgUrl]): DepGraph =
  result = DepGraph(nodes: @[], idgen: 0'i32,
    startNodesLen: startSet.len,
    reqs: defaultReqs())
  for s in startSet:
    result.packageToDependency[s] = result.nodes.len
    result.nodes.add Dependency(pkg: s, versions: @[], v: VarId(result.idgen), isRoot: true)
    inc result.idgen

proc createGraph*(c: var AtlasContext; s: PkgUrl): DepGraph =
  result = DepGraph(nodes: @[], idgen: 0'i32,
    startNodesLen: 1,
    reqs: defaultReqs())
  result.packageToDependency[s] = result.nodes.len
  result.nodes.add Dependency(pkg: s, versions: @[], v: VarId(result.idgen), isRoot: true, isTopLevel: true)
  inc result.idgen

proc toJson*(d: DepGraph): JsonNode =
  result = newJObject()
  result["nodes"] = toJson(d.nodes)
  result["reqs"] = toJson(d.reqs)

proc createGraphFromWorkspace*(c: var AtlasContext): DepGraph =
  result = DepGraph(nodes: @[], idgen: 0'i32, startNodesLen: 0, reqs: defaultReqs())
  let configFile = c.workspace / AtlasWorkspace
  var f = newFileStream(configFile, fmRead)
  if f == nil:
    error c, configFile, "cannot open: " & configFile
    return

  try:
    let j = parseJson(f, configFile)
    let g = j["graphs"]

    result.nodes = jsonTo(g["nodes"], typeof(result.nodes))
    result.reqs = jsonTo(g["reqs"], typeof(result.reqs))

    for i, n in mpairs(result.nodes):
      result.packageToDependency[n.pkg] = i
      if n.isRoot: result.startNodesLen = i + 1
  except:
    error c, configFile, "cannot read: " & configFile


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
          if status == 0:
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
      req: EmptyReqs)
    if found != 1:
      pv.req = UnknownReqs
    else:
      let nimbleContents = readFile(nimbleFile)
      if lastNimbleContents == nimbleContents:
        pv.req = g.nodes[idx].versions[^1].req
      else:
        pv.req = g.reqs.len
        g.reqs.add parseNimbleFile(nc, nimbleFile, c.overrides)
        lastNimbleContents = ensureMove nimbleContents

      if g.reqs[pv.req].status == Normal:
        for dep, _ in items(g.reqs[pv.req].deps):
          if not g.packageToDependency.hasKey(dep):
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

proc pkgUrlToDirname(c: var AtlasContext; g: var DepGraph; d: Dependency): (string, string, PackageAction) =
  # XXX implement namespace support here
  let depsDir = if d.isTopLevel: "" elif d.isRoot: c.workspace else: c.depsDir
  let dest = depsDir / d.pkg.projectName
  result = (d.pkg.dir, dest, if dirExists(dest): DoNothing else: DoClone)

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
      let (src, dest, todo) = pkgUrlToDirname(c, g, w)
      g.nodes[i].ondisk = dest
      if todo == DoClone:
        info(c, dest, "cloning: " & src)
        let (status, _) =
          if w.pkg.isFileProtocol:
            copyFromDisk(c, w, g.nodes[i].ondisk)
          else:
            cloneUrl(c, w.pkg, g.nodes[i].ondisk, false)
        g.nodes[i].status = status

      if g.nodes[i].status == Ok:
        withDir c, dest:
          traverseDependency(c, nc, g, i, processed, m)
    inc i

proc findDependencyForDep(g: DepGraph; dep: PkgUrl): int {.inline.} =
  assert g.packageToDependency.hasKey(dep), $(dep, g.packageToDependency)
  result = g.packageToDependency.getOrDefault(dep)

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

proc toFormular*(c: var AtlasContext; g: var DepGraph; algo: ResolutionAlgorithm): Form =
  # Key idea: use a SAT variable for every `Requirements` object, which are
  # shared.
  result = Form()
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
      result.mapping[ver.v] = SatVarInfo(pkg: p.pkg, commit: ver.commit, version: ver.version, index: i)

      inc g.idgen
      b.add ver.v
      inc i

    b.closeOpr # ExactlyOneOfForm
    b.closeOpr # OrForm

  # Model the dependency graph:
  for p in mitems(g.nodes):
    for ver in mvalidVersions(p, g):
      if isValid(g.reqs[ver.req].v):
        # already covered this sub-formula (ref semantics!)
        continue
      g.reqs[ver.req].v = VarId(g.idgen)
      inc g.idgen

      b.openOpr(EqForm)
      b.add g.reqs[ver.req].v
      b.openOpr(AndForm)

      for dep, query in items g.reqs[ver.req].deps:
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
    for ver in mvalidVersions(p, g):
      if g.reqs[ver.req].deps.len > 0:
        b.openOpr(OrForm)
        b.addNegated ver.v # if this version is chosen, these are its dependencies
        b.add g.reqs[ver.req].v
        b.closeOpr # OrForm

  b.closeOpr
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
        if g.reqs[g.nodes[i].versions[activeVersion].req].hasInstallHooks:
          let (nf, found) = findNimbleFile(g, i)
          if found == 1:
            runNimScriptInstallHook c, nf, pkg.projectName
        # check for nim script builders
        for p in mitems c.plugins.builderPatterns:
          let f = p[0] % pkg.projectName
          if fileExists(f):
            runNimScriptBuilder c, p, pkg.projectName

proc solve*(c: var AtlasContext; g: var DepGraph; f: Form) =
  var s = newSeq[BindingKind](g.idgen)
  if satisfiable(f.f, s):
    for i in 0 ..< g.startNodesLen:
      g.nodes[i].active = true
    for i in 0 ..< s.len:
      if s[i] == setToTrue and f.mapping.hasKey(VarId i):
        let m = f.mapping[VarId i]
        let idx = findDependencyForDep(g, m.pkg)
        g.nodes[idx].active = true
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
      for i in g.startNodesLen ..< g.nodes.len:
        for v in mitems(g.nodes[i].versions):
          let item = f.mapping[v.v]
          if s[int v.v] == setToTrue:
            info c, item.pkg.projectName, "[x] " & toString item
          else:
            info c, item.pkg.projectName, "[ ] " & toString item
      info c, "../resolve", "end of selection"
  else:
    error c, c.workspace, "version conflict; for more information use --showGraph"
    for p in mitems(g.nodes):
      var usedVersions = 0
      for ver in mvalidVersions(p, g):
        if s[ver.v.int] == setToTrue: inc usedVersions
      if usedVersions > 1:
        for ver in mvalidVersions(p, g):
          if s[ver.v.int] == setToTrue:
            error c, p.pkg.projectName, string(ver.version) & " required"

proc expandWithoutClone*(c: var AtlasContext; g: var DepGraph; nc: NimbleContext) =
  ## Expand the graph by adding all dependencies.
  var processed = initHashSet[PkgUrl]()
  var i = 0
  while i < g.nodes.len:
    let w {.cursor.} = g.nodes[i]

    if not processed.containsOrIncl(w.pkg):
      let (_, dest, todo) = pkgUrlToDirname(c, g, w)
      if todo == DoNothing:
        withDir c, dest:
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

iterator directDependencies*(g: DepGraph; c: var AtlasContext; d: Dependency): lent Dependency =
  if d.activeVersion < d.versions.len:
    let deps {.cursor.} = g.reqs[d.versions[d.activeVersion].req].deps
    for dep in deps:
      let idx = findDependencyForDep(g, dep[0])
      yield g.nodes[idx]

proc getCfgPath*(g: DepGraph; d: Dependency): lent CfgPath =
  result = CfgPath g.reqs[d.versions[d.activeVersion].req].srcDir

proc commit*(d: Dependency): string =
  result =
    if d.activeVersion < d.versions.len: d.versions[d.activeVersion].commit
    else: ""

proc bestNimVersion*(g: DepGraph): Version =
  result = Version""
  for n in allNodes(g):
    if n.active and g.reqs[n.versions[n.activeVersion].req].nimVersion != Version"":
      let v = g.reqs[n.versions[n.activeVersion].req].nimVersion
      if v > result: result = v