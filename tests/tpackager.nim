import std/[algorithm, json, os, osproc, paths, sequtils, strutils, tempfiles, times, unittest, uri]

import packager/packager
import packager/alldeps
import packager/archivehelpers
import packager/cacheharvest
import packager/githubheadcheck
import basic/context
import basic/dependencycache
import basic/gitops

proc withEnvVar(name: string; value: string; body: proc() {.closure.}) =
  let hadOldValue = existsEnv(name)
  let oldValue = getEnv(name)
  if value.len == 0:
    putEnv(name, "")
  else:
    putEnv(name, value)
  try:
    body()
  finally:
    if hadOldValue:
      putEnv(name, oldValue)
    else:
      delEnv(name)

proc runGit(args: openArray[string]; workdir = ""): string =
  let cmd = "git " & args.mapIt(quoteShell(it)).join(" ")
  let res =
    if workdir.len > 0:
      execCmdEx(cmd, workingDir = workdir)
    else:
      execCmdEx(cmd)
  check res.exitCode == 0
  res.output

proc writeText(path: string; contents: string) =
  createDir(parentDir(path))
  writeFile(path, contents)

proc fileUri(path: Path): Uri =
  parseUri("file://" & $path)

proc jsonStringSeq(node: JsonNode): seq[string] =
  for item in node:
    result.add item.getStr()
  result.sort()

proc allDeps(path: string): JsonNode =
  let root = parseFile(path)
  root["allDeps"]

suite "packager daemon options":
  test "daemon interval parser supports suffixes":
    check parseDaemonInterval("45") == 45
    check parseDaemonInterval("30s") == 30
    check parseDaemonInterval("15m") == 15 * 60
    check parseDaemonInterval("2h") == 2 * 60 * 60
    check parseDaemonInterval("1d") == 24 * 60 * 60

  test "daemon interval parser rejects invalid values":
    expect ValueError:
      discard parseDaemonInterval("")
    expect ValueError:
      discard parseDaemonInterval("0")
    expect ValueError:
      discard parseDaemonInterval("abc")

  test "packager options default daemon interval to one hour":
    var args: seq[string]
    let opts = parseAtlasPackagerOptions(@[], "test", args)
    check not opts.daemon.enabled
    check opts.daemon.intervalSeconds == DefaultDaemonIntervalSeconds

  test "packager options parse daemon schedule":
    var args: seq[string]
    let opts = parseAtlasPackagerOptions(
      @["--daemon", "--interval=20m", "packages.json", "pkgs"],
      "test",
      args
    )
    check opts.daemon.enabled
    check opts.daemon.intervalSeconds == 20 * 60
    check args == @["packages.json", "pkgs"]

  test "daemon sleep floors elapsed and overrun intervals":
    check daemonSleepMilliseconds(initDuration(milliseconds = 3_000)) == 3_000
    check daemonSleepMilliseconds(initDuration(milliseconds = 0)) == 0
    check daemonSleepMilliseconds(initDuration(milliseconds = -500)) == 0

suite "packager env options":
  test "packager options read env defaults":
    withEnvVar(EnvPackages, "env-pkgs") do:
      withEnvVar(EnvOnly, "alpha,beta") do:
        withEnvVar(EnvIgnore, "gamma") do:
          withEnvVar(EnvUpdateRepos, "true") do:
            withEnvVar(EnvGitHubApiChunkSize, "17") do:
              withEnvVar(EnvCompression, "xz") do:
                withEnvVar(EnvThreads, "3") do:
                  withEnvVar(EnvEphemeral, "yes") do:
                    var args: seq[string]
                    let opts = parseAtlasPackagerOptions(@[], "test", args)
                    check opts.metadataDir == Path("env-pkgs")
                    check opts.packageNames == @["alpha", "beta"]
                    check opts.ignoredPackageNames == @["gamma"]
                    check opts.updateRepos
                    check opts.createTarballs
                    check opts.githubApiChunkSize == 17
                    check opts.compressions == @[acXz]
                    check opts.threadCount == 3
                    check opts.ephemeral

  test "cli options override env defaults":
    withEnvVar(EnvPackages, "env-pkgs") do:
      withEnvVar(EnvOnly, "alpha,beta") do:
        withEnvVar(EnvIgnore, "gamma") do:
          withEnvVar(EnvUpdateRepos, "false") do:
            withEnvVar(EnvGitHubApiChunkSize, "17") do:
              withEnvVar(EnvCompression, "xz") do:
                withEnvVar(EnvThreads, "3") do:
                  withEnvVar(EnvEphemeral, "false") do:
                    var args: seq[string]
                    let opts = parseAtlasPackagerOptions(@[
                      "--packages=cli-pkgs",
                      "--only=delta",
                      "--ignore=epsilon,zeta",
                      "--update-repos",
                      "--no-tarballs",
                      "--retry-missing",
                      "--github-api-chunk-size=19",
                      "--compression=gzip",
                      "--threads=5",
                      "--ephemeral"
                    ], "test", args)
                    check opts.metadataDir == Path("cli-pkgs")
                    check opts.packageNames == @["delta"]
                    check opts.ignoredPackageNames == @["epsilon", "zeta"]
                    check opts.updateRepos
                    check not opts.createTarballs
                    check opts.retryMissing
                    check opts.githubApiChunkSize == 19
                    check opts.compressions == @[acGzip]
                    check opts.threadCount == 5
                    check opts.ephemeral

  test "regenerate tarballs overrides no tarballs when set later":
    var args: seq[string]
    let opts = parseAtlasPackagerOptions(
      @["--no-tarballs", "--regenerate-tarballs"],
      "test",
      args
    )
    check opts.createTarballs
    check opts.regenerateTarballs

  test "no tarballs can be set from env":
    withEnvVar(EnvNoTarballs, "true") do:
      var args: seq[string]
      let opts = parseAtlasPackagerOptions(@[], "test", args)
      check not opts.createTarballs

suite "packager mirrored repo helpers":
  test "bare repo shape without HEAD commit is not usable":
    let root = createTempDir("atlas-packager", "broken-bare-test-")
    defer: removeDir(root)

    let bareRepo = root / "pkg.git"
    createDir(bareRepo / "objects")
    createDir(bareRepo / "refs")
    writeText(bareRepo / "HEAD", "ref: refs/heads/main\n")
    writeText(bareRepo / "config", "[core]\n\tbare = true\n")

    check isBareGitRepo(Path(bareRepo))
    check not isUsableBareGitRepo(Path(bareRepo))

  test "bare clone without retries preserves git error output":
    let root = createTempDir("atlas-packager", "bare-clone-error-")
    defer: removeDir(root)

    let missingRepo = root / "missing"
    let dest = root / "pkg.git"
    let (status, msg) = cloneBareSingleBranch(fileUri(Path(missingRepo)), Path(dest), retries = 0)

    check status != CloneStatus.Ok
    check msg.len > 0

  test "bare single-branch clone omits non-default branches":
    let root = createTempDir("atlas-packager", "mirror-test-")
    defer: removeDir(root)

    let srcRepo = root / "source"
    createDir(srcRepo)
    discard runGit(["init", "-b", "main"], srcRepo)
    discard runGit(["config", "user.name", "Atlas Tests"], srcRepo)
    discard runGit(["config", "user.email", "atlas-tests@example.com"], srcRepo)
    writeText(srcRepo / "pkg.nimble", "version = \"0.1.0\"\n")
    discard runGit(["add", "pkg.nimble"], srcRepo)
    discard runGit(["commit", "-m", "main commit"], srcRepo)
    discard runGit(["tag", "v0.1.0"], srcRepo)

    discard runGit(["checkout", "-b", "feature"], srcRepo)
    writeText(srcRepo / "feature.txt", "feature branch only\n")
    discard runGit(["add", "feature.txt"], srcRepo)
    discard runGit(["commit", "-m", "feature commit"], srcRepo)
    discard runGit(["checkout", "main"], srcRepo)

    let mirrorRepo = root / "pkg.git"
    let (status, msg) = cloneBareSingleBranch(fileUri(Path(srcRepo)), Path(mirrorRepo))
    check status == CloneStatus.Ok
    check msg.len == 0
    check dirExists(mirrorRepo)
    check fileExists(mirrorRepo / "info/refs")

    let remotes = runGit(["remote"], mirrorRepo)
    check "origin" in remotes

    let refs = runGit(["for-each-ref", "--format=%(refname)"], mirrorRepo)
    check "refs/heads/main" in refs
    check "refs/heads/feature" notin refs
    check "refs/tags/v0.1.0" in refs

  test "bare repo update and worktree expose default branch content":
    let root = createTempDir("atlas-packager", "worktree-test-")
    defer: removeDir(root)

    let srcRepo = root / "source"
    createDir(srcRepo)
    discard runGit(["init", "-b", "main"], srcRepo)
    discard runGit(["config", "user.name", "Atlas Tests"], srcRepo)
    discard runGit(["config", "user.email", "atlas-tests@example.com"], srcRepo)
    writeText(srcRepo / "pkg.nimble", "version = \"0.1.0\"\n")
    discard runGit(["add", "pkg.nimble"], srcRepo)
    discard runGit(["commit", "-m", "initial"], srcRepo)

    let mirrorRepo = root / "pkg.git"
    let (status, msg) = cloneBareSingleBranch(fileUri(Path(srcRepo)), Path(mirrorRepo))
    check status == CloneStatus.Ok
    check msg.len == 0

    let worktree = root / "worktree"
    check addWorktreeFromBareRepo(Path(mirrorRepo), Path(worktree))
    check fileExists(worktree / "pkg.nimble")
    removeWorktreeFromBareRepo(Path(mirrorRepo), Path(worktree))
    check not dirExists(worktree)

    writeText(srcRepo / "README.md", "updated on main\n")
    discard runGit(["add", "README.md"], srcRepo)
    discard runGit(["commit", "-m", "update main"], srcRepo)
    discard runGit(["tag", "v0.2.0"], srcRepo)
    discard runGit(["checkout", "-b", "feature"], srcRepo)
    writeText(srcRepo / "feature.txt", "feature branch only\n")
    discard runGit(["add", "feature.txt"], srcRepo)
    discard runGit(["commit", "-m", "feature branch"], srcRepo)
    discard runGit(["checkout", "main"], srcRepo)

    check updateBareRepoDefaultBranch(Path(mirrorRepo))
    check fileExists(mirrorRepo / "info/refs")

    check addWorktreeFromBareRepo(Path(mirrorRepo), Path(worktree))
    check fileExists(worktree / "README.md")
    check not fileExists(worktree / "feature.txt")

    let tags = runGit(["tag"], worktree)
    check "v0.2.0" in tags

  test "bare repo worktree add prunes stale missing worktree registrations":
    let root = createTempDir("atlas-packager", "stale-worktree-test-")
    defer: removeDir(root)

    let srcRepo = root / "source"
    createDir(srcRepo)
    discard runGit(["init", "-b", "main"], srcRepo)
    discard runGit(["config", "user.name", "Atlas Tests"], srcRepo)
    discard runGit(["config", "user.email", "atlas-tests@example.com"], srcRepo)
    writeText(srcRepo / "pkg.nimble", "version = \"0.1.0\"\n")
    discard runGit(["add", "pkg.nimble"], srcRepo)
    discard runGit(["commit", "-m", "initial"], srcRepo)

    let mirrorRepo = root / "pkg.git"
    let (status, msg) = cloneBareSingleBranch(fileUri(Path(srcRepo)), Path(mirrorRepo))
    check status == CloneStatus.Ok
    check msg.len == 0

    let worktree = root / "worktree"
    check addWorktreeFromBareRepo(Path(mirrorRepo), Path(worktree))
    removeDir(worktree)

    check addWorktreeFromBareRepo(Path(mirrorRepo), Path(worktree))
    check fileExists(worktree / "pkg.nimble")

suite "packager retained index versioning":
  test "retained release cache version match requires current cache version":
    let root = createTempDir("atlas-packager", "index-version-")
    defer: removeDir(root)

    let indexPath = root / "index.json"
    writeFile(indexPath, $(%*{
      "releaseCacheVersion": PackageReleaseCacheVersion,
      "compressions": ["gzip"],
      "packages": []
    }))
    check retainedReleaseCacheVersionMatches(Path(root))

    writeFile(indexPath, $(%*{
      "releaseCacheVersion": PackageReleaseCacheVersion - 1,
      "compressions": ["gzip"],
      "packages": []
    }))
    check not retainedReleaseCacheVersionMatches(Path(root))

suite "packager allDeps metadata":
  test "allDeps expands official deps and keeps url deps without expanding them":
    let root = createTempDir("atlas-packager", "all-deps-")
    defer: removeDir(root)

    let packagesFile = root / "packages.json"
    writeText(packagesFile, $(%*[
      {
        "name": "alpha",
        "url": "https://example.com/alpha",
        "method": "git",
        "tags": [],
        "description": "alpha"
      },
      {
        "name": "beta",
        "url": "https://example.com/beta",
        "method": "git",
        "tags": [],
        "description": "beta"
      },
      {
        "name": "gamma",
        "url": "https://example.com/gamma",
        "method": "git",
        "tags": [],
        "description": "gamma"
      },
      {
        "name": "delta",
        "url": "https://example.com/delta",
        "method": "git",
        "tags": [],
        "description": "delta"
      }
    ]))

    writeText(root / "alpha" / "releases.json", pretty(%*{
      "name": "alpha",
      "releases": [
        {
          "vtag": "1.0.0@aaaa",
          "release": {
            "requirements": [
              {"name": "beta", "version": ">= 1.0.0"},
              {"name": "delta", "version": "*"},
              {"url": "https://example.com/external", "version": "*"},
              {"name": "missing", "version": "*"}
            ],
            "version": "1.0.0",
            "status": "Normal"
          }
        },
        {
          "vtag": "2.0.0@bbbb",
          "release": {
            "requirements": [
              {"name": "gamma", "version": "*"}
            ],
            "version": "2.0.0",
            "status": "Normal",
            "features": {
              "dev": [
                {"url": "https://example.com/feature-only", "version": "*"}
              ]
            }
          }
        },
        {
          "vtag": "#head@eeee",
          "release": {
            "requirements": [
              {"name": "gamma", "version": "*"}
            ],
            "version": "#head",
            "status": "Normal"
          }
        }
      ]
    }))
    writeText(root / "beta" / "releases.json", pretty(%*{
      "name": "beta",
      "releases": [
        {
          "vtag": "1.0.0@cccc",
          "release": {
            "requirements": [
              {"name": "gamma", "version": "*"}
            ],
            "version": "1.0.0",
            "status": "Normal"
          }
        }
      ]
    }))
    writeText(root / "gamma" / "releases.json", pretty(%*{
      "name": "gamma",
      "releases": [
        {
          "vtag": "1.0.0@dddd",
          "release": {
            "requirements": [
              {"name": "alpha", "version": "*"}
            ],
            "version": "1.0.0",
            "status": "Normal"
          }
        }
      ]
    }))

    let summary = updatePackageAllDeps(Path(packagesFile), Path(root), @["alpha"], @[], 2)
    check summary.packagesProcessed == 1
    check summary.packagesUpdated == 1
    check summary.packagesFailed == 0
    let deps = allDeps(root / "alpha" / "releases.json")
    check jsonStringSeq(deps["packages"]) == @[
      "beta <= 1.0.0",
      "delta <= 1.0.0",
      "gamma"
    ]
    check jsonStringSeq(deps["urls"]) == @[
      "https://example.com/external <= 1.0.0",
      "https://example.com/feature-only > 1.0.0"
    ]
    check jsonStringSeq(deps["unresolved"]) == @[
      "delta",
      "missing"
    ]

suite "packager release metadata comparison":
  test "comparable release metadata ignores derived allDeps and timestamps":
    let harvested = %*{
      "name": "alpha",
      "releaseCount": 1,
      "releases": [
        {
          "vtag": "1.0.0@aaaa",
          "release": {
            "version": "1.0.0",
            "status": "Normal"
          }
        }
      ],
      "tarballs": [
        {
          "version": "1.0.0",
          "entries": []
        }
      ]
    }
    let retained = %*{
      "name": "alpha",
      "releaseCount": 1,
      "releases": [
        {
          "vtag": "1.0.0@aaaa",
          "release": {
            "version": "1.0.0",
            "status": "Normal"
          }
        }
      ],
      "tarballs": [
        {
          "version": "1.0.0",
          "entries": []
        }
      ],
      "generatedAt": "2026-05-20T00:00:00Z",
      "allDeps": {
        "packages": ["beta"],
        "urls": [],
        "unresolved": []
      }
    }
    check comparableReleaseMetadata(retained) == comparableReleaseMetadata(harvested)

  test "comparable release metadata still detects tarball changes":
    let base = %*{
      "name": "alpha",
      "releaseCount": 1,
      "releases": [],
      "tarballs": [{"version": "1.0.0", "entries": []}]
    }
    let changed = %*{
      "name": "alpha",
      "releaseCount": 1,
      "releases": [],
      "tarballs": [{"version": "1.0.0", "entries": [{"compression": "xz"}]}]
    }
    check comparableReleaseMetadata(base) != comparableReleaseMetadata(changed)

  test "comparable release metadata ignores tarball timestamps and order":
    let base = %*{
      "name": "alpha",
      "releaseCount": 2,
      "releases": [],
      "tarballs": [
        {
          "version": "2.0.0",
          "createdAt": "2026-05-22T10:00:00Z",
          "gitSha": "bbbb",
          "compression": "gzip",
          "contentSha": "2222",
          "file": "alpha-2.tar.gz"
        },
        {
          "version": "1.0.0",
          "createdAt": "2026-05-22T10:00:00Z",
          "gitSha": "aaaa",
          "compression": "gzip",
          "contentSha": "1111",
          "file": "alpha-1.tar.gz"
        }
      ]
    }
    let same = %*{
      "name": "alpha",
      "releaseCount": 2,
      "releases": [],
      "tarballs": [
        {
          "version": "1.0.0",
          "createdAt": "2026-05-22T11:00:00Z",
          "gitSha": "aaaa",
          "compression": "gzip",
          "contentSha": "1111",
          "file": "alpha-1.tar.gz"
        },
        {
          "version": "2.0.0",
          "createdAt": "2026-05-22T11:00:00Z",
          "gitSha": "bbbb",
          "compression": "gzip",
          "contentSha": "2222",
          "file": "alpha-2.tar.gz"
        }
      ]
    }
    check comparableReleaseMetadata(base) == comparableReleaseMetadata(same)

  test "matching digest entries include content hash when present":
    let entries = %*[
      {
        "version": "1.0.0",
        "gitSha": "aaaa",
        "compression": "gzip",
        "contentSha": "old"
      },
      {
        "version": "1.0.0",
        "gitSha": "aaaa",
        "compression": "gzip",
        "contentSha": "new"
      }
    ]
    check matchingDigestEntry(entries, "1.0.0", "aaaa", "gzip", "new") == entries[1]
    check matchingDigestEntry(entries, "1.0.0", "aaaa", "gzip", "missing").isNil
    check matchingDigestEntry(entries, "1.0.0", "aaaa", "xz", "new").isNil
