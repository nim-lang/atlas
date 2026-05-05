import std/[json, jsonutils, paths, tables, sets, strutils]
import sattypes, deptypes, pkgurls, versions, nimblecontext

export json, jsonutils

proc toJsonHook*(v: VersionInterval): JsonNode = toJson($(v))
proc toJsonHook*(v: Version): JsonNode = toJson($v)
proc toJsonHook*(v: CommitHash): JsonNode = toJson($v)
proc toJsonHook*(v: VersionTag): JsonNode = toJson(repr(v))

proc fromJsonHook*(a: var VersionInterval; b: JsonNode; opt = Joptions()) =
  var err = false
  a = parseVersionInterval(b.getStr(), 0, err)


proc fromJsonHook*(a: var Version; b: JsonNode; opt = Joptions()) =
  a = toVersion(b.getStr())

proc fromJsonHook*(a: var CommitHash; b: JsonNode; opt = Joptions()) =
  a = toCommitHash(b.getStr())

proc fromJsonHook*(a: var VersionTag; b: JsonNode; opt = Joptions()) =
  var raw = b.getStr()
  var isTip = false
  if raw.endsWith("^"):
    isTip = true
    raw = raw[0..^2]
  a = toVersionTag(raw)
  a.isTip = isTip
proc toJsonHook*(v: PkgUrl): JsonNode =
  %($(v))

proc fromJsonHook*(a: var PkgUrl; b: JsonNode; opt = Joptions()) =
  a = toPkgUriRaw(parseUri(b.getStr()))

proc toJsonHook*(vid: VarId): JsonNode = toJson(int(vid))

proc fromJsonHook*(a: var VarId; b: JsonNode; opt = Joptions()) =
  a = VarId(int(b.getInt()))

proc toJsonHook*(p: Path): JsonNode = toJson($(p))

proc fromJsonHook*(a: var Path; b: JsonNode; opt = Joptions()) =
  a = Path(b.getStr())

proc toJsonHook*(v: (PkgUrl, VersionInterval), opt: ToJsonOptions): JsonNode =
  result = newJObject()
  result["url"] = toJsonHook(v[0])
  result["version"] = toJsonHook(v[1])

proc fromJsonHook*(a: var (PkgUrl, VersionInterval); b: JsonNode; opt = Joptions()) =
  a[0].fromJson(b["url"])
  a[1].fromJson(b["version"])

proc toJsonHook*(r: NimbleRelease, opt: ToJsonOptions): JsonNode
proc fromJsonHook*(r: var NimbleRelease; b: JsonNode; opt = Joptions())

proc toJsonHook*(t: OrderedTable[PackageVersion, NimbleRelease], opt: ToJsonOptions): JsonNode =
  result = newJArray()
  for k, v in t:
    var tpl = newJArray()
    tpl.add toJson(k, opt)
    tpl.add toJsonHook(v, opt)
    result.add tpl
    # result[repr(k.vtag)] = toJson(v, opt)

proc fromJsonHook*(t: var OrderedTable[PackageVersion, NimbleRelease]; b: JsonNode; opt = Joptions()) =
  for item in b:
    var pv: PackageVersion
    pv.fromJson(item[0])
    var release: NimbleRelease
    fromJsonHook(release, item[1], opt)
    t[pv] = release

proc toJsonHook*(t: OrderedTable[PkgUrl, Package], opt: ToJsonOptions): JsonNode =
  result = newJArray()
  for k, v in t:
    var item = newJObject()
    item["url"] = toJsonHook(k)
    item["package"] = toJson(v, opt)
    result.add item

proc fromJsonHook*(t: var OrderedTable[PkgUrl, Package]; b: JsonNode; opt = Joptions()) =
  for item in b:
    var url: PkgUrl
    url.fromJson(item["url"])
    var pkg: Package
    pkg.fromJson(item["package"])
    t[url] = pkg

proc nimbleReleaseToJson(r: NimbleRelease, opt: ToJsonOptions): JsonNode =
  if r.isNil:
    return newJNull()
  result = newJObject()
  if r.name != "":
    result["name"] = toJson(r.name, opt)
  result["requirements"] = toJson(r.requirements, opt)
  if r.hasInstallHooks:
    result["hasInstallHooks"] = toJson(r.hasInstallHooks, opt)
  if r.author != "":
    result["author"] = toJson(r.author, opt)
  if r.description != "":
    result["description"] = toJson(r.description, opt)
  if r.license != "":
    result["license"] = toJson(r.license, opt)
  if r.srcDir != Path "":
    result["srcDir"] = toJson(r.srcDir, opt)
  if r.binDir != Path "":
    result["binDir"] = toJson(r.binDir, opt)
  if r.bin.len > 0:
    result["bin"] = toJson(r.bin, opt)
  if r.namedBin.len > 0:
    result["namedBin"] = toJson(r.namedBin, opt)
  if r.backend != "":
    result["backend"] = toJson(r.backend, opt)
  if r.hasBin:
    result["hasBin"] = toJson(r.hasBin, opt)
  result["version"] = toJson(r.version, opt)
  if r.nimVersion != Version"":
    result["nimVersion"] = toJson(r.nimVersion, opt)
  result["status"] = toJson(r.status, opt)
  if r.err != "":
    result["err"] = toJson(r.err, opt)
  if r.features.len > 0:
    result["features"] = toJson(r.features, opt)
  if r.reqsByFeatures.len > 0:
    result["reqsByFeatures"] = toJson(r.reqsByFeatures, opt)
  if r.featureVars.len > 0:
    result["featureVars"] = toJson(r.featureVars, opt)

proc toJsonHook*(r: NimbleRelease): JsonNode =
  nimbleReleaseToJson(r, ToJsonOptions())

proc toJsonHook*(r: NimbleRelease, opt: ToJsonOptions): JsonNode =
  nimbleReleaseToJson(r, opt)

proc fromJsonHook*(r: var NimbleRelease; b: JsonNode; opt = Joptions()) =
  if r.isNil:
    r = new(NimbleRelease)
  if b.hasKey("name"):
    r.name = b["name"].getStr()
  r.version.fromJson(b["version"])
  if b.hasKey("nimVersion"):
    r.nimVersion.fromJson(b["nimVersion"])
  r.requirements.fromJson(b["requirements"])
  r.status.fromJson(b["status"])
  if b.hasKey("hasInstallHooks"):
    r.hasInstallHooks = b["hasInstallHooks"].getBool()
  if b.hasKey("author"):
    r.author = b["author"].getStr()
  if b.hasKey("description"):
    r.description = b["description"].getStr()
  if b.hasKey("license"):
    r.license = b["license"].getStr()
  if b.hasKey("srcDir"):
    r.srcDir.fromJson(b["srcDir"])
  if b.hasKey("binDir"):
    r.binDir.fromJson(b["binDir"])
  if b.hasKey("bin"):
    r.bin.fromJson(b["bin"])
  if b.hasKey("namedBin"):
    r.namedBin.fromJson(b["namedBin"])
  if b.hasKey("backend"):
    r.backend = b["backend"].getStr()
  if b.hasKey("hasBin"):
    r.hasBin = b["hasBin"].getBool()
  if b.hasKey("err"):
    r.err = b["err"].getStr()
  if b.hasKey("features"):
    r.features.fromJson(b["features"])
  if b.hasKey("reqsByFeatures"):
    r.reqsByFeatures.fromJson(b["reqsByFeatures"])
  if b.hasKey("featureVars"):
    r.featureVars.fromJson(b["featureVars"])

proc toJsonGraph*(d: DepGraph): JsonNode =
  result = toJson(d, ToJsonOptions(enumMode: joptEnumString))

proc dumpJson*(d: DepGraph, filename: string, pretty = true) =
  let jn = toJsonGraph(d)
  if pretty:
    writeFile(filename, pretty(jn))
  else:
    writeFile(filename, $(jn))

proc loadJson*(nc: var NimbleContext, json: JsonNode): DepGraph =
  result.fromJson(json, Joptions(allowMissingKeys: true, allowExtraKeys: true))
  var pkgs = result.pkgs
  result.pkgs.clear()

  for url, pkg in pkgs:
    let url2 = nc.createUrl($pkg.url)
    pkg.url = url2
    if pkg.subdir.string.len == 0:
      pkg.subdir = url2.subdir()
    result.pkgs[url2] = pkg
  
  let rootUrl = nc.createUrl($result.root.url)
  result.root = result.pkgs[rootUrl]

proc loadJson*(nc: var NimbleContext, filename: string): DepGraph =
  let jn = parseFile(filename)
  result = loadJson(nc, jn)
