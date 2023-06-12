## OS utilities like 'withDir'.
## (c) 2021 Andreas Rumpf

import os, strutils, osproc, uri, json

export UriParseError

type
  PackageUrl* = Uri

export uri.`$`, uri.`/`

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

proc getUrl*(x: string): PackageUrl =
  try:
    let u = parseUri(x).PackageUrl
    if u.scheme in ["git", "https", "http", "hg", "file"]:
      result = u
  except UriParseError:
    discard

proc cloneUrl*(url: PackageUrl, dest: string; cloneUsingHttps: bool): string =
  ## Returns an error message on error or else "".
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
