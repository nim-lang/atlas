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

    # Later graph passes already hold the regular release at this commit.
    # Short pins and #head must reuse it without any historical Git reads.
    if info.releases.len == 1:
      pkg.versions[info.releases[0][0]] = info.releases[0][1]
    let repeatedTrace = ws / "repeated-trace.log"
    putEnv("GIT_TRACE", repeatedTrace)
    let repeated = nc.loadPackageReleaseInfo(pkg, ExplicitVersions, @[
      VersionTag(v: Version("#" & target[0..6])),
      VersionTag(v: Version"#head")])
    check repeated.releases.len == 2
    if repeated.releases.len == 2:
      check $repeated.releases[0][0].version == "1.2.3+5"
      check repeated.releases[0][0].vtag.isPinned
      check not repeated.releases[0][0].vtag.isTip
      check repeated.releases[1][0].vtag.isTip
      check not repeated.releases[1][0].vtag.isPinned
    let repeatedCommands = readFile(repeatedTrace)
    for command in ["log --format", "ls-tree", " show ", "merge-base", "rev-list"]:
      check command notin repeatedCommands

    let branch = nc.loadPackageReleaseInfo(pkg, ExplicitVersions,
      @[VersionTag(v: Version"#master")])
    check branch.releases.len == 1
    if branch.releases.len == 1:
      pkg.versions[branch.releases[0][0]] = branch.releases[0][1]

    # A moving ref must still resolve again; new metadata cannot reuse the old tip.
    writeFile(ws / "widget.nimble", "version = \"2.0.0\"\n")
    discard git(ws, "add", "widget.nimble")
    discard git(ws, "commit", "-m", "new version")
    let moved = nc.loadPackageReleaseInfo(pkg, ExplicitVersions,
      @[VersionTag(v: Version"#head")])
    check moved.releases.len == 1
    if moved.releases.len == 1:
      check $moved.releases[0][0].version == "2.0.0"
      check moved.releases[0][0].commit.h != target
    let movedBranch = nc.loadPackageReleaseInfo(pkg, ExplicitVersions,
      @[VersionTag(v: Version"#master")])
    check movedBranch.releases.len == 1
    if movedBranch.releases.len == 1:
      check $movedBranch.releases[0][1].version == "2.0.0"
      check movedBranch.releases[0][0].commit.h != target
