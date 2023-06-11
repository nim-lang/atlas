## OS utilities like 'withDir'.
## (c) 2021 Andreas Rumpf

import os, strutils, osproc, uri, options

export uri, options

proc getFilePath*(x: Uri): string =
  assert x.scheme == "file"
  result = x.hostname
  if x.port.len() > 0:
    result &= ":"
    result &= x.port
  result &= x.path
  result &= x.query

proc isUrl*(x: string): bool =
  x.startsWith("git://") or x.startsWith("https://") or x.startsWith("http://")

proc getUrl*(x: string): Uri =
  try:
    let u = parseUri(x)
    # x.startsWith("git://") or x.startsWith("https://") or x.startsWith("http://")
    if u.scheme in ["git", "https", "http", "hg"]:
      result = u
  except UriParseError:
    discard

proc cloneUrl*(url: Uri, dest: string; cloneUsingHttps: bool): string =
  ## Returns an error message on error or else "".
  result = ""
  var modUrl = url
  if url.scheme == "git" and cloneUsingHttps:
    modUrl.scheme = "https"

  if url.scheme == "git":
    modUrl.scheme = "" # git doesn't recognize git://

  var isGithub = false
  if modUrl.hostname == "github.com":
    isGithub = true

  let (_, exitCode) = execCmdEx("git ls-remote --quiet --tags " & $modUrl)
  var xcode = exitCode
  if isGithub and exitCode != QuitSuccess:
    # retry multiple times to avoid annoying github timeouts:
    for i in 0..4:
      os.sleep(4000)
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
