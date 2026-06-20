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

const Usage = "atlas-run - Nimble task runner for Atlas Version " & AtlasVersion & """

Usage:
  atlas-run [options] [task] [arguments]

Options:
  --help, -h            show this help
  --version, -v         show the version
  --project=path, -p    use the project directory or Nimble file at path
  --nim=path            use the Nim executable at path
  --list                list tasks without running one

With no task, atlas-run lists the tasks declared in the project's Nimble file.
Arguments after the task name are exposed to the task as commandLineParams.
"""

type
  CliOptions = object
    projectArg: Path
    nimExe: string
    listOnly: bool
    task: string
    taskArgs: seq[string]

proc writeHelp(code = 0) =
  stdout.write(Usage)
  stdout.flushFile()
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
  let eq = arg.find('=')
  if eq >= 0:
    result.key = arg[2 ..< eq]
    result.value = arg[eq+1 .. ^1]
  else:
    result.key = arg[2 .. ^1]

proc parseCliOptions(params: seq[string]): CliOptions =
  result.nimExe = "nim"

  var i = 0
  while i < params.len:
    let arg = params[i]

    if result.task.len > 0:
      if arg == "--":
        inc i
        while i < params.len:
          result.taskArgs.add params[i]
          inc i
        break
      else:
        result.taskArgs.add arg
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
    elif arg.startsWith("--"):
      let (key, value) = splitLongOption(arg)
      case key.normalize
      of "project":
        result.projectArg = Path readOptionValue(params, i, arg, value)
      of "nim":
        result.nimExe = readOptionValue(params, i, arg, value)
      else:
        quit("atlas-run: unknown option: " & arg, 2)
    elif arg.startsWith("-"):
      quit("atlas-run: unknown option: " & arg, 2)
    else:
      result.task = arg
    inc i

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

proc atlasRunMain(params: seq[string]): int =
  let opts = parseCliOptions(params)
  let nimbleFile = resolveNimbleFile(opts.projectArg)

  if opts.listOnly or opts.task.len == 0:
    printTasks(nimbleFile)
    return 0

  result = runNimbleTask(nimbleFile, opts.task, opts.taskArgs, opts.nimExe)

proc main() =
  try:
    quit atlasRunMain(commandLineParams())
  except ValueError, IOError, OSError:
    quit("atlas-run: " & getCurrentExceptionMsg(), 1)

when isMainModule:
  main()
