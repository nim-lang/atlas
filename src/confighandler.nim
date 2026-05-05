#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Configuration handling.

import std / [algorithm, strutils, os, streams, json, tables, jsonutils, uri, sequtils]
import basic/[versions, nimblecontext, deptypesjson, context, reporters, compiledpatterns, parse_requires, deptypes, pkgurls]

proc readPluginsDir(dir: Path) =
  for k, f in walkDir($(project() / dir)):
    if k == pcFile and f.endsWith(".nims"):
      extractPluginInfo f, context().plugins

type
  JsonConfig* = object
    deps*: string
    nameOverrides*: Table[string, string]
    urlOverrides*: Table[string, string]
    pkgOverrides*: Table[string, string]
    plugins*: string
    resolver*: string
    graph*: JsonNode

  ActivatedPackage* = object
    url*: PkgUrl
    name*: string
    version*: string
    author*: string
    description*: string
    license*: string
    commit*: CommitHash
    features*: seq[string]
    ondisk*: Path
    srcDir*: Path
    bin*: seq[string]
    namedBin*: Table[string, string]
    backend*: string
    hasBin*: bool
    isRoot*: bool

  ActivationCache* = object
    packages*: seq[ActivatedPackage]

proc writeDefaultConfigFile*() =
  let config = JsonConfig(
    deps: $depsDir(relative=true),
    nameOverrides: initTable[string, string](),
    urlOverrides: initTable[string, string](),
    pkgOverrides: initTable[string, string](),
    resolver: $SemVer,
    graph: newJNull()
  )
  let configFile = getProjectConfig()
  writeFile($configFile, pretty %*config)

proc readConfigFile*(configFile: Path): JsonConfig =
  var f = newFileStream($configFile, fmRead)
  if f == nil:
    warn "atlas:config", "could not read project config:", $configFile
    return

  try:
    let j = parseJson(f, $configFile)
    result = j.jsonTo(JsonConfig, Joptions(allowExtraKeys: true, allowMissingKeys: true))

  finally:
    close f

proc readAtlasContext*(ctx: var AtlasContext, projectDir: Path) =
  let configFile = projectDir.getProjectConfig()
  info "atlas:config", "Reading config file: ", $configFile
  let m = readConfigFile(configFile)

  ctx.projectDir = projectDir

  if m.deps.len > 0:
    ctx.depsDir = m.deps.Path.expandTilde()
  
  # Handle package name overrides
  for key, val in m.nameOverrides:
    let err = ctx.nameOverrides.addPattern(key, val)
    if err.len > 0:
      error configFile, "invalid name override pattern: " & err

  # Handle URL overrides  
  for key, val in m.urlOverrides:
    let err = ctx.urlOverrides.addPattern(key, val)
    if err.len > 0:
      error configFile, "invalid URL override pattern: " & err

  # Handle package overrides
  for key, val in m.pkgOverrides:
    ctx.pkgOverrides[key] = parseUri(val)
  if m.resolver.len > 0:
    try:
      ctx.defaultAlgo = parseEnum[ResolutionAlgorithm](m.resolver)
    except ValueError:
      warn configFile, "ignored unknown resolver: " & m.resolver
  if m.plugins.len > 0:
    ctx.pluginsFile = m.plugins.Path
    readPluginsDir(m.plugins.Path)
  

proc readConfig*() =
  readAtlasContext(context(), project())
  # trace "atlas:config", "read config file: ", repr context()

proc writeConfig*() =
  # TODO: serialize graph in a smarter way

  let config = JsonConfig(
    deps: $depsDir(relative=true),
    nameOverrides: context().nameOverrides.toTable(),
    urlOverrides: context().urlOverrides.toTable(),
    pkgOverrides: context().pkgOverrides.pairs().toSeq().mapIt((it[0], $it[1])).toTable(),
    plugins: $context().pluginsFile,
    resolver: $context().defaultAlgo,
    graph: newJNull()
  )

  let jcfg = toJson(config)
  doAssert not jcfg.isNil()
  let configFile = getProjectConfig()
  debug "atlas", "writing config file: ", $configFile
  writeFile($configFile, pretty(jcfg))

proc writeDepGraph*(g: DepGraph, debug: bool = false) =
  var configFile = depGraphCacheFile(context())
  if debug:
    configFile = configFile.changeFileExt("debug.json")
  debug "atlas", "writing dep graph to: ", $configFile
  dumpJson(g, $configFile, pretty = true)

proc removeDepGraphCache*() =
  for configFile in [
    depGraphCacheFile(context()),
    depGraphCacheFile(context()).changeFileExt("debug.json")
  ]:
    if fileExists($configFile):
      removeFile($configFile)

proc toJsonHook*(pkg: ActivatedPackage, opt: ToJsonOptions): JsonNode =
  result = newJObject()
  result["url"] = toJson(pkg.url, opt)
  if pkg.name != "":
    result["name"] = toJson(pkg.name, opt)
  result["version"] = toJson(pkg.version, opt)
  if pkg.author != "":
    result["author"] = toJson(pkg.author, opt)
  if pkg.description != "":
    result["description"] = toJson(pkg.description, opt)
  if pkg.license != "":
    result["license"] = toJson(pkg.license, opt)
  result["commit"] = toJson(pkg.commit, opt)
  result["features"] = toJson(pkg.features, opt)
  result["ondisk"] = toJson(pkg.ondisk, opt)
  result["srcDir"] = toJson(pkg.srcDir, opt)
  if pkg.bin.len > 0:
    result["bin"] = toJson(pkg.bin, opt)
  if pkg.namedBin.len > 0:
    result["namedBin"] = toJson(pkg.namedBin, opt)
  if pkg.backend != "":
    result["backend"] = toJson(pkg.backend, opt)
  if pkg.hasBin:
    result["hasBin"] = toJson(pkg.hasBin, opt)
  result["isRoot"] = toJson(pkg.isRoot, opt)

proc toJsonHook*(cache: ActivationCache, opt: ToJsonOptions): JsonNode =
  result = newJObject()
  result["packages"] = toJson(cache.packages, opt)

proc toActivationCache*(g: DepGraph): ActivationCache =
  for pkg in values(g.pkgs):
    if not pkg.active or pkg.activeVersion.isNil:
      continue

    let rel = pkg.activeNimbleRelease()
    var features = pkg.activeFeatures
    features.sort()

    result.packages.add ActivatedPackage(
      url: pkg.url,
      name: if rel.isNil: "" else: rel.name,
      version: repr(pkg.activeVersion.vtag),
      author: if rel.isNil: "" else: rel.author,
      description: if rel.isNil: "" else: rel.description,
      license: if rel.isNil: "" else: rel.license,
      commit: pkg.activeVersion.commit(),
      features: features,
      ondisk: pkg.ondisk,
      srcDir: if rel.isNil: Path"" else: rel.srcDir,
      bin: if rel.isNil: @[] else: rel.bin,
      namedBin: if rel.isNil: initTable[string, string]() else: rel.namedBin,
      backend: if rel.isNil: "" else: rel.backend,
      hasBin: if rel.isNil: false else: rel.hasBin,
      isRoot: pkg.isRoot
    )

  result.packages.sort(proc (a, b: ActivatedPackage): int =
    cmp($a.url, $b.url)
  )

proc writeActivationCache*(g: DepGraph) =
  let configFile = activationCacheFile()
  createDir($configFile.parentDir())
  debug "atlas", "writing activation cache to: ", $configFile
  let jn = toJson(toActivationCache(g), ToJsonOptions(enumMode: joptEnumString))
  writeFile($configFile, pretty(jn))

proc loadActivationCache*(nimbleFile: Path): ActivationCache =
  doAssert nimbleFile.isAbsolute() and endsWith($nimbleFile, ".nimble") and fileExists($nimbleFile)
  let projectDir = nimbleFile.parentDir()
  var ctx = AtlasContext(projectDir: projectDir)
  readAtlasContext(ctx, projectDir)
  let configFile = activationCacheFile(ctx)
  debug "atlas", "reading activation cache from: ", $configFile
  result.fromJson(parseFile($configFile), Joptions(allowMissingKeys: true, allowExtraKeys: true))

proc loadDepGraph*(nc: var NimbleContext, nimbleFile: Path): DepGraph =
  doAssert nimbleFile.isAbsolute() and endsWith($nimbleFile, ".nimble") and fileExists($nimbleFile)
  let projectDir = nimbleFile.parentDir()
  var ctx = AtlasContext(projectDir: projectDir)
  readAtlasContext(ctx, projectDir)
  let configFile = depGraphCacheFile(ctx)
  debug "atlas", "reading dep graph from: ", $configFile
  result = loadJson(nc, $configFile)
