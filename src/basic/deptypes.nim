import std/[unicode, paths, sha1, tables, json, jsonutils, hashes]
import sattypes, pkgurls, versions, context, compiledpatterns

export sha1, tables

type

  PackageState* = enum
    NotInitialized
    Found
    Processed
    Error

  ReleaseStatus* = enum
    Normal, HasBrokenRepo, HasBrokenNimbleFile, HasBrokenRelease, HasUnknownNimbleFile, HasBrokenDep

  Package* = ref object
    url*: PkgUrl
    state*: PackageState
    versions*: OrderedTable[PackageVersion, NimbleRelease]
    activeVersion*: PackageVersion
    ondisk*: Path
    active*: bool
    isRoot*: bool
    isTopLevel*: bool
    errors*: seq[string]

  NimbleRelease* = ref object
    version*: Version
    nimVersion*: Version
    status*: ReleaseStatus
    requirements*: seq[(PkgUrl, VersionInterval)]
    hasInstallHooks*: bool
    srcDir*: Path
    err*: string
    rid*: VarId = NoVar

  PackageVersion* = ref object
    vtag*: VersionTag
    vid*: VarId = NoVar

  DepGraph* = object
    root*: Package
    pkgs*: OrderedTable[PkgUrl, Package]

  NimbleContext* = object
    packageToDependency*: Table[PkgUrl, Package]
    overrides*: Patterns
    hasPackageList*: bool
    nameToUrl*: Table[string, PkgUrl]

const
  EmptyReqs* = 0
  UnknownReqs* = 1

  FileWorkspace* = "file://"

proc toPkgVer*(vtag: VersionTag): PackageVersion =
  result = PackageVersion(vtag: vtag)

proc version*(pv: PackageVersion): Version =
  pv.vtag.version
proc commit*(pv: PackageVersion): CommitHash =
  pv.vtag.commit

proc createUrl*(nc: NimbleContext, orig: Path): PkgUrl =
  var didReplace = false
  result = createUrlSkipPatterns($orig)

proc createUrl*(nc: NimbleContext, nameOrig: string; projectName: string = ""): PkgUrl =
  ## primary point to createUrl's from a name or argument
  ## TODO: add unit tests!
  var didReplace = false
  var name = substitute(nc.overrides, nameOrig, didReplace)
  debug "createUrl", "name:", name, "orig:", nameOrig, "patterns:", $nc.overrides
  if name.isUrl():
    result = createUrlSkipPatterns(name)
  else:
    let lname = unicode.toLower(name)
    if lname in nc.nameToUrl:
      result = nc.nameToUrl[lname]
    else:
      raise newException(ValueError, "project name not found in packages database")
  if projectName != "":
    result.projectName = projectName

proc sortVersionsAsc*(a, b: VersionTag): int =
  (if a.v < b.v: -1
  elif a.v == b.v: 0
  else: 1)

proc sortVersionsDesc*(a, b: VersionTag): int =
  (if a.v < b.v: 1
  elif a.v == b.v: 0
  else: -1)

proc sortVersionsDesc*(a, b: (VersionTag, NimbleRelease)): int =
  sortVersionsDesc(a[0], b[0])

proc sortVersionsDesc*(a, b: (PackageVersion, NimbleRelease)): int =
  sortVersionsDesc(a[0].vtag, b[0].vtag)

proc sortVersionsAsc*(a, b: (VersionTag, NimbleRelease)): int =
  sortVersionsAsc(a[0], b[0])

proc sortVersionsAsc*(a, b: (PackageVersion, NimbleRelease)): int =
  sortVersionsAsc(a[0].vtag, b[0].vtag)

proc `$`*(d: Package): string =
  d.url.projectName

proc projectName*(d: Package): string =
  d.url.projectName

proc toJsonHook*(v: (PkgUrl, VersionInterval), opt: ToJsonOptions): JsonNode =
  result = newJObject()
  result["url"] = toJsonHook(v[0])
  result["version"] = toJsonHook(v[1])

proc toJsonHook*(r: NimbleRelease, opt: ToJsonOptions = ToJsonOptions()): JsonNode =
  if r == nil:
    return newJNull()
  result = newJObject()
  result["requirements"] = toJson(r.requirements, opt)
  if r.hasInstallHooks:
    result["hasInstallHooks"] = toJson(r.hasInstallHooks, opt)
  if r.srcDir != Path "":
    result["srcDir"] = toJson(r.srcDir, opt)
  # if r.version != Version"":
  result["version"] = toJson(r.version, opt)
  # if r.vid != NoVar:
  #   result["varId"] = toJson(r.vid, opt)
  result["status"] = toJson(r.status, opt)

proc hash*(r: Package): Hash =
  ## use pkg name and url for identification and lookups
  var h: Hash = 0
  h = h !& hash(r.url)
  result = !$h

proc hash*(r: NimbleRelease): Hash =
  var h: Hash = 0
  h = h !& hash(r.version)
  h = h !& hash(r.requirements)
  h = h !& hash(r.nimVersion)
  h = h !& hash(r.hasInstallHooks)
  h = h !& hash($r.srcDir)
  h = h !& hash($r.err)
  h = h !& hash($r.status)
  result = !$h

proc `==`*(a, b: NimbleRelease): bool =
  result = true
  result = result and a.version == b.version
  result = result and a.requirements == b.requirements
  result = result and a.nimVersion == b.nimVersion
  result = result and a.hasInstallHooks == b.hasInstallHooks
  result = result and a.srcDir == b.srcDir
  result = result and a.err == b.err
  result = result and a.status == b.status

proc `$`*(r: PackageVersion): string =
  result = $(r.vtag)

proc hash*(r: PackageVersion): Hash =
  result = hash(r.vtag)
proc `==`*(a, b: PackageVersion): bool =
  result = a.vtag == b.vtag

proc toJsonHook*(t: Table[VersionTag, NimbleRelease], opt: ToJsonOptions): JsonNode =
  result = newJObject()
  for k, v in t:
    result[repr(k)] = toJson(v, opt)

proc toJsonHook*(t: OrderedTable[PackageVersion, NimbleRelease], opt: ToJsonOptions): JsonNode =
  result = newJArray()
  for k, v in t:
    var tpl = newJArray()
    tpl.add toJson(k, opt)
    tpl.add toJson(v, opt)
    result.add tpl
    # result[repr(k.vtag)] = toJson(v, opt)

proc toJsonHook*(t: OrderedTable[PkgUrl, Package], opt: ToJsonOptions): JsonNode =
  result = newJObject()
  for k, v in t:
    result[$(k)] = toJson(v, opt)

proc activeNimbleRelease*(pkg: Package): NimbleRelease =
  if pkg.activeVersion.isNil:
    result = nil
  else:
    let av = pkg.activeVersion
    result = pkg.versions[av]

type 
  VisitState = enum
    NotVisited, InProgress, Visited

proc topologicalSort*(graph: DepGraph): seq[Package] =
  ## Returns a sequence of packages in topological order
  ## Packages that are depended upon come before packages that depend on them
  result = @[]
  var visited = initTable[PkgUrl, VisitState]()
  
  # Initialize all packages as not visited
  for url, pkg in graph.pkgs:
    visited[url] = NotVisited
  
  # DFS-based topological sort
  proc visit(pkg: Package): seq[Package] =
    if visited[pkg.url] == Visited:
      return
    if visited[pkg.url] == InProgress:
      # This means we have a cycle, which shouldn't happen in a valid dependency graph
      # But we'll handle it gracefully
      return
    
    visited[pkg.url] = InProgress
    
    # Get the active release to check its dependencies
    let release = pkg.activeNimbleRelease()
    if not release.isNil:
      # Visit all dependencies first
      for (depUrl, _) in release.requirements:
        if depUrl in graph.pkgs:
          let depPkg = graph.pkgs[depUrl]
          result.add visit(depPkg)
    
    # Mark as visited and add to result
    visited[pkg.url] = Visited
    result.add(pkg)
  
  # Start with root package
  if not graph.root.isNil:
    result.add visit(graph.root)
  
  # Visit any remaining packages (disconnected or not reachable from root)
  for url, pkg in graph.pkgs:
    if visited[url] == NotVisited:
      result.add visit(pkg)

# Alternative implementation as a closure iterator
iterator topological*(graph: DepGraph): Package =
  ## Iterates through packages in topological order
  ## This implementation builds the full list first, then yields each package
  for pkg in topologicalSort(graph):
    yield pkg

proc validateDependencyGraph*(graph: DepGraph): bool =
  ## Checks if the dependency graph is valid (no cycles)
  var visited = initTable[PkgUrl, VisitState]()
  var valid = true
  
  # Initialize all packages as not visited
  for url, pkg in graph.pkgs:
    visited[url] = NotVisited
  
  proc checkCycles(pkg: Package): bool =
    if visited[pkg.url] == Visited:
      return true
    if visited[pkg.url] == InProgress:
      # Cycle detected
      return false
    
    visited[pkg.url] = InProgress
    
    # Check all dependencies
    let release = pkg.activeNimbleRelease()
    if not release.isNil:
      for (depUrl, _) in release.requirements:
        if depUrl in graph.pkgs:
          let depPkg = graph.pkgs[depUrl]
          if not checkCycles(depPkg):
            return false
    
    visited[pkg.url] = Visited
    return true
  
  # Check from all possible starting points
  for url, pkg in graph.pkgs:
    if visited[url] == NotVisited:
      if not checkCycles(pkg):
        return false
  
  return true
