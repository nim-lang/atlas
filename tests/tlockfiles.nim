import std/[os, paths, strutils, tables, unittest]

import atlas
import basic/[context, gitops, lockfiletypes, pkgurls, reporters]
import integration_test_utils

type
  LockFixture = object
    baseDir: Path
    projectDir: Path
    dependencyDir: Path
    dependencyUrl: string
    dependencyCommit: string
    nimbleContent: string

proc createLockFixture(name: string): LockFixture =
  result.baseDir = getTempDir().Path / Path("atlas_lockfiles_" & name)
  result.projectDir = result.baseDir / Path"workspace"
  result.dependencyDir = result.baseDir / Path"source" / Path"lockeddep"

  if dirExists($result.baseDir):
    removeDir($result.baseDir)
  createDir($result.projectDir)
  createDir($result.dependencyDir)

  withDir $result.dependencyDir:
    writeFile("lockeddep.nimble", "version \"1.0.0\"\n")
    writeFile("marker.txt", "locked revision\n")
    exec "git init"
    exec "git config user.email atlas-tests@example.com"
    exec "git config user.name Atlas Tests"
    exec "git add lockeddep.nimble marker.txt"
    exec "git commit -m \"Add locked dependency\""
    exec "git tag v1.0.0"

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
  setContext AtlasContext()
  setAtlasVerbosity(Error)
  withDir $fixture.projectDir:
    atlasRun(@["--deps=deps", "--project=.", "--noexec", "install"])

suite "lock file integration":
  test "pin creates an Atlas lock file from installed dependencies":
    let oldContext = context()
    let fixture = createLockFixture("pin")
    defer:
      setContext(oldContext)
      removeLockFixture(fixture)

    fixture.installFixture()
    withDir $fixture.projectDir:
      let nimCfg = readFile("nim.cfg")
      atlasRun(@["pin"])

      check atlasErrors() == 0
      check fileExists("atlas.lock")

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
      setContext(oldContext)
      removeLockFixture(fixture)

    fixture.installFixture()
    withDir $fixture.projectDir:
      let nimCfg = readFile("nim.cfg")
      atlasRun(@["pin", "saved.lock"])

      withDir $fixture.dependencyDir:
        writeFile("marker.txt", "new revision\n")
        exec "git add marker.txt"
        exec "git commit -m \"Advance dependency\""
      check currentGitCommit(fixture.dependencyDir).h != fixture.dependencyCommit

      removeDir("deps")
      writeFile("nim.cfg", "corrupted config\n")
      writeFile("lockfixture.nimble", "version \"9.9.9\"\n")

      atlasRun(@["replay", "saved.lock"])

      let installedDependency = Path"deps" / Path"lockeddep"
      check atlasErrors() == 0
      check dirExists($installedDependency)
      check currentGitCommit(installedDependency).h == fixture.dependencyCommit
      check readFile($(installedDependency / Path"marker.txt")) ==
        "locked revision\n"
      check readFile("nim.cfg") == nimCfg
      check readFile("lockfixture.nimble") == fixture.nimbleContent
