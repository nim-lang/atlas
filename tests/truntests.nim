import std/[os, strutils, unittest]
import testerutils

suite "atlas test runner":
  # Ensure atlas binary exists
  if execShellCmd("nim c --nimcache:.nimcache -o:$# -d:release src/atlas.nim" % [atlasExe]) != 0:
    quit "Failed to build atlas binary"

  let ws = "tests/ws_runtests"
  if not dirExists(ws): createDir(ws)

  withDir ws:
    # Clean previous markers and prepare tests dir
    if fileExists("ran_a.txt"): removeFile("ran_a.txt")
    if fileExists("ran_b.txt"): removeFile("ran_b.txt")
    if not dirExists("tests"): createDir("tests")

    test "runs all tests by default":
      exec atlasExe & " --project:. test"
      check fileExists("ran_a.txt")
      check fileExists("ran_b.txt")

    # Reset markers
    if fileExists("ran_a.txt"): removeFile("ran_a.txt")
    if fileExists("ran_b.txt"): removeFile("ran_b.txt")

    test "runs a single specified test":
      exec atlasExe & " --project:. test tests/ta.nim"
      check fileExists("ran_a.txt")
      check not fileExists("ran_b.txt")

    # Reset markers
    if fileExists("ran_a.txt"): removeFile("ran_a.txt")
    if fileExists("ran_b.txt"): removeFile("ran_b.txt")

    test "runs multiple specified tests":
      exec atlasExe & " --project:. test tests/ta.nim tests/tb.nim"
      check fileExists("ran_a.txt")
      check fileExists("ran_b.txt")
