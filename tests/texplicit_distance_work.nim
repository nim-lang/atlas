import std/[os, osproc, paths, strutils, tempfiles, unittest]
import basic/[context, deptypes, gitops, nimblecontext, pkgurls, versions]
import releaseinfo

proc git(repo: string; args: varargs[string]): string =
  let cmd = "git -C " & quoteShell(repo) & " " & quoteShellCommand(args)
  let (output, status) = execCmdEx(cmd)
  doAssert status == 0, output
  output.strip()

suite "explicit release distance work":
  test "history length does not multiply distance calculations":
    let ws = createTempDir("atlas-explicit-distance-", "")
    let oldContext = context()
    let oldTrace = getEnv("GIT_TRACE")
    let hadTrace = existsEnv("GIT_TRACE")
    defer:
      setContext(oldContext)
      if hadTrace: putEnv("GIT_TRACE", oldTrace)
      else: delEnv("GIT_TRACE")
      removeDir(ws)

    setContext(AtlasContext(projectDir: Path(ws), depsDir: Path"deps"))
    discard git(ws, "init", "-b", "master")
    discard git(ws, "config", "user.name", "test-user")
    discard git(ws, "config", "user.email", "test@example.com")
    for i in 0..5:
      writeFile(ws / "widget.nimble",
        "version = \"1.2.3\"\ndescription = \"revision " & $i & "\"\n")
      discard git(ws, "add", "widget.nimble")
      discard git(ws, "commit", "-m", "metadata " & $i)
    let target = git(ws, "rev-parse", "HEAD")
    var nc = createUnfilledNimbleContext()
    var pkg = Package(url: nc.createUrl("file://" & ws), ondisk: Path(ws),
      isLocalOnly: true)
    let trace = ws / "git-trace.log"
    putEnv("GIT_TRACE", trace)
    let info = nc.loadPackageReleaseInfo(pkg, ExplicitVersions,
      @[VersionTag(v: Version("#" & target), c: initCommitHash(target, FromNone))])
    check info.releases.len == 1
    if info.releases.len == 1:
      check $info.releases[0][0].version == "1.2.3+5"
      check info.releases[0][0].commit.h == target
    # One ancestry/distance query selects the version base and one decorates
    # the requested release. No distance queries belong to historical candidates.
    let commands = readFile(trace)
    check commands.count("merge-base --is-ancestor") == 2
    check commands.count("rev-list --count") == 2
