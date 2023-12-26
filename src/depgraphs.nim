#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std / [sets, tables, os, strutils]

import context, sat, nameresolver, configutils, gitops, runners, osutils

type
  Requirements* = ref object
    deps*: seq[(Package, VersionInterval)]
    hasInstallHooks*: bool
    srcDir: string
    nimVersion: Version
    v: VarId

  DependencyStatus* = enum
    Normal, HasBrokenNimbleFile, HasUnknownNimbleFile, HasBrokenDep

  DependencyVersion* = object  # Represents a specific version of a project.
    version*: Version
    commit*: string
    req*: Requirements
    status*: DependencyStatus
    v: VarId

  Dependency* = object
    pkg*: Package
    versions*: seq[DependencyVersion]
    v: VarId
    active*: bool
    activeVersion*: int
    status: CloneStatus

  SatVarInfo* = object # attached information for a SAT variable
    pkg: Package
    commit: string
    version: Version
    index: int

  DepGraph* = object
    nodes: seq[Dependency]
    idgen: int32
    startNodesLen: int
    mapping: Table[VarId, SatVarInfo]
    packageToDependency: Table[Package, int]

proc createGraph*(c: var AtlasContext; startSet: openArray[Package]): DepGraph =
  result = DepGraph(nodes: @[], idgen: 0'i32, startNodesLen: startSet.len)
  for s in startSet:
    result.packageToDependency[s] = result.nodes.len
    result.nodes.add Dependency(pkg: s, versions: @[], v: VarId(result.idgen))
    inc result.idgen

proc createGraph*(c: var AtlasContext; s: Package): DepGraph =
  result = DepGraph(nodes: @[], idgen: 0'i32, startNodesLen: 1)
  result.packageToDependency[s] = result.nodes.len
  result.nodes.add Dependency(pkg: s, versions: @[], v: VarId(result.idgen))
  inc result.idgen

type
  TraversalMode = enum
    AllReleases,
    CurrentCommit

iterator releases(c: var AtlasContext; m: TraversalMode): (string, Version) =
  yield ("#head", Version"#head") # dummy implementation for now
  #let tags = collectTaggedVersions(c)
  #for x in tags:
  #  gitCheckout(...)
  #  yield ()

proc parseNimbleFile(c: var AtlasContext; proj: var Dependency; nimble: PackageNimble) =
  let nimbleInfo = parseNimble(c, nimble)

  proj.versions[^1].req.hasInstallHooks = nimbleInfo.hasInstallHooks
  proj.versions[^1].req.srcDir = nimbleInfo.srcDir

  for r in nimbleInfo.requires:
    var i = 0
    while i < r.len and r[i] notin {'#', '<', '=', '>'} + Whitespace: inc i
    let name = r.substr(0, i-1)
    let pkg = c.resolvePackage(name)

    var err = pkg.name.string.len == 0
    if len($pkg.url) == 0 or not pkg.exists:
      #error c, pkg, "invalid pkgUrl in nimble file: " & name
      proj.versions[^1].status = HasBrokenDep

    let query = parseVersionInterval(r, i, err) # update err

    if err:
      if proj.versions[^1].status != HasBrokenDep:
        proj.versions[^1].status = HasBrokenNimbleFile
      #error c, pkg, "invalid 'requires' syntax in nimble file: " & r
    else:
      if cmpIgnoreCase(pkg.name.string, "nim") == 0:
        let v = extractGeQuery(query)
        if v != Version"":
          proj.versions[^1].req.nimVersion = v
      else:
        proj.versions[^1].req.deps.add (pkg, query)

proc traverseDependency(c: var AtlasContext; g: var DepGraph; idx: int;
                        processed: var HashSet[PackageRepo];
                        m: TraversalMode) =
  var lastNimbleContents = "<invalid content>"

  for commit, release in releases(c, m):
    var nimbleFile = g.nodes[idx].pkg.name.string & ".nimble"
    var found = 0
    if fileExists(nimbleFile):
      inc found
    else:
      for file in walkFiles("*.nimble"):
        nimbleFile = file
        inc found
    var pv = DependencyVersion(
      version: release,
      commit: commit,
      req: Requirements(deps: @[], v: NoVar),
      status: Normal)
    if found != 1:
      pv.status = HasUnknownNimbleFile
    else:
      let nimbleContents = readFile(nimbleFile)
      if lastNimbleContents == nimbleContents:
        pv.req = g.nodes[idx].versions[^1].req
        pv.status = g.nodes[idx].versions[^1].status
      else:
        parseNimbleFile(c, g.nodes[idx], PackageNimble(nimbleFile))
        lastNimbleContents = ensureMove nimbleContents

      if pv.status == Normal:
        for dep, _ in items(pv.req.deps):
          if not dep.exists:
            pv.status = HasBrokenDep
          elif not processed.containsOrIncl(dep.repo):
            g.packageToDependency[dep] = g.nodes.len
            g.nodes.add Dependency(pkg: dep, versions: @[])

    g.nodes[idx].versions.add ensureMove pv

const
  FileProtocol = "file"

proc copyFromDisk(c: var AtlasContext; w: Dependency; destDir: string): (CloneStatus, string) =
  var u = w.pkg.url.getFilePath()
  if u.startsWith("./"): u = c.workspace / u.substr(2)
  template selectDir(a, b: string): string =
    if dirExists(a): a else: b

  #let dir = selectDir(u & "@" & w.commit, u)
  let dir = u
  if dirExists(dir):
    copyDir(dir, destDir)
    result = (Ok, "")
  else:
    result = (NotFound, dir)
  #writeFile destDir / ThisVersion, w.commit
  #echo "WRITTEN ", destDir / ThisVersion

proc expand*(c: var AtlasContext; g: var DepGraph; m: TraversalMode) =
  ## Expand the graph by adding all dependencies.
  var processed = initHashSet[PackageRepo]()
  var i = 0
  while i < g.nodes.len:
    let w {.cursor.} = g.nodes[i]

    if not processed.containsOrIncl(w.pkg.repo):
      if not dirExists(w.pkg.path.string):
        withDir c, (if i < g.startNodesLen: c.workspace else: c.depsDir):
          let (status, _) =
            if w.pkg.url.scheme == FileProtocol:
              copyFromDisk(c, w, w.pkg.path.string)
            else:
              info(c, w.pkg, "cloning: " & $w.pkg.url)
              cloneUrl(c, w.pkg.url, w.pkg.path.string, false)

          g.nodes[i].status = status

      withDir c, w.pkg:
        traverseDependency(c, g, i, processed, m)
    inc i

proc findDependencyForDep(g: DepGraph; dep: Package): int {.inline.} =
  assert g.packageToDependency.hasKey(dep)
  result = g.packageToDependency.getOrDefault(dep)

iterator mvalidVersions*(p: var Dependency): var DependencyVersion =
  for v in mitems p.versions:
    if v.status == Normal: yield v

proc toFormular*(g: var DepGraph; algo: ResolutionAlgorithm): Formular =
  # Key idea: use a SAT variable for every `Requirements` object, which are
  # shared.
  var b: Builder
  b.openOpr(AndForm)

  # all active nodes must be true:
  for i in 0 ..< g.startNodesLen:
    b.add newVar(g.nodes[i].v)

  for p in mitems(g.nodes):
    # if Package p is installed, pick one of its concrete versions, but not versions
    # that are errornous:
    # A -> (exactly one of: A1, A2, A3)
    b.openOpr(OrForm)
    b.openOpr(NotForm)
    b.add newVar(p.v)
    b.closeOpr # NotForm

    b.openOpr(ExactlyOneOfForm)
    var i = 0
    for ver in mitems p.versions:
      ver.v = VarId(g.idgen)
      g.mapping[ver.v] = SatVarInfo(pkg: p.pkg, commit: ver.commit, version: ver.version, index: i)

      inc g.idgen
      b.add newVar(ver.v)
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
      b.add newVar(ver.req.v)
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
              b.add newVar(av.versions[j].v)
              break
          #mapping.add (g.nodes[i].pkg, commit, v)
        elif algo == MinVer:
          for j in countup(0, av.versions.len-1):
            if q.matches(av.versions[j].version):
              b.add newVar(av.versions[j].v)
        else:
          for j in countdown(av.versions.len-1, 0):
            if q.matches(av.versions[j].version):
              b.add newVar(av.versions[j].v)
        b.closeOpr # ExactlyOneOfForm

      b.closeOpr # AndForm
      b.closeOpr # EqForm

  # Model the dependency graph:
  for p in mitems(g.nodes):
    for ver in mvalidVersions p:
      if ver.req.deps.len > 0:
        b.openOpr(OrForm)
        b.openOpr(NotForm)
        b.add newVar(ver.v) # if this version is chosen, these are its dependencies
        b.closeOpr # NotForm

        b.add newVar(ver.req.v)
        b.closeOpr # OrForm

  b.closeOpr
  result = toForm(b)

proc toString(x: SatVarInfo): string =
  "(" & x.pkg.repo.string & ", " & $x.version & ")"

proc runBuildSteps*(c: var AtlasContext; g: var DepGraph) =
  ## execute build steps for the dependency graph
  ##
  ## `countdown` suffices to give us some kind of topological sort:
  ##
  for i in countdown(g.nodes.len-1, 0):
    if g.nodes[i].active:
      let pkg = g.nodes[i].pkg
      tryWithDir c, pkg:
        # check for install hooks
        let activeVersion = g.nodes[i].activeVersion
        if g.nodes[i].versions[activeVersion].req.hasInstallHooks:
          let nf = pkg.nimble
          runNimScriptInstallHook c, nf, pkg
        # check for nim script builders
        for p in mitems c.plugins.builderPatterns:
          let f = p[0] % pkg.repo.string
          if fileExists(f):
            runNimScriptBuilder c, p, pkg

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
        let destDir = m.pkg.name.string
        debug c, m.pkg, "package satisfiable: " & $m.pkg
        withDir c, m.pkg:
          checkoutGitCommit(c, PackageDir(destDir), m.commit)

    if NoExec notin c.flags:
      runBuildSteps(c, g)
      #echo f

    if ListVersions in c.flags:
      info c, toRepo("../resolve"), "selected:"
      for i in g.startNodesLen ..< g.nodes.len:
        for v in mitems(g.nodes[i].versions):
          let item = g.mapping[v.v]
          if s[int v.v] == setToTrue:
            info c, item.pkg, "[x] " & toString item
          else:
            info c, item.pkg, "[ ] " & toString item
      info c, toRepo("../resolve"), "end of selection"
  else:
    error c, toRepo(c.workspace), "version conflict; for more information use --showGraph"
    for p in mitems(g.nodes):
      var usedVersions = 0
      for ver in mvalidVersions p:
        if s[ver.v.int] == setToTrue: inc usedVersions
      if usedVersions > 1:
        for ver in mvalidVersions p:
          if s[ver.v.int] == setToTrue:
            error c, p.pkg, string(ver.version) & " required"

proc expandWithoutClone*(c: var AtlasContext; g: var DepGraph) =
  ## Expand the graph by adding all dependencies.
  var processed = initHashSet[PackageRepo]()
  var i = 0
  while i < g.nodes.len:
    let w {.cursor.} = g.nodes[i]

    if not processed.containsOrIncl(w.pkg.repo):
      if dirExists(w.pkg.path.string):
        withDir c, w.pkg:
          traverseDependency(c, g, i, processed, CurrentCommit)
    inc i

iterator allNodes*(g: DepGraph): lent Dependency =
  for i in 0 ..< g.nodes.len: yield g.nodes[i]

iterator toposorted*(g: DepGraph): lent Dependency =
  for i in countdown(g.nodes.len-1, 0): yield g.nodes[i]

iterator directDependencies*(g: DepGraph; d: Dependency): lent Dependency =
  let deps {.cursor.} = d.versions[d.activeVersion].req.deps
  for dep in deps:
    let idx = findDependencyForDep(g, dep[0])
    yield g.nodes[idx]

proc getCfgPath*(g: DepGraph; d: Dependency): lent CfgPath =
  result = CfgPath d.versions[d.activeVersion].req.srcDir

proc commit*(d: Dependency): string =
  d.versions[d.activeVersion].commit

proc bestNimVersion*(g: DepGraph): Version =
  result = Version""
  for n in allNodes(g):
    if n.active and n.versions[n.activeVersion].req.nimVersion != Version"":
      let v = n.versions[n.activeVersion].req.nimVersion
      if v > result: result = v
