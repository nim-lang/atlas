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

  test "tilde keeps patch updates within a zero-major minor release":
    let patch = p"~= 0.2.3"
    check $patch == ">= 0.2.3 & < 0.3.0"
    check not patch.matches(v"0.2.2")
    check patch.matches(v"0.2.3")
    check patch.matches(v"0.2.99")
    check not patch.matches(v"0.3.0")
    let minor = p"~= 0.2"
    check $minor == ">= 0.2.0 & < 1.0.0"
    check minor.matches(v"0.3.0")
    check not minor.matches(v"1.0.0")

  test "extractRequirementName stops at compatible operators":
    let (name, feats, idx) = extractRequirementName("jester ^= 0.4.1")
    check name == "jester"
    check feats.len == 0
    var err = false
    let interval = parseVersionInterval("jester ^= 0.4.1", idx, err)
    check not err
    check $interval == ">= 0.4.1 & < 0.5.0"

  test "intersections honor every operator on either side":
    let requirements = [
      "1.2.3", "== 1.2.3", "> 1.2.3", ">= 1.2.3", "< 1.5.0", "<= 1.5.0",
      "^= 1.2.3", "~= 1.2.3", "^= 0.4.1", "~= 0.4", "^= 0.0.3", "~= 0"]
    let versions = ["0.0.0", "0.0.3", "0.0.4", "0.4.0", "0.4.1", "0.4.9",
      "0.5.0", "0.9.9", "1.0.0", "1.2.2", "1.2.3", "1.2.4", "1.3.0",
      "1.5.0", "1.8.0", "2.0.0", "1.2.3-rc.1", "1.2.3+build.5"]
    for left in requirements:
      for right in requirements:
        let text = left & " & " & right
        let interval = p(text)
        let restored = p($interval)
        check interval == restored
        for version in versions:
          checkpoint text & " with " & version
          let expected = p(left).matches(Version(version)) and p(right).matches(Version(version))
          check interval.matches(Version(version)) == expected
          check restored.matches(Version(version)) == expected
          check interval.matches(VersionTag(v: Version(version))) == expected

  test "reversed bounds and repeated lower bounds retain both requirements":
    let reversed = p"< 2.0 & >= 1.0"
    check not reversed.matches(v"0.5")
    check reversed.matches(v"1.8")
    check not reversed.matches(v"2.0")
    let repeated = p">= 1.0 & >= 2.0"
    check not repeated.matches(v"1.8")
    check repeated.matches(v"2.0")
    check not (p"> 2.0 & < 1.0").matches(v"1.5")

  test "Nim minimum version uses the strongest lower bound in either position":
    check (p"< 3.0 & >= 2.0").extractGeQuery == v"2.0"
    check (p">= 1.0 & >= 2.0").extractGeQuery == v"2.0"
    check (p"< 3.0 & ^= 2.0").extractGeQuery == v"2.0"
    check (p"< 3.0").extractGeQuery == v""

  test "existing Atlas aliases and whitespace remain supported":
    for text in [">= 1.0, < 2.0", "< 2.0, >= 1.0", " >= 1.0 & < 2.0 "]:
      check p(text).matches(v"1.5")
      check not p(text).matches(v"0.5")
      check not p(text).matches(v"2.0")
    check (p"= 1.2.3 ").matches(v"1.2.3")
    check (p"*").matches(v"1.2.3")
    check (p"").matches(v"1.2.3")

  test "incomplete intersections and trailing input are rejected":
    for text in ["&", ">=", "<", "==", "^=", "~=", "^ 1.2", "~ 1.2",
        ">= 1.0 &", ">= 1.0 & ", ">= 1.0 & <", ">= 1.0 & <=",
        ">= 1.0 & ^=", ">= 1.0 & ~=", ">= 1.0 & & < 2.0",
        ">= 1.0 & < 2.0 & > 0.5", "^= 1.2 & < 2.0 & >= 1.0",
        ">= 1.0, < 2.0, > 0.5", ">= 1.0 garbage", "< 2.0 | >= 1.0",
        "1.2.3 trailing", "* trailing", ">= *", "^= #head"]:
      checkpoint text
      var err = false
      discard parseVersionInterval(text, 0, err)
      check err
