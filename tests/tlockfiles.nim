## Tests for Atlas lock-file creation, replay, and change detection.

import std/[json, os, osproc, paths, strutils, tables, unittest]

import atlas
import basic/[context, gitops, lockfiletypes, pkgurls, reporters, versions]
import lockfiles

type
  LockFixture = object
    baseDir: Path
    projectDir: Path
    dependencyDir: Path
    dependencyUrl: string
    dependencyCommit: string
    nimbleContent: string

proc git(dir, args: string) =
  let (outp, code) = execCmdEx("git -C " & quoteShell(dir) & " " & args)
  doAssert code == 0, "git " & args & " failed in " & dir & ":\n" & outp

proc freshDir(name: string): string =
  result = os.getCurrentDir() / "tests" / name
  if dirExists(result):
    removeDir(result)
  createDir(result)

proc setupDep(name, url: string): tuple[url, commit: string] =
  ## Creates `deps/<name>` as a one-commit git repo with `origin` set to `url`.
  let depDir = "deps" / name
  createDir(depDir)
  git(depDir, "init -q")
  git(depDir, "config user.email test@example.com")
  git(depDir, "config user.name test-user")
  git(depDir, "remote add origin " & quoteShell(url))
  writeFile(depDir / "f.txt", "hello")
  git(depDir, "add .")
  git(depDir, "commit -q -m initial")

  let gotUrl = getCanonicalUrl(Path depDir)
  let gotCommit = currentGitCommit(Path depDir)
  doAssert gotCommit.isFull, "expected a full commit hash, got: " & $gotCommit
  result = (gotUrl, gotCommit.h)

template withCwd(dir: string; body: untyped) =
  let saved = os.getCurrentDir()
  setCurrentDir(dir)
  try:
    body
  finally:
    setCurrentDir(saved)

proc createLockFixture(name: string): LockFixture =
  # Keep the fixture on the checkout's volume. GitHub's Windows checkout is on
  # D:, while getTempDir() is on C:. Cross-volume path behavior is unrelated to
  # the lock-file behavior covered here.
  result.baseDir = freshDir("ws_lockfiles_integration_" & name).Path
  result.projectDir = result.baseDir / Path"workspace"
  result.dependencyDir = result.baseDir / Path"source" / Path"lockeddep"

  createDir($result.projectDir)
  createDir($result.dependencyDir)

  writeFile($(result.dependencyDir / Path"lockeddep.nimble"),
    "version \"1.0.0\"\n")
  writeFile($(result.dependencyDir / Path"marker.txt"), "locked revision\n")
  git($result.dependencyDir, "init -q")
  git($result.dependencyDir, "config user.email atlas-tests@example.com")
  git($result.dependencyDir, "config user.name Atlas-Tests")
  git($result.dependencyDir, "add lockeddep.nimble marker.txt")
  git($result.dependencyDir, "commit -q -m add-locked-dependency")
  git($result.dependencyDir, "tag v1.0.0")

  result.dependencyCommit = currentGitCommit(result.dependencyDir).h
  result.dependencyUrl = toWindowsFileUrl(
    "file://" & $result.dependencyDir.absolutePath)
  result.nimbleContent =
    "version \"0.1.0\"\n" &
    "requires \"" & result.dependencyUrl & " >= 1.0.0\"\n"
  writeFile($(result.projectDir / Path"lockfixture.nimble"), result.nimbleContent)

proc removeLockFixture(fixture: LockFixture) =
  if dirExists($fixture.baseDir):
    removeDir($fixture.baseDir)

proc installFixture(fixture: LockFixture) =
  resetAtlasReporter()
  setAtlasVerbosity(Error)
  setContext AtlasContext()
  withCwd $fixture.projectDir:
    atlasRun(@["--deps=deps", "--project=.", "--noexec", "install"])

suite "Lockfile listChanged":
  setup:
    # project()=="." while cwd is the fixture root, deps live under "deps".
    setContext AtlasContext(projectDir: Path".", depsDir: Path"deps")

  test "atlas.lock: matching deps produce no warnings":
    let root = freshDir("ws_lockfiles_clean")
    defer:
      removeDir(root)

    withCwd root:
      let exp = setupDep("foo", "https://example.com/foo")

      var lf = LockFile(items: initOrderedTable[string, LockFileEntry]())
      lf.items["foo"] = LockFileEntry(
        dir: Path("deps" / "foo"), url: exp.url, commit: exp.commit)
      # hostOS left empty so the nim/gcc/clang version comparison is skipped.
      write(lf, "atlas.lock")

      resetAtlasReporter()
      listChanged(Path"atlas.lock")
      check atlasReporter.warnings == 0

  test "atlas.lock: a drifted commit is detected":
    let root = freshDir("ws_lockfiles_drift")
    defer:
      removeDir(root)

    withCwd root:
      let exp = setupDep("foo", "https://example.com/foo")

      var lf = LockFile(items: initOrderedTable[string, LockFileEntry]())
      lf.items["foo"] = LockFileEntry(
        dir: Path("deps" / "foo"), url: exp.url, commit: exp.commit)
      write(lf, "atlas.lock")

      git("deps" / "foo", "commit -q --allow-empty -m second")

      resetAtlasReporter()
      listChanged(Path"atlas.lock")
      check atlasReporter.warnings >= 1

  test "nimble.lock: conversion locates deps by package name":
    let root = freshDir("ws_lockfiles_nimble")
    defer:
      removeDir(root)

    withCwd root:
      # The package is `unittest2`, but the repository is `nim-unittest2`.
      let url = "https://github.com/status-im/nim-unittest2"
      let exp = setupDep("unittest2", url)

      let nl = %*{
        "version": 2,
        "packages": {
          "unittest2": {
            "version": "0.2.4",
            "vcsRevision": exp.commit,
            "url": exp.url,
            "downloadMethod": "git",
            "dependencies": [],
            "checksums": {"sha1": "0000000000000000000000000000000000000000"}
          }
        },
        "tasks": {}
      }
      writeFile("nimble.lock", pretty(nl))

      resetAtlasReporter()
      listChanged(NimbleLockFileName)
      check atlasReporter.warnings == 0

suite "Lockfile integration":
  test "pin creates an Atlas lock file from installed dependencies":
    let oldContext = context()
    let fixture = createLockFixture("pin")
    defer:
      resetAtlasReporter()
      setContext(oldContext)
      removeLockFixture(fixture)

    fixture.installFixture()
    require atlasErrors() == 0

    withCwd $fixture.projectDir:
      let nimCfg = readFile("nim.cfg")
      atlasRun(@["pin"])

      require atlasErrors() == 0
      require fileExists("atlas.lock")

      let lock = readLockFile(Path"atlas.lock")
      check lock.items.len == 1
      check lock.items.hasKey("lockeddep")
      if lock.items.hasKey("lockeddep"):
        let entry = lock.items["lockeddep"]
        check entry.dir == Path"$deps" / Path"lockeddep"
        check entry.url == fixture.dependencyUrl
        check entry.commit == fixture.dependencyCommit
      check lock.nimcfg.join("\n") == nimCfg
      check lock.nimbleFile.filename == Path"lockfixture.nimble"
      check lock.nimbleFile.content.join("\n") == fixture.nimbleContent

  test "replay restores the locked revision and project files":
    let oldContext = context()
    let fixture = createLockFixture("replay")
    defer:
      resetAtlasReporter()
      setContext(oldContext)
      removeLockFixture(fixture)

    fixture.installFixture()
    require atlasErrors() == 0

    withCwd $fixture.projectDir:
      let nimCfg = readFile("nim.cfg")
      atlasRun(@["pin", "saved.lock"])
      require atlasErrors() == 0

      writeFile($(fixture.dependencyDir / Path"marker.txt"), "new revision\n")
      git($fixture.dependencyDir, "add marker.txt")
      git($fixture.dependencyDir, "commit -q -m advance-dependency")
      check currentGitCommit(fixture.dependencyDir).h != fixture.dependencyCommit

      removeDir("deps")
      writeFile("nim.cfg", "corrupted config\n")
      writeFile("lockfixture.nimble", "version \"9.9.9\"\n")

      atlasRun(@["replay", "saved.lock"])

      let installedDependency = Path"deps" / Path"lockeddep"
      require atlasErrors() == 0
      require dirExists($installedDependency)
      check currentGitCommit(installedDependency).h == fixture.dependencyCommit
      check readFile($(installedDependency / Path"marker.txt")) ==
        "locked revision\n"
      check readFile("nim.cfg") == nimCfg
      check readFile("lockfixture.nimble") == fixture.nimbleContent
