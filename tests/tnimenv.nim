import std/[unittest, envvars, options, os, osproc, paths, strutils, tables, tempfiles]

import basic/[context, sha256]
import atlas
import confighandler
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

proc runGit(dir: Path; args: string): string =
  let (output, code) = execCmdEx("git -C " & quoteShell($dir) & " " & args)
  doAssert code == 0, output
  result = output.strip()

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

    const AbcDigest = "ba7816bf8f01cfea414140de5dae2223" &
      "b00361a396177a9cb410ff61f20015ad"
    writeFile(path, "abc")
    check sha256File(path) == AbcDigest
    check digestMatches(path, "sha256:" & AbcDigest)
    check not digestMatches(path, "sha256:" & repeat('0', 64))

    writeFile(path, "")
    check sha256File(path) == "e3b0c44298fc1c149afbf4c8996fb924" &
      "27ae41e4649b934ca495991b7852b855"

    writeFile(path, "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
    check sha256File(path) == "248d6a61d20638b8e5c026930c3e6039" &
      "a33ce45964ff2167f6ecedd419db06c1"

    writeFile(path, repeat('a', 1_000_000))
    check sha256File(path) == "cdc76e5c9914fb9281a1c7e284d73e67" &
      "f1809a48a497200e046d39ccc7112cd0"

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

  test "builds custom Git refs and records their SHAs":
    let oldContext = context()
    let projectDir = Path(genTempPath("atlas nim env project ", ""))
    let repoDir = Path(genTempPath("atlas nim env repo ", ""))
    defer:
      setContext(oldContext)
      if dirExists($projectDir):
        removeDir($projectDir)
      if dirExists($repoDir):
        removeDir($repoDir)

    createDir($projectDir)
    createDir($repoDir)
    writeFile($(projectDir / Path"atlas.config"), "{}\n")
    discard runGit(repoDir, "init")
    discard runGit(repoDir, "config user.email atlas@example.invalid")
    discard runGit(repoDir, "config user.name Atlas")
    when defined(windows):
      writeFile($(repoDir / Path"build_all.bat"), "@echo off\nmkdir bin\ntype nul > bin\\nim.exe\n")
    else:
      writeFile($(repoDir / Path"build_all.sh"), "mkdir -p bin\ntouch bin/nim\n")
    writeFile($(repoDir / Path"compiler.nim"), "discard\n")
    discard runGit(repoDir, "add .")
    discard runGit(repoDir, "commit -m initial")
    discard runGit(repoDir, "checkout -b custom")
    writeFile($(repoDir / Path"compiler.nim"), "echo \"custom\"\n")
    discard runGit(repoDir, "commit -am custom")
    let sha = runGit(repoDir, "rev-parse HEAD")

    let branchSource = NimSourceSpec(remoteUrl: $repoDir, gitRef: "custom")
    setContext(AtlasContext())
    atlasRun(@[
      "--project=" & $projectDir,
      "env",
      "custom-branch",
      "--git-url=" & branchSource.remoteUrl,
      "--git-ref=" & branchSource.gitRef
    ])
    setContext(AtlasContext(projectDir: projectDir, depsDir: Path"deps"))
    readConfig()
    let shaSource = NimSourceSpec(remoteUrl: $repoDir, gitRef: sha)
    check setupNimEnv("custom-sha", false, source = shaSource)

    let config = readConfigFile(projectDir / Path"atlas.config")
    check config.nimEnvs["custom-branch"].url == $repoDir
    check config.nimEnvs["custom-branch"].gitRef == "custom"
    check config.nimEnvs["custom-branch"].sha == sha
    check config.nimEnvs["custom-sha"].sha == sha
    check "\"sha\": \"" & sha & "\"" in readFile($(projectDir / Path"atlas.config"))
