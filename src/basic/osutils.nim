## OS utilities like 'withDir'.
## (c) 2021 Andreas Rumpf

import std / [os, paths, strutils, osproc, uri]
import reporters

export paths

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

proc readableFile*(s: Path, path: Path): Path =
  if s.isRelativeTo(path):
    relativePath(s, path)
  else:
    s


proc absoluteDepsDir*(workspace, value: Path): Path =
  if value == Path ".":
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

template withDir*(dir: string; body: untyped) =
  let oldDir = ospaths2.getCurrentDir()
  debug dir, "Current directory is now: " & dir
  try:
    setCurrentDir(dir)
    body
  finally:
    setCurrentDir(oldDir)

template withDir*(dir: Path; body: untyped) =
  let oldDir = paths.getCurrentDir()
  try:
    setCurrentDir($dir)
    body
  finally:
    setCurrentDir($oldDir)

template tryWithDir*(dir: string; body: untyped) =
  let oldDir = ospaths2.getCurrentDir()
  try:
    if dirExists(dir):
      setCurrentDir(dir)
      debug dir, "Current directory is now: " & dir
      body
  finally:
    setCurrentDir(oldDir)
