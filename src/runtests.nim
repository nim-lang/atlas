import std/[osproc, os, strutils, sequtils, math, paths, algorithm]
import basic/reporters

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
  ## Run commands with limited parallelism; returns first non‑zero exit code or 0.
  ## If `parallel <= 0`, uses `countProcessors()`; otherwise, runs in batches of `parallel`.
  if commands.len == 0:
    return 0
  if parallel <= 0:
    return execProcesses(commands, n = countProcessors(),
      beforeRunEvent = proc (idx: int) = discard,
      afterRunEvent = proc (idx: int, p: Process) = discard
    )
  var i = 0
  while i < commands.len:
    let j = min(i + parallel, commands.len)
    let code = execProcesses(commands[i ..< j], n = parallel,
      beforeRunEvent = proc (idx: int) = discard,
      afterRunEvent = proc (idx: int, p: Process) = discard
    )
    if code != 0:
      return code
    i = j
  return 0

proc runTestsParallel*(tests: seq[string]; nimPath = findExe("nim"); extraArgs: seq[string] = @[]; runCode = true; parallel: int = countProcessors()): int =
  ## Build and execute Nim test commands in parallel.
  if nimPath.len == 0:
    return -1
  var cmds: seq[string] = @[]
  for tf in tests:
    cmds.add buildTestCommand(nimPath, tf, extraArgs, runCode)
  result = runCommandsParallel(cmds, parallel)

proc discoverTests*(projectDir: Path): seq[string] =
  ## Find and return all tests matching tests/t*.nim inside projectDir.
  let old = os.getCurrentDir()
  defer: os.setCurrentDir(old)
  os.setCurrentDir($projectDir)
  for f in walkFiles("tests/t*.nim"):
    result.add f
  result.sort(system.cmp[string])

proc runTestsSerial*(projectDir: Path; extraArgs: seq[string] = @[]; runCode = true): int =
  ## Sequentially compile and (optionally) run each discovered test.
  if projectDir.len == 0 or not dirExists($projectDir):
    fatal "No project directory detected", "atlas:test"
    return 1
  let nimPath = findExe("nim")
  if nimPath.len == 0:
    fatal "Nim compiler not found in PATH", "atlas:test"
    return 1
  let old = os.getCurrentDir()
  defer: os.setCurrentDir(old)
  os.setCurrentDir($projectDir)
  let tests = discoverTests(projectDir)
  if tests.len == 0:
    warn "atlas:test", "No tests found matching 'tests/t*.nim'"
    return 0
  for tf in tests:
    info "atlas:test", "running:", tf
    let cmd = buildTestCommand(nimPath, tf, extraArgs, runCode)
    let code = execShellCmd(cmd)
    if code != 0:
      fatal "Test failed: " & tf, "atlas:test", code
      return code
  notice "atlas:test", "All tests passed"
  return 0

proc runTests*(projectDir: Path; extraArgs: seq[string] = @[]; runCode = true; parallel: int): int =
  ## Run tests either serially or in parallel (parallel<=0 uses CPU count).
  if projectDir.len == 0 or not dirExists($projectDir):
    fatal "No project directory detected", "atlas:test"
    return 1
  let nimPath = findExe("nim")
  if nimPath.len == 0:
    fatal "Nim compiler not found in PATH", "atlas:test"
    return 1
  let tests = discoverTests(projectDir)
  if tests.len == 0:
    warn "atlas:test", "No tests found matching 'tests/t*.nim'"
    return 0
  if parallel > 1:
    let code = runTestsParallel(tests, nimPath, extraArgs, runCode, parallel)
    if code != 0:
      fatal "A test failed", "atlas:test", code
    else:
      notice "atlas:test", "All tests passed"
    return code
  else:
    return runTestsSerial(projectDir, extraArgs, runCode)

when isMainModule:
  # Example usage: run all tests matching tests/t*.nim in parallel.
  var tests: seq[string] = @[]
  for f in walkFiles("tests/t*.nim"):
    tests.add(f)
  let code = runTestsParallel(tests)
  quit(code)
