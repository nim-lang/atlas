import std/unittest

import packager/packager

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
