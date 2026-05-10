import std/[unittest, os, algorithm, strutils, importutils, terminal, tables]
import basic/[context, pkgurls, deptypes, nimblecontext, compiledpatterns, osutils, versions]
import basic/nimbleparser
import basic/parse_requires
import runners

import integration_test_utils

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

  test "parse nimble file when defined(linux or macosx)":
    let nimbleFile = Path("tests" / "test_data" / "jester_inverted.nimble")
    var res = extractRequiresInfo(nimbleFile)
    echo "Nimble release: ", repr res
    when defined(linux) or defined(macosx):
      check doesContain(res, "httpbeast")
    else:
      check not doesContain(res, "httpbeast")

  test "parse nimble file when macos or linux":
    let nimbleFile = Path("tests" / "test_data" / "jester_combined.nimble")
    var res = extractRequiresInfo(nimbleFile)
    echo "Nimble release: ", repr res
    when defined(macosx) or defined(linux):
      check doesContain(res, "httpbeast")
    else:
      check not doesContain(res, "httpbeast")

  test "parse nimble file with features":
    setAtlasVerbosity(Trace)
    let nimbleFile = Path("tests" / "test_data" / "jester_feature.nimble")
    var res = extractRequiresInfo(nimbleFile)
    echo "Nimble release: ", $res
    check res.requires.len == 1
    check res.features.len == 3
    check res.features.hasKey("useHttpbeast")
    check res.features["useHttpbeast"].len == 1
    check res.features["useHttpbeast"][0] == "httpbeast >= 0.4.0"
    check res.features.hasKey("useAsyncTools")
    check res.features["useAsyncTools"].len == 1
    check res.features["useAsyncTools"][0] == "asynctools >= 0.1.0"
    check res.features.hasKey("useOldAsyncTools")
    check res.features["useOldAsyncTools"].len == 1
    check res.features["useOldAsyncTools"][0] == "asynctools >= 0.1.0"

  test "parse nimble file with bin metadata":
    let nimbleFile = Path("tests" / "test_data" / "bin_metadata.nimble")
    var res = extractRequiresInfo(nimbleFile)
    check res.name == "bin_metadata"
    check res.author == "Atlas Tester"
    check res.description == "Fixture for binary metadata parsing"
    check res.license == "MIT"
    check res.srcDir == Path"src"
    check res.binDir == Path"bin"
    check res.skipDirs == @["tests", "examples"]
    check res.skipFiles == @["config.local"]
    check res.skipExt == @["tmp", "bak"]
    check res.installDirs == @["assets"]
    check res.installFiles == @["README.md", "LICENSE"]
    check res.installExt == @["nim", "nims"]
    check res.bin == @["main", "worker"]
    check res.namedBin["main"] == "myfoo"
    check res.namedBin["tools/helper"] == "helper"
    check res.backend == "c"
    check res.hasBin

    var nc = createUnfilledNimbleContext()
    let release = nc.parseNimbleFile(nimbleFile)
    check release.name == "bin_metadata"
    check release.author == "Atlas Tester"
    check release.description == "Fixture for binary metadata parsing"
    check release.license == "MIT"
    check release.srcDir == Path"src"
    check release.binDir == Path"bin"
    check release.skipDirs == @["tests", "examples"]
    check release.skipFiles == @["config.local"]
    check release.skipExt == @["tmp", "bak"]
    check release.installDirs == @["assets"]
    check release.installFiles == @["README.md", "LICENSE"]
    check release.installExt == @["nim", "nims"]
    check release.bin == @["main", "worker"]
    check release.namedBin["main"] == "myfoo"
    check release.namedBin["tools/helper"] == "helper"
    check release.backend == "c"
    check release.hasBin

  test "install hook template accepts feature blocks":
    runNimScriptInstallHook Path("tests" / "test_data" / "install_hook_feature.nimble"),
      "install_hook_feature"

  test "patch nimble file skips existing dependency by URL project name":
    let nimbleFile = Path("tests" / "test_data" / "use_duplicate.nimble")
    writeFile($nimbleFile, dedent"""
    requires "https://example.com/someuser/ws_link_semver"
    """)
    var nc = NimbleContext()
    nc.put("ws_link_semver", toPkgUriRaw(parseUri "https://example.com/other/ws_link_semver"))

    patchNimbleFile(nc, nimbleFile, "ws_link_semver")

    let reqs = extractRequiresInfo(nimbleFile).requires
    check reqs.len == 1
    check reqs[0] == "https://example.com/someuser/ws_link_semver"

    removeFile($nimbleFile)

  test "parse nimble file with when statements":
    let nimbleFile = Path("tests" / "test_data" / "jester_boolean.nimble")
    var res = extractRequiresInfo(nimbleFile)
    echo "Nimble release: ", $res
    
    # Check basic package info is parsed correctly
    check res.version == "0.6.0"
    
    # Should always have the base requirement
    check doesContain(res, "nim >= 1.0.0")
    
    # Count how many httpbeast requirements we expect based on platform
    var expectedHttpbeastCount = 0
    
    # when defined(linux): -> only true on Linux
    when defined(linux):
      expectedHttpbeastCount += 1
    
    # when defined(linux) or defined(macosx): -> true on Linux or macOS
    when defined(linux) or defined(macosx):
      expectedHttpbeastCount += 1
    
    # when not defined(linux) or defined(macosx): -> true when NOT Linux OR when macOS
    # This is true on macOS, Windows, and other non-Linux platforms
    when not defined(linux) or defined(macosx):
      expectedHttpbeastCount += 1
    
    # when not (defined(linux) or defined(macosx)): -> true when neither Linux nor macOS
    when not (defined(linux) or defined(macosx)):
      expectedHttpbeastCount += 1
    
    # when defined(windows) and (defined(linux) or defined(macosx)): -> impossible, always false
    when defined(windows) and (defined(linux) or defined(macosx)):
      expectedHttpbeastCount += 1
    
    # Count actual httpbeast requirements in the result
    var actualHttpbeastCount = 0
    for req in res.requires:
      if req.contains("httpbeast"):
        actualHttpbeastCount += 1
    
    echo "Expected httpbeast count: ", expectedHttpbeastCount
    echo "Actual httpbeast count: ", actualHttpbeastCount
    check actualHttpbeastCount == expectedHttpbeastCount
    
    # Verify no errors occurred during parsing
    check not res.hasErrors

  test "parse nimble file with when statements runtime defines":
    let nimbleFile = Path("tests" / "test_data" / "jester_boolean.nimble")

    setBasicDefines("linux", true)
    setBasicDefines("macosx", true)
    setBasicDefines("windows", true)
    setBasicDefines("posix", true)
    setBasicDefines("freebsd", false)
    setBasicDefines("openbsd", false)
    setBasicDefines("netbsd", false)

    var res = extractRequiresInfo(nimbleFile)
    echo "Nimble release: ", $res
    
    # Check basic package info is parsed correctly
    check res.version == "0.6.0"
    
    # Should always have the base requirement
    check doesContain(res, "nim >= 1.0.0")
    
    # Count how many httpbeast requirements we expect based on platform
    var expectedHttpbeastCount = 4
    
    var actualHttpbeastCount = 0
    for req in res.requires:
      echo "got req: ", req
      if req.contains("httpbeast"):
        actualHttpbeastCount += 1
    
    echo "Expected httpbeast count: ", expectedHttpbeastCount
    echo "Actual httpbeast count: ", actualHttpbeastCount
    check actualHttpbeastCount == expectedHttpbeastCount

  test "parse nimble file with NimMajor and NimMinor when statements":
    let nimbleFile = Path("tests" / "test_data" / "nim_version_when.nimble")
    setBasicIntegerDefines("NimMajor", 2)
    setBasicIntegerDefines("NimMinor", 0)
    setBasicIntegerDefines("NimPatch", 0)

    var res = extractRequiresInfo(nimbleFile)
    check doesContain(res, "nim >= 1.0.0")
    check doesContain(res, "db_connector >= 0.1.0")
    check doesContain(res, "tuple_ge >= 1.0.0")
    check not doesContain(res, "impossible")

    setBasicIntegerDefines("NimMajor", 1)
    setBasicIntegerDefines("NimMinor", 8)
    res = extractRequiresInfo(nimbleFile)
    check doesContain(res, "nim >= 1.0.0")
    check not doesContain(res, "db_connector")
    check not doesContain(res, "tuple_ge")
    check not doesContain(res, "impossible")

    setBasicIntegerDefines("NimMajor", NimMajor)
    setBasicIntegerDefines("NimMinor", NimMinor)
    setBasicIntegerDefines("NimPatch", NimPatch)
