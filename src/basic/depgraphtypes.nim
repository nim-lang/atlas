
import std / [sets, paths, dirs, tables, os, strutils, streams, json, jsonutils, algorithm]

import sattypes, context, gitops, reporters, nimbleparser, pkgurls, versions

type
  DependencyVersion* = object  # Represents a specific version of a project.
    version*: Version
    commit*: string
    req*: int # index into graph.reqs so that it can be shared between versions
    v*: VarId

  Dependency* = object
    pkg*: PkgUrl
    versions*: seq[DependencyVersion]
    #v: VarId
    active*: bool
    isRoot*: bool
    isTopLevel*: bool
    status*: CloneStatus
    activeVersion*: int
    ondisk*: Path

  DepGraph* = object
    nodes*: seq[Dependency]
    reqs*: seq[Requirements]
    packageToDependency*: Table[PkgUrl, int]
    ondisk*: OrderedTable[string, Path] # URL -> dirname mapping
    reqsByDeps*: Table[Requirements, int]

const
  EmptyReqs* = 0
  UnknownReqs* = 1
  FileWorkspace* = "file://./"


proc defaultReqs(): seq[Requirements] =
  @[Requirements(deps: @[], v: NoVar), Requirements(status: HasUnknownNimbleFile, v: NoVar)]

proc toJson*(d: DepGraph): JsonNode =
  result = newJObject()
  result["nodes"] = toJson(d.nodes)
  result["reqs"] = toJson(d.reqs)

proc findNimbleFile*(g: DepGraph; idx: int): (Path, int) =
  var nimbleFile = g.nodes[idx].pkg.projectName & ".nimble"
  var found = 0
  if fileExists(nimbleFile):
    inc found
  else:
    for file in walkFiles("*.nimble"):
      nimbleFile = file
      inc found
  result = (Path(ensureMove nimbleFile), found)

type
  PackageAction* = enum
    DoNothing, DoClone

proc pkgUrlToDirname*(c: var AtlasContext; g: var DepGraph; d: Dependency): (Path, PackageAction) =
  # XXX implement namespace support here
  var dest = Path g.ondisk.getOrDefault(d.pkg.url)
  if dest.string.len == 0:
    if d.isTopLevel:
      dest = c.workspace
    else:
      let depsDir = if d.isRoot: c.workspace else: c.depsDir
      dest = depsDir / Path d.pkg.projectName
  result = (dest, if dirExists(dest): DoNothing else: DoClone)

proc toDestDir*(g: DepGraph; d: Dependency): Path =
  result = d.ondisk

proc enrichVersionsViaExplicitHash*(versions: var seq[DependencyVersion]; x: VersionInterval) =
  let commit = extractSpecificCommit(x)
  if commit.len > 0:
    for v in versions:
      if v.commit == commit: return
    versions.add DependencyVersion(version: Version"",
      commit: commit, req: EmptyReqs, v: NoVar)

iterator allNodes*(g: DepGraph): lent Dependency =
  for i in 0 ..< g.nodes.len: yield g.nodes[i]

iterator allActiveNodes*(g: DepGraph): lent Dependency =
  for i in 0 ..< g.nodes.len:
    if g.nodes[i].active:
      yield g.nodes[i]

iterator toposorted*(g: DepGraph): lent Dependency =
  for i in countdown(g.nodes.len-1, 0): yield g.nodes[i]

proc findDependencyForDep*(g: DepGraph; dep: PkgUrl): int {.inline.} =
  assert g.packageToDependency.hasKey(dep), $(dep, g.packageToDependency)
  result = g.packageToDependency.getOrDefault(dep)

iterator directDependencies*(g: DepGraph; c: var AtlasContext; d: Dependency): lent Dependency =
  if d.activeVersion >= 0 and d.activeVersion < d.versions.len:
    let deps {.cursor.} = g.reqs[d.versions[d.activeVersion].req].deps
    for dep in deps:
      let idx = findDependencyForDep(g, dep[0])
      yield g.nodes[idx]

proc getCfgPath*(g: DepGraph; d: Dependency): lent CfgPath =
  result = CfgPath g.reqs[d.versions[d.activeVersion].req].srcDir

proc commit*(d: Dependency): string =
  result =
    if d.activeVersion >= 0 and d.activeVersion < d.versions.len: d.versions[d.activeVersion].commit
    else: ""

proc bestNimVersion*(g: DepGraph): Version =
  result = Version""
  for n in allNodes(g):
    if n.active and g.reqs[n.versions[n.activeVersion].req].nimVersion != Version"":
      let v = g.reqs[n.versions[n.activeVersion].req].nimVersion
      if v > result: result = v

proc readOnDisk(c: var AtlasContext; result: var DepGraph) =
  let configFile = c.workspace / AtlasWorkspace
  var f = newFileStream($configFile, fmRead)
  if f == nil:
    return
  try:
    let j = parseJson(f, $configFile)
    let g = j["graph"]
    let n = g.getOrDefault("nodes")
    if n.isNil: return
    let nodes = jsonTo(n, typeof(result.nodes))
    for n in nodes:
      result.ondisk[n.pkg.url] = n.ondisk
      if dirExists(n.ondisk):
        if n.isRoot:
          if not result.packageToDependency.hasKey(n.pkg):
            result.packageToDependency[n.pkg] = result.nodes.len
            result.nodes.add Dependency(pkg: n.pkg, versions: @[], isRoot: true, isTopLevel: n.isTopLevel, activeVersion: -1)
  except:
    error c, configFile, "cannot read: " & $configFile

proc createGraph*(c: var AtlasContext; s: PkgUrl): DepGraph =
  result = DepGraph(nodes: @[],
    reqs: defaultReqs())
  result.packageToDependency[s] = result.nodes.len
  result.nodes.add Dependency(pkg: s, versions: @[], isRoot: true, isTopLevel: true, activeVersion: -1)
  readOnDisk(c, result)

proc createGraphFromWorkspace*(c: var AtlasContext): DepGraph =
  result = DepGraph(nodes: @[], reqs: defaultReqs())
  let configFile = c.workspace / AtlasWorkspace
  var f = newFileStream($configFile, fmRead)
  if f == nil:
    error c, configFile, "cannot open: " & $configFile
    return

  try:
    let j = parseJson(f, $configFile)
    let g = j["graph"]

    result.nodes = jsonTo(g["nodes"], typeof(result.nodes))
    result.reqs = jsonTo(g["reqs"], typeof(result.reqs))

    for i, n in mpairs(result.nodes):
      result.packageToDependency[n.pkg] = i
  except:
    error c, configFile, "cannot read: " & $configFile

proc copyFromDisk*(c: var AtlasContext; w: Dependency; destDir: Path): (CloneStatus, string) =
  var dir = w.pkg.url
  if dir.startsWith(FileWorkspace):
    dir = $c.workspace / dir.substr(FileWorkspace.len)
  #template selectDir(a, b: string): string =
  #  if dirExists(a): a else: b

  #let dir = selectDir(u & "@" & w.commit, u)
  if w.isTopLevel:
    result = (Ok, "")
  elif dirExists(dir):
    info c, destDir, "cloning: " & dir
    copyDir(dir, $destDir)
    result = (Ok, "")
  else:
    result = (NotFound, dir)
  #writeFile destDir / ThisVersion, w.commit
  #echo "WRITTEN ", destDir / ThisVersion
