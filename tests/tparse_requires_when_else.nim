import std/[os, strutils, unittest, paths, sequtils]

import basic/parse_requires
import basic/reporters

suite "parse_requires: when/elif/else handling":
  test "else branch is processed when no condition matches":
    # Ensure platform defines are in a known state
    setBasicDefines("windows", false)
    setBasicDefines("posix", true)

    let nimbleContent = """
when defined(windows):
  requires "winpkg >= 1.0"
else:
  requires "posixpkg >= 2.0"
"""

    let fname = getTempDir() / "atlas_test_when_else.nimble"
    writeFile(fname, nimbleContent)

    let info = extractRequiresInfo(fname.Path)
    check info.hasErrors == false
    check info.requires.anyIt(it.contains("posixpkg >= 2.0"))

  test "reports identical parser diagnostics only once":
    let nimbleContent = """
when unsupportedCondition():
  requires "firstpkg >= 1.0"
when unsupportedCondition():
  requires "secondpkg >= 1.0"
"""

    let fname = getTempDir() / "atlas_test_repeated_parser_error.nimble"
    writeFile(fname, nimbleContent)
    defer:
      removeFile(fname)

    let oldVerbosity = atlasReporter.verbosity
    setAtlasVerbosity(Notice)
    defer:
      setAtlasVerbosity(oldVerbosity)

    discard extractRequiresInfo(fname.Path)

    setAtlasVerbosity(Info)
    setAtlasAssertOnError(true)
    defer:
      setAtlasAssertOnError(false)

    expect AssertionDefect:
      discard extractRequiresInfo(fname.Path)

    discard extractRequiresInfo(fname.Path)
