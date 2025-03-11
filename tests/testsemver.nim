# Small program that runs the test cases

import std / [strutils, os, osproc, sequtils, strformat, unittest]
import basic/context
import testerutils

if execShellCmd("nim c -o:$# -d:release src/atlas.nim" % [atlasExe]) != 0:
  quit("FAILURE: compilation of atlas failed")

ensureGitHttpServer()

template testSemVer2(name, expected: string) =
  # createDir name
  # withDir name:
  block:
    let cmd = atlasExe & " --full --proxy=http://localhost:4242 --ignoreerrors --dumbProxy --keepWorkspace --resolver=SemVer --colors:off --list use proj_a"
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
  # createDir name
  # withDir name:
  block:
    let cmd = atlasExe & " --full --proxy=http://localhost:4242 --ignoreerrors --dumbProxy --keepWorkspace --resolver=MinVer --colors:off --list use proj_a"
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
      withDir "tests/ws_semproject1":
        removeDirs("deps")
        setupGraph()
        let semVerExpectedResult = dedent"""
        [Warn]   (Resolved) selected: 
        [Warn]   (proj_a.buildGraph.example.com) [ ] (proj_a.buildGraph.example.com, 1.0.0@e479b438) 
        [Warn]   (proj_a.buildGraph.example.com) [x] (proj_a.buildGraph.example.com, 1.1.0@fb3804df^) 
        [Warn]   (proj_b.buildGraph.example.com) [ ] (proj_b.buildGraph.example.com, 1.0.0@af427510) 
        [Warn]   (proj_b.buildGraph.example.com) [x] (proj_b.buildGraph.example.com, 1.1.0@ee875bae^) 
        [Warn]   (proj_c.buildGraph.example.com) [x] (proj_c.buildGraph.example.com, 1.2.0@9331e14f^) 
        [Warn]   (proj_d.buildGraph.example.com) [x] (proj_d.buildGraph.example.com, 1.0.0@0dec9c97) 
        [Warn]   (proj_d.buildGraph.example.com) [!] (HasBrokenDep; pkg: proj_d.buildGraph.example.com, 2.0.0@dd98f775^) 
        [Warn]   (Resolved) end of selection 
        """
        testSemVer2("semproject1", semVerExpectedResult)

  test "semproject2":
      withDir "tests/ws_semproject2":
        removeDirs("semproject2")
        removeDirs("deps")
        setupGraphNoGitTags()
        let semVerExpectedResultNoGitTags = dedent"""
        [Warn]   (Resolved) selected: 
        [Warn]   (proj_a.buildGraphNoGitTags.example.com) [ ] (proj_a.buildGraphNoGitTags.example.com, 1.0.0@88d1801b) 
        [Warn]   (proj_a.buildGraphNoGitTags.example.com) [ ] (proj_a.buildGraphNoGitTags.example.com, 1.0.0@6a1cc178) 
        [Warn]   (proj_a.buildGraphNoGitTags.example.com) [x] (proj_a.buildGraphNoGitTags.example.com, 1.1.0@61eacba5^) 
        [Warn]   (proj_b.buildGraphNoGitTags.example.com) [ ] (proj_b.buildGraphNoGitTags.example.com, 1.0.0@289ae9ee) 
        [Warn]   (proj_b.buildGraphNoGitTags.example.com) [ ] (proj_b.buildGraphNoGitTags.example.com, 1.0.0@bbb208a9) 
        [Warn]   (proj_b.buildGraphNoGitTags.example.com) [x] (proj_b.buildGraphNoGitTags.example.com, 1.1.0@c70824d8^) 
        [Warn]   (proj_c.buildGraphNoGitTags.example.com) [ ] (proj_c.buildGraphNoGitTags.example.com, 1.0.0@8756fa45) 
        [Warn]   (proj_c.buildGraphNoGitTags.example.com) [x] (proj_c.buildGraphNoGitTags.example.com, 1.2.0@d6c04d67^) 
        [Warn]   (proj_d.buildGraphNoGitTags.example.com) [x] (proj_d.buildGraphNoGitTags.example.com, 1.0.0@0bd0e77a) 
        [Warn]   (proj_d.buildGraphNoGitTags.example.com) [!] (HasBrokenDep; pkg: proj_d.buildGraphNoGitTags.example.com, 2.0.0@7ee36fec^) 
        [Warn]   (Resolved) end of selection 
        """
        
        testSemVer2("semproject2", semVerExpectedResultNoGitTags)

  test "minproject1":
      withDir "tests/ws_minproject1":
        removeDirs("deps")
        setupGraph()
        let minVerExpectedResult = dedent"""
        [Warn]   (Resolved) selected: 
        [Warn]   (proj_a.buildGraph.example.com) [x] (proj_a.buildGraph.example.com, 1.0.0@e479b438) 
        [Warn]   (proj_a.buildGraph.example.com) [ ] (proj_a.buildGraph.example.com, 1.1.0@fb3804df^) 
        [Warn]   (proj_b.buildGraph.example.com) [x] (proj_b.buildGraph.example.com, 1.0.0@af427510) 
        [Warn]   (proj_b.buildGraph.example.com) [ ] (proj_b.buildGraph.example.com, 1.1.0@ee875bae^) 
        [Warn]   (proj_c.buildGraph.example.com) [x] (proj_c.buildGraph.example.com, 1.2.0@9331e14f^) 
        [Warn]   (proj_d.buildGraph.example.com) [x] (proj_d.buildGraph.example.com, 1.0.0@0dec9c97) 
        [Warn]   (proj_d.buildGraph.example.com) [!] (HasBrokenDep; pkg: proj_d.buildGraph.example.com, 2.0.0@dd98f775^) 
        [Warn]   (Resolved) end of selection 
        """
        testMinVer("minproject", minVerExpectedResult)
