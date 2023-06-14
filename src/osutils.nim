## OS utilities like 'withDir'.
## (c) 2021 Andreas Rumpf

import std / [os, strutils, osproc, uri]
import context

template projectFromCurrentDir*(): PackageName =
  PackageName(c.currentDir.splitPath.tail)

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

proc cloneUrl*(url: PackageUrl, dest: string; cloneUsingHttps: bool): string =
  ## Returns an error message on error or else "".
  assert not dest.contains("://")
  result = ""
  var modUrl = url
  if url.scheme == "git" and cloneUsingHttps:
    modUrl.scheme = "https"

  if url.scheme == "git":
    modUrl.scheme = "" # git doesn't recognize git://

  var isGithub = false
  if modUrl.hostname == "github.com":
    if modUrl.path.endsWith("/"):
      # github + https + trailing url slash causes a
      # checkout/ls-remote to fail with Repository not found
      modUrl.path = modUrl.path[0 .. ^2]
    isGithub = true

  let (_, exitCode) = execCmdEx("git ls-remote --quiet --tags " & $modUrl)
  var xcode = exitCode
  if isGithub and exitCode != QuitSuccess:
    # retry multiple times to avoid annoying github timeouts:
    for i in 0..4:
      os.sleep(4000)
      echo "Cloning URL: ", $modUrl
      xcode = execCmdEx("git ls-remote --quiet --tags " & $modUrl)[1]
      if xcode == QuitSuccess: break

  if xcode == QuitSuccess:
    # retry multiple times to avoid annoying github timeouts:
    let cmd = "git clone --recursive " & $modUrl & " " & dest
    for i in 0..4:
      if execShellCmd(cmd) == 0: return ""
      os.sleep(4000)
    result = "exernal program failed: " & cmd
  elif not isGithub:
    let (_, exitCode) = execCmdEx("hg identify " & $modUrl)
    if exitCode == QuitSuccess:
      let cmd = "hg clone " & $modUrl & " " & dest
      for i in 0..4:
        if execShellCmd(cmd) == 0: return ""
        os.sleep(4000)
      result = "exernal program failed: " & cmd
    else:
      result = "Unable to identify url: " & $modUrl
  else:
    result = "Unable to identify url: " & $modUrl

proc readableFile*(s: string): string = relativePath(s, getCurrentDir())

template toDestDir*(p: PackageName): string = p.string

proc selectDir*(a, b: string): string = (if dirExists(a): a else: b)

proc absoluteDepsDir*(workspace, value: string): string =
  if value == ".":
    result = workspace
  elif isAbsolute(value):
    result = value
  else:
    result = workspace / value

template withDir*(c: var AtlasContext; dir: string; body: untyped) =
  when MockupRun:
    body
  else:
    let oldDir = getCurrentDir()
    try:
      when ProduceTest:
        echo "Current directory is now ", dir
      setCurrentDir(dir)
      body
    finally:
      setCurrentDir(oldDir)

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

proc readLockFile*(filename: string): LockFile =
  let jsonAsStr = readFile(filename)
  let jsonTree = parseJson(jsonAsStr)
  result = to(jsonTree, LockFile)

proc dependencyDir*(c: AtlasContext; w: Dependency): string =
  result = c.workspace / w.name.string
  if not dirExists(result):
    result = c.depsDir / w.name.string

proc findNimbleFile*(c: AtlasContext; dep: Dependency): string =
  when MockupRun:
    result = TestsDir / dep.name.string & ".nimble"
    doAssert fileExists(result), "file does not exist " & result
  else:
    let dir = dependencyDir(c, dep)
    result = dir / (dep.name.string & ".nimble")
    if not fileExists(result):
      result = ""
      for x in walkFiles(dir / "*.nimble"):
        if result.len == 0:
          result = x
        else:
          # ambiguous .nimble file
          return ""
