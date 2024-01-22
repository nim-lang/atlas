# Small program that runs the test cases

import std / [strutils, os, osproc, sequtils, strformat]
from std/private/gitutils import diffFiles
import setups

if execShellCmd("nim c -d:debug -r tests/unittests.nim") != 0:
  quit("FAILURE: unit tests failed")

var failures = 0

let atlasExe = absolutePath("bin" / "atlas".addFileExt(ExeExt))
if execShellCmd("nim c -o:$# -d:release src/atlas.nim" % [atlasExe]) != 0:
  quit("FAILURE: compilation of atlas failed")


proc sameDirContents(expected, given: string): bool =
  result = true
  for _, e in walkDir(expected):
    let g = given / splitPath(e).tail
    if fileExists(g):
      if readFile(e) != readFile(g):
        echo "FAILURE: files differ: ", e
        echo diffFiles(e, g).output
        inc failures
        result = false
    else:
      echo "FAILURE: file does not exist: ", g
      inc failures
      result = false

const
  SemVerExpectedResult = """
[Info] (../resolve) selected:
[Info] (proj_a) [ ] (proj_a, 1.1.0)
[Info] (proj_a) [x] (proj_a, 1.0.0)
[Info] (proj_b) [ ] (proj_b, 1.1.0)
[Info] (proj_b) [x] (proj_b, 1.0.0)
[Info] (proj_c) [x] (proj_c, 1.2.0)
[Info] (proj_d) [ ] (proj_d, 2.0.0)
[Info] (proj_d) [x] (proj_d, 1.0.0)
[Info] (../resolve) end of selection
"""

  SemVerExpectedResultNoGitTags = """
[Info] (../resolve) selected:
[Info] (proj_a) [ ] (proj_a, #head)
[Info] (proj_a) [ ] (proj_a, 1.1.0)
[Info] (proj_a) [x] (proj_a, 1.0.0)
[Info] (proj_b) [ ] (proj_b, #head)
[Info] (proj_b) [ ] (proj_b, 1.1.0)
[Info] (proj_b) [x] (proj_b, 1.0.0)
[Info] (proj_c) [ ] (proj_c, #head)
[Info] (proj_c) [x] (proj_c, 1.2.0)
[Info] (proj_c) [ ] (proj_c, 1.0.0)
[Info] (proj_d) [ ] (proj_d, #head)
[Info] (proj_d) [ ] (proj_d, 2.0.0)
[Info] (proj_d) [x] (proj_d, 1.0.0)
[Info] (../resolve) end of selection
"""

  MinVerExpectedResult = """selected:
[ ] (proj_a, 1.1.0)
[x] (proj_a, 1.0.0)
[ ] (proj_b, 1.1.0)
[x] (proj_b, 1.0.0)
[x] (proj_c, 1.2.0)
[ ] (proj_d, 2.0.0)
[x] (proj_d, 1.0.0)
end of selection
"""

proc testSemVer2(expected: string) =
  createDir "semproject"
  withDir "semproject":
    let cmd = atlasExe & " --full --keepWorkspace --resolver=SemVer --colors:off --list use proj_a"
    let (outp, status) = execCmdEx(cmd)
    if status == 0:
      if outp.contains expected:
        discard "fine"
      else:
        echo "expected ", expected, " but got ", outp
        raise newException(AssertionDefect, "Test failed!")
    else:
      echo "\n\n<<<<<<<<<<<<<<<< failed "
      echo "testSemVer2:command: ", cmd
      echo "testSemVer2:pwd: ", getCurrentDir()
      echo "testSemVer2:failed command:\n", outp
      echo ">>>>>>>>>>>>>>>> failed\n"
      assert false, "testSemVer2"

proc testMinVer() =
  buildGraph()
  createDir "minproject"
  withDir "minproject":
    let (outp, status) = execCmdEx(atlasExe & " --keepWorkspace --resolver=MinVer --list use proj_a")
    if status == 0:
      if outp.contains MinVerExpectedResult:
        discard "fine"
      else:
        echo "expected ", MinVerExpectedResult, " but got ", outp
        raise newException(AssertionDefect, "Test failed!")
    else:
      assert false, outp

withDir "tests/ws_semver2":
  try:
    buildGraph()
    testSemVer2(SemVerExpectedResult)
  finally:
    removeDir "does_not_exist"
    removeDir "semproject"
    removeDir "minproject"
    removeDir "source"
    removeDir "proj_a"
    removeDir "proj_b"
    removeDir "proj_c"
    removeDir "proj_d"

withDir "tests/ws_semver2":
  try:
    buildGraphNoGitTags()
    testSemVer2(SemVerExpectedResultNoGitTags)
  finally:
    removeDir "does_not_exist"
    removeDir "semproject"
    removeDir "minproject"
    removeDir "source"
    removeDir "proj_a"
    removeDir "proj_b"
    removeDir "proj_c"
    removeDir "proj_d"

when false: # withDir "tests/ws_semver2":
  try:
    testMinVer()
  finally:
    removeDir "does_not_exist"
    removeDir "semproject"
    removeDir "minproject"
    removeDir "source"
    removeDir "proj_a"
    removeDir "proj_b"
    removeDir "proj_c"
    removeDir "proj_d"

proc integrationTest() =
  # Test installation of some "important_packages" which we are sure
  # won't disappear in the near or far future. Turns out `nitter` has
  # quite some dependencies so it suffices:
  exec atlasExe & " --verbosity:trace --keepWorkspace use https://github.com/zedeus/nitter"
  discard sameDirContents("expected", ".")

proc cleanupIntegrationTest() =
  var dirs: seq[string] = @[]
  for k, f in walkDir("."):
    if k == pcDir and dirExists(f / ".git"):
      dirs.add f
  for d in dirs: removeDir d
  removeFile "nim.cfg"
  removeFile "ws_integration.nimble"

when not defined(quick):
  withDir "tests/ws_integration":
    try:
      integrationTest()
    finally:
      when not defined(keepTestDirs):
        cleanupIntegrationTest()

if failures > 0: quit($failures & " failures occurred.")
