
import std / [sets, paths, files, dirs, tables, os, strutils, streams, json, jsonutils, algorithm]

import sattypes, context, deptypes, gitops, reporters, nimbleparser, pkgurls, versions


# proc commit*(d: DepConstraint): CommitHash =
#   result =
#     if d.activeRelease >= 0 and d.activeRelease < d.releases.len:
#       d.releases[d.activeRelease].vtag.commit()
#     else:
#       CommitHash(h: "")

proc toJsonHook*(vid: VarId): JsonNode = toJson($(int(vid)))
proc toJsonHook*(p: Path): JsonNode = toJson($(p))

# proc defaultReqs*(): seq[Requirements] =
#   let emptyReq = Requirements(release: NimbleRelease(deps: @[]), vid: NoVar)
#   let unknownReq = Requirements(release: NimbleRelease(status: HasUnknownNimbleFile), vid: NoVar)
#   result = @[emptyReq, unknownReq]

# proc sortPackageVersions*(a, b: PackageVersion): int =
#   (if a.vtag.v < b.vtag.v: 1
#   elif a.vtag.v == b.vtag.v: 0
#   else: -1)

# proc initPackageVersion*(version: Version, commit: CommitHash, req = EmptyReqs, vid = NoVar): PackageVersion =
#   result = PackageVersion(vtag: VersionTag(c: commit, v: version), reqIdx: req, vid: vid)

# proc enrichVersionsViaExplicitHash*(releases: var seq[PackageVersion]; x: VersionInterval) =
#   let commit = extractSpecificCommit(x)
#   if not commit.isEmpty():
#     for ver in releases:
#       if ver.vtag.commit() == commit:
#         return
#     releases.add initPackageVersion(Version"", commit) 

proc dumpJson*(d: DepGraph, filename: string, full = true, pretty = true) =
  let jn = toJson(d, ToJsonOptions(enumMode: joptEnumString))
  if pretty:
    writeFile(filename, pretty(jn))
  else:
    writeFile(filename, $(jn))

proc toDestDir*(g: DepGraph; d: Package): Path =
  result = d.ondisk

iterator allNodes*(g: DepGraph): Package =
  for pkg in values(g.pkgs):
    yield pkg

iterator allActiveNodes*(g: DepGraph): Package =
  for pkg in values(g.pkgs):
    if pkg.active and not pkg.activeVersion.isNil:
      doAssert pkg.state == Processed
      yield pkg

# iterator toposorted*(g: DepGraph): lent Package =
#   for i in countdown(g.pkgs.len-1, 0):
#     yield g.nodes[i]

# proc findDependencyForDep*(g: DepGraph; dep: PkgUrl): int {.inline.} =
#   assert g.packageToDependency.hasKey(dep), $(dep, g.packageToDependency)
#   result = g.packageToDependency.getOrDefault(dep)

proc getCfgPath*(g: DepGraph; d: Package): lent CfgPath =
  result = CfgPath g.pkgs[d.url].activeNimbleRelease().srcDir

# proc bestNimVersion*(g: DepGraph): Version =
#   result = Version""
#   for n in allNodes(g):
#     if n.active and g.reqs[n.versions[n.activeRelease].req].nimVersion != Version"":
#       let v = g.reqs[n.versions[n.activeRelease].req].nimVersion
#       if v > result: result = v

# proc readOnDisk(result: var DepGraph) =
#   let configFile = context().workspace / AtlasWorkspace
#   var f = newFileStream($configFile, fmRead)
#   if f == nil:
#     return
#   try:
#     let j = parseJson(f, $configFile)
#     let g = j["graph"]
#     let n = g.getOrDefault("nodes")
#     if n.isNil: return
#     let nodes = jsonTo(n, typeof(result.pkgs))
#     for n in nodes:
#       # result.ondisk[n.url.url] = n.ondisk
#       if dirExists(n.dep.ondisk):
#         if n.dep.isRoot:
#           if not result.packageToDependency.hasKey(n.dep.url):
#             result.packageToDependency[n.dep.url] = result.nodes.len
#             result.nodes.add DepConstraint(dep: n.dep, activeRelease: -1)
#   except:
#     warn configFile, "couldn't load graph from: " & $configFile

# proc createGraph*(s: PkgUrl): DepGraph =
#   result = DepGraph(nodes: @[], reqs: defaultReqs())
#   result.packageToDependency[s] = result.nodes.len
#   let dep = Package(pkg: s, isRoot: true, isTopLevel: true)
#   result.nodes.add DepConstraint(dep: dep, versions: @[], activeRelease: -1)
#   readOnDisk(result)

# proc createGraphFromWorkspace*(): DepGraph =
#   result = DepGraph(nodes: @[], reqs: defaultReqs())
#   let configFile = context().workspace / AtlasWorkspace
#   var f = newFileStream($configFile, fmRead)
#   if f == nil:
#     error configFile, "cannot open: " & $configFile
#     return
#   try:
#     let j = parseJson(f, $configFile)
#     let g = j["graph"]
#     result.nodes = jsonTo(g["nodes"], typeof(result.nodes))
#     result.reqs = jsonTo(g["reqs"], typeof(result.reqs))
#     for i, n in mpairs(result.nodes):
#       result.packageToDependency[n.dep.url] = i
#   except:
#     warn configFile, "couldn't load graph from: " & $configFile
