import std/[unittest, json, os, times, paths, strutils]
import basic/context
import basic/atlasversion
import basic/httpclientutils
import basic/packageinfos

suite "packages list":
  test "package list urls prefer CDN and retain fallback":
    check PackagesJsonUrls[0] == "https://packages.nim-lang.org/packages.json"
    check PackagesJsonUrls[^1].startsWith("https://raw.githubusercontent.com/nim-lang/packages/")

  test "http client user agent matches atlas version":
    check AtlasUserAgent == "atlas/" & AtlasPackageVersion
    check AtlasPackageVersion.len > 0

  test "package info parses registry subdir":
    let pkg = fromJson(parseJson("""
      {
        "name": "proven",
        "url": "https://github.com/hyperpolymath/proven",
        "method": "git",
        "tags": ["safety"],
        "description": "Subdir package",
        "license": "MIT",
        "subdir": "bindings/nim"
      }
    """))
    check pkg != nil
    check pkg.kind == pkPackage
    check pkg.name == "proven"
    check pkg.subdir == "bindings/nim"

  test "updatePackages downloads packages.json":
    let pkgsDir = Path(getTempDir()) / Path("atlas_pkgs_" & $int(epochTime()))
    let pkgsFile = packageInfosFile(pkgsDir)
    defer:
      if fileExists($pkgsFile):
        removeFile($pkgsFile)
      if dirExists($pkgsDir):
        removeDir($pkgsDir)
    updatePackages(pkgsDir)
    check fileExists($pkgsFile)
    check getFileSize($pkgsFile) > 0

  test "legacy package caches are removed by default":
    let oldCtx = context()
    let ws = Path(getTempDir()) / Path("atlas_cleanup_" & $int(epochTime()))
    defer:
      setContext(oldCtx)
      if dirExists($ws):
        removeDir($ws)

    setContext(AtlasContext(projectDir: ws, depsDir: Path"deps"))
    createDir($depsDir())
    createDir($(depsDir() / Path"_nimble"))
    createDir($packagesDirectory())

    removeLegacyPackageCaches()

    check not dirExists($(depsDir() / Path"_nimble"))
    check not dirExists($packagesDirectory())

  test "packages git cache is kept for packages repo mode":
    let oldCtx = context()
    let ws = Path(getTempDir()) / Path("atlas_cleanup_git_" & $int(epochTime()))
    defer:
      setContext(oldCtx)
      if dirExists($ws):
        removeDir($ws)

    setContext(AtlasContext(projectDir: ws, depsDir: Path"deps", flags: {PackagesGit}))
    createDir($depsDir())
    createDir($(depsDir() / Path"_nimble"))
    createDir($packagesDirectory())

    removeLegacyPackageCaches()

    check not dirExists($(depsDir() / Path"_nimble"))
    check dirExists($packagesDirectory())
