import std/[os, osproc, paths, strutils, unittest]
from std/envvars import delEnv, existsEnv, getEnv, putEnv

import atlasrun
import nimble/nimblebuilder
import nimble/nimbletaskrunner
import testrunner

proc freshDir(name: string): Path =
  result = Path(getTempDir()) / Path name
  if dirExists($result):
    removeDir($result)
  createDir($result)

proc normalizedPath(path: string): string =
  path.replace("\\", "/")

template withNimFlags(value: string; body: untyped) =
  let hadNimFlags = existsEnv("NIMFLAGS")
  let oldNimFlags = getEnv("NIMFLAGS")
  putEnv("NIMFLAGS", value)
  try:
    body
  finally:
    if hadNimFlags:
      putEnv("NIMFLAGS", oldNimFlags)
    else:
      delEnv("NIMFLAGS")

suite "atlas-run":
  test "lists tasks from nimble file":
    let dir = freshDir("atlas_run_lists_tasks")
    defer:
      removeDir($dir)

    let nimbleFile = dir / Path"demo.nimble"
    writeFile($nimbleFile, """
version = "0.1.0"

task hello, "Writes hello":
  discard

task hidden, "":
  discard
""")

    let tasks = listNimbleTasks(nimbleFile)
    check tasks.len == 2
    check tasks[0].name == "hello"
    check tasks[0].description == "Writes hello"
    check tasks[1].name == "hidden"

  test "runs task with command line params":
    let dir = freshDir("atlas_run_command_line_params")
    defer:
      removeDir($dir)

    let nimbleFile = dir / Path"demo.nimble"
    writeFile($nimbleFile, """
version = "0.1.0"

task hello, "Writes task args":
  writeFile("args.txt", commandLineParams.join(","))
""")

    check runNimbleTask(nimbleFile, "hello", @["one", "--two"]) == 0
    check readFile($(dir / Path"args.txt")) == "one,--two"

  test "thisDir points at package directory":
    let dir = freshDir("atlas_run_this_dir")
    defer:
      removeDir($dir)

    let nimbleFile = dir / Path"demo.nimble"
    writeFile($nimbleFile, """
version = "0.1.0"

task where, "Writes package dir":
  writeFile("dir.txt", thisDir())
""")

    check runNimbleTask(nimbleFile, "where") == 0
    check normalizedPath(readFile($(dir / Path"dir.txt"))) ==
      normalizedPath($dir.absolutePath())

  test "unknown task fails before script execution":
    let dir = freshDir("atlas_run_unknown_task")
    defer:
      removeDir($dir)

    let nimbleFile = dir / Path"demo.nimble"
    writeFile($nimbleFile, """
version = "0.1.0"

task hello, "Writes hello":
  discard
""")

    expect ValueError:
      discard runNimbleTask(nimbleFile, "missing")

  test "runs nim command requested by setCommand":
    let dir = freshDir("atlas_run_set_command")
    defer:
      removeDir($dir)

    let nimbleFile = dir / Path"demo.nimble"
    let outputName = "built".addFileExt(ExeExt)
    writeFile($(dir / Path"main.nim"), "echo \"built\"\n")
    writeFile($nimbleFile, """
version = "0.1.0"

task build, "Builds main":
  setCommand "c", "main.nim"
  switch "out", "built"
""")

    check runNimbleTask(nimbleFile, "build") == 0
    check fileExists($(dir / Path outputName))

  test "lists binaries from nimble file":
    let dir = freshDir("atlas_run_lists_binaries")
    defer:
      removeDir($dir)

    let nimbleFile = dir / Path"demo.nimble"
    writeFile($nimbleFile, """
version = "0.1.0"
srcDir = "src"
binDir = "dist"
bin = @["main", "tools/helper"]
namedBin = {"main": "demo"}.toTable
namedBin["tools/helper"] = "helper"
""")

    let binaries = listNimbleBinaries(nimbleFile, compilerArgs = ["-d:foo"])
    check binaries.len == 2
    check binaries[0].name == "main"
    check binaries[0].source == dir / Path"src" / Path"main.nim"
    check binaries[0].output == dir / Path"dist" / Path("demo".addFileExt(ExeExt))
    check "-d:foo" in binaries[0].commandLine
    check binaries[1].name == "tools/helper"
    check binaries[1].source == dir / Path"src" / Path"tools" / Path"helper.nim"
    check binaries[1].output == dir / Path"dist" / Path("helper".addFileExt(ExeExt))
    check "-d:foo" in binaries[1].commandLine

  test "builds binaries from nimble file":
    let dir = freshDir("atlas_run_builds_binaries")
    defer:
      removeDir($dir)

    let srcDir = dir / Path"src"
    createDir($srcDir)
    writeFile($(srcDir / Path"tool.nim"), "echo \"tool\"\n")

    let nimbleFile = dir / Path"demo.nimble"
    writeFile($nimbleFile, """
version = "0.1.0"
srcDir = "src"
binDir = "dist"
bin = @["tool"]
namedBin = {"tool": "demo-tool"}.toTable
""")

    check runNimbleBuild(nimbleFile) == 0
    check fileExists($(dir / Path"dist" / Path("demo-tool".addFileExt(ExeExt))))

  test "build passes compiler args after dash dash":
    let dir = freshDir("atlas_run_build_compiler_args")
    defer:
      removeDir($dir)

    let srcDir = dir / Path"src"
    createDir($srcDir)
    writeFile($(srcDir / Path"tool.nim"), """
when not defined(fromBuildDash):
  {.error: "missing build compiler define".}
echo "build flag ok"
""")

    let nimbleFile = dir / Path"demo.nimble"
    writeFile($nimbleFile, """
version = "0.1.0"
srcDir = "src"
binDir = "dist"
bin = @["tool"]
namedBin = {"tool": "demo-tool"}.toTable
""")

    let code = atlasRunMain(@[
      "--project:" & $dir,
      "build",
      "--",
      "-d:fromBuildDash"
    ])
    check code == 0
    check fileExists($(dir / Path"dist" / Path("demo-tool".addFileExt(ExeExt))))

  test "discovers t-star test files":
    let dir = freshDir("atlas_run_discovers_tests")
    defer:
      removeDir($dir)

    let testsDir = dir / Path"tests"
    createDir($testsDir)
    writeFile($(testsDir / Path"talpha.nim"), "discard\n")
    writeFile($(testsDir / Path"tbeta.nim"), "discard\n")
    writeFile($(testsDir / Path"tbeta_extra.nim"), "discard\n")
    writeFile($(testsDir / Path"ttype.nim"), "discard\n")
    writeFile($(testsDir / Path"other.nim"), "discard\n")

    let srcDir = dir / Path"src"
    createDir($srcDir)
    writeFile($(srcDir / Path"beta.nim"), "discard\n")
    writeFile($(srcDir / Path"tbeta.nim"), "discard\n")
    writeFile($(srcDir / Path"type.nim"), "discard\n")

    let examplesDir = dir / Path"examples"
    createDir($examplesDir)
    writeFile($(examplesDir / Path"one.nim"), "discard\n")
    writeFile($(examplesDir / Path"two.nim"), "discard\n")
    writeFile($(examplesDir / Path"notes.txt"), "discard\n")

    let tests = discoverTestFiles(dir)
    check tests.len == 4
    check normalizedPath($tests[0]).endsWith("tests/talpha.nim")
    check normalizedPath($tests[1]).endsWith("tests/tbeta.nim")
    check normalizedPath($tests[2]).endsWith("tests/tbeta_extra.nim")
    check normalizedPath($tests[3]).endsWith("tests/ttype.nim")

    let selected = discoverTestFiles(dir, ["beta"])
    check selected.len == 2
    check normalizedPath($selected[0]).endsWith("tests/tbeta.nim")
    check normalizedPath($selected[1]).endsWith("tests/tbeta_extra.nim")

    let selectedByFilename = discoverTestFiles(dir, ["beta.nim"])
    check selectedByFilename.len == 1
    check normalizedPath($selectedByFilename[0]).endsWith("tests/tbeta.nim")

    let selectedByTestName = discoverTestFiles(dir, ["tbeta"])
    check selectedByTestName.len == 2
    check normalizedPath($selectedByTestName[0]).endsWith("tests/tbeta.nim")
    check normalizedPath($selectedByTestName[1]).endsWith("tests/tbeta_extra.nim")

    let selectedByDirectPath = discoverTestFiles(dir, ["src/beta.nim"])
    check selectedByDirectPath.len == 1
    check normalizedPath($selectedByDirectPath[0]).endsWith("src/beta.nim")

    let selectedByDirectTestPath = discoverTestFiles(dir, ["src/tbeta.nim"])
    check selectedByDirectTestPath.len == 1
    check normalizedPath($selectedByDirectTestPath[0]).endsWith("src/tbeta.nim")

    let selectedByTSourcePath = discoverTestFiles(dir, ["src/type.nim"])
    check selectedByTSourcePath.len == 1
    check normalizedPath($selectedByTSourcePath[0]).endsWith("src/type.nim")

    let selectedByGlob = discoverTestFiles(dir, ["examples/*.nim"])
    check selectedByGlob.len == 2
    check normalizedPath($selectedByGlob[0]).endsWith("examples/one.nim")
    check normalizedPath($selectedByGlob[1]).endsWith("examples/two.nim")

    let selectedByDirectTestsPath = discoverTestFiles(dir, ["tests/tbeta.nim"])
    check selectedByDirectTestsPath.len == 1
    check normalizedPath($selectedByDirectTestsPath[0]).endsWith("tests/tbeta.nim")

    let allWithSkip = discoverTestFiles(dir, [], ["beta_extra"])
    check allWithSkip.len == 3
    check normalizedPath($allWithSkip[0]).endsWith("tests/talpha.nim")
    check normalizedPath($allWithSkip[1]).endsWith("tests/tbeta.nim")
    check normalizedPath($allWithSkip[2]).endsWith("tests/ttype.nim")

    let selectedWithSkip = discoverTestFiles(dir, ["beta"], ["beta_extra"])
    check selectedWithSkip.len == 1
    check normalizedPath($selectedWithSkip[0]).endsWith("tests/tbeta.nim")

    let directSelectedWithSkip = discoverTestFiles(
      dir,
      ["examples/*.nim"],
      ["examples/two.nim"]
    )
    check directSelectedWithSkip.len == 1
    check normalizedPath($directSelectedWithSkip[0]).endsWith("examples/one.nim")

    expect ValueError:
      discard discoverTestFiles(dir, ["missing"])

    expect ValueError:
      discard discoverTestFiles(dir, ["beta"], ["beta"])

    let defaultOptions = initAtlasTestOptions()
    check defaultOptions.shuffle
    check not defaultOptions.compileOnly
    check not defaultOptions.onlyErrors
    check not defaultOptions.showCompilerOutput
    check defaultOptions.compilerArgs.len == 0
    check defaultOptions.skipSelectors.len == 0

  test "compile-only compiles tests without running them":
    let dir = freshDir("atlas_run_compile_only")
    defer:
      removeDir($dir)

    let testsDir = dir / Path"tests"
    createDir($testsDir)
    writeFile($(testsDir / Path"tcompileonly.nim"), """
writeFile("ran.out", "ran")
""")

    let code = runAtlasTests(initAtlasTestOptions(
      projectDir = dir,
      compileOnly = true,
      shuffle = false,
      showProgress = false,
      showOutput = false
    ))
    check code == 0
    check fileExists($(dir / Path".nimcache" / Path"atlas-run" /
      Path"tests" / Path"tcompileonly" / Path("tcompileonly".addFileExt(ExeExt))))
    check not fileExists($(dir / Path"ran.out"))

  test "compile-only compiles direct path selectors without running them":
    let dir = freshDir("atlas_run_compile_only_examples")
    defer:
      removeDir($dir)

    let examplesDir = dir / Path"examples"
    createDir($examplesDir)
    writeFile($(examplesDir / Path"one.nim"), """
writeFile("ran-one.out", "ran")
""")
    writeFile($(examplesDir / Path"two.nim"), """
writeFile("ran-two.out", "ran")
""")

    let code = runAtlasTests(initAtlasTestOptions(
      projectDir = dir,
      selectors = @["examples/*.nim"],
      compileOnly = true,
      shuffle = false,
      showProgress = false,
      showOutput = false
    ))
    check code == 0
    check fileExists($(dir / Path".nimcache" / Path"atlas-run" /
      Path"examples" / Path"one" / Path("one".addFileExt(ExeExt))))
    check fileExists($(dir / Path".nimcache" / Path"atlas-run" /
      Path"examples" / Path"two" / Path("two".addFileExt(ExeExt))))
    check not fileExists($(dir / Path"ran-one.out"))
    check not fileExists($(dir / Path"ran-two.out"))

  test "NIMFLAGS are passed to test compilation":
    let dir = freshDir("atlas_run_nimflags")
    defer:
      removeDir($dir)

    let testsDir = dir / Path"tests"
    createDir($testsDir)
    writeFile($(testsDir / Path"tnimflags.nim"), """
when not defined(fromNimFlags):
  {.error: "missing NIMFLAGS define".}
writeFile("nimflags.out", "ok")
""")

    withNimFlags("-d:fromNimFlags"):
      let code = runAtlasTests(initAtlasTestOptions(
        projectDir = dir,
        shuffle = false,
        showProgress = false,
        showOutput = false
      ))
      check code == 0
    check readFile($(dir / Path"nimflags.out")) == "ok"

  test "test -- compiler args override NIMFLAGS":
    let dir = freshDir("atlas_run_dash_compiler_args")
    defer:
      removeDir($dir)

    writeFile($(dir / Path"demo.nimble"), "version = \"0.1.0\"\n")
    let testsDir = dir / Path"tests"
    createDir($testsDir)
    writeFile($(testsDir / Path"tcli_flags.nim"), """
const mode {.strdefine.}: string = ""
when mode != "dash":
  {.error: "expected explicit compiler arg to override NIMFLAGS".}
writeFile("mode.out", mode)
""")

    withNimFlags("-d:mode=env"):
      let code = atlasRunMain(@[
        "--project:" & $dir,
        "tests",
        "--no-shuffle",
        "--only-errors",
        "cli",
        "--",
        "-d:mode=dash"
      ])
      check code == 0
    check readFile($(dir / Path"mode.out")) == "dash"

  test "runs discovered tests in parallel":
    let dir = freshDir("atlas_run_parallel_tests")
    defer:
      removeDir($dir)

    let testsDir = dir / Path"tests"
    createDir($testsDir)
    writeFile($(testsDir / Path"tone.nim"), """
writeFile("one.out", "ok")
""")
    writeFile($(testsDir / Path"ttwo.nim"), """
writeFile("two.out", "ok")
""")

    let code = runAtlasTests(initAtlasTestOptions(
      projectDir = dir,
      jobs = 2,
      showProgress = false,
      showOutput = false
    ))
    check code == 0
    check readFile($(dir / Path"one.out")) == "ok"
    check readFile($(dir / Path"two.out")) == "ok"
    check dirExists($(dir / Path".nimcache" / Path"atlas-run" / Path"tests" / Path"tone"))
    check dirExists($(dir / Path".nimcache" / Path"atlas-run" / Path"tests" / Path"ttwo"))

  test "non-interactive runs print progress summaries":
    let dir = freshDir("atlas_run_only_errors_summaries")
    defer:
      removeDir($dir)

    writeFile($(dir / Path"demo.nimble"), "version = \"0.1.0\"\n")
    let testsDir = dir / Path"tests"
    createDir($testsDir)
    writeFile($(testsDir / Path"tone.nim"), "discard\n")

    let atlasRunExe = dir / Path"atlas-run-test"
    let (buildOutput, buildExitCode) = execCmdEx(
      "nim c --out:" & quoteShell($atlasRunExe) & " src/atlasrun.nim"
    )
    check buildExitCode == 0
    if buildExitCode != 0:
      checkpoint buildOutput
    else:
      let (regularOutput, regularExitCode) = execCmdEx(
        quoteShell($atlasRunExe) & " --project:" & quoteShell($dir) &
          " tests --no-shuffle"
      )
      check regularExitCode == 0
      check "atlas-run:" in regularOutput
      check "tests/tone.nim" in regularOutput
      check "compiling" in regularOutput
      check "running" in regularOutput
      check "success" in regularOutput
      check "command: nim c" in regularOutput

      let (output, exitCode) = execCmdEx(
        quoteShell($atlasRunExe) & " --project:" & quoteShell($dir) &
          " tests --only-errors --no-shuffle"
      )
      check exitCode == 0
      check "atlas-run:" in output
      check "tests/tone.nim" in output
      check "compiling" in output
      check "running" in output
      check "success" in output

  test "CLI skip selectors remove matching tests":
    let dir = freshDir("atlas_run_skip_selectors")
    defer:
      removeDir($dir)

    writeFile($(dir / Path"demo.nimble"), "version = \"0.1.0\"\n")
    let testsDir = dir / Path"tests"
    createDir($testsDir)
    writeFile($(testsDir / Path"talpha.nim"), "writeFile(\"alpha.out\", \"ok\")\n")
    writeFile($(testsDir / Path"tbeta.nim"), "writeFile(\"beta.out\", \"ok\")\n")
    writeFile($(testsDir / Path"tgamma.nim"), "writeFile(\"gamma.out\", \"ok\")\n")

    let code = atlasRunMain(@[
      "--project:" & $dir,
      "tests",
      "--no-shuffle",
      "--only-errors",
      "t",
      "--skip",
      "alpha",
      "--skip",
      "gamma"
    ])
    check code == 0
    check not fileExists($(dir / Path"alpha.out"))
    check readFile($(dir / Path"beta.out")) == "ok"
    check not fileExists($(dir / Path"gamma.out"))

  test "uses custom nimcache root with per-test subdirectories":
    let dir = freshDir("atlas_run_custom_nimcache")
    defer:
      removeDir($dir)

    let testsDir = dir / Path"tests"
    createDir($testsDir)
    writeFile($(testsDir / Path"tcache.nim"), "discard\n")

    let code = runAtlasTests(initAtlasTestOptions(
      projectDir = dir,
      nimcacheDir = Path"custom-cache",
      shuffle = false,
      showProgress = false,
      showOutput = false
    ))
    check code == 0
    check dirExists($(dir / Path"custom-cache" / Path"tests" / Path"tcache"))
