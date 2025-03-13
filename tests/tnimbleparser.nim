
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
      for req in res.requires:
        check not req.contains("httpbeast")
    else:
      check doesContain(res, "httpbeast")

  test "parse nimble file when defined(windows)":
    let nimbleFile = Path("tests" / "test_data" / "jester_inverted.nimble")
    var res = extractRequiresInfo(nimbleFile)
    echo "Nimble release: ", repr res
    when defined(windows):
      for req in res.requires:
        check not req.contains("httpbeast")
    else:
      check doesContain(res, "httpbeast")
