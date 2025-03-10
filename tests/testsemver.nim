# Small program that runs the test cases

import std / [strutils, os, osproc, sequtils, strformat, unittest]
import basic/context
import testerutils

if execShellCmd("nim c -o:$# -d:release src/atlas.nim" % [atlasExe]) != 0:
  quit("FAILURE: compilation of atlas failed")

ensureGitHttpServer()

template testSemVer2(name, expected: string) =
  createDir name
  withDir name:
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
      echo "testSemVer2:pwd: ", ospaths2.getCurrentDir()
      echo "testSemVer2:failed command:"
      echo "================ Output:\n\t" & outp.replace("\n", "\n\t")
      echo ">>>>>>>>>>>>>>>> failed\n"
      check status == 0

template testMinVer(name, expected: string) =
  createDir name
  withDir name:
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
      echo "tesMinVer2:command: ", cmd
      echo "tesMinVer2:pwd: ", ospaths2.getCurrentDir()
      echo "tesMinVer2:failed command:"
      echo "================ Output:\n\t" & outp.replace("\n", "\n\t")
      echo ">>>>>>>>>>>>>>>> failed\n"
      check status == 0

template removeDirs(projDir: string) =
  removeDir projDir
  removeDir "does_not_exist"
  # removeDir "semproject"
  # removeDir "minproject"
  removeDir "source"
  removeDir "proj_a"
  removeDir "proj_b"
  removeDir "proj_c"
  removeDir "proj_d"

proc setupGraph* =
  createDir "source"
  withDir "source":

    exec "git clone http://localhost:4242/buildGraph/proj_a"
    exec "git clone http://localhost:4242/buildGraph/proj_b"
    exec "git clone http://localhost:4242/buildGraph/proj_c"
    exec "git clone http://localhost:4242/buildGraph/proj_d"

proc setupGraphNoGitTags* =
  createDir "source"
  withDir "source":

    exec "git clone http://localhost:4242/buildGraphNoGitTags/proj_a"
    exec "git clone http://localhost:4242/buildGraphNoGitTags/proj_b"
    exec "git clone http://localhost:4242/buildGraphNoGitTags/proj_c"
    exec "git clone http://localhost:4242/buildGraphNoGitTags/proj_d"

suite "basic repo tests":
  test "semproject1":
      withDir "tests/ws_semver2":
        removeDirs("semproject1")
        setupGraph()
        let semVerExpectedResult = dedent"""
        [Info] (../resolve) selected:
        [Info] (proj_a) [x] (proj_a, 1.1.0)
        [Info] (proj_a) [ ] (proj_a, 1.0.0)
        [Info] (proj_b) [ ] (proj_b, 1.1.0)
        [Info] (proj_b) [x] (proj_b, 1.1.0)
        [Info] (proj_c) [x] (proj_c, 1.2.0)
        [Info] (proj_d) [ ] (proj_d, 2.0.0)
        [Info] (proj_d) [x] (proj_d, 1.0.0)
        [Info] (../resolve) end of selection

        """
        testSemVer2("semproject1", semVerExpectedResult)

  test "semproject2":
      withDir "tests/ws_semver2":
        removeDirs("semproject2")
        setupGraphNoGitTags()
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
        
        testSemVer2("semproject2", semVerExpectedResultNoGitTags)

  test "minproject1":
      withDir "tests/ws_semver2":
        removeDirs("minproject")
        setupGraph()
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
        testMinVer("minproject", minVerExpectedResult)
