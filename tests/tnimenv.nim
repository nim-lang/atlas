import std/[unittest, envvars, options, os, paths, strutils, tempfiles]

import basic/context
import nimenv

const ReleaseIndex = """
{
  "2.2.10": {
    "linux_arm64": {
      "github_url": "https://example.invalid/github.tar.xz",
      "nimlang_url": "https://example.invalid/nimlang.tar.xz",
      "digest": "sha256:abc123"
    },
    "windows_x64": {
      "github_url": "https://example.invalid/nim.zip"
    }
  }
}
"""

suite "Nim environments":
  test "maps every binary release platform":
    check releasePlatform("linux", "amd64") == "linux_x64"
    check releasePlatform("linux", "i386") == "linux_x32"
    check releasePlatform("linux", "arm64") == "linux_arm64"
    check releasePlatform("linux", "arm") == "linux_armv7l"
    check releasePlatform("macosx", "amd64") == "macosx_x64"
    check releasePlatform("darwin", "aarch64") == "macosx_arm64"
    check releasePlatform("windows", "amd64") == "windows_x64"
    check releasePlatform("win32", "i686") == "windows_x32"
    check releasePlatform("freebsd", "amd64") == ""
    check releasePlatform("macosx", "i386") == ""

  test "maps the current host when it has binary releases":
    when defined(linux) or defined(macosx) or defined(windows):
      when defined(amd64) or defined(i386) or defined(arm64) or defined(arm):
        check hostReleasePlatform().len > 0

  test "prefers the nim-lang download URL":
    let release = findBinaryRelease(ReleaseIndex, "2.2.10", "linux_arm64")
    require release.isSome()
    check release.get().url == "https://example.invalid/nimlang.tar.xz"
    check release.get().digest == "sha256:abc123"

  test "falls back to the GitHub download URL":
    let release = findBinaryRelease(ReleaseIndex, "2.2.10", "windows_x64")
    require release.isSome()
    check release.get().url == "https://example.invalid/nim.zip"
    check release.get().digest == ""

  test "reports unavailable versions and platforms":
    check findBinaryRelease(ReleaseIndex, "2.2.8", "linux_arm64").isNone()
    check findBinaryRelease(ReleaseIndex, "2.2.10", "macosx_arm64").isNone()

  test "rejects a release without a download URL":
    expect ValueError:
      discard findBinaryRelease(
        "{\"2.2.10\":{\"linux_x64\":{}}}", "2.2.10", "linux_x64")

  test "computes and checks SHA-256 release digests":
    let path = genTempPath("atlas_sha256_", ".txt")
    defer:
      if fileExists(path):
        removeFile(path)
    writeFile(path, "abc")

    const Expected = "ba7816bf8f01cfea414140de5dae2223" &
      "b00361a396177a9cb410ff61f20015ad"
    check sha256File(path) == Expected
    check digestMatches(path, "sha256:" & Expected)
    check not digestMatches(path, "sha256:" & repeat('0', 64))

  test "uses Nim's standard build script":
    when defined(windows):
      check NimBuildScript == "build_all.bat"
    else:
      check NimBuildScript == "build_all.sh"

  test "adds the absolute Nim bin directory to GITHUB_PATH":
    let oldContext = context()
    let hadGitHubPath = existsEnv("GITHUB_PATH")
    let oldGitHubPath = getEnv("GITHUB_PATH")
    let projectDir = Path(genTempPath("atlas github path ", ""))
    let githubPath = projectDir / Path"github_path"
    let binDir = projectDir / Path"deps" / Path"nim-2.2.10" / Path"bin"
    defer:
      setContext(oldContext)
      if hadGitHubPath:
        putEnv("GITHUB_PATH", oldGitHubPath)
      else:
        delEnv("GITHUB_PATH")
      if dirExists($projectDir):
        removeDir($projectDir)

    createDir($binDir)
    writeFile($githubPath, "already-present\n")
    putEnv("GITHUB_PATH", $githubPath)
    setContext(AtlasContext(projectDir: projectDir, depsDir: Path"deps"))

    check addNimEnvToGitHubPath("2.2.10")
    check readFile($githubPath) == "already-present\n" & $binDir.absolutePath() & "\n"
