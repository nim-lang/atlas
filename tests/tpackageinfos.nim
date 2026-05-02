import std/[unittest, os, times, paths]
import basic/context
import basic/packageinfos

suite "packages list":
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
