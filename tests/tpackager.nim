import std/[algorithm, json, os, osproc, paths, sequtils, sets, strutils, tempfiles, times, unittest, uri]

import atlas_pkg
import atlas_packager
import packager/packager
import packager/alldeps
import packager/archivehelpers
import packager/cacheharvest
import packager/githubheadcheck
import packager/projpkg
import basic/context
import basic/dependencycache
import basic/deptypes
import basic/gitops
import basic/packageinfos
import basic/versions

proc toLowerAsciiAscii(c: char): string =
  $toLowerAscii(c)

proc bucketedPkgPath(root: string; name: string): string =
  root / toLowerAsciiAscii(name[0]) / name

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

  test "packager options default archive compression to xz":
    var args: seq[string]
    let opts = parseAtlasPackagerOptions(@[], "test", args)
    check opts.compressions == @[acXz]
    check not opts.createTarballs

  test "atlas-package options default archive compressions to xz gzip zip":
    var args: seq[string]
    let opts = parseAtlasPackageOptions(@[], "test", args)
    check opts.compressions == @[acXz, acGzip, acZip]

  test "packager options parse daemon schedule":
    var args: seq[string]
    let opts = parseAtlasPackagerOptions(
      @["--daemon", "--interval=20m", "--packages-file=packages.json", "--packages=pkgs"],
      "test",
      args
    )
    check opts.daemon.enabled
    check opts.daemon.intervalSeconds == 20 * 60
    check opts.packagesFile == Path("packages.json")
    check opts.metadataDir == Path("pkgs")
    check args.len == 0

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
                    check not opts.createTarballs
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
                      "--packages-file=cli-packages.json",
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
                    check opts.packagesFile == Path("cli-packages.json")
                    check opts.packageNames == @["delta"]
                    check opts.ignoredPackageNames == @["epsilon", "zeta"]
                    check opts.updateRepos
                    check not opts.createTarballs
                    check opts.retryMissing
                    check opts.githubApiChunkSize == 19
                    check opts.compressions == @[acGzip]
                    check opts.threadCount == 5
                    check opts.ephemeral

  test "packager options parse only-starts-with filters":
    var args: seq[string]
    let opts = parseAtlasPackagerOptions(
      @["--only-starts-with=boo", "--only-starts-with=a,b"],
      "test",
      args
    )
    check opts.packagePrefixes == @["boo", "a", "b"]

  test "packager defaults packages file to metadata dir packages.json":
    var args: seq[string]
    let opts = parseAtlasPackagerOptions(@["--packages=cache"], "test", args)
    check resolveMetadataDir(opts) == Path("cache").absolutePath()
    check resolvePackagesFile(opts).len == 0

  test "packager options parse explicit packages file":
    var args: seq[string]
    let opts = parseAtlasPackagerOptions(
      @["--packages-file=./packages.json"],
      "test",
      args
    )
    check opts.packagesFile == Path("./packages.json")

  test "regenerate tarballs overrides no tarballs when set later":
    var args: seq[string]
    let opts = parseAtlasPackagerOptions(
      @["--no-tarballs", "--regenerate-tarballs"],
      "test",
      args
    )
    check opts.createTarballs
    check opts.regenerateTarballs

  test "packager enables tarballs when requested":
    var args: seq[string]
    let opts = parseAtlasPackagerOptions(@["--tarballs"], "test", args)
    check opts.createTarballs

  test "no tarballs can be set from env":
    withEnvVar(EnvNoTarballs, "true") do:
      var args: seq[string]
      let opts = parseAtlasPackagerOptions(@[], "test", args)
      check not opts.createTarballs

  test "false no-tarballs env leaves tarballs disabled by default":
    withEnvVar(EnvNoTarballs, "false") do:
      var args: seq[string]
      let opts = parseAtlasPackagerOptions(@[], "test", args)
      check not opts.createTarballs

suite "local project packager options":
  test "atlas-package defaults to latest release mode":
    var args: seq[string]
    let opts = parseAtlasPackageOptions(@[], "test", args)
    check opts.releaseMode == prmLatestRelease
    check not opts.createTarballs

  test "atlas-package parses head mode":
    var args: seq[string]
    let opts = parseAtlasPackageOptions(@["--head"], "test", args)
    check opts.releaseMode == prmHead

  test "atlas-package enables tarballs when requested":
    var args: seq[string]
    let opts = parseAtlasPackageOptions(@["--tarballs"], "test", args)
    check opts.createTarballs

  test "atlas-package keeps no-tarballs option":
    var args: seq[string]
    let opts = parseAtlasPackageOptions(@["--tarballs", "--no-tarballs"], "test", args)
    check not opts.createTarballs

  test "atlas-package parses all selection mode":
    var args: seq[string]
    let opts = parseAtlasPackageOptions(@["--all"], "test", args)
    check opts.releaseMode == prmLatestRelease
    check opts.selectionMode == psmAllReleases

  test "atlas-package head mode keeps single-release selection":
    var args: seq[string]
    let opts = parseAtlasPackageOptions(@["--head", "--all"], "test", args)
    check opts.releaseMode == prmHead
    check opts.selectionMode == psmAllReleases

suite "packager mirrored repo helpers":
  test "packager workspace uses explicit packages file override":
    let oldContext = context()
    defer:
      setContext(oldContext)

    let root = createTempDir("atlas-packager", "packages-file-override-")
    defer: removeDir(root)

    let metadataDir = Path(root / "pkgs")
    let packagesFile = Path(root / "packages.json")
    initPackagerWorkspace(metadataDir, packagesFile)

    check packageInfosFile() == packagesFile

  test "unchanged github packages still harvest but skip repo update":
    var skipRepoUpdatePackages = initHashSet[string]()
    skipRepoUpdatePackages.incl "alpha"

    check shouldUpdatePackageRepo(true, skipRepoUpdatePackages, "beta")
    check not shouldUpdatePackageRepo(true, skipRepoUpdatePackages, "alpha")
    check not shouldUpdatePackageRepo(false, skipRepoUpdatePackages, "beta")

  test "package filters match exact names and prefixes":
    check matchesPackageFilters("alpha", @[], @[])
    check matchesPackageFilters("alpha", @["alpha"], @[])
    check not matchesPackageFilters("alpha", @["beta"], @[])
    check matchesPackageFilters("boop", @[], @["boo"])
    check not matchesPackageFilters("alpha", @[], @["boo"])
    check matchesPackageFilters("boop", @["boop"], @["boo"])
    check not matchesPackageFilters("alpha", @["alpha"], @["boo"])

  test "alphabetical workspace layout handles single-character package names":
    let root = createTempDir("atlas-packager", "single-char-layout-")
    defer: removeDir(root)

    let info = PackageInfo(name: "m")
    let workspaceRoot = resolvePackageWorkspaceRoot(Path(root), info)

    check packageBucketDir(info.name) == Path"m"
    check workspaceRoot == Path(root / "m" / "m").absolutePath()

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

  test "harvest writes metadata for packages without versioned releases":
    let root = createTempDir("atlas-packager", "head-only-package-")
    defer: removeDir(root)

    let srcRepo = root / "source"
    createDir(srcRepo)
    discard runGit(["init", "-b", "main"], srcRepo)
    discard runGit(["config", "user.name", "Atlas Tests"], srcRepo)
    discard runGit(["config", "user.email", "atlas-tests@example.com"], srcRepo)
    writeText(srcRepo / "headonly.nimble", "description = \"head only\"\n")
    discard runGit(["add", "headonly.nimble"], srcRepo)
    discard runGit(["commit", "-m", "initial"], srcRepo)
    let headCommit = runGit(["rev-parse", "HEAD"], srcRepo).strip()

    let packagesFile = root / "packages.json"
    writeText(packagesFile, pretty(%*[
      {
        "name": "headonly",
        "url": $fileUri(Path(srcRepo)),
        "method": "git",
        "tags": [],
        "description": "head only",
        "license": "MIT"
      }
    ]))

    let metadataDir = Path(root / "pkgs")
    let summary = harvestRegistryCaches(
      Path(packagesFile),
      metadataDir,
      ephemeral = true,
      updateRepos = false,
      skipRepoUpdatePackages = initHashSet[string](),
      packageForgeMetadata = initTable[string, PackageForgeMetadata](),
      pkgNames = @["headonly"],
      pkgPrefixes = @[],
      ignoredPkgNames = @[],
      compressions = @[acXz],
      threadCount = 1,
      createTarballs = false
    )

    check summary.packagesProcessed == 1
    check summary.packagesFailed == 0
    let releases = parseFile(root / "pkgs" / "h" / "headonly" / "releases.json")
    let head = parseFile(root / "pkgs" / "h" / "headonly" / "release-head.json")
    check releases["releases"].len == 0
    check releases["releaseCacheVersion"].getInt() == PackageReleaseCacheVersion
    check head["v"].getStr() == "#head@" & headCommit

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

suite "packager github unchanged checks":
  test "unchanged github packages are skipped only for current release cache version":
    let root = createTempDir("atlas-packager", "github-unchanged-current-")
    defer: removeDir(root)

    let packagesFile = root / "packages.json"
    writeText(packagesFile, pretty(%*[
      {
        "name": "alpha",
        "url": "https://github.com/example/alpha",
        "method": "git",
        "tags": [],
        "description": "alpha"
      }
    ]))
    writeText(bucketedPkgPath(root, "alpha") / "releases.json", pretty(%*{
      "releaseCacheVersion": PackageReleaseCacheVersion,
      "name": "alpha",
      "releases": [
        {"v": "1.0.0@aaaaaaaa"}
      ]
    }))
    writeText(root / "index.json", pretty(%*{
      "releaseCacheVersion": PackageReleaseCacheVersion,
      "compressions": ["xz"],
      "packages": [
        {
          "name": "alpha",
          "latestCommit": "deadbeef",
          "releasesMetadata": "a/alpha/releases.json"
        }
      ]
    }))

    var repoStates = initTable[string, GitHubRepoState]()
    repoStates["alpha"] = GitHubRepoState(
      headOid: "deadbeef",
      tagNames: @["1.0.0"],
      forgeReleases: @[]
    )

    let skipped = findUnchangedGitHubPackages(
      Path(packagesFile),
      Path(root),
      @[],
      @[],
      @[],
      repoStates,
      @["xz"]
    )
    check skipped == @["alpha"]

  test "stale release cache version disables unchanged github package skipping":
    let root = createTempDir("atlas-packager", "github-unchanged-stale-")
    defer: removeDir(root)

    let packagesFile = root / "packages.json"
    writeText(packagesFile, pretty(%*[
      {
        "name": "alpha",
        "url": "https://github.com/example/alpha",
        "method": "git",
        "tags": [],
        "description": "alpha"
      }
    ]))
    writeText(bucketedPkgPath(root, "alpha") / "releases.json", pretty(%*{
      "releaseCacheVersion": PackageReleaseCacheVersion,
      "name": "alpha",
      "releases": [
        {"v": "1.0.0@aaaaaaaa"}
      ]
    }))
    writeText(root / "index.json", pretty(%*{
      "releaseCacheVersion": PackageReleaseCacheVersion - 1,
      "compressions": ["xz"],
      "packages": [
        {
          "name": "alpha",
          "latestCommit": "deadbeef",
          "releasesMetadata": "a/alpha/releases.json"
        }
      ]
    }))

    var repoStates = initTable[string, GitHubRepoState]()
    repoStates["alpha"] = GitHubRepoState(
      headOid: "deadbeef",
      tagNames: @["1.0.0"],
      forgeReleases: @[]
    )

    let skipped = findUnchangedGitHubPackages(
      Path(packagesFile),
      Path(root),
      @[],
      @[],
      @[],
      repoStates,
      @["xz"]
    )
    check skipped.len == 0

  test "missing retained releases cache version disables unchanged github package skipping":
    let root = createTempDir("atlas-packager", "github-unchanged-missing-release-version-")
    defer: removeDir(root)

    let packagesFile = root / "packages.json"
    writeText(packagesFile, pretty(%*[
      {
        "name": "alpha",
        "url": "https://github.com/example/alpha",
        "method": "git",
        "tags": [],
        "description": "alpha"
      }
    ]))
    writeText(bucketedPkgPath(root, "alpha") / "releases.json", pretty(%*{
      "name": "alpha",
      "releases": [
        {"v": "1.0.0@aaaaaaaa"}
      ]
    }))
    writeText(root / "index.json", pretty(%*{
      "releaseCacheVersion": PackageReleaseCacheVersion,
      "compressions": ["xz"],
      "packages": [
        {
          "name": "alpha",
          "latestCommit": "deadbeef",
          "releasesMetadata": "a/alpha/releases.json"
        }
      ]
    }))

    var repoStates = initTable[string, GitHubRepoState]()
    repoStates["alpha"] = GitHubRepoState(
      headOid: "deadbeef",
      tagNames: @["1.0.0"],
      forgeReleases: @[]
    )

    let skipped = findUnchangedGitHubPackages(
      Path(packagesFile),
      Path(root),
      @[],
      @[],
      @[],
      repoStates,
      @["xz"]
    )
    check skipped.len == 0

suite "packager allDeps metadata":
  test "package bucket dir uses first package letter":
    check packageBucketDir("alpha") == Path"a"
    check packageBucketDir("Beta") == Path"b"

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

    writeText(bucketedPkgPath(root, "alpha") / "releases.json", pretty(%*{
      "name": "alpha",
      "releases": [
        {
          "v": "1.0.0@aaaa",
          "r": [
            "beta >= 1.0.0",
            "delta",
            "https://example.com/external",
            "missing"
          ]
        },
        {
          "v": "2.0.0@bbbb",
          "r": [
            "gamma"
          ],
          "f": {
            "dev": [
              "https://example.com/feature-only"
            ]
          }
        }
      ]
    }))
    writeText(bucketedPkgPath(root, "beta") / "releases.json", pretty(%*{
      "name": "beta",
      "releases": [
        {
          "v": "1.0.0@cccc",
          "r": [
            "gamma"
          ]
        }
      ]
    }))
    writeText(bucketedPkgPath(root, "gamma") / "releases.json", pretty(%*{
      "name": "gamma",
      "releases": [
        {
          "v": "1.0.0@dddd",
          "r": [
            "alpha"
          ]
        }
      ]
    }))

    let summary = updatePackageAllDeps(Path(packagesFile), Path(root), @["alpha"], @[], @[], 2)
    check summary.packagesProcessed == 1
    check summary.packagesUpdated == 1
    check summary.packagesFailed == 0
    let deps = allDeps(bucketedPkgPath(root, "alpha") / "releases.json")
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

  test "allDeps prefix filter processes matching packages only":
    let root = createTempDir("atlas-packager", "all-deps-prefix-")
    defer: removeDir(root)

    let packagesFile = root / "packages.json"
    writeText(packagesFile, pretty(%*[
      {
        "name": "alpha",
        "url": "https://example.com/alpha",
        "method": "git",
        "tags": [],
        "description": "alpha package",
        "license": "MIT"
      },
      {
        "name": "alpine",
        "url": "https://example.com/alpine",
        "method": "git",
        "tags": [],
        "description": "alpine package",
        "license": "MIT"
      },
      {
        "name": "beta",
        "url": "https://example.com/beta",
        "method": "git",
        "tags": [],
        "description": "beta package",
        "license": "MIT"
      }
    ]))

    writeText(bucketedPkgPath(root, "alpha") / "releases.json", pretty(%*{
      "name": "alpha",
      "releases": [{"v": "1.0.0@aaaa", "r": ["beta"]}]
    }))
    writeText(bucketedPkgPath(root, "alpine") / "releases.json", pretty(%*{
      "name": "alpine",
      "releases": [{"v": "1.0.0@bbbb", "r": ["beta"]}]
    }))
    writeText(bucketedPkgPath(root, "beta") / "releases.json", pretty(%*{
      "name": "beta",
      "releases": [{"v": "1.0.0@cccc", "r": ["alpha"]}]
    }))

    let summary = updatePackageAllDeps(Path(packagesFile), Path(root), @[], @["alp"], @[], 2)
    check summary.packagesProcessed == 2
    check summary.packagesUpdated == 2
    check summary.packagesFailed == 0

    check allDeps(bucketedPkgPath(root, "alpha") / "releases.json").kind == JObject
    check allDeps(bucketedPkgPath(root, "alpine") / "releases.json").kind == JObject
    let betaRoot = parseFile(bucketedPkgPath(root, "beta") / "releases.json")
    check "allDeps" notin betaRoot

suite "packager release metadata comparison":
  test "local project release files match packager naming":
    let pkg = Package(name: "atlas")
    let info = PackageInfo(kind: pkPackage, name: "atlas")
    let ver = VersionTag(v: Version"0.14.3", c: initCommitHash("d85ba9fb", FromGitTag)).toPkgVer()
    let release = NimbleRelease(version: Version"0.14.3", status: Normal)
    check projectReleaseStem(pkg, info, ver, release, "122f443a7178") == "atlas-0.14.3-d85ba9fb-122f443a"
    check projectReleaseMetadataFileName(pkg, info, ver, release, "122f443a7178") == "atlas-0.14.3-d85ba9fb-122f443a.json"

  test "latest packaged release selector skips head and prefers highest version":
    let headRelease = (
      VersionTag(v: Version"#head", c: initCommitHash("aaaaaaaa", FromHead)).toPkgVer(),
      NimbleRelease(version: Version"#head", status: Normal)
    )
    let stableRelease = (
      VersionTag(v: Version"1.2.0", c: initCommitHash("bbbbbbbb", FromGitTag)).toPkgVer(),
      NimbleRelease(version: Version"1.2.0", status: Normal)
    )
    let latestRelease = (
      VersionTag(v: Version"2.0.0", c: initCommitHash("cccccccc", FromGitTag)).toPkgVer(),
      NimbleRelease(version: Version"2.0.0", status: Normal)
    )

    let releases = @[headRelease, stableRelease, latestRelease]
    let selected = selectLatestPackagedRelease(releases)
    check selected == 2
    check releases[selected][0].vtag.version == Version"2.0.0"

  test "projectReleaseMetadataFileName uses first packaged release naming":
    let pkg = Package(name: "atlas")
    let info = PackageInfo(kind: pkPackage, name: "atlas")
    let ver = VersionTag(v: Version"1.0.0", c: initCommitHash("aaaaaaaa", FromGitTag)).toPkgVer()
    let release = NimbleRelease(version: Version"1.0.0", status: Normal)
    check projectReleaseMetadataFileName(pkg, info, ver, release, "deadbeefcafebabe") ==
      "atlas-1.0.0-aaaaaaaa-deadbeef.json"

  test "projectReleaseMetadataFileName uses release-head for head":
    let pkg = Package(name: "atlas")
    let info = PackageInfo(kind: pkPackage, name: "atlas")
    let ver = VersionTag(v: Version"#head", c: initCommitHash("aaaaaaaa", FromHead)).toPkgVer()
    let release = NimbleRelease(version: Version"#head", status: Normal)
    check projectReleaseMetadataFileName(pkg, info, ver, release, "deadbeefcafebabe") ==
      "release-head.json"

  test "comparable release metadata ignores derived allDeps and timestamps":
    let harvested = %*{
      "name": "alpha",
      "releases": [
        {
          "v": "1.0.0@aaaa"
        }
      ],
      "tarballs": {
        "1.0.0": []
      }
    }
    let retained = %*{
      "name": "alpha",
      "releases": [
        {
          "v": "1.0.0@aaaa"
        }
      ],
      "tarballs": {
        "1.0.0": []
      },
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
      "releases": [],
      "tarballs": {"1.0.0": []}
    }
    let changed = %*{
      "name": "alpha",
      "releases": [],
      "tarballs": {"1.0.0": [{"f": "alpha-1.tar.xz"}]}
    }
    check comparableReleaseMetadata(base) != comparableReleaseMetadata(changed)

  test "comparable release metadata still detects forge release changes":
    let base = %*{
      "name": "alpha",
      "releases": [],
      "tags": true,
      "forge": {
        "archives": {
          "tar.gz": "/archive/refs/tags/{tag}.tar.gz",
          "zip": "/archive/refs/tags/{tag}.zip"
        },
        "releases": [
          "v1.0.0"
        ],
        "tagVersions": {
          "v1.0.0": "1.0.0"
        },
        "latest": "v1.0.0",
        "prerelease": ["v1.0.0"]
      }
    }
    let changed = %*{
      "name": "alpha",
      "releases": [],
      "tags": true,
      "forge": {
        "archives": {
          "tar.gz": "/archive/refs/tags/{tag}.tar.gz",
          "zip": "/archive/refs/tags/{tag}.zip"
        },
        "releases": [
          "v1.1.0"
        ],
        "tagVersions": {
          "v1.1.0": "1.1.0"
        },
        "latest": "v1.1.0",
        "prerelease": ["v1.1.0"]
      }
    }
    check comparableReleaseMetadata(base) != comparableReleaseMetadata(changed)

  test "comparable release metadata still detects tag presence changes":
    let base = %*{
      "name": "alpha",
      "releases": [],
      "tags": false,
      "forge": {
        "archives": {
          "tar.gz": "/archive/refs/tags/{tag}.tar.gz",
          "zip": "/archive/refs/tags/{tag}.zip"
        },
        "releases": [],
        "latest": "",
        "prerelease": []
      }
    }
    let changed = %*{
      "name": "alpha",
      "releases": [],
      "tags": true,
      "forge": {
        "archives": {
          "tar.gz": "/archive/refs/tags/{tag}.tar.gz",
          "zip": "/archive/refs/tags/{tag}.zip"
        },
        "releases": [],
        "latest": "",
        "prerelease": []
      }
    }
    check comparableReleaseMetadata(base) != comparableReleaseMetadata(changed)

  test "merge release metadata preserves existing tags when no new tag evidence exists":
    let root = createTempDir("atlas-packager", "preserve-tags-")
    defer: removeDir(root)

    let workspaceRoot = Path(root)
    writeFile(root / "releases.json", pretty(%*{
      "name": "alpha",
      "releases": [{"v": "1.0.0@aaaa"}],
      "tags": true
    }))

    mergePackageReleaseMetadata(
      workspaceRoot,
      PackageInfo(name: "alpha"),
      %*{
        "releases": [{"v": "1.0.0@aaaa"}]
      },
      newJNull(),
      false
    )

    let rewritten = parseFile(root / "releases.json")
    check rewritten["tags"].getBool()

  test "merge release metadata compacts duplicated release fields":
    let root = createTempDir("atlas-packager", "compact-release-fields-")
    defer: removeDir(root)

    let workspaceRoot = Path(root)
    mergePackageReleaseMetadata(
      workspaceRoot,
      PackageInfo(name: "alpha"),
      %*{
        "author": "Atlas Tester",
        "description": "Test package",
        "license": "MIT",
        "nim": "2.0.0",
        "srcDir": "src",
        "releases": [
          {
            "v": "#head@aaaaaaaa",
            "r": [],
            "a": "Atlas Tester",
            "d": "Test package",
            "l": "MIT",
            "m": "2.0.0",
            "s": "src"
          },
          {
            "v": "1.0.0@bbbbbbbb",
            "r": [],
            "a": "Other Tester",
            "d": "Test package",
            "l": "MIT",
            "m": "2.2.0",
            "s": "lib"
          }
        ]
      },
      newJNull(),
      releaseHeadMetadata = %*{
        "v": "#head@aaaaaaaa",
        "r": [],
        "a": "Atlas Tester",
        "d": "Test package",
        "l": "MIT",
        "m": "2.0.0",
        "s": "src"
      },
      updateHeadMetadata = true
    )

    let rewritten = parseFile(root / "releases.json")
    let head = parseFile(root / "release-head.json")
    check "a" notin head
    check "d" notin head
    check "l" notin head
    check "m" notin head
    check "s" notin head

    check rewritten["releases"].len == 1
    let tagged = rewritten["releases"][0]
    check tagged["a"].getStr() == "Other Tester"
    check "d" notin tagged
    check "l" notin tagged
    check tagged["m"].getStr() == "2.2.0"
    check tagged["s"].getStr() == "lib"

  test "merge release metadata tolerates legacy unversioned commit entries":
    let root = createTempDir("atlas-packager", "unversioned-release-entry-")
    defer: removeDir(root)

    let workspaceRoot = Path(root)
    mergePackageReleaseMetadata(
      workspaceRoot,
      PackageInfo(name: "alpha"),
      %*{
        "releases": [
          {
            "v": "~@cbbd23c289ac624e2137752f893697d7dd784b17",
            "r": []
          }
        ]
      },
      newJNull(),
      releaseHeadMetadata = %*{
        "v": "#head@4fa3648fa318c295fa67082df63c804974814772",
        "r": []
      },
      updateHeadMetadata = true
    )

    let rewritten = parseFile(root / "releases.json")
    let head = parseFile(root / "release-head.json")
    check rewritten["releaseCacheVersion"].getInt() == PackageReleaseCacheVersion
    check rewritten["releases"].len == 0
    check head["v"].getStr() == "#head@4fa3648fa318c295fa67082df63c804974814772"

  test "merge release metadata writes head separately":
    let root = createTempDir("atlas-packager", "separate-head-")
    defer: removeDir(root)

    let workspaceRoot = Path(root)
    mergePackageReleaseMetadata(
      workspaceRoot,
      PackageInfo(name: "alpha"),
      %*{
        "author": "Atlas Tester",
        "binDir": "bin",
        "bin": ["alpha"],
        "releases": [
          {
            "v": "#head@aaaaaaaa",
            "b": "headbin",
            "p": ["alpha-head"]
          },
          {
            "v": "1.0.0@bbbbbbbb"
          }
        ]
      },
      %*{
        "head": [{
          "s": "headhash",
          "f": "alpha-head.tar.gz"
        }],
        "1.0.0": [{
          "s": "stablehash",
          "f": "alpha-1.0.0.tar.gz"
        }]
      },
      releaseHeadMetadata = %*{
        "v": "#head@aaaaaaaa",
        "b": "headbin",
        "p": ["alpha-head"]
      },
      updateHeadMetadata = true
    )

    let releases = parseFile(root / "releases.json")
    check releases["releases"].len == 1
    check releases["releases"][0]["v"].getStr() == "1.0.0@bbbbbbbb"
    check "head" notin releases
    check "head" notin releases["tarballs"]
    check releases["tarballs"]["1.0.0"][0]["f"].getStr() == "alpha-1.0.0.tar.gz"

    let head = parseFile(root / "release-head.json")
    check head["v"].getStr() == "#head@aaaaaaaa"
    check head["b"].getStr() == "headbin"
    check head["p"][0].getStr() == "alpha-head"
    check head["tarballs"][0]["f"].getStr() == "alpha-head.tar.gz"
    check "name" notin head
    check "generatedAt" notin head

  test "merge release metadata keeps releases json stable for head-only changes":
    let root = createTempDir("atlas-packager", "head-only-change-")
    defer: removeDir(root)

    let workspaceRoot = Path(root)
    writeFile(root / "releases.json", pretty(%*{
      "name": "alpha",
      "generatedAt": "2026-05-26T00:00:00Z",
      "releaseCacheVersion": PackageReleaseCacheVersion,
      "binDir": "bin",
      "bin": ["alpha"],
      "tags": false,
      "releases": [
        {
          "v": "1.0.0@bbbbbbbb"
        }
      ],
      "tarballs": {
        "1.0.0": [{
          "s": "stablehash",
          "f": "alpha-1.0.0.tar.gz"
        }]
      }
    }))
    writeFile(root / "release-head.json", "{\"v\":\"#head@aaaaaaaa\",\"b\":\"headbin\",\"tarballs\":[{\"s\":\"headhash-a\",\"f\":\"alpha-head-a.tar.gz\"}]}")

    let releasesBefore = readFile(root / "releases.json")
    mergePackageReleaseMetadata(
      workspaceRoot,
      PackageInfo(name: "alpha"),
      %*{
        "name": "alpha",
        "head": "cccccccc",
        "binDir": "bin",
        "bin": ["alpha"],
        "releases": [
          {
            "v": "#head@cccccccc",
            "b": "headbin2"
          },
          {
            "v": "1.0.0@bbbbbbbb"
          }
        ]
      },
      %*{
        "head": [{
          "s": "headhash-b",
          "f": "alpha-head-b.tar.gz"
        }],
        "1.0.0": [{
          "s": "stablehash",
          "f": "alpha-1.0.0.tar.gz"
        }]
      },
      releaseHeadMetadata = %*{
        "v": "#head@cccccccc",
        "b": "headbin2"
      },
      updateHeadMetadata = true
    )

    check readFile(root / "releases.json") == releasesBefore
    check "head" notin parseFile(root / "releases.json")
    let headContents = readFile(root / "release-head.json")
    check '\n' notin headContents
    let head = parseJson(headContents)
    check head["v"].getStr() == "#head@cccccccc"
    check head["b"].getStr() == "headbin2"
    check head["tarballs"][0]["f"].getStr() == "alpha-head-b.tar.gz"

  test "comparable release metadata normalizes tarball order":
    let base = %*{
      "name": "alpha",
      "releases": [],
      "tarballs": {
        "2.0.0": [{
          "s": "2222",
          "f": "alpha-2.tar.gz"
        }],
        "1.0.0": [{
          "s": "1111",
          "f": "alpha-1.tar.gz"
        }]
      }
    }
    let same = %*{
      "name": "alpha",
      "releases": [],
      "tarballs": {
        "1.0.0": [{
          "s": "1111",
          "f": "alpha-1.tar.gz"
        }],
        "2.0.0": [{
          "s": "2222",
          "f": "alpha-2.tar.gz"
        }]
      }
    }
    check comparableReleaseMetadata(base) == comparableReleaseMetadata(same)

  test "github forge release metadata uses relative archive paths":
    let metadata = buildForgeReleaseMetadata(GitHubRepoState(
      forgeReleases: @[
        GitHubForgeRelease(tagName: "v2.0.0", version: "2.0.0", latest: true),
        GitHubForgeRelease(tagName: "1.5.0", version: "1.5.0", prerelease: true)
      ]
    ))
    check metadata["archives"]["tar.gz"].getStr() == "/archive/refs/tags/{tag}.tar.gz"
    check metadata["archives"]["zip"].getStr() == "/archive/refs/tags/{tag}.zip"
    check metadata["releases"][0].getStr() == "1.5.0"
    check metadata["releases"][1].getStr() == "v2.0.0"
    check metadata["tagVersions"]["v2.0.0"].getStr() == "2.0.0"
    check metadata["latest"].getStr() == "v2.0.0"
    check metadata["prerelease"][0].getStr() == "1.5.0"

  test "merge release metadata drops retained tarballs when tarballs disabled":
    let root = createTempDir("atlas-packager", "no-tarballs-")
    defer: removeDir(root)

    let workspaceRoot = Path(root)
    writeFile(root / "releases.json", $(%*{
      "name": "alpha",
      "releases": [{"v": "1.0.0@aaaa"}],
      "tarballs": {
        "1.0.0": [{
          "s": "old",
          "f": "alpha-1.tar.xz"
        }]
      }
    }))

    mergePackageReleaseMetadata(
      workspaceRoot,
      PackageInfo(name: "alpha"),
      %*{
        "releases": [{"v": "1.0.0@aaaa"}]
      },
      newJNull()
    )

    let rewritten = parseFile(root / "releases.json")
    check "tarballs" notin rewritten

  test "merge release metadata rewrites tarballs to canonical entries":
    let root = createTempDir("atlas-packager", "canonical-tarballs-")
    defer: removeDir(root)

    let workspaceRoot = Path(root)
    writeFile(root / "releases.json", $(%*{
      "name": "alpha",
      "releases": [{"v": "1.0.0@aaaa"}],
      "tarballs": {
        "1.0.0": [{
          "s": "old",
          "f": "alpha-1.tar.xz",
          "size": 123,
          "createdAt": "2026-05-20T00:00:00Z",
          "archiveRoot": "alpha-1.0.0"
        }]
      }
    }))

    mergePackageReleaseMetadata(
      workspaceRoot,
      PackageInfo(name: "alpha"),
      %*{
        "releases": [{"v": "1.0.0@aaaa"}]
      },
      %*{
        "1.0.0": [{
          "s": "old",
          "f": "alpha-1.tar.xz"
        }]
      }
    )

    let rewritten = parseFile(root / "releases.json")
    check rewritten["tarballs"]["1.0.0"][0]["s"].getStr() == "old"
    check rewritten["tarballs"]["1.0.0"][0]["f"].getStr() == "alpha-1.tar.xz"
    check "size" notin rewritten["tarballs"]["1.0.0"][0]
    check "createdAt" notin rewritten["tarballs"]["1.0.0"][0]
    check "archiveRoot" notin rewritten["tarballs"]["1.0.0"][0]

  test "merge package forge release metadata stores forge releases separately":
    let root = createTempDir("atlas-packager", "forge-releases-")
    defer: removeDir(root)

    let workspaceRoot = Path(root)
    writeFile(root / "releases.json", $(%*{
      "name": "alpha",
      "releases": [{"v": "1.0.0@aaaa"}]
    }))

    mergePackageForgeReleaseMetadata(
      workspaceRoot,
      PackageInfo(name: "alpha"),
      true,
      %*{
        "archives": {
          "tar.gz": "/archive/refs/tags/{tag}.tar.gz",
          "zip": "/archive/refs/tags/{tag}.zip"
        },
        "releases": [
          "v1.0.0"
        ],
        "tagVersions": {
          "v1.0.0": "1.0.0"
        },
        "latest": "v1.0.0",
        "prerelease": ["v1.0.0"]
      }
    )

    let rewritten = parseFile(root / "releases.json")
    check rewritten["tags"].getBool()
    check rewritten["forge"]["releases"][0].getStr() == "v1.0.0"
    check rewritten["forge"]["tagVersions"]["v1.0.0"].getStr() == "1.0.0"
    check rewritten["forge"]["latest"].getStr() == "v1.0.0"
    check rewritten["forge"]["prerelease"][0].getStr() == "v1.0.0"
    check rewritten["forge"]["archives"]["tar.gz"].getStr() ==
      "/archive/refs/tags/{tag}.tar.gz"

  test "matching digest entries include content hash when present":
    let entries = %*{
      "1.0.0": [
        {
          "s": "old",
          "f": "alpha-1.tar.gz"
        },
        {
          "s": "new",
          "f": "alpha-1.tar.gz"
        },
        {
          "s": "new",
          "f": "alpha-1.tar.xz"
        }
      ]
    }
    check matchingDigestEntry(entries, "1.0.0", "aaaa", "gzip", "new") == entries["1.0.0"][1]
    check matchingDigestEntry(entries, "1.0.0", "aaaa", "xz", "new") == entries["1.0.0"][2]
    check matchingDigestEntry(entries, "1.0.0", "aaaa", "gzip", "missing").isNil

  test "archive entries use canonical tarball metadata":
    let release = NimbleRelease(name: "alpha", version: Version"1.0.0", status: Normal)
    let entry = initArchiveEntry(
      "1.0.0",
      "bbbbbbbb",
      "alpha-1.tar.xz",
      Path"",
      release
    )
    check "version" notin entry
    check "gitSha" notin entry
    check entry["s"].getStr() == "bbbbbbbb"
    check "sha" notin entry
    check "contentSha" notin entry
    check entry["f"].getStr() == "alpha-1.tar.xz"
    check "file" notin entry
    check "size" notin entry
    check "createdAt" notin entry
    check "gitShortSha" notin entry
    check "contentShortSha" notin entry
    check "compression" notin entry
    check "srcDir" notin entry
    check "archiveRoot" notin entry
    check "n" notin entry
