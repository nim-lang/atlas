
import std/[unittest, os, algorithm, strutils, importutils, terminal]
import basic/[context, pkgurls, deptypes, nimblecontext, compiledpatterns, osutils, versions]
import basic/nimbleparser
import basic/parse_requires

import testerutils

suite "nimbleparser":
  test "parse nimble file":
    let nimbleFile = Path("tests" / "test_data" / "jester.nimble")
    var res = extractRequiresInfo(nimbleFile)
    echo "Nimble release: ", repr res
    when defined(windows):
      for req in res.requires:
        check not req.contains("httpbeast")
    else:
      var hasHttpbeast = false
      for req in res.requires:
        if req.contains("httpbeast"):
          hasHttpbeast = true
      check hasHttpbeast
