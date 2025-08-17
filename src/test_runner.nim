import std/[osproc, os, strutils, sequtils, math]

## Parallel test runner utilities using osproc.execProcesses.

proc buildTestCommand*(nimPath, testFile: string; extraArgs: seq[string] = @[]; runCode = true): string =
  ## Compose a Nim compile (and optional run) command for a test file.
  var cmd = quoteShell(nimPath) & " c -d:debug"
  if extraArgs.len > 0:
    for a in extraArgs:
      cmd.add " " & quoteShell(a)
  if runCode:
    cmd.add " -r"
  cmd.add " " & quoteShell(testFile)
  result = cmd

proc runCommandsParallel*(commands: seq[string]; parallel: int = 0): int =
  ## Run arbitrary commands with limited parallelism; returns first non‑zero exit code or 0.
  ## If `parallel <= 0`, runs all in parallel; otherwise, runs in batches of `parallel`.
  if commands.len == 0:
    return 0
  if parallel <= 0:
    return execProcesses(commands,
      proc (idx: int) = discard,
      proc (idx: int, p: Process) = discard
    )
  var i = 0
  while i < commands.len:
    let j = min(i + parallel, commands.len)
    let code = execProcesses(commands[i ..< j],
      proc (idx: int) = discard,
      proc (idx: int, p: Process) = discard
    )
    if code != 0:
      return code
    i = j
  return 0

proc runTestsParallel*(tests: seq[string]; nimPath = findExe("nim"); extraArgs: seq[string] = @[]; runCode = true; parallel: int = 0): int =
  ## Build and execute Nim test commands in parallel.
  if nimPath.len == 0:
    return -1
  var cmds: seq[string] = @[]
  for tf in tests:
    cmds.add buildTestCommand(nimPath, tf, extraArgs, runCode)
  result = runCommandsParallel(cmds, parallel)

when isMainModule:
  # Example usage: run all tests matching tests/t*.nim in parallel.
  var tests: seq[string] = @[]
  for f in walkFiles("tests/t*.nim"):
    tests.add(f)
  let code = runTestsParallel(tests)
  quit(code)
