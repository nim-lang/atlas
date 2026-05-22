import std/[paths, tables, hashes, sets]
import sattypes, pkgurls, versions, context

export tables

type

  PackageState* = enum
    NotInitialized
    LazyDeferred
    DoLoad
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
    activeFeatures*: seq[string]
    module*: string
    ondisk*: Path
    subdir*: Path
    nimbleFile*: Path
    active*: bool
    name*: string
    isOfficial*: bool
    isAtlasProject*: bool # true if the package is an atlas project
    isFork*: bool
    isRoot*, isLocalOnly*: bool
    errors*: seq[string]
    originHead*: CommitHash

  NimbleRelease* = ref object
    name*: string
    version*: Version
    author*: string
    description*: string
    license*: string
    nimVersion*: Version
    status*: ReleaseStatus
    requirements*: seq[(PkgUrl, VersionInterval)]
    reqsByFeatures*: Table[PkgUrl, HashSet[string]]
    hasInstallHooks*: bool
    srcDir*: Path
    binDir*: Path
    skipDirs*: seq[string]
    skipFiles*: seq[string]
    skipExt*: seq[string]
    installDirs*: seq[string]
    installFiles*: seq[string]
    installExt*: seq[string]
    bin*: seq[string]
    namedBin*: Table[string, string]
    backend*: string
    hasBin*: bool
    err*: string
    features*: Table[string, seq[(PkgUrl, VersionInterval)]]
    featureVars*: Table[string, VarId]

  PackageVersion* = ref object
    vtag*: VersionTag
    vid*: VarId = NoVar

  DepGraph* = object
    mode*: TraversalMode
    root*: Package
    pkgs*: OrderedTable[PkgUrl, Package]

  TraversalMode* = enum
    AllReleases,
    ExplicitVersions,
    CurrentCommit

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

proc sortVersionsDesc*(a, b: (VersionTag, NimbleRelease)): int =
  sortVersionsDesc(a[0], b[0])

proc sortVersionsDesc*(a, b: (PackageVersion, NimbleRelease)): int =
  sortVersionsDesc(a[0].vtag, b[0].vtag)

proc sortVersionsAsc*(a, b: (VersionTag, NimbleRelease)): int =
  sortVersionsAsc(a[0], b[0])

proc sortVersionsAsc*(a, b: (PackageVersion, NimbleRelease)): int =
  sortVersionsAsc(a[0].vtag, b[0].vtag)

proc `$`*(d: Package): string =
  if d.name.len > 0: d.name
  else: d.url.projectName()

proc projectName*(d: Package): string =
  if d.name.len > 0: d.name
  else: d.url.projectName()

proc remoteName*(d: Package): string =
  d.url.projectName()

proc hash*(r: Package): Hash =
  ## use pkg name and url for identification and lookups
  var h: Hash = 0
  h = h !& hash(r.url)
  result = !$h

proc hash*(r: NimbleRelease): Hash =
  var h: Hash = 0
  for _, val in fieldPairs(r[]):
    h = h !& hash(val)
  result = !$h

proc `==`*(a, b: NimbleRelease): bool =
  for _, valA, valB in fieldPairs(a[], b[]):
    if valA != valB:
      return false
  result = true

proc `$`*(r: PackageVersion): string =
  result = $(r.vtag)

proc hash*(r: PackageVersion): Hash =
  result = hash(r.vtag)
proc `==`*(a, b: PackageVersion): bool =
  result = a.vtag == b.vtag

proc activeNimbleRelease*(pkg: Package): NimbleRelease =
  if pkg.activeVersion.isNil:
    result = nil
  else:
    let av = pkg.activeVersion
    result = pkg.versions[av]

proc toReporterName*(pkg: Package): string =
  if pkg.isNil: "nil"
  else: pkg.url.fullName()

proc findRelease*(pkg: Package, v: VersionInterval): NimbleRelease =
  for vtag, release in pkg.versions:
    if v.matches(vtag.vtag):
      return release
  result = nil

proc matches*(v: VersionInterval, pkgVer: PackageVersion): bool =
  v.matches(pkgVer.vtag)
