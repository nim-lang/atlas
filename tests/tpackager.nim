import std/[os, osproc, paths, sequtils, strutils, tempfiles, unittest, uri]

import packager/packager
import packager/archivehelpers
import basic/context
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
      putEnv(name, "")

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
                      "--github-api-chunk-size=19",
                      "--compression=gzip",
                      "--threads=5",
                      "--ephemeral"
                    ], "test", args)
                    check opts.metadataDir == Path("cli-pkgs")
                    check opts.packageNames == @["delta"]
                    check opts.ignoredPackageNames == @["epsilon", "zeta"]
                    check opts.updateRepos
                    check opts.githubApiChunkSize == 19
                    check opts.compressions == @[acGzip]
                    check opts.threadCount == 5
                    check opts.ephemeral

suite "packager mirrored repo helpers":
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
