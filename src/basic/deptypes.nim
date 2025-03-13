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
    module*: string
    ondisk*: Path
    nimbleFile*: Path
    active*: bool
    isRoot*: bool
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
  d.url.fullName()

proc projectName*(d: Package): string =
  d.url.projectName()

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

proc toReporterName*(pkg: Package): string =
  if pkg.isNil: "nil"
  else: pkg.url.fullName()

proc findRelease*(pkg: Package, v: VersionInterval): NimbleRelease =
  for vtag, release in pkg.versions:
    if v.matches(vtag.vtag):
      return release
  result = nil
