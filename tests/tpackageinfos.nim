import std/[unittest, json, os, osproc, times, paths, strutils]
import std/[streams, times, paths, httpclient, tempfiles]
import basic/context
import basic/atlasversion
import basic/httpclientutils
import basic/packageinfos

suite "packages list":
  test "package list urls prefer CDN and retain fallback":
    check PackagesJsonUrls[0] == "https://packages.nim-lang.org/packages.json"
    check PackagesJsonUrls[^1].startsWith("https://raw.githubusercontent.com/nim-lang/packages/")

  test "http client user agent matches atlas version":
    let client = newAtlasHttpClient()
    defer: client.close()
    check client.headers["User-Agent"] == "atlas/" & AtlasPackageVersion
    check client.headers["Accept-Encoding"] == "gzip"

  test "gzip encoded package list is decompressed with gzip":
    if findExe("gzip").len == 0:
      skip()
    else:
      let plain = "[{\"name\":\"pkg\",\"url\":\"https://example.invalid/pkg\"," &
        "\"method\":\"git\",\"tags\":[],\"description\":\"pkg\"}]"
      let plainPath = genTempPath("atlas_packages_", ".json")
      writeFile(plainPath, plain)
      defer:
        if fileExists(plainPath):
          removeFile(plainPath)

      let process = startProcess("gzip", args = ["-c", plainPath],
                                 options = {poUsePath, poStdErrToStdOut})
      let compressed = process.outputStream.readAll()
      let exitCode = process.waitForExit()
      process.close()
      check exitCode == 0

      let headers = newHttpHeaders({"Content-Encoding": "gzip"})
      check decodePackageList(headers, compressed) == plain

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
