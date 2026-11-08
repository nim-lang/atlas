## Regression tests for #113: `atlas.active.json` used to store absolute
## paths, which broke workspaces that are moved to another location or
## shared between machines (dual boot).

import std/[unittest, json, os, uri, paths]
import basic/[context, pkgurls, versions]
import confighandler

const wsName = "portable_ws_test"

proc `/`(p: Path, s: string): Path =
  ## local sugar for joining Path with a string literal
  p / Path(s)

proc cwd(): Path =
  paths.getCurrentDir().absolutePath.Path

proc wsDir(): Path =
  cwd() / wsName

proc depOndisk(): Path =
  wsDir() / "deps" / "pkg_a"

proc sampleCache(): ActivationCache =
  let url = toPkgUriRaw(parseUri "https://example.com/portabletest/pkg_a.git")
  result.packages = @[
    ActivatedPackage(url: url, name: "portable_ws_test", version: "#head",
      commit: CommitHash(h: "-", orig: FromNone), ondisk: wsDir(), srcDir: Path"",
      isRoot: true),
    ActivatedPackage(url: url, name: "pkg_a", version: "1.0.0",
      commit: CommitHash(h: "cafe", orig: FromNone), ondisk: depOndisk(), srcDir: Path"src",
      isRoot: false),
  ]

proc cacheFile(): Path =
  wsDir() / "deps" / ".cache" / "atlas.active.json"

proc removeWs(name: string) =
  if dirExists(name):
    removeDir(name)

suite "portable ondisk paths in the activation cache (#113)":
  setup:
    removeWs(wsName)
    createDir($wsDir())
    project(wsDir())
    context().depsDir = Path "deps"

  teardown:
    removeWs(wsName)
    removeWs(wsName & "_moved")

  test "ondisk paths inside the workspace are written relative":
    writeActivationCache(sampleCache())
    let jn = parseFile($cacheFile())
    check jn["packages"][0]["ondisk"].getStr() == "."
    check jn["packages"][1]["ondisk"].getStr() == "deps/pkg_a"

  test "relative ondisk paths resolve against the workspace on load":
    writeActivationCache(sampleCache())
    let nimbleFile = wsDir() / "portable_ws_test.nimble"
    writeFile($nimbleFile, "version = \"0.1.0\"\n")
    let loaded = loadActivationCache(nimbleFile)
    check $loaded.packages[0].ondisk == $wsDir()
    check $loaded.packages[1].ondisk == $depOndisk()

  test "paths outside the workspace are kept absolute":
    let outside = cwd() / "outside_pkg"
    check $portableOndisk(outside) == $outside

  test "old caches with absolute paths still load unchanged":
    # hand-write a cache in the pre-#113 format and load it back
    var cache: ActivationCache
    cache.packages = sampleCache().packages
    let ws = wsDir()
    let jn = %*{"packages": [
      %*{"url": "https://example.com/portabletest/pkg_a.git",
         "name": "pkg_a", "version": "1.0.0", "commit": "cafe",
         "features": [], "ondisk": $(ws / "deps" / "pkg_a"),
         "srcDir": "src", "isRoot": false}]}
    createDir($(ws / "deps" / ".cache"))
    writeFile($cacheFile(), pretty(jn))
    let nimbleFile = ws / "portable_ws_test.nimble"
    writeFile($nimbleFile, "version = \"0.1.0\"\n")
    let loaded = loadActivationCache(nimbleFile)
    check $loaded.packages[0].ondisk == $(ws / "deps" / "pkg_a")

  test "workspace can be moved and the cache still resolves":
    writeActivationCache(sampleCache())
    let nimbleFile = wsDir() / "portable_ws_test.nimble"
    writeFile($nimbleFile, "version = \"0.1.0\"\n")
    let otherName = wsName & "_moved"
    moveDir(wsName, otherName)
    let movedNimble = cwd() / otherName / "portable_ws_test.nimble"
    let movedWs = movedNimble.parentDir()
    let loaded = loadActivationCache(movedNimble)
    check $loaded.packages[0].ondisk == $movedWs
    check $loaded.packages[1].ondisk == $(movedWs / "deps" / "pkg_a")
