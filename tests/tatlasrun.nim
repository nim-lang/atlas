import std/[os, paths, unittest]

import nimbletaskrunner

proc freshDir(name: string): Path =
  result = Path(getTempDir()) / Path name
  if dirExists($result):
    removeDir($result)
  createDir($result)

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
    check readFile($(dir / Path"dir.txt")) == $dir.absolutePath()

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
