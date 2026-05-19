import std/[os, paths, unittest]

import packager/packager
import packager/archivehelpers

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
