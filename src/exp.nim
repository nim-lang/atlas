#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std / [sets, tables, os, strutils]

import context, sat, nameresolver, configutils, gitops

type
  DepDescription* = ref object
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
    desc*: DepDescription
    status*: DependencyStatus
    v: VarId

  Dependency* = object
    pkg*: Package
    versions*: seq[DependencyVersion]
    v: VarId

  DepGraph* = object
    nodes: seq[Dependency]
    idgen: int32
    startNodesLen: int
    mapping: Table[VarId, (Package, string, Version)]
    packageToDependency: Table[Package, int]

proc createGraph*(startSet: openArray[Package]): DepGraph =
  result = DepGraph(nodes: @[], idgen: 0'i32, startNodesLen: startSet.len)
  for s in startSet:
    result.packageToDependency[s] = result.nodes.len
    result.nodes.add Dependency(pkg: s, versions: @[], v: VarId(result.idgen))
    inc result.idgen

iterator allReleases(c: var AtlasContext): (string, Version) =
  yield ("#head", Version"#head") # dummy implementation for now

proc parseNimbleFile(c: var AtlasContext; proj: var Dependency; nimble: PackageNimble) =
  # XXX Fix code duplication. Copied from `traversal.nim`:
  let nimbleInfo = parseNimble(c, nimble)

  proj.versions[^1].desc.hasInstallHooks = nimbleInfo.hasInstallHooks
  proj.versions[^1].desc.srcDir = nimbleInfo.srcDir

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
          proj.versions[^1].desc.nimVersion = v
      else:
        proj.versions[^1].desc.deps.add (pkg, query)

proc traverseDependency(c: var AtlasContext; g: var DepGraph; idx: int;
                     processed: var HashSet[PackageRepo]) =
  var lastNimbleContents = "<invalid content>"

  for commit, release in allReleases(c):
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
      desc: DepDescription(deps: @[], v: NoVar),
      status: Normal)
    if found != 1:
      pv.status = HasUnknownNimbleFile
    else:
      let nimbleContents = readFile(nimbleFile)
      if lastNimbleContents == nimbleContents:
        pv.desc = g.nodes[idx].versions[^1].desc
        pv.status = g.nodes[idx].versions[^1].status
      else:
        parseNimbleFile(c, g.nodes[idx], PackageNimble(nimbleFile))
        lastNimbleContents = ensureMove nimbleContents

      if pv.status == Normal:
        for dep, _ in items(pv.desc.deps):
          if not dep.exists:
            pv.status = HasBrokenDep
          elif not processed.containsOrIncl(dep.repo):
            g.packageToDependency[dep] = g.nodes.len
            g.nodes.add Dependency(pkg: dep, versions: @[])

    g.nodes[idx].versions.add ensureMove pv

proc expand*(c: var AtlasContext; g: var DepGraph) =
  ## Expand the graph by adding all dependencies.
  var processed = initHashSet[PackageRepo]()
  var i = 0
  while i < g.nodes.len:
    let w {.cursor.} = g.nodes[i]

    if not processed.containsOrIncl(w.pkg.repo):
      if not dirExists(w.pkg.path.string):
        withDir c, (if i < g.startNodesLen: c.workspace else: c.depsDir):
          info(c, w.pkg, "cloning: " & $w.pkg.url)
          let (status, err) = cloneUrl(c, w.pkg.url, w.pkg.path.string, false)
          #g.nodes[i].status = status

      withDir c, w.pkg:
        traverseDependency(c, g, i, processed)
    inc i

proc findDependencyForDep(g: DepGraph; dep: Package): int {.inline.} =
  assert g.packageToDependency.hasKey(dep)
  result = g.packageToDependency.getOrDefault(dep)

iterator mvalidVersions*(p: var Dependency): var DependencyVersion =
  for v in mitems p.versions:
    if v.status == Normal: yield v

proc toFormular*(g: var DepGraph; algo: ResolutionAlgorithm): Formular =
  # Key idea: use a SAT variable for every `DepDescription` object, which are
  # shared.
  var idgen = g.idgen

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
    for ver in mitems p.versions:
      ver.v = VarId(idgen)
      g.mapping[ver.v] = (p.pkg, ver.commit, ver.version)

      inc idgen
      b.add newVar(ver.v)

    b.closeOpr # ExactlyOneOfForm
    b.closeOpr # OrForm

  # Model the dependency graph:
  for p in mitems(g.nodes):
    for ver in mvalidVersions p:
      if isValid(ver.desc.v):
        # already covered this sub-formula (ref semantics!)
        continue
      ver.desc.v = VarId(idgen)
      inc idgen

      b.openOpr(EqForm)
      b.add newVar(ver.desc.v)
      b.openOpr(AndForm)

      for dep, query in items ver.desc.deps:
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
      if ver.desc.deps.len > 0:
        b.openOpr(OrForm)
        b.openOpr(NotForm)
        b.add newVar(ver.v) # if this version is chosen, these are its dependencies
        b.closeOpr # NotForm

        b.add newVar(ver.desc.v)
        b.closeOpr # OrForm

  b.closeOpr
  result = toForm(b)

proc solve(c: var AtlasContext; g: var DepGraph; f: Formular) =
  var s = newSeq[BindingKind](g.idgen)
  if satisfiable(f, s):
    for i in 0 ..< s.len:
      if s[i] == setToTrue and g.mapping.hasKey(VarId i):
        let pkg = g.mapping[VarId i][0]
        let destDir = pkg.name.string
        debug c, pkg, "package satisfiable: " & $pkg
        withDir c, pkg:
          checkoutGitCommit(c, PackageDir(destDir), g.mapping[VarId i][1])
    #[
    if NoExec notin c.flags:
      runBuildSteps(c, g)
      #echo f
    if ListVersions in c.flags:
      info c, toRepo("../resolve"), "selected:"
      for i in g.nodes.len..<s.len:
        let item = mapping[i - g.nodes.len]
        if s[i] == setToTrue:
          info c, item[0], "[x] " & toString item
        else:
          info c, item[0], "[ ] " & toString item
      info c, toRepo("../resolve"), "end of selection"
    ]#
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
