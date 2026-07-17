import std/[os, paths, sequtils, strutils, times, unittest, uri]

import atlas, confighandler
import basic/[compiledpatterns, configutils, context, pkgurls]

type
  UnlinkWorkspace = object
    path: Path
    linkedUrl, childUrl, keptUrl: PkgUrl

proc setupUnlinkWorkspace(name: string; keptNeedsChild = false): UnlinkWorkspace =
  result.path = Path(getTempDir()) / Path(name & "_" & $int(epochTime()))
  if dirExists($result.path):
    removeDir($result.path)
  createDir($result.path)
  setContext AtlasContext(projectDir: result.path, depsDir: Path"deps")

  let deps = result.path / Path"deps"
  let linked = result.path / Path"linked"
  let child = result.path / Path"child"
  let kept = result.path / Path"kept"
  for dir in [deps, linked, child, kept]:
    createDir($dir)
    createDir($(dir / Path"src"))

  let nimbleFile = result.path / Path"project.nimble"
  let linkedNimble = linked / Path"linked.nimble"
  let childNimble = child / Path"child.nimble"
  let keptNimble = kept / Path"kept.nimble"
  result.linkedUrl = toPkgUriRaw(parseUri("link://" & $linkedNimble.absolutePath()))
  result.childUrl = toPkgUriRaw(parseUri("https://example.com/child"))
  result.keptUrl = toPkgUriRaw(parseUri("https://example.com/kept"))

  writeFile($nimbleFile, "requires \"linked\"\nrequires \"https://example.com/kept\"\n")
  writeFile($linkedNimble, "requires \"https://example.com/child\"\n")
  writeFile($childNimble, "")
  if keptNeedsChild:
    writeFile($keptNimble, "requires \"https://example.com/child\"\n")
  else:
    writeFile($keptNimble, "")
  writeDefaultConfigFile()
  discard context().nameOverrides.addPattern(
    result.linkedUrl.projectName, $result.linkedUrl.url)
  writeConfig()

  createNimbleLink(result.linkedUrl, linkedNimble, CfgPath"src")
  createNimbleLink(result.childUrl, childNimble, CfgPath"src")
  createNimbleLink(result.keptUrl, keptNimble, CfgPath"src")
  writeActivationCache(ActivationCache(packages: @[
    ActivatedPackage(
      url: toPkgUriRaw(parseUri("atlas://project")), ondisk: result.path,
      srcDir: Path"src", isRoot: true
    ),
    ActivatedPackage(url: result.linkedUrl, ondisk: linked, srcDir: Path"src"),
    ActivatedPackage(url: result.childUrl, ondisk: child, srcDir: Path"src"),
    ActivatedPackage(url: result.keptUrl, ondisk: kept, srcDir: Path"src")
  ]))
  patchNimCfg(@[
    CfgPath(linked / Path"src"),
    CfgPath(child / Path"src"),
    CfgPath(kept / Path"src")
  ], CfgPath(result.path))

proc runAtlas(ws: Path; params: seq[string]) =
  let oldDir = paths.getCurrentDir()
  try:
    setCurrentDir($ws)
    atlasRun(params)
  finally:
    setCurrentDir($oldDir)

suite "unlink":
  test "removes a linked package, its children, and activation-cache entries":
    let ws = setupUnlinkWorkspace("atlas_unlink_all")
    defer: removeDir($ws.path)

    runAtlas(ws.path, @["unlink", "linked"])

    let nimbleFile = ws.path / Path"project.nimble"
    check readFile($nimbleFile) == "requires \"https://example.com/kept\"\n"
    check not fileExists($ws.linkedUrl.toLinkPath())
    check not fileExists($ws.childUrl.toLinkPath())
    check fileExists($ws.keptUrl.toLinkPath())

    let cache = loadActivationCache(nimbleFile.absolutePath())
    check cache.packages.len == 2
    check cache.packages.allIt(it.url.projectName != "linked")
    check cache.packages.allIt(it.url.projectName != "child")
    check cache.packages.anyIt(it.url.projectName == "kept")

    let cfg = readFile($(ws.path / Path"nim.cfg"))
    check "linked/src" notin cfg
    check "child/src" notin cfg
    check "kept/src" in cfg
    check "linked" notin readFile($(ws.path / Path"deps/atlas.config"))

  test "keeps a child that another active package requires":
    let ws = setupUnlinkWorkspace("atlas_unlink_shared", keptNeedsChild = true)
    defer: removeDir($ws.path)

    runAtlas(ws.path, @["unlink", "linked"])

    let nimbleFile = ws.path / Path"project.nimble"
    check not fileExists($ws.linkedUrl.toLinkPath())
    check fileExists($ws.childUrl.toLinkPath())
    let cache = loadActivationCache(nimbleFile.absolutePath())
    check cache.packages.anyIt(it.url.projectName == "child")
    check "child/src" in readFile($(ws.path / Path"nim.cfg"))

  test "--only leaves child links and activation-cache entries":
    let ws = setupUnlinkWorkspace("atlas_unlink_only")
    defer: removeDir($ws.path)

    runAtlas(ws.path, @["unlink", "--only", "linked"])

    let nimbleFile = ws.path / Path"project.nimble"
    check not fileExists($ws.linkedUrl.toLinkPath())
    check fileExists($ws.childUrl.toLinkPath())

    let cache = loadActivationCache(nimbleFile.absolutePath())
    check cache.packages.allIt(it.url.projectName != "linked")
    check cache.packages.anyIt(it.url.projectName == "child")
    check "child/src" in readFile($(ws.path / Path"nim.cfg"))
