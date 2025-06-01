
import std/[unittest, os, algorithm, strutils, importutils, terminal]
import basic/[context, pkgurls, deptypes, nimblecontext, compiledpatterns, osutils, versions]
import basic/nimbleparser
import basic/parse_requires

import testerutils

proc doesContain(res: NimbleFileInfo, name: string): bool =
  for req in res.requires:
    if req.contains(name):
      result = true

suite "nimbleparser":
  test "parse nimble file when not defined(windows)":
    let nimbleFile = Path("tests" / "test_data" / "jester.nimble")
    var res = extractRequiresInfo(nimbleFile)
    echo "Nimble release: ", repr res
    when defined(windows):
      check not doesContain(res, "httpbeast")
    else:
      check doesContain(res, "httpbeast")

  test "parse nimble file when defined(windows)":
    let nimbleFile = Path("tests" / "test_data" / "jester_inverted.nimble")
    var res = extractRequiresInfo(nimbleFile)
    echo "Nimble release: ", repr res
    when defined(windows):
      check not doesContain(res, "httpbeast")
    else:
      check doesContain(res, "httpbeast")

  test "parse nimble file when macos or linux":
    let nimbleFile = Path("tests" / "test_data" / "jester_combined.nimble")
    var res = extractRequiresInfo(nimbleFile)
    echo "Nimble release: ", repr res
    when defined(macosx) or defined(linux):
      check doesContain(res, "httpbeast")
    else:
      check not doesContain(res, "httpbeast")

  test "parse nimble file with features":
    let nimbleFile = Path("tests" / "test_data" / "jester_feature.nimble")
    var res = extractRequiresInfo(nimbleFile)
    echo "Nimble release: ", $res
    check res.requires.len == 1
    check res.features.hasKey("useHttpbeast")
    check res.features["useHttpbeast"].len == 1
    check res.features["useHttpbeast"][0] == "httpbeast >= 0.4.0"
