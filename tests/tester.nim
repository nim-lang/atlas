# Small program that runs the test cases

import std / [strutils, os, osproc, sequtils, strformat, unittest]
from std/private/gitutils import diffFiles
import testrepos
import githttpserver

# Run unit tests in config.nims
# if execShellCmd("nim c -d:debug -r tests/unittests.nim") != 0:
#   quit("FAILURE: unit tests failed")


let atlasExe = absolutePath("bin" / "atlas".addFileExt(ExeExt))
if execShellCmd("nim c -o:$# -d:release src/atlas.nim" % [atlasExe]) != 0:
  quit("FAILURE: compilation of atlas failed")

proc checkServer() =
  try:
    if checkHttpReadme():
      return
  except CatchableError:
    echo "Starting Tester git http server"
    runGitHttpServerThread([
      "test-repos/ws_integration",
      "test-repos/ws_generated"
    ])
    for count in 1..10:
      os.sleep(1000)
      if checkHttpReadme():
        return

    quit "Error accessing git-http server.\n" &
        "Check that tests/githttpserver server is running on port 4242.\n" &
        "To start it run in another terminal:\n" &
        "  nim c -r tests/githttpserver test-repos/generated"

checkServer()

template sameDirContents(expected, given: string) =
  # result = true
  for _, e in walkDir(expected):
    let g = given / splitPath(e).tail
    if fileExists(g):
      let edata  = readFile(e)
      let gdata = readFile(g)
      check gdata == edata
      if gdata != edata:
        echo "FAILURE: files differ: ", e.absolutePath
        echo diffFiles(e, g).output
    else:
      echo "FAILURE: file does not exist: ", g
      check fileExists(g)
      # result = false

template testSemVer2(expected: string) =
  createDir "semproject"
  withDir "semproject":
    let cmd = atlasExe & " --full --keepWorkspace --resolver=SemVer --colors:off --list use proj_a"
    let (outp, status) = execCmdEx(cmd)
    if status == 0:
      checkpoint "<<<<<<<<<<<<<<<< Failed test\n" &
                  "\nExpected contents:\n\t" & expected.replace("\n", "\n\t") &
                  "\nInstead got:\n\t" & outp.replace("\n", "\n\t") &
                  ">>>>>>>>>>>>>>>> Failed\n"
      check outp.contains expected
    else:
      echo "\n\n"
      echo "<<<<<<<<<<<<<<<< Failed Exec "
      echo "testSemVer2:command: ", cmd
      echo "testSemVer2:pwd: ", getCurrentDir()
      echo "testSemVer2:failed command:"
      echo "================ Output:\n\t" & outp.replace("\n", "\n\t")
      echo ">>>>>>>>>>>>>>>> failed\n"
      check status == 0

template testMinVer(expected: string) =
  createDir "minproject"
  withDir "minproject":
    let cmd = atlasExe & " --keepWorkspace --resolver=MinVer --list use proj_a"
    let (outp, status) = execCmdEx(atlasExe & " --keepWorkspace --resolver=MinVer --list use proj_a")
    if status == 0:
      checkpoint "<<<<<<<<<<<<<<<< Failed test\n" &
                  "\nExpected contents:\n\t" & expected.replace("\n", "\n\t") &
                  "\nInstead got:\n\t" & outp.replace("\n", "\n\t") &
                  ">>>>>>>>>>>>>>>> Failed\n"
      check outp.contains expected
    else:
      echo "\n\n"
      echo "<<<<<<<<<<<<<<<< Failed Exec "
      echo "testSemVer2:command: ", cmd
      echo "testSemVer2:pwd: ", getCurrentDir()
      echo "testSemVer2:failed command:"
      echo "================ Output:\n\t" & outp.replace("\n", "\n\t")
      echo ">>>>>>>>>>>>>>>> failed\n"
      check status == 0

template removeDirs() =
  removeDir "does_not_exist"
  removeDir "semproject"
  removeDir "minproject"
  removeDir "source"
  removeDir "proj_a"
  removeDir "proj_b"
  removeDir "proj_c"
  removeDir "proj_d"

suite "basic repo tests":
  test "tests/ws_semver2":
    withDir "tests/ws_semver2":
      try:
        buildGraph()
        let semVerExpectedResult = dedent"""
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
        testSemVer2(semVerExpectedResult)
      finally:
        removeDirs()

  test "tests/ws_semver2":
    withDir "tests/ws_semver2":
      try:
        buildGraphNoGitTags()
        let semVerExpectedResultNoGitTags = dedent"""
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
        testSemVer2(semVerExpectedResultNoGitTags)
      finally:
        removeDirs()

  test "tests/ws_semver2":
      withDir "tests/ws_semver2":
        buildGraph()
        try:
          let minVerExpectedResult = dedent"""
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
          testMinVer(minVerExpectedResult)
        finally:
          removeDirs()

proc integrationTest() =
  # Test installation of some "important_packages" which we are sure
  # won't disappear in the near or far future. Turns out `nitter` has
  # quite some dependencies so it suffices:

  exec atlasExe & " --proxy=http://localhost:4242/ --dumbproxy --full --verbosity:trace --keepWorkspace use https://github.com/zedeus/nitter"
  # exec atlasExe & " --verbosity:trace --keepWorkspace use https://github.com/zedeus/nitter"

  sameDirContents("expected", ".")

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

# if failures > 0: quit($failures & " failures occurred.")

# Normal: create or remotely cloning repos
# nim c -r   1.80s user 0.71s system 60% cpu 4.178 total
# shims/nim c -r   32.00s user 25.11s system 41% cpu 2:18.60 total
# nim c -r   30.83s user 24.67s system 40% cpu 2:17.17 total

# Local repos:
# nim c -r   1.59s user 0.60s system 88% cpu 2.472 total
# w/integration: nim c -r   23.86s user 18.01s system 71% cpu 58.225 total
# w/integration: nim c -r   32.00s user 25.11s system 41% cpu 1:22.80 total
