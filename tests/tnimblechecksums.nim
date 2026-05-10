import std/[unittest, os, osproc, paths, strutils, tempfiles]
import basic/nimblechecksums

proc quoteArg(value: string): string =
  quoteShell(value)

proc initGitRepo(path: Path) =
  discard execCmdEx("git -C " & quoteArg($path) & " init")
  discard execCmdEx("git -C " & quoteArg($path) & " config user.name test-user")
  discard execCmdEx("git -C " & quoteArg($path) & " config user.email test@example.com")
  discard execCmdEx("git -C " & quoteArg($path) & " add .")
  discard execCmdEx("git -C " & quoteArg($path) & " commit -m initial")

proc sourceNimbleDir(): Path =
  let configured = getEnv("NIMBLE_DIR")
  if configured.len > 0:
    Path(configured)
  else:
    Path(getHomeDir()) / Path".nimble"

suite "nimble checksum":
  test "matches nimble install cache checksum for a local git package":
    let nimbleExe = findExe("nimble")
    if nimbleExe.len == 0:
      skip()
    else:
      let upstreamNimbleDir = sourceNimbleDir()
      let packageListCache = upstreamNimbleDir / Path"packages_official.json"
      if not fileExists($packageListCache):
        skip()
      else:
        let tempRoot = Path(genTempPath("atlas_nimble_checksum_", ""))
        let packageDir = tempRoot / Path"mypro"
        let srcDir = packageDir / Path"src"
        let nimbleHome = tempRoot / Path"nimble-home"
        defer:
          if dirExists($tempRoot):
            removeDir($tempRoot)

        createDir($srcDir)
        writeFile($(packageDir / Path"mypro.nimble"), """
version = "0.1.0"
author = "test"
description = "test"
license = "MIT"
srcDir = "src"
""")
        writeFile($(srcDir / Path"mypro.nim"), "proc x* = discard\n")
        writeFile($(packageDir / Path"README.md"), "readme\n")
        writeFile($(packageDir / Path".gitignore"), "ignored.txt\n")
        writeFile($(packageDir / Path"ignored.txt"), "not tracked\n")
        initGitRepo(packageDir)

        let expected = nimbleChecksum("mypro", packageDir)

        createDir($nimbleHome)
        copyFile($packageListCache, $(nimbleHome / Path"packages_official.json"))

        let installCmd =
          "export NIMBLE_DIR=" & quoteArg($nimbleHome) &
          " && cd " & quoteArg($tempRoot) &
          " && " & quoteArg(nimbleExe) & " install -y --offline " &
          quoteArg("file://" & $packageDir)
        let (outp, code) = execCmdEx(installCmd)
        check code == 0
        check outp.len >= 0

        let pkgsDir = nimbleHome / Path"pkgs2"
        check dirExists($pkgsDir)

        var installedDirs: seq[string]
        for kind, path in walkDir($pkgsDir):
          if kind == pcDir:
            installedDirs.add(path.lastPathPart())

        check installedDirs.len == 1
        let installedDir = installedDirs[0]
        check installedDir.startsWith("mypro-0.1.0-")
        check installedDir.endsWith(expected)
