#
#           Atlas Package Cloner
#        (c) Copyright 2026 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std/[os, paths, strutils]

import basic/atlasversion
import nimbletaskrunner
import testrunner

const Usage = "atlas-run - Atlas project runner Version " & AtlasVersion & """

Usage:
  atlas-run [options] task [--list | task-name [arguments]]
  atlas-run [options] test [--list] [--jobs:N] [test-selector...]

Commands:
  task                  list or run tasks declared in the project's Nimble file
  test                  run tests matching tests/t*.nim in parallel

Options:
  --help, -h            show this help
  --version, -v         show the version
  --project=path, -p    use the project directory or Nimble file at path
  --nim=path            use the Nim executable at path
  --list                list tasks or tests without running them
  --jobs=N, -j:N        number of parallel test jobs, or auto
  --nimcache=path       test cache root; each test gets a subdirectory
  --no-shuffle          run tests in sorted discovery order
  --shuffle             shuffle test order (default)

With no command, atlas-run prints this help and the project's Nimble tasks.
For compatibility, atlas-run <name> still runs a Nimble task unless <name> is
a built-in command such as test.
"""

type
  CliCommand = enum
    cmdTask, cmdTest

  CliOptions = object
    command: CliCommand
    commandSet: bool
    projectArg: Path
    nimExe: string
    nimcacheDir: Path
    listOnly: bool
    jobs: int
    testOptionsSeen: bool
    shuffle: bool
    task: string
    taskArgs: seq[string]
    testSelectors: seq[string]

proc writeUsage() =
  stdout.write(Usage)
  stdout.flushFile()

proc writeHelp(code = 0) =
  writeUsage()
  quit(code)

proc writeVersion() =
  stdout.write("version: " & AtlasVersion & "\n")
  stdout.flushFile()
  quit(0)

proc readOptionValue(params: seq[string]; i: var int; key, value: string): string =
  if value.len > 0:
    return value
  inc i
  if i >= params.len:
    quit("atlas-run: missing value for " & key, 2)
  result = params[i]

proc splitLongOption(arg: string): tuple[key, value: string] =
  let
    eq = arg.find('=')
    colon = arg.find(':')
    sep =
      if eq >= 0:
        eq
      else:
        colon
  if sep >= 0:
    result.key = arg[2 ..< sep]
    result.value = arg[sep+1 .. ^1]
  else:
    result.key = arg[2 .. ^1]

proc readJobsValue(params: seq[string]; i: var int; key, value: string): int =
  let raw = readOptionValue(params, i, key, value).normalize
  if raw == "auto":
    return DefaultAtlasTestJobs
  try:
    result = parseInt(raw)
  except ValueError:
    quit("atlas-run: invalid jobs value: " & raw, 2)
  if result <= 0:
    quit("atlas-run: jobs must be greater than zero or auto", 2)

proc parseCliOptions(params: seq[string]): CliOptions =
  result.nimExe = "nim"
  result.command = cmdTask
  result.shuffle = true

  var i = 0
  while i < params.len:
    let arg = params[i]

    if result.command == cmdTask and result.task.len > 0:
      if arg == "--":
        inc i
        while i < params.len:
          result.taskArgs.add params[i]
          inc i
        break
      else:
        result.taskArgs.add arg
    elif result.command == cmdTest and arg == "--":
      inc i
      while i < params.len:
        result.testSelectors.add params[i]
        inc i
      break
    elif arg == "--":
      inc i
      while i < params.len:
        result.taskArgs.add params[i]
        inc i
      break
    elif arg == "-h" or arg == "--help":
      writeHelp(0)
    elif arg == "-v" or arg == "--version":
      writeVersion()
    elif arg == "--list":
      result.listOnly = true
    elif arg == "-p":
      result.projectArg = Path readOptionValue(params, i, arg, "")
    elif arg.startsWith("-p:") or arg.startsWith("-p="):
      result.projectArg = Path arg[3 .. ^1]
    elif arg == "-j":
      result.testOptionsSeen = true
      result.jobs = readJobsValue(params, i, arg, "")
    elif arg.startsWith("-j:") or arg.startsWith("-j="):
      result.testOptionsSeen = true
      result.jobs = readJobsValue(params, i, arg, arg[3 .. ^1])
    elif arg.startsWith("--"):
      let (key, value) = splitLongOption(arg)
      case key.normalize
      of "project":
        result.projectArg = Path readOptionValue(params, i, arg, value)
      of "nim":
        result.nimExe = readOptionValue(params, i, arg, value)
      of "jobs":
        result.testOptionsSeen = true
        result.jobs = readJobsValue(params, i, arg, value)
      of "nimcache", "nimcache-dir", "nimcache-root":
        result.testOptionsSeen = true
        result.nimcacheDir = Path readOptionValue(params, i, arg, value)
      of "shuffle":
        result.testOptionsSeen = true
        result.shuffle = true
      of "no-shuffle":
        result.testOptionsSeen = true
        result.shuffle = false
      else:
        quit("atlas-run: unknown option: " & arg, 2)
    elif arg.startsWith("-"):
      quit("atlas-run: unknown option: " & arg, 2)
    else:
      if not result.commandSet:
        case arg.normalize
        of "task":
          result.command = cmdTask
          result.commandSet = true
        of "test":
          result.command = cmdTest
          result.commandSet = true
        else:
          result.command = cmdTask
          result.commandSet = true
          result.task = arg
      else:
        case result.command
        of cmdTask:
          if result.task.len == 0:
            result.task = arg
          else:
            result.taskArgs.add arg
        of cmdTest:
          result.testSelectors.add arg
    inc i

  if result.testOptionsSeen and result.command != cmdTest:
    quit("atlas-run: test options require the test command", 2)

proc printTasks(nimbleFile: Path) =
  let tasks = listNimbleTasks(nimbleFile)
  if tasks.len == 0:
    echo "No tasks found in " & $nimbleFile
    return

  var width = 0
  for task in tasks:
    width = max(width, task.name.len)

  for task in tasks:
    if task.description.len > 0:
      echo alignLeft(task.name, width + 2), task.description
    else:
      echo task.name

proc resolveProjectDir(projectArg: Path): Path =
  resolveNimbleFile(projectArg).parentDir()

proc printTests(projectDir: Path; selectors: openArray[string]) =
  let tests = discoverTestFiles(projectDir, selectors)
  for path in tests:
    echo ($path.relativePath(projectDir, '/')).replace("\\", "/")

proc atlasRunMain(params: seq[string]): int =
  let opts = parseCliOptions(params)
  case opts.command
  of cmdTask:
    if not opts.commandSet and not opts.listOnly and opts.task.len == 0:
      writeUsage()
      let nimbleFile = resolveNimbleFile(opts.projectArg)
      echo "\nNimble tasks:"
      printTasks(nimbleFile)
      return 0
    let nimbleFile = resolveNimbleFile(opts.projectArg)
    if opts.listOnly or opts.task.len == 0:
      printTasks(nimbleFile)
      return 0
    result = runNimbleTask(nimbleFile, opts.task, opts.taskArgs, opts.nimExe)
  of cmdTest:
    let projectDir = resolveProjectDir(opts.projectArg)
    if opts.listOnly:
      printTests(projectDir, opts.testSelectors)
      return 0
    result = runAtlasTests(initAtlasTestOptions(
      projectDir = projectDir,
      nimExe = opts.nimExe,
      nimcacheDir = opts.nimcacheDir,
      jobs = opts.jobs,
      selectors = opts.testSelectors,
      shuffle = opts.shuffle
    ))

proc main() =
  try:
    quit atlasRunMain(commandLineParams())
  except ValueError, IOError, OSError:
    quit("atlas-run: " & getCurrentExceptionMsg(), 1)

when isMainModule:
  main()
