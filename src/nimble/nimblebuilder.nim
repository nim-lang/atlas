#
#           Atlas Package Cloner
#        (c) Copyright 2026 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std/[algorithm, os, osproc, paths, strutils, tables]

import ../basic/parse_requires
import ../basic/reporters

type
  NimbleBinary* = object
    name*: string
    source*: Path
    output*: Path
    backend*: string
    commandLine*: string

proc quoteCommand(command: string; args: openArray[string]): string =
  result = quoteShell(command)
  for arg in args:
    result.add " "
    result.add quoteShell(arg)

proc nativeOutputName(name: string): string =
  when defined(windows):
    result = name.addFileExt(ExeExt)
  else:
    result = name

proc outputName(info: NimbleFileInfo; binName: string): string =
  if binName in info.namedBin:
    result = info.namedBin[binName]
  else:
    result = $Path(binName).splitFile().name

proc sourcePath(projectDir: Path; srcDir: Path; binName: string): Path =
  let rel =
    if Path(binName).splitFile().ext.len == 0:
      Path(binName.addFileExt("nim"))
    else:
      Path(binName)
  if ($srcDir).len > 0:
    projectDir / srcDir / rel
  else:
    let srcCandidate = projectDir / Path"src" / rel
    if fileExists($srcCandidate):
      srcCandidate
    else:
      projectDir / rel

proc outputPath(projectDir: Path; binDir: Path; name: string; backend: string): Path =
  let filename =
    if backend.normalize == "js":
      name.addFileExt("js")
    else:
      nativeOutputName(name)
  if ($binDir).len > 0:
    projectDir / binDir / Path(filename)
  else:
    projectDir / Path(filename)

proc backendCommand(backend: string): string =
  if backend.len > 0:
    result = backend.normalize
  else:
    result = "c"

proc buildArgs(target: NimbleBinary): seq[string] =
  @[
    target.backend,
    "--out:" & $target.output,
    $target.source
  ]

proc binaryNames(info: NimbleFileInfo): seq[string] =
  if info.bin.len > 0:
    result = info.bin
  else:
    for name in info.namedBin.keys:
      result.add name
    result.sort()

proc listNimbleBinaries*(nimbleFile: Path; nimExe = "nim"): seq[NimbleBinary] =
  let
    nimbleFile = nimbleFile.absolutePath()
    projectDir = nimbleFile.parentDir()
    info = extractRequiresInfo(nimbleFile)
    backend = backendCommand(info.backend)
    bins = binaryNames(info)
  if bins.len == 0:
    return

  for binName in bins:
    let target = NimbleBinary(
      name: binName,
      source: sourcePath(projectDir, info.srcDir, binName),
      output: outputPath(projectDir, info.binDir, outputName(info, binName), backend),
      backend: backend
    )
    let args = buildArgs(target)
    result.add NimbleBinary(
      name: target.name,
      source: target.source,
      output: target.output,
      backend: target.backend,
      commandLine: quoteCommand(nimExe, args)
    )

proc runBuildProcess(nimExe: string; projectDir: Path; target: NimbleBinary): int =
  let args = buildArgs(target)
  writeAtlasRunStatusLine(target.name & " -> " & $target.output & " ", "running", arsRunning)
  writeAtlasRunLine("command: " & quoteCommand(nimExe, args))
  createDir($target.output.parentDir())
  var process: Process
  try:
    process = startProcess(
      nimExe,
      workingDir = $projectDir,
      args = args,
      options = {poParentStreams, poUsePath}
    )
    result = waitForExit(process)
    if result == 0:
      writeAtlasRunStatusLine(target.name & " ", "success", arsSuccess)
    else:
      writeAtlasRunStatusLine(target.name & " ", "failed", arsFailed)
  finally:
    if process != nil:
      close(process)

proc runNimbleBuild*(nimbleFile: Path; nimExe = "nim"): int =
  let
    nimbleFile = nimbleFile.absolutePath()
    projectDir = nimbleFile.parentDir()
    targets = listNimbleBinaries(nimbleFile, nimExe)

  if targets.len == 0:
    raise newException(ValueError, "no binaries declared in: " & $nimbleFile)

  for target in targets:
    if not fileExists($target.source):
      raise newException(ValueError, "binary source does not exist: " & $target.source)
    let code = runBuildProcess(nimExe, projectDir, target)
    if code != 0:
      return code
  result = 0
