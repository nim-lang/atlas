{.define: atlasUnitTests.}

import std/[unittest, json, os, osproc, streams, times, paths, strutils,
            httpclient, tempfiles, uri]
import basic/context
import basic/atlasversion
import basic/httpclientutils
import basic/packageinfos
import basic/reporters

const AtlasRootDir = currentSourcePath().parentDir().parentDir()

proc nimbleVersion(): string =
  for line in readFile(AtlasRootDir / "atlas.nimble").splitLines():
    if line.startsWith("version ="):
      return line.split("=")[1].replace("\"", "").strip()
  "0.0.0"

proc gitDirty(dir: string): bool =
  let (outp, code) = execCmdEx("git -C " & quoteShell(dir) &
    " status --porcelain --untracked-files=no")
  code == 0 and outp.strip().len > 0

suite "packages list":
  test "atlas package version matches atlas.nimble":
    let expected =
      if gitDirty(AtlasRootDir): nimbleVersion() & "+dirty"
      else: nimbleVersion()
    check AtlasPackageVersion == expected
    check AtlasPackageVersion != "0.0.0"

  test "atlas package version falls back without atlas.nimble":
    let tmp = Path(genTempPath("atlas_no_nimble_", ""))
    let srcDir = tmp / Path"src" / Path"basic"
    let mainFile = tmp / Path"check_version.nim"
    defer:
      if dirExists($tmp):
        removeDir($tmp)

    createDir($srcDir)
    writeFile($(srcDir / Path"atlasversion.nim"),
              readFile(AtlasRootDir / "src" / "basic" / "atlasversion.nim"))
    writeFile($mainFile, """
import basic/atlasversion
doAssert AtlasPackageVersion == "0.0.0"
doAssert AtlasCommit == "unknown"
""")

    let (outp, code) = execCmdEx("nim c --path:" & quoteShell($(tmp / Path"src")) & " " & quoteShell($mainFile))
    check code == 0
    check outp.len >= 0

  test "atlas package version marks dirty git checkout":
    let tmp = Path(genTempPath("atlas_dirty_version_", ""))
    let srcDir = tmp / Path"src" / Path"basic"
    let mainFile = tmp / Path"check_version.nim"
    defer:
      if dirExists($tmp):
        removeDir($tmp)

    createDir($srcDir)
    writeFile($(srcDir / Path"atlasversion.nim"),
              readFile(AtlasRootDir / "src" / "basic" / "atlasversion.nim"))
    writeFile($(tmp / Path"atlas.nimble"), "version = \"1.2.3\"\n")
    writeFile($mainFile, """
import basic/atlasversion
doAssert AtlasPackageVersion == "1.2.4+dirty"
doAssert AtlasIsDirty
""")
    discard execCmdEx("git -C " & quoteShell($tmp) & " init")
    discard execCmdEx("git -C " & quoteShell($tmp) & " config user.name test-user")
    discard execCmdEx("git -C " & quoteShell($tmp) & " config user.email test@example.com")
    discard execCmdEx("git -C " & quoteShell($tmp) & " add .")
    discard execCmdEx("git -C " & quoteShell($tmp) & " commit -m initial")
    writeFile($(tmp / Path"atlas.nimble"), "version = \"1.2.4\"\n")
    check gitDirty($tmp)

    let (outp, code) = execCmdEx("nim c -r --path:" & quoteShell($(tmp / Path"src")) & " " & quoteShell($mainFile))
    check code == 0
    check outp.len >= 0

  test "atlas package version ignores untracked files":
    let tmp = Path(genTempPath("atlas_untracked_version_", ""))
    let srcDir = tmp / Path"src" / Path"basic"
    let mainFile = tmp / Path"check_version.nim"
    defer:
      if dirExists($tmp):
        removeDir($tmp)

    createDir($srcDir)
    writeFile($(srcDir / Path"atlasversion.nim"),
              readFile(AtlasRootDir / "src" / "basic" / "atlasversion.nim"))
    writeFile($(tmp / Path"atlas.nimble"), "version = \"1.2.3\"\n")
    writeFile($mainFile, """
import basic/atlasversion
doAssert AtlasPackageVersion == "1.2.3"
doAssert not AtlasIsDirty
""")
    discard execCmdEx("git -C " & quoteShell($tmp) & " init")
    discard execCmdEx("git -C " & quoteShell($tmp) & " config user.name test-user")
    discard execCmdEx("git -C " & quoteShell($tmp) & " config user.email test@example.com")
    discard execCmdEx("git -C " & quoteShell($tmp) & " add .")
    discard execCmdEx("git -C " & quoteShell($tmp) & " commit -m initial")
    writeFile($(tmp / Path"build-artifact.txt"), "artifact")
    check not gitDirty($tmp)

    let (outp, code) = execCmdEx("nim c -r --path:" & quoteShell($(tmp / Path"src")) & " " & quoteShell($mainFile))
    check code == 0
    check outp.len >= 0

  test "package list uses the GitHub raw source":
    check PackagesJsonUrls.len == 1
    check PackagesJsonUrls[0] ==
      "https://raw.githubusercontent.com/nim-lang/packages/refs/heads/master/packages.json"

  test "http client user agent matches atlas version":
    let client = newAtlasHttpClient()
    defer: client.close()
    check client.headers["User-Agent"] == "atlas/" & AtlasPackageVersion
    check client.headers["Accept-Encoding"] == "gzip"

    let uncompressedClient = newAtlasHttpClient(acceptGzip = false)
    defer: uncompressedClient.close()
    check uncompressedClient.headers["User-Agent"] == "atlas/" & AtlasPackageVersion
    check not uncompressedClient.headers.hasKey("Accept-Encoding")

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

  test "package list requests identity when gzip is unavailable or on Windows":
    let client = newPackageListHttpClient()
    defer: client.close()
    let encoding =
      if defined(windows) or findExe("gzip").len == 0: "identity"
      else: "gzip"
    check client.headers["Accept-Encoding"] == encoding

    let emptyPath = createTempDir("atlas-no-gzip-", "")
    defer: removeDir(emptyPath)
    let oldPath = getEnv("PATH")
    putEnv("PATH", emptyPath)
    defer: putEnv("PATH", oldPath)
    let clientWithoutGzip = newPackageListHttpClient()
    defer: clientWithoutGzip.close()
    check clientWithoutGzip.headers["Accept-Encoding"] == "identity"

  test "updatePackages retains and reuses a shallow Git checkout after HTTP failure":
    let tmp = createTempDir("atlas-packages-test-", "")
    defer: removeDir(tmp)
    let repoDir = tmp / "registry"
    createDir(repoDir)
    let git = "git -C " & quoteShell(repoDir)
    require execCmdEx(git & " init").exitCode == 0
    writeFile(repoDir / "packages.json", "[]")
    require execCmdEx(git & " add packages.json").exitCode == 0
    require execCmdEx(git & " -c user.name=Atlas -c user.email=atlas@example.com" &
      " -c commit.gpgsign=false commit -m Registry").exitCode == 0

    let traceFile = tmp / "git-trace.log"
    let oldTrace = getEnv("GIT_TRACE")
    let hadTrace = existsEnv("GIT_TRACE")
    putEnv("GIT_TRACE", traceFile)
    defer:
      if hadTrace: putEnv("GIT_TRACE", oldTrace)
      else: delEnv("GIT_TRACE")

    var repoUrl = parseUri("file:///")
    repoUrl.path = repoDir.replace('\\', '/')
    when defined(windows):
      repoUrl.path = "/" & repoUrl.path
    let cacheDir = Path(tmp / "cache")
    let gitDir = Path(tmp / ".packages")
    let urls = ["http://127.0.0.1:0/packages.json"]
    createDir($cacheDir)
    writeFile($packageInfosFile(cacheDir), "[{}]")
    updatePackagesFrom(cacheDir, gitDir, urls, repoUrl)
    check readFile($packageInfosFile(cacheDir)) == "[]"
    check fileExists($(gitDir / Path".git" / Path"shallow"))

    writeFile(repoDir / "packages.json", "[{}]")
    require execCmdEx(git & " -c user.name=Atlas -c user.email=atlas@example.com" &
      " -c commit.gpgsign=false commit -am Refresh").exitCode == 0
    let warnings = atlasReporter.warnings
    updatePackagesFrom(cacheDir, gitDir, urls, repoUrl)
    check atlasReporter.warnings == warnings
    check readFile($packageInfosFile(cacheDir)) == "[{}]"
    let trace = readFile(traceFile)
    check trace.count("built-in: git clone --depth=1") == 1
    check "built-in: git pull" in trace

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
    updatePackages(pkgsDir, pkgsDir / Path".packages")
    check fileExists($pkgsFile)
    check getFileSize($pkgsFile) > 0

  test "existing package checkout migrates to deps/.packages":
    let oldCtx = context()
    let ws = createTempDir("atlas-package-migration-", "")
    defer:
      setContext(oldCtx)
      removeDir(ws)
    setContext(AtlasContext(projectDir: Path(ws), depsDir: Path"deps"))
    let oldCheckout = depsDir() / Path"_packages"
    let newCheckout = depsDir() / Path".packages"
    let oldNimbleCache = depsDir() / Path"_nimble"
    createDir($(oldCheckout / Path".git"))
    createDir($oldNimbleCache)
    writeFile($(oldCheckout / Path"packages.json"), "[]")

    migratePackageCaches()
    migratePackageCaches()

    check packagesDirectory() == newCheckout
    check not dirExists($oldCheckout)
    check not dirExists($oldNimbleCache)
    check dirExists($(newCheckout / Path".git"))
    check readFile($(newCheckout / Path"packages.json")) == "[]"

  test "migration preserves both checkouts if deps/.packages exists":
    let oldCtx = context()
    let ws = createTempDir("atlas-package-collision-", "")
    defer:
      setContext(oldCtx)
      removeDir(ws)
    setContext(AtlasContext(projectDir: Path(ws), depsDir: Path"deps", flags: {PackagesGit}))
    let oldCheckout = depsDir() / Path"_packages"
    createDir($oldCheckout)
    createDir($packagesDirectory())
    writeFile($(oldCheckout / Path"packages.json"), "[]")
    writeFile($(packagesDirectory() / Path"packages.json"), "[{}]")

    migratePackageCaches()

    check readFile($(oldCheckout / Path"packages.json")) == "[]"
    check readFile($(packagesDirectory() / Path"packages.json")) == "[{}]"
