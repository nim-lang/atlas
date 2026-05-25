import std/[json, jsonutils, paths, tables, sets, strutils, uri]
import sattypes, deptypes, pkgurls, versions, nimblecontext

export json, jsonutils

var pkgUrlJsonContext {.threadvar.}: NimbleContext
var pkgUrlJsonContextLoaded {.threadvar.}: bool

proc jsonContext(): var NimbleContext =
  if not pkgUrlJsonContextLoaded:
    pkgUrlJsonContext = createNimbleContext()
    pkgUrlJsonContextLoaded = true
  result = pkgUrlJsonContext

proc compactPkgUrlName*(v: PkgUrl): string =
  let nc = jsonContext()
  if nc.canRoundTripByRegistryName(v):
    nc.registryName(v)
  else:
    v.projectName()

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
  let nc = jsonContext()
  if nc.canRoundTripByRegistryName(v):
    %(nc.registryName(v))
  else:
    %($(v))

proc fromJsonHook*(a: var PkgUrl; b: JsonNode; opt = Joptions()) =
  let raw = b.getStr()
  var nc = jsonContext()
  try:
    a = nc.createUrl(raw)
  except CatchableError:
    a = createUrlSkipPatterns(raw, skipDirTest = true)

proc toJsonHook*(vid: VarId): JsonNode = toJson(int(vid))

proc fromJsonHook*(a: var VarId; b: JsonNode; opt = Joptions()) =
  a = VarId(int(b.getInt()))

proc toJsonHook*(p: Path): JsonNode = toJson(p.string)

proc fromJsonHook*(a: var Path; b: JsonNode; opt = Joptions()) =
  a = Path(b.getStr())

proc toJsonHook*(v: (PkgUrl, VersionInterval), opt: ToJsonOptions): JsonNode =
  result = newJObject()
  let nc = jsonContext()
  if nc.canRoundTripByRegistryName(v[0]):
    result["name"] = toJson(nc.registryName(v[0]), opt)
  else:
    result["url"] = toJsonHook(v[0])
  result["version"] = toJsonHook(v[1])

proc fromJsonHook*(a: var (PkgUrl, VersionInterval); b: JsonNode; opt = Joptions()) =
  if b.hasKey("url"):
    a[0].fromJson(b["url"])
  elif b.hasKey("name"):
    a[0].fromJson(b["name"])
  else:
    raise newException(ValueError, "requirement entry is missing both 'url' and 'name'")
  a[1].fromJson(b["version"])

proc requirementName(v: PkgUrl): string =
  let nc = jsonContext()
  if nc.canRoundTripByRegistryName(v):
    result = nc.registryName(v)
  else:
    result = v.compactForgeAlias()

proc requirementToJson(req: (PkgUrl, VersionInterval)): JsonNode =
  result = %requirementName(req[0])
  let query = $req[1]
  if query != "*":
    result = %(result.getStr() & " " & query)

proc requirementsToJson(reqs: seq[(PkgUrl, VersionInterval)]): JsonNode =
  result = newJArray()
  for req in reqs:
    result.add requirementToJson(req)

proc splitRequirement(raw: string): (string, int) =
  var i = 0
  while i < raw.len:
    if raw[i] in Whitespace:
      var j = i
      while j < raw.len and raw[j] in Whitespace:
        inc j
      if j >= raw.len or raw[j] in {'#', '<', '=', '>', '*'} + Digits:
        return (raw.substr(0, i - 1), j)
    inc i

  let url = parseUri(raw)
  if url.scheme.len > 0:
    result = (raw, raw.len)
  else:
    let (name, _, verIdx) = extractRequirementName(raw)
    result = (name, verIdx)

proc requirementFromJson(b: JsonNode): (PkgUrl, VersionInterval) =
  let raw = b.getStr()
  let (name, verIdx) = splitRequirement(raw)
  result[0].fromJson(%name)
  var err = false
  result[1] = parseVersionInterval(raw, verIdx, err)
  if err:
    raise newException(ValueError, "invalid requirement entry: " & raw)

proc requirementsFromJson(reqs: var seq[(PkgUrl, VersionInterval)]; b: JsonNode) =
  reqs.setLen(0)
  for item in b:
    reqs.add requirementFromJson(item)

proc featuresToJson(features: Table[string, seq[(PkgUrl, VersionInterval)]]): JsonNode =
  result = newJObject()
  for feature, reqs in features:
    result[feature] = requirementsToJson(reqs)

proc featuresFromJson(
    features: var Table[string, seq[(PkgUrl, VersionInterval)]];
    b: JsonNode
) =
  features.clear()
  if b.kind != JObject:
    return
  for feature, featureReqs in b:
    var reqs: seq[(PkgUrl, VersionInterval)]
    reqs.requirementsFromJson(featureReqs)
    features[feature] = reqs

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
    result["n"] = toJson(r.name, opt)
  result["r"] = requirementsToJson(r.requirements)
  if r.hasInstallHooks:
    result["h"] = toJson(r.hasInstallHooks, opt)
  if r.hasBin:
    result["g"] = toJson(r.hasBin, opt)
  if r.author != "":
    result["a"] = toJson(r.author, opt)
  if r.description != "":
    result["d"] = toJson(r.description, opt)
  if r.license != "":
    result["l"] = toJson(r.license, opt)
  if r.srcDir != Path "":
    result["s"] = toJson(r.srcDir, opt)
  if r.binDir != Path "":
    result["b"] = toJson(r.binDir, opt)
  if r.skipDirs.len > 0:
    result["x"] = toJson(r.skipDirs, opt)
  if r.skipFiles.len > 0:
    result["y"] = toJson(r.skipFiles, opt)
  if r.skipExt.len > 0:
    result["z"] = toJson(r.skipExt, opt)
  if r.installDirs.len > 0:
    result["i"] = toJson(r.installDirs, opt)
  if r.installFiles.len > 0:
    result["j"] = toJson(r.installFiles, opt)
  if r.installExt.len > 0:
    result["k"] = toJson(r.installExt, opt)
  if r.bin.len > 0:
    result["p"] = toJson(r.bin, opt)
  if r.namedBin.len > 0:
    result["o"] = toJson(r.namedBin, opt)
  if r.backend != "":
    result["e"] = toJson(r.backend, opt)
  result["v"] = toJson(r.version, opt)
  if r.nimVersion != Version"":
    result["m"] = toJson(r.nimVersion, opt)
  if r.status != Normal:
    result["S"] = toJson(r.status, opt)
  if r.err != "":
    result["E"] = toJson(r.err, opt)
  if r.features.len > 0:
    result["f"] = featuresToJson(r.features)
  if r.reqsByFeatures.len > 0:
    result["q"] = toJson(r.reqsByFeatures, opt)
  if r.featureVars.len > 0:
    result["F"] = toJson(r.featureVars, opt)

proc toJsonHook*(r: NimbleRelease): JsonNode =
  nimbleReleaseToJson(r, ToJsonOptions())

proc toJsonHook*(r: NimbleRelease, opt: ToJsonOptions): JsonNode =
  nimbleReleaseToJson(r, opt)

proc fromJsonHook*(r: var NimbleRelease; b: JsonNode; opt = Joptions()) =
  if r.isNil:
    r = new(NimbleRelease)
  if b.hasKey("n"):
    r.name = b["n"].getStr()
  if b.hasKey("v"):
    r.version.fromJson(b["v"])
  if b.hasKey("m"):
    r.nimVersion.fromJson(b["m"])
  if b.hasKey("r"):
    r.requirements.requirementsFromJson(b["r"])
  else:
    r.requirements.setLen(0)
  if b.hasKey("S"):
    r.status.fromJson(b["S"])
  else:
    r.status = Normal
  if b.hasKey("h"):
    r.hasInstallHooks = b["h"].getBool()
  if b.hasKey("a"):
    r.author = b["a"].getStr()
  if b.hasKey("d"):
    r.description = b["d"].getStr()
  if b.hasKey("l"):
    r.license = b["l"].getStr()
  if b.hasKey("s"):
    r.srcDir.fromJson(b["s"])
  if b.hasKey("b"):
    r.binDir.fromJson(b["b"])
  if b.hasKey("x"):
    r.skipDirs.fromJson(b["x"])
  if b.hasKey("y"):
    r.skipFiles.fromJson(b["y"])
  if b.hasKey("z"):
    r.skipExt.fromJson(b["z"])
  if b.hasKey("i"):
    r.installDirs.fromJson(b["i"])
  if b.hasKey("j"):
    r.installFiles.fromJson(b["j"])
  if b.hasKey("k"):
    r.installExt.fromJson(b["k"])
  if b.hasKey("p"):
    r.bin.fromJson(b["p"])
  if b.hasKey("o"):
    r.namedBin.fromJson(b["o"])
  if b.hasKey("e"):
    r.backend = b["e"].getStr()
  if b.hasKey("g"):
    r.hasBin = b["g"].getBool()
  if b.hasKey("E"):
    r.err = b["E"].getStr()
  if b.hasKey("f"):
    r.features.featuresFromJson(b["f"])
  if b.hasKey("q"):
    r.reqsByFeatures.fromJson(b["q"])
  if b.hasKey("F"):
    r.featureVars.fromJson(b["F"])

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
