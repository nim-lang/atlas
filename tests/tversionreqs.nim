import std/unittest
import basic/versions

template v(x): untyped = Version(x)

proc p(s: string): VersionInterval =
  var err = false
  result = parseVersionInterval(s, 0, err)
  check not err

suite "version requirement operators":
  test "tag parser ignores digits outside tag name":
    let tags = parseTaggedVersions("""
aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa refs/remotes/user2.example.github.com/tags/v1.2.3
bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb refs/remotes/user2.example.github.com/tags/release
""")

    check tags.len == 1
    check tags[0].c.h == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    check tags[0].v == v"1.2.3"

  test "nimble comparison operators":
    check (p"== 1.2.3").matches(v"1.2.3")
    check not (p"== 1.2.3").matches(v"1.2.4")
    check (p"> 1.2.3").matches(v"1.2.4")
    check not (p"> 1.2.3").matches(v"1.2.3")
    check (p"< 1.2.3").matches(v"1.2.2")
    check not (p"< 1.2.3").matches(v"1.2.3")
    check (p">= 1.2.3").matches(v"1.2.3")
    check (p">= 1.2.3").matches(v"1.2.4")
    check not (p">= 1.2.3").matches(v"1.2.2")
    check (p"<= 1.2.3").matches(v"1.2.3")
    check (p"<= 1.2.3").matches(v"1.2.2")
    check not (p"<= 1.2.3").matches(v"1.2.4")

  test "caret expands to compatible semver interval":
    let interval = p"^= 1.2.2"
    check $interval == ">= 1.2.2 & < 2.0.0"
    check interval.matches(v"1.2.2")
    check interval.matches(v"1.9.9")
    check not interval.matches(v"2.0.0")

  test "caret handles zero major versions":
    let interval = p"^= 0.4.1"
    check $interval == ">= 0.4.1 & < 0.5.0"
    check interval.matches(v"0.4.1")
    check interval.matches(v"0.4.9")
    check not interval.matches(v"0.5.0")

  test "caret handles single zero":
    let interval = p"^= 0"
    check $interval == ">= 0.0.0 & < 1.0.0"
    check interval.matches(v"0.0.0")
    check interval.matches(v"0.9.9")
    check not interval.matches(v"1.0.0")

  test "caret handles zero minor patch versions":
    let interval = p"^= 0.0.3"
    check $interval == ">= 0.0.3 & < 0.0.4"
    check interval.matches(v"0.0.3")
    check not interval.matches(v"0.0.4")

  test "caret handles short zero minor versions":
    let interval = p"^= 0.0"
    check $interval == ">= 0.0.0 & < 0.0.1"
    check interval.matches(v"0.0.0")
    check not interval.matches(v"0.0.1")

  test "tilde expands to nimble compatible interval":
    let interval = p"~= 1.2.2"
    check $interval == ">= 1.2.2 & < 1.3.0"
    check interval.matches(v"1.2.9")
    check not interval.matches(v"1.3.0")

  test "tilde handles shorter versions":
    let minor = p"~= 0.4"
    check $minor == ">= 0.4.0 & < 1.0.0"
    check minor.matches(v"0.9.9")
    check not minor.matches(v"1.0.0")

    let major = p"~= 0"
    check $major == ">= 0.0.0 & < 1.0.0"
    check major.matches(v"0.9.9")
    check not major.matches(v"1.0.0")

  test "extractRequirementName stops at compatible operators":
    let (name, feats, idx) = extractRequirementName("jester ^= 0.4.1")
    check name == "jester"
    check feats.len == 0
    var err = false
    let interval = parseVersionInterval("jester ^= 0.4.1", idx, err)
    check not err
    check $interval == ">= 0.4.1 & < 0.5.0"
