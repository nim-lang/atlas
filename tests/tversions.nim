import std/unittest

import basic/versions

proc p(s: string): VersionInterval =
  var err = false
  result = parseVersionInterval(s, 0, err)
  check not err

suite "versions semver prerelease":
  test "parse version with prerelease and build suffixes":
    check parseVersion("1.2.3-alpha.1", 0) == Version"1.2.3-alpha.1"
    check parseVersion("v1.2.3-rc.1+build.5", 0) == Version"1.2.3-rc.1+build.5"
    check parseExplicitVersion("1.2.3-beta+exp.sha.5114f85") == Version"1.2.3-beta+exp.sha.5114f85"

  test "prerelease precedence follows semver":
    let ordered = [
      Version"1.0.0-alpha",
      Version"1.0.0-alpha.1",
      Version"1.0.0-alpha.beta",
      Version"1.0.0-beta",
      Version"1.0.0-beta.2",
      Version"1.0.0-beta.11",
      Version"1.0.0-rc.1",
      Version"1.0.0"
    ]
    for i in 0 ..< ordered.high:
      check ordered[i] < ordered[i + 1]

  test "build metadata does not affect precedence":
    check Version"1.0.0+20130313144700" == Version"1.0.0+exp.sha.5114f85"
    check not (Version"1.0.0+20130313144700" < Version"1.0.0+exp.sha.5114f85")
    check not (Version"1.0.0+exp.sha.5114f85" < Version"1.0.0+20130313144700")

  test "normal releases sort above prereleases with same core":
    check Version"1.0.0-alpha" < Version"1.0.0"
    check Version"1.0.0-rc.1" < Version"1.0.0"

  test "version intervals accept prerelease suffixes":
    let interval = p(">= 1.0.0-rc.1, < 1.0.0")
    check interval.matches(Version"1.0.0-rc.1")
    check interval.matches(Version"1.0.0-rc.2")
    check not interval.matches(Version"1.0.0")
