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

proc selectDir*(a, b: string): string =
  ## selects the first dir that exists
  ## 
  if dirExists(a): a else: b

proc absoluteDepsDir*(workspace, value: string): string =
  if value == ".":
    result = workspace
  elif isAbsolute(value):
    result = value
  else:
    result = workspace / value

template tryWithDir*(dir: string; body: untyped) =
  let oldDir = getCurrentDir()
  try:
    if dirExists(dir):
      setCurrentDir(dir)
      body
  finally:
    setCurrentDir(oldDir)

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
