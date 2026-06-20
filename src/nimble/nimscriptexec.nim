#
#           Atlas Package Cloner
#        (c) Copyright 2026 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std/[files, os, osproc, paths]

type
  NimScriptCleanup* = enum
    CleanupAlways
    CleanupOnSuccess
    CleanupNever

  NimScriptRunOptions* = object
    workingDir*: Path
    scriptPrefix*: string
    nimExe*: string
    nimArgs*: seq[string]
    cleanup*: NimScriptCleanup
    candidateLimit*: int

  NimScriptRunResult* = object
    exitCode*: int
    scriptFile*: Path
    commandLine*: string

proc initNimScriptRunOptions*(scriptPrefix: string;
                              workingDir = Path"";
                              nimExe = "nim";
                              nimArgs: seq[string] = @["e", "--hints:off", "--define:atlas"];
                              cleanup = CleanupAlways;
                              candidateLimit = 100): NimScriptRunOptions =
  NimScriptRunOptions(
    workingDir: workingDir,
    scriptPrefix: scriptPrefix,
    nimExe: nimExe,
    nimArgs: nimArgs,
    cleanup: cleanup,
    candidateLimit: candidateLimit
  )

proc currentDirPath(): Path =
  Path(os.getCurrentDir())

proc effectiveWorkingDir(options: NimScriptRunOptions): Path =
  if ($options.workingDir).len > 0:
    options.workingDir
  else:
    currentDirPath()

proc nextScriptPath(dir: Path; prefix: string; limit: int): Path =
  for i in 0 ..< limit:
    let candidate = dir / Path(prefix & "_" & $i & ".nims")
    if not fileExists(candidate):
      return candidate
  raise newException(IOError, "could not create temporary NimScript: " & prefix)

proc resolveExe(exe: string): string =
  let found = findExe(exe)
  if found.len > 0:
    result = found
  else:
    result = exe

proc formatCommandLine(exe: string; args: openArray[string]): string =
  result = quoteShell(exe)
  for arg in args:
    result.add " "
    result.add quoteShell(arg)

proc shouldCleanup(cleanup: NimScriptCleanup; exitCode: int): bool =
  case cleanup
  of CleanupAlways:
    true
  of CleanupOnSuccess:
    exitCode == 0
  of CleanupNever:
    false

proc runTempNimScript*(scriptContent: string;
                       options: NimScriptRunOptions): NimScriptRunResult =
  let
    workingDir = options.effectiveWorkingDir()
    scriptFile = nextScriptPath(workingDir, options.scriptPrefix, options.candidateLimit)
    exe = resolveExe(options.nimExe)
  var args = options.nimArgs
  args.add $scriptFile

  result.scriptFile = scriptFile
  result.commandLine = formatCommandLine(exe, args)
  result.exitCode = -1

  writeFile($scriptFile, scriptContent)

  let oldDir = os.getCurrentDir()
  var process: Process
  try:
    process = startProcess(
      exe,
      workingDir = $workingDir,
      args = args,
      options = {poParentStreams, poUsePath}
    )
    result.exitCode = waitForExit(process)
  finally:
    if process != nil:
      close(process)
    if dirExists(oldDir):
      setCurrentDir(oldDir)
    if shouldCleanup(options.cleanup, result.exitCode) and fileExists(scriptFile):
      removeFile(scriptFile)
