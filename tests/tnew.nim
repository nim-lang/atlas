import std/[os, paths, unittest]
import basic/[context, pkgurls]
import atlas

template withDir(dir: string; body: untyped) =
  let old = os.getCurrentDir()
  try:
    os.setCurrentDir(dir)
    body
  finally:
    os.setCurrentDir(old)

suite "new command":
  var
    root: Path
    remoteRepo: Path
    workDir: Path

  setup:
    setContext(AtlasContext())
    setAtlasVerbosity(Error)

    root = Path("tests/ws_new_command").absolutePath
    remoteRepo = root / Path"remote" / Path"newpkg"
    workDir = root / Path"work"

    if dirExists($root):
      removeDir($root)
    createDir($(root / Path"remote"))
    createDir($workDir)
    createDir($remoteRepo)

    withDir $remoteRepo:
      doAssert execShellCmd("git init") == 0
      doAssert execShellCmd("git config user.name \"atlas-tests\"") == 0
      doAssert execShellCmd("git config user.email \"atlas-tests@example.com\"") == 0
      doAssert execShellCmd("git config commit.gpgsign false") == 0
      writeFile("newpkg.nimble", "version = \"0.1.0\"\n")
      writeFile("newpkg.nim", "discard\n")
      doAssert execShellCmd("git add newpkg.nimble newpkg.nim") == 0
      doAssert execShellCmd("git commit -m \"init new project\"") == 0

  teardown:
    if dirExists($root):
      removeDir($root)
    setContext(AtlasContext())

  test "clones url into new project directory":
    withDir $workDir:
      let sourceUrl = toWindowsFileUrl("file://" & $remoteRepo.absolutePath)
      atlasRun(@["new", sourceUrl])

      let cloned = (workDir / Path"newpkg").absolutePath
      check dirExists($cloned)
      check dirExists($(cloned / Path".git"))
      check fileExists($(cloned / Path"newpkg.nimble"))
      check dirExists($(cloned / Path"deps"))
      check fileExists($(cloned / Path"deps" / Path"atlas.config"))
      check project() == cloned
