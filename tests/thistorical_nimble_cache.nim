import std/[os, osproc, paths, strutils, tempfiles, unittest]
import basic/[context, dependencycache, deptypes, gitops, nimblecontext, pkgurls, versions]
import releaseinfo

proc git(repo: string; args: varargs[string]): string =
  let (output, status) = execCmdEx("git -C " & quoteShell(repo) & " " & quoteShellCommand(args))
  doAssert status == 0, output
  output.strip()

suite "historical Nimble content cache":
  setup:
    let ws = createTempDir("atlas-nimble-cache-", "")
    let oldContext = context()
    let hadTrace = existsEnv("GIT_TRACE")
    let oldTrace = getEnv("GIT_TRACE")
    setContext(AtlasContext(projectDir: Path(ws), depsDir: Path"deps"))
    discard git(ws, "init", "-b", "master")
    discard git(ws, "config", "user.name", "test-user")
    discard git(ws, "config", "user.email", "test@example.com")
    writeFile(ws / "widget.nimble", "version = \"1.0.0\"\nrequires \"dep\"\n")
    discard git(ws, "add", "widget.nimble")
    discard git(ws, "commit", "-m", "first version")
    let first = initCommitHash(git(ws, "rev-parse", "HEAD"), FromNone)
    var nc = createUnfilledNimbleContext()
    nc.put("dep", nc.createUrl("https://example.com/first"))
    let pkg = Package(url: nc.createUrl("https://example.com/widget"), ondisk: Path(ws))
  teardown:
    setContext(oldContext)
    if hadTrace: putEnv("GIT_TRACE", oldTrace)
    else: delEnv("GIT_TRACE")
    removeDir(ws)

  test "a second context reuses contents but resolves requirements again":
    let tag = VersionTag(v: Version"1.0.0", c: first)
    let initial = nc.processNimbleRelease(pkg, tag)
    check $initial.version == "1.0.0"
    check fileExists($nimbleFileCachePath(pkg, first))
    var other = createUnfilledNimbleContext()
    let replacement = other.createUrl("https://example.com/replacement")
    other.put("dep", replacement)
    let trace = ws / "cached-trace.log"
    writeFile(trace, "")
    putEnv("GIT_TRACE", trace)
    let cached = other.processNimbleRelease(pkg, tag)
    check cached.requirements[0][0] == replacement
    check cached.requirements[0][0] != initial.requirements[0][0]
    check readFile(trace).len == 0

  test "new commits and worktree changes do not reuse old contents":
    discard nc.processNimbleRelease(pkg, VersionTag(v: Version"1.0.0", c: first))
    writeFile(ws / "widget.nimble", "version = \"2.0.0\"\n")
    discard git(ws, "add", "widget.nimble")
    discard git(ws, "commit", "-m", "second version")
    let second = initCommitHash(git(ws, "rev-parse", "HEAD"), FromNone)
    let updated = nc.processNimbleRelease(pkg, VersionTag(v: Version"2.0.0", c: second))
    check $updated.version == "2.0.0"
    let old = nc.processNimbleRelease(pkg, VersionTag(v: Version"1.0.0", c: first))
    check $old.version == "1.0.0"
    writeFile(ws / "widget.nimble", "version = \"3.0.0\"\n")
    let worktree = nc.processNimbleRelease(pkg, VersionTag(v: Version"#head", c: second))
    check $worktree.version == "3.0.0"

  test "a corrupt cache falls back to Git":
    let tag = VersionTag(v: Version"1.0.0", c: first)
    discard nc.processNimbleRelease(pkg, tag)
    writeFile($nimbleFileCachePath(pkg, first), "not valid JSON")
    let recovered = nc.processNimbleRelease(pkg, tag)
    check recovered.status == Normal
    check $recovered.version == "1.0.0"

  test "subdirectory packages at the same commit have separate cache entries":
    createDir(ws / "nested")
    writeFile(ws / "nested" / "widget.nimble", "version = \"4.0.0\"\n")
    discard git(ws, "add", "nested/widget.nimble")
    discard git(ws, "commit", "-m", "nested package")
    let commit = initCommitHash(git(ws, "rev-parse", "HEAD"), FromNone)
    let nested = Package(url: pkg.url, ondisk: pkg.ondisk, subdir: Path"nested")
    let outerRelease = nc.processNimbleRelease(pkg, VersionTag(v: Version"1.0.0", c: commit))
    let innerRelease = nc.processNimbleRelease(nested, VersionTag(v: Version"4.0.0", c: commit))
    check $outerRelease.version == "1.0.0"
    check $innerRelease.version == "4.0.0"
    check nimbleFileCachePath(pkg, commit) != nimbleFileCachePath(nested, commit)

  test "short hashes and missing objects are not cached":
    let short = initCommitHash(first.h[0..6], FromNone)
    check nimbleFileCachePath(pkg, short).string.len == 0
    let missing = initCommitHash("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", FromNone)
    let absent = loadGitNimbleFiles(pkg, missing)
    check absent.len == 0
    check not fileExists($nimbleFileCachePath(pkg, missing))
