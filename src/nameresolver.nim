#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Resolves package names and turn them to URLs.

import std / [os, unicode, strutils, osproc, sequtils]
import context, osutils, packagesjson, gitops

proc cloneUrlImpl(c: var AtlasContext,
                  url: PackageUrl,
                  dest: string;
                  cloneUsingHttps: bool):
                (CloneStatus, string) =
  ## Returns an error message on error or else "".
  assert not dest.contains("://")
  result = (OtherError, "")
  var modUrl = url
  if url.scheme == "git" and cloneUsingHttps:
    modUrl.scheme = "https"

  if url.scheme == "git":
    modUrl.scheme = "" # git doesn't recognize git://

  infoNow c, toName($modUrl), "Cloning URL: " & $modUrl

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
      infoNow c, toName($modUrl), "Cloning URL: " & $modUrl
      xcode = execCmdEx("git ls-remote --quiet --tags " & $modUrl)[1]
      if xcode == QuitSuccess: break

  if xcode == QuitSuccess:
    # retry multiple times to avoid annoying github timeouts:
    let cmd = "git clone --recursive " & $modUrl & " " & dest
    for i in 0..4:
      if execShellCmd(cmd) == 0: return (Ok, "")
      os.sleep(4000)
    result = (OtherError, "exernal program failed: " & cmd)
  elif not isGithub:
    let (_, exitCode) = execCmdEx("hg identify " & $modUrl)
    if exitCode == QuitSuccess:
      let cmd = "hg clone " & $modUrl & " " & dest
      for i in 0..4:
        if execShellCmd(cmd) == 0: return (Ok, "")
        os.sleep(4000)
      result = (OtherError, "exernal program failed: " & cmd)
    else:
      result = (NotFound, "Unable to identify url: " & $modUrl)
  else:
    result = (NotFound, "Unable to identify url: " & $modUrl)

proc cloneUrl*(c: var AtlasContext;
               url: PackageUrl,
               dest: string;
               cloneUsingHttps: bool): (CloneStatus, string) =
  when MockupRun:
    result = (Ok, "")
  else:
    result = cloneUrlImpl(c, url, dest, cloneUsingHttps)
    when ProduceTest:
      echo "cloned ", url, " into ", dest

proc updatePackages*(c: var AtlasContext) =
  if dirExists(c.workspace / PackagesDir):
    withDir(c, c.workspace / PackagesDir):
      gitPull(c, PackageName PackagesDir)
  else:
    withDir c, c.workspace:
      let (status, err) = cloneUrl(c, getUrl "https://github.com/nim-lang/packages", PackagesDir, false)
      if status != Ok:
        error c, PackageName(PackagesDir), err

proc fillPackageLookupTable(c: var AtlasContext) =
  if not c.hasPackageList:
    c.hasPackageList = true
    when not MockupRun:
      if not fileExists(c.workspace / PackagesDir / "packages.json"):
        updatePackages(c)
    let plist = getPackages(when MockupRun: TestsDir else: c.workspace)
    for entry in plist:
      c.urlMapping[unicode.toLower entry.name] = entry.url

proc resolvePackage*(c: var AtlasContext; p: string): (PackageName, PackageUrl) =
  proc lookup(c: var AtlasContext; p: string): tuple[name: string, url: string] =
    fillPackageLookupTable(c)

    result.name = unicode.toLower p.toName().string
    result.url = p

    if p.isUrl:
      if UsesOverrides in c.flags:
        result.url = c.overrides.substitute(p)
        if result.url.len > 0: return result
      if not c.urlMapping.hasKey(result.name):
        c.urlMapping[result.name] = p
      else:
        if c.urlMapping[result.name] != result.url:
          let purl = result.url.getUrl()
          let org = purl.path.parentDir.lastPathPart
          let pname = org & "." & result.name
          warn c, toName(result.name),
                  "conflicting url's for package; renaming package: " &
                    result.name & " to " & pname
          result.name = pname
    else:
      # either the project name or the URL can be overwritten!
      result.name = p
      if UsesOverrides in c.flags:
        result.url = c.overrides.substitute(p)
        if result.url.len > 0: return result

      result.url = c.urlMapping.getOrDefault(unicode.toLower p)

      if result.url.len == 0:
        result.url = getUrlFromGithub(p)
        if result.url.len == 0:
          inc c.errors

      if UsesOverrides in c.flags:
        let newUrl = c.overrides.substitute(result.url)
        if newUrl.len > 0:
          result.url = newUrl

  let (name, urlstr) = lookup(c, p)
  when ProduceTest:
    echo "resolve url: ", p, " to: ", urlstr
  result = (name.toName(), urlstr.getUrl())
