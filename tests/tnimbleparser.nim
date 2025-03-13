
import std/[unittest, os, algorithm, strutils, importutils, terminal]
import basic/[context, pkgurls, deptypes, nimblecontext, compiledpatterns, osutils, versions]
import basic/nimbleparser

import testerutils

suite "nimbleparser":
  test "parse nimble file":
    let nimbleFile = "tests" / "test_data" / "jester.nimble"
    var nimbleContext = createNimbleContext()
    var nimbleRelease = nimbleContext.parseNimbleFile(nimbleFile)
    check nimbleRelease.status == Normal
