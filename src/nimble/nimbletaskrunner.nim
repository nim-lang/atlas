#
#           Atlas Package Cloner
#        (c) Copyright 2026 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std/[files, os, paths, strutils]

import ../basic/[nimblecontext, parse_requires]
import nimscriptexec

type
  NimbleTask* = object
    name*: string
    description*: string

const
  InternalCommand = "e"
  NoopCommand = "nop"
  ScriptTemplate = """
import system except getCommand, setCommand, switch, `--`, thisDir,
  packageName, version, author, description, license, srcDir, binDir, backend,
  testEntryPoint, skipDirs, skipFiles, skipExt, installDirs, installFiles,
  installExt, bin, paths, entryPoints, foreignDeps, requires, task,
  packageName
import std/[os, strutils, tables]
export tables

const
  projectFile* = $1
  actionName* = $2
  commandLineParams*: seq[string] = $3
  atlasNimExe = $4
  NimbleVersion* = "0.0.0"
  NimbleMajor* = 0
  NimbleMinor* = 0
  NimblePatch* = 0

var
  packageName* = ""
  version*: string
  author*: string
  description*: string
  license*: string
  srcDir*: string
  binDir*: string
  backend*: string
  testEntryPoint*: string

  skipDirs*, skipFiles*, skipExt*, installDirs*, installFiles*,
    installExt*, bin*, paths*, entryPoints*: seq[string] = @[]
  requiresData*: seq[string] = @[]
  taskRequiresData*: Table[string, seq[string]]
  foreignDeps*: seq[string] = @[]
  namedBin*: Table[string, string]

  flags: Table[string, seq[string]]
  command = $5
  project = ""
  success = false
  retVal = true

proc requires*(deps: varargs[string]) =
  for d in deps:
    requiresData.add d

proc taskRequires*(task: string; deps: varargs[string]) =
  if task notin taskRequiresData:
    taskRequiresData[task] = @[]
  for d in deps:
    taskRequiresData[task].add d

proc getCommand*(): string =
  command

proc setCommand*(cmd: string; prj = "") =
  command = cmd
  if prj.len > 0:
    project = prj

proc switch*(key: string; value = "") =
  flags.mgetOrPut(key, @[]).add value

template `--`*(key, val: untyped) =
  switch(astToStr(key), strip(astToStr(val)))

template `--`*(key: untyped) =
  switch(astToStr(key), "")

proc getPkgDir*(): string =
  result = projectFile.rsplit(seps = {'/', '\\', ':'}, maxsplit = 1)[0]

proc thisDir*(): string =
  getPkgDir()

proc getPaths*(): seq[string] =
  getEnv("__NIMBLE_PATHS").split("|")

proc getPathsClause*(): string =
  for p in getPaths():
    if p.len > 0:
      if result.len > 0:
        result.add " "
      result.add "--path:" & quoteShell(p)

template feature*(names: varargs[string]; body: untyped) =
  discard

template dev*(body: untyped) =
  discard

template before*(action: untyped; body: untyped) =
  discard

template after*(action: untyped; body: untyped) =
  discard

template task*(name: untyped; description: string; body: untyped): untyped =
  proc `name Task`*() =
    body

  if actionName == astToStr(name).normalize:
    success = true
    `name Task`()

include $1

if not success:
  quit "atlas-run: task not found: " & actionName, 1

if not retVal:
  quit 1

if command.normalize notin [$5.normalize, $6.normalize]:
  var cmdLine = quoteShell(atlasNimExe) & " " & command
  for key, vals in flags:
    if vals.len == 0:
      cmdLine.add " --" & key
    else:
      for val in vals:
        cmdLine.add " --" & key
        if val.len > 0:
          cmdLine.add ":" & quoteShell(val)
  if project.len > 0:
    cmdLine.add " " & quoteShell(project)
  for arg in commandLineParams:
    cmdLine.add " " & quoteShell(arg)
  exec cmdLine
"""

proc nimStringSeqLit(values: openArray[string]): string =
  result = "@["
  for i, value in values:
    if i > 0:
      result.add ", "
    result.add value.escape()
  result.add "]"

proc nimIncludePath(path: Path): string =
  ($path).replace("\\", "/").escape()

proc taskScriptContent(nimbleFile: Path; taskName: string;
                       taskArgs: openArray[string]; nimExe: string): string =
  result = ScriptTemplate % [
    nimIncludePath(nimbleFile),
    taskName.normalize.escape(),
    nimStringSeqLit(taskArgs),
    nimExe.escape(),
    InternalCommand.escape(),
    NoopCommand.escape()
  ]

proc listNimbleTasks*(nimbleFile: Path): seq[NimbleTask] =
  let info = extractRequiresInfo(nimbleFile)
  for task in info.tasks:
    result.add NimbleTask(name: task[0], description: task[1])

proc hasNimbleTask(tasks: openArray[NimbleTask]; name: string): bool =
  let wanted = name.normalize
  for task in tasks:
    if task.name.normalize == wanted:
      return true

proc runNimbleTask*(nimbleFile: Path; taskName: string;
                    taskArgs: openArray[string] = [];
                    nimExe = "nim"): int =
  if taskName.len == 0:
    raise newException(ValueError, "task name is required")

  let nimbleFile = nimbleFile.absolutePath()
  if not fileExists(nimbleFile):
    raise newException(ValueError, "nimble file does not exist: " & $nimbleFile)

  let tasks = listNimbleTasks(nimbleFile)
  if not hasNimbleTask(tasks, taskName):
    raise newException(ValueError, "task not found: " & taskName)

  let projectDir = nimbleFile.parentDir()
  let options = initNimScriptRunOptions(
    "atlas_run_" & $getCurrentProcessId(),
    workingDir = projectDir,
    nimExe = nimExe,
    nimArgs = @["e", "--hints:off", "--verbosity:0", "--define:atlas"]
  )
  result = runTempNimScript(
    taskScriptContent(nimbleFile, taskName, taskArgs, nimExe),
    options
  ).exitCode

proc findProjectDir*(start: Path): Path =
  var current = start.absolutePath()
  if fileExists(current):
    current = current.parentDir()

  while ($current).len > 0:
    if findNimbleFile(current, "").len > 0:
      return current
    let parent = current.parentDir()
    if parent == current:
      break
    current = parent

  raise newException(ValueError, "no Nimble file found")

proc resolveNimbleFile*(projectArg: Path = Path"";
                        currentDir: Path = paths.getCurrentDir()): Path =
  let base =
    if ($projectArg).len > 0:
      projectArg.expandTilde().absolutePath()
    else:
      findProjectDir(currentDir)

  if base.splitFile().ext in ["nimble", ".nimble"] and fileExists(base):
    return base

  let files = findNimbleFile(base, "")

  if files.len == 0:
    raise newException(ValueError, "no Nimble file found in: " & $base)
  if files.len > 1:
    raise newException(ValueError, "ambiguous Nimble files found in: " & $base)
  result = files[0].absolutePath()
