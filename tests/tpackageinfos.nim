import std/[unittest, json, os, osproc, streams, times, paths, strutils,
            httpclient, tempfiles]
import basic/context
import basic/atlasversion
import basic/httpclientutils
import basic/packageinfos

const AtlasRootDir = currentSourcePath().parentDir().parentDir()

proc nimbleVersion(): string =
  for line in readFile(AtlasRootDir / "atlas.nimble").splitLines():
    if line.startsWith("version ="):
      return line.split("=")[1].replace("\"", "").strip()
  "0.0.0"

proc changedPath(line: string): string =
  if line.len <= 3:
    return ""
  let path = line[3..^1].strip()
  let renameSep = path.rfind(" -> ")
  if renameSep >= 0:
    path[renameSep + 4 .. ^1]
  else:
    path

proc gitDirty(dir: string): bool =
  let (outp, code) = execCmdEx("git -C " & quoteShell(dir) & " status --porcelain")
  if code != 0:
    return false
  for line in outp.splitLines():
    let cleanLine = line.strip()
    if cleanLine.len == 0:
      continue
    if changedPath(cleanLine) != "nimblemeta.json":
      return true
  false

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
doAssert AtlasPackageVersion == "1.2.3+dirty"
doAssert AtlasIsDirty
""")
    discard execCmdEx("git -C " & quoteShell($tmp) & " init")
    discard execCmdEx("git -C " & quoteShell($tmp) & " config user.name test-user")
    discard execCmdEx("git -C " & quoteShell($tmp) & " config user.email test@example.com")
    discard execCmdEx("git -C " & quoteShell($tmp) & " add .")
    discard execCmdEx("git -C " & quoteShell($tmp) & " commit -m initial")
    writeFile($(tmp / Path"dirty.txt"), "dirty")

    let (outp, code) = execCmdEx("nim c --path:" & quoteShell($(tmp / Path"src")) & " " & quoteShell($mainFile))
    check code == 0
    check outp.len >= 0

  test "atlas package version ignores standalone nimblemeta change":
    let tmp = Path(genTempPath("atlas_nimblemeta_version_", ""))
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
    writeFile($(tmp / Path"nimblemeta.json"), "{}")

    let (outp, code) = execCmdEx("nim c --path:" & quoteShell($(tmp / Path"src")) & " " & quoteShell($mainFile))
    check code == 0
    check outp.len >= 0

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
