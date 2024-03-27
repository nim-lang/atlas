
import std/unittest
import std/strutils
import std/paths
import std/options

import context, reporters, nimbleparser, pkgurls
import osutils
import compiledpatterns
import pkgurls
import depgraphs

proc toDirSep(s: string): string =
  result = s.replace("/", $DirSep)

template setupDepsAndGraph(url: string) =
  var
    p {.inject.} = initPatterns()
    u {.inject.} = createUrl(url, p)
    c {.inject.} = AtlasContext()
    g {.inject.} = createGraph(c, u, readConfig = false)
    d {.inject.} = Dependency()

  c.depsDir = "fakeDeps"
  c.workspace = "/workspace/".toDirSep
  c.projectDir = "/workspace".toDirSep

suite "test pkgurls":

  test "basic url":
    setupDepsAndGraph("https://github.com/example/proj.git")
    check $u == "https://github.com/example/proj.git"
    check u.projectName == "proj"

  test "basic url no git":
    setupDepsAndGraph("https://github.com/example/proj")
    check $u == "https://github.com/example/proj"
    check u.projectName == "proj"

  test "basic url prefix":
    setupDepsAndGraph("https://github.com/example/nim-proj")
    check $u == "https://github.com/example/nim-proj"
    check u.projectName == "nim-proj"

suite "nimble stuff":

  setup:
    setupDepsAndGraph("https://github.com/example/nim-proj")
    osutils.filesContext.currDir = "/workspace/".toDirSep
    osutils.filesContext.walkDirs["/workspace/fakeDeps/apatheia/*.nimble".toDirSep] = @["/workspace/fakeDeps/apatheia.nimble".toDirSep]

  test "basic path":
    let dir = "/workspace/fakeDeps/apatheia".toDirSep
    echo "BAISC PATH: ", dir
    let res = findNimbleFile(c, u, dir)
    check res == some("/workspace/fakeDeps/apatheia.nimble".toDirSep)

  test "with currdir":
    let currDir = "/workspace/fakeDeps/apatheia".toDirSep
    let res = findNimbleFile(c, u, currDir)
    check res == some("/workspace/fakeDeps/apatheia.nimble".toDirSep)

  test "with files":
    let dir = "/workspace/fakeDeps/apatheia".toDirSep
    osutils.filesContext.currDir = dir
    let res = findNimbleFile(c, dir)
    check res == some("/workspace/fakeDeps/apatheia.nimble".toDirSep)

  test "missing":
    osutils.filesContext.walkDirs["/workspace/fakeDeps/apatheia/*.nimble".toDirSep] = @[]
    let res = findNimbleFile(c, u, "/workspace/fakeDeps/apatheia".toDirSep)
    check res == string.none
    check c.errors == 0

  test "ambiguous":
    osutils.filesContext.walkDirs["/workspace/fakeDeps/apatheia/*.nimble".toDirSep] = @[
      "/workspace/fakeDeps/apatheia.nimble".toDirSep,
      "/workspace/fakeDeps/nim-apatheia.nimble".toDirSep
    ]
    let res = findNimbleFile(c, u, "/workspace/fakeDeps/apatheia".toDirSep)
    check res == string.none
    check c.errors == 1

  test "check module name recovery":
    let res = findNimbleFile(c, u, "/workspace/fakeDeps/apatheia".toDirSep)
    check res == some("/workspace/fakeDeps/apatheia.nimble".toDirSep)

suite "tests":
  test "basic":

    setupDepsAndGraph("https://github.com/codex-storage/apatheia.git")
    echo "U: ", u
    # echo "G: ", g.toJson().pretty()



