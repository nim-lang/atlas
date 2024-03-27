## OS utilities like 'withDir'.
## (c) 2021 Andreas Rumpf

import std / [os, strutils, osproc, uri]

proc lastPathComponent*(s: string): string =
  var last = s.len - 1
  while last >= 0 and s[last] in {DirSep, AltSep}: dec last
  var first = last - 1
  while first >= 0 and s[first] notin {DirSep, AltSep}: dec first
  result = s.substr(first+1, last)

type
  PackageUrl* = Uri

proc getFilePath*(x: PackageUrl): string =
  assert x.scheme == "file"
  result = x.hostname
  if x.port.len() > 0:
    result &= ":"
    result &= x.port
  result &= x.path
  result &= x.query

proc isUrl*(x: string): bool =
  x.startsWith("git://") or
  x.startsWith("https://") or
  x.startsWith("http://") or
  x.startsWith("file://")

proc readableFile*(s: string): string =
  if s.isRelativeTo(getCurrentDir()):
    relativePath(s, getCurrentDir())
  else:
    s


proc absoluteDepsDir*(workspace, value: string): string =
  if value == ".":
    result = workspace
  elif isAbsolute(value):
    result = value
  else:
    result = workspace / value


proc silentExec*(cmd: string; args: openArray[string]): (string, int) =
  var cmdLine = cmd
  for i in 0..<args.len:
    cmdLine.add ' '
    cmdLine.add quoteShell(args[i])
  result = osproc.execCmdEx(cmdLine)

proc nimbleExec*(cmd: string; args: openArray[string]) =
  var cmdLine = "nimble " & cmd
  for i in 0..<args.len:
    cmdLine.add ' '
    cmdLine.add quoteShell(args[i])
  discard os.execShellCmd(cmdLine)

when not defined(atlasUnitTests) or defined(atlasNoUnitTestFiles):
  export os
else:

  ## This portion of the module sets up shims for a few file operations
  ## used for unit testing proc's which rely on file io.
  ## 
  ## It greatly simplifies testing handling of various nimble file cases
  ## without needing to create integration tests.
  ##

  import std/tables
  export tables
  from os import `/`, execShellCmd, sleep, copyDir, DirSep
  export `/`, execShellCmd, sleep, copyDir, DirSep

  type
    OsFileContext* = object
      fileExists*: Table[string, bool]
      dirExists*: Table[string, bool]
      walkDirs*: Table[string, seq[string]]
      absPaths*: Table[string, string]
      currDir*: string

  var filesContext*: OsFileContext

  proc getCurrentDir*(): string =
    result = filesContext.currDir
  proc setCurrentDir*(dir: string) =
    filesContext.currDir = dir
  proc absolutePath*(fl: string): string =
    if fl.isAbsolute():
      fl
    else:
      filesContext.absPaths[fl]
  iterator walkFiles*(dir: string): string =
    for f in filesContext.walkDirs[dir]:
      yield f
  proc fileExists*(fl: string): bool =
    if fl in filesContext.fileExists:
      result = filesContext.fileExists[fl]
  proc dirExists*(dir: string): bool =
    if dir in filesContext.dirExists:
      result = filesContext.dirExists[dir]
    else:
      for (fl, exist) in filesContext.fileExists.pairs():
        if fl.isRelativeTo(dir):
          result = true
          break
