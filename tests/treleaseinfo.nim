import std/[os, osproc, paths, sequtils, strutils, tempfiles, unittest]

import basic/[context, deptypes, nimblecontext, pkgurls, versions]
import releaseinfo

proc runGit(args: openArray[string]; workdir: string): string =
  let cmd = "git " & args.mapIt(quoteShell(it)).join(" ")
  let res = execCmdEx(cmd, workingDir = workdir)
  check res.exitCode == 0
  res.output

proc writeText(path: string; contents: string) =
  createDir(parentDir(path))
  writeFile(path, contents)

suite "release info":
  test "skips unversioned nimble history entries":
    let oldCtx = context()
    let root = createTempDir("atlas-releaseinfo", "unversioned-")
    defer:
      setContext(oldCtx)
      if dirExists(root):
        removeDir(root)

    let repo = root / "pkg"
    createDir(repo)
    discard runGit(["init", "-b", "main"], repo)
    discard runGit(["config", "user.name", "Atlas Tests"], repo)
    discard runGit(["config", "user.email", "atlas-tests@example.com"], repo)

    writeText(repo / "pkg.nimble", "description = \"unversioned\"\n")
    discard runGit(["add", "pkg.nimble"], repo)
    discard runGit(["commit", "-m", "unversioned"], repo)
    let unversionedCommit = runGit(["rev-parse", "HEAD"], repo).strip()

    writeText(repo / "pkg.nimble", "version = \"0.1.0\"\n")
    discard runGit(["add", "pkg.nimble"], repo)
    discard runGit(["commit", "-m", "versioned"], repo)

    var nc = createUnfilledNimbleContext()
    let url = createUrlSkipPatterns("https://github.com/example/pkg", skipDirTest = true)
    var pkg = Package(url: url, ondisk: Path(repo), state: Found, isLocalOnly: true)
    var ctx = oldCtx
    ctx.depsDir = Path(root) / Path"deps"
    setContext(ctx)

    let info = nc.loadPackageReleaseInfo(pkg, AllReleases, @[])
    check info.releases.len == 1
    check info.releases[0][0].vtag.version == Version"0.1.0"
    check info.releases.allIt(it[0].vtag.commit.h != unversionedCommit)
