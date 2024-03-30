#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Resolves package names and turn them to URLs.

import std / [os, strutils, osproc]
import context, gitops, reporters, pkgurls

proc retryUrl(cmd, urlstr: string; c: var AtlasContext; displayName: string;
              tryBeforeSleep = true): bool =
  ## Retries a url-based command `cmd` with an increasing delay.
  ## Performs an initial request when `tryBeforeSLeep` is `true`.
  const Pauses = [0, 1000, 2000, 3000, 4000, 6000]
  let firstPause = if tryBeforeSleep: 0 else: 1
  for i in firstPause..<Pauses.len:
    if i > firstPause: infoNow c, displayName, "Retrying remote URL: " & urlstr
    os.sleep(Pauses[i])
    if execCmdEx(cmd)[1] == QuitSuccess: return true
  return false

const
  GitProtocol = "git://"

proc hasHostnameOf(url: string; host: string): bool =
  var i = 0
  while i < url.len and url[i] in Letters: inc i
  result = i > 0 and url.continuesWith("://", i) and url.continuesWith(host, i + 3)

proc cloneUrl*(c: var AtlasContext,
                  url: PkgUrl,
                  dest: string;
                  cloneUsingHttps: bool): (CloneStatus, string) =
  ## Returns an error message on error or else "".
  assert not dest.contains("://")

  var modurl = url.url
  if modurl.startsWith(GitProtocol):
    modurl =
      if cloneusinghttps:
        "https://" & modurl.substr(GitProtocol.len)
      else:
        modurl.substr(GitProtocol.len) # git doesn't recognize git://
  let isGitHub = modurl.hasHostnameOf "github.com"
  if isGitHub and modurl.endswith("/"):
    # github + https + trailing url slash causes a
    # checkout/ls-remote to fail with repository not found
    setLen modurl, modurl.len - 1
  infoNow c, url.projectName, "Cloning url: " & modurl

  # Checking repo with git
  trace c, "atlas cloner", "checking repo " & $url
  let gitCmdStr = "git ls-remote --quiet --tags " & modurl
  var success = execCmdEx(gitCmdStr)[1] == QuitSuccess
  if not success and isGitHub:
    trace c, "atlas cloner", "failed check ls-remote..."
    # retry multiple times to avoid annoying GitHub timeouts:
    success = retryUrl(gitCmdStr, modurl, c, url.projectName, false)

  if not success:
    if isGitHub:
      (NotFound, "Unable to identify url: " & modurl)
    else:
      # Checking repo with Mercurial
      if retryUrl("hg identify " & modurl, modurl, c, url.projectName, true):
        (NotFound, "Unable to identify url: " & modurl)
      else:
        let hgCmdStr = "hg clone " & modurl & " " & dest
        if retryUrl(hgCmdStr, modurl, c, url.projectName, true):
          (Ok, "")
        else:
          (OtherError, "exernal program failed: " & hgCmdStr)
  else:
    if gitops.clone(c, url.url, dest, fullClones=true): # gitops.clone has buit-in retrying
      infoNow c, url.projectName, "Cloning success"
      (Ok, "")
    else:
      infoNow c, url.projectName, "Cloning failed: " & modurl
      (OtherError, "exernal program failed: " & $GitClone)
