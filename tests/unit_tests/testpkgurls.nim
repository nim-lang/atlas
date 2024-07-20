
import std/unittest
import std/strutils
import std/paths
import std/options

import ../setups

import context, reporters, nimbleparser
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

template withProjectDir*(names: varargs[string], blk: untyped) =
  createDir "workspace"
  setCurrentDir("workspace")
  c.workspace = os.getCurrentDir()
  for name in names:
    createDir name
    setCurrentDir(name)
    c.projectDir = os.getCurrentDir()
  `blk`
  discard
  when false:
    echo "\n<<<<<< CWD: ", os.getCurrentDir()
    echo "workspace: ", c.workspace
    echo "projectDir: ", c.projectDir, "\n"
    discard execShellCmd("find " & dir)
    echo ">>>>>>\n\n"

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

# var testTemplateDir: string
# withTempTestDirFull("test_template", remove=false):
#   buildGraphNoGitTags()
#   testTemplateDir = dir

suite "nimble stuff":
  setup:
    setupDepsAndGraph("https://github.com/example/nim-testProj1")

  test "find nimble in project dir from project dir":
    withTempTestDir "test":
      withProjectDir "fakeDeps", "testProj1":
        writeFile("testProj1.nimble", "")
        let projDir = "workspace" / "fakeDeps" / "testProj1"
        let res1 = findNimbleFile(c, u, dir / projDir)
        check res1.get().relativePath(dir) == projDir / "testProj1.nimble"

        setCurrentDir(dir / "workspace")
        let res2 = findNimbleFile(c, u, dir / projDir)
        check res2.get().relativePath(dir) == projDir / "testProj1.nimble"

  test "find nimble in project dir with other name":
    withTempTestDir "test":
      withProjectDir "fakeDeps", "nim-testProj1":
        writeFile("testProj1.nimble", "")
        let projDir = "workspace" / "fakeDeps" / "nim-testProj1"
        let res = findNimbleFile(c, u, dir / projDir)
        check res.get().relativePath(dir) == projDir / "testProj1.nimble"

  test "missing":
    withTempTestDir "basic_url":
      withProjectDir "fakeDeps", "testProj1":
        let projDir = "workspace" / "fakeDeps" / "testProj1"
        let res1 = findNimbleFile(c, u, dir / projDir)
        check res1.isNone()

  test "ambiguous":
    withTempTestDir "basic_url":
      withProjectDir "fakeDeps", "testProj1":
        writeFile("testProj1.nimble", "")
        writeFile("testProj2.nimble", "")
        let projDir = "workspace" / "fakeDeps" / "testProj1"
        let res = findNimbleFile(c, u, dir / projDir)
        check res == string.none
        # check c.errors == 1

