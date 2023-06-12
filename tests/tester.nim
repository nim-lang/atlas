# Small program that runs the test cases

import std / [strutils, os, sequtils, strformat]
from std/private/gitutils import diffFiles

if execShellCmd("nim c -r src/versions.nim") != 0:
  quit("FAILURE: unit tests in src/versions.nim failed")

var failures = 0

let atlasExe = absolutePath("bin" / "atlas".addFileExt(ExeExt))
if execShellCmd("nim c -o:$# src/atlas.nim" % [atlasExe]) != 0:
  quit("FAILURE: compilation of atlas failed")

proc exec(cmd: string) =
  if execShellCmd(cmd) != 0:
    quit "FAILURE: " & cmd

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

proc testWsConflict() =
  const myproject = "tests/ws_conflict/myproject"
  createDir(myproject)
  exec atlasExe & " --project=" & myproject & " --showGraph --genLock use https://github.com/apkg"
  if sameDirContents("tests/ws_conflict/expected", myproject):
    removeDir("tests/ws_conflict/apkg")
    removeDir("tests/ws_conflict/bpkg")
    removeDir("tests/ws_conflict/cpkg")
    removeDir("tests/ws_conflict/dpkg")
    removeDir(myproject)

type
  Node = object
    name: string
    versions: seq[string]
    deps: seq[string]

proc createNode(name: string, versions: seq[string], deps: seq[string]): Node =
  result = Node(name: name, versions: versions, deps: deps)

template withDir(dir: string; body: untyped) =
  let old = getCurrentDir()
  try:
    setCurrentDir(dir)
    body
  finally:
    setCurrentDir(old)

proc createNimblePackage(node: Node) =
  for v in node.versions:
    let packagePath = if v != "1.0.0": node.name & "@" & v else: node.name
    createDir(packagePath)
    withDir packagePath:
      var nimbleContent = ""
      for d in node.deps:
        nimbleContent.add &"requires \"{d}\""
      writeFile(node.name & ".nimble", nimbleContent)

proc testSemVer() =
  # Example graph data
  let graph = @[
    createNode("A", @["1.0.0", "1.1.0", "2.0.0"], @[]),
    createNode("B", @["2.1.0", "3.0.0", "3.1.0"], @["A >= 1.0.0"]),
    createNode("C", @["1.2.0", "1.2.1"], @["B >= 2.0.0"]),
    createNode("D", @["1.0.0", "1.1.0", "1.1.1"], @["C >= 1.0"]),
    createNode("E", @["2.0.0", "2.0.1", "2.1.0"], @["D >= 1.0.0"]),
    createNode("F", @["1.0.0", "1.0.1", "1.1.0"], @["E >= 2.0.0"])
  ]

  createDir "source"
  withDir "source":
    for i in 0..<graph.len:
      createNimblePackage graph[i]

  createDir "myproject"
  withDir "myproject":
    exec atlasExe & " --showGraph use F"

withDir "tests/ws_semver":
  testSemVer()
if sameDirContents("tests/ws_semver/expected", "tests/ws_semver/myproject"):
  removeDir("tests/ws_semver/myproject")
  removeDir("tests/ws_semver/source")

testWsConflict()
if failures > 0: quit($failures & " failures occurred.")
