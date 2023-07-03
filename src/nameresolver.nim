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

  infoNow c, toRepo($modUrl), "Cloning URL: " & $modUrl

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
      infoNow c, toRepo($modUrl), "Cloning URL: " & $modUrl
      xcode = execCmdEx("git ls-remote --quiet --tags " & $modUrl)[1]
      if xcode == QuitSuccess: break

  if xcode == QuitSuccess:
    if gitops.clone(c, modUrl, dest):
      return (Ok, "")
    else:
      result = (OtherError, "exernal program failed: " & $GitClone)
  elif not isGithub:
    let (_, exitCode) = execCmdEx("hg identify " & $modUrl)
    if exitCode == QuitSuccess:
      let cmd = "hg clone " & $modUrl & " " & dest
      for i in 0..4:
        if execShellCmd(cmd) == 0: return (Ok, "")
        os.sleep(i*1_000+2_000)
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
  if dirExists(c.workspace / DefaultPackagesDir):
    withDir(c, c.workspace / DefaultPackagesDir):
      gitPull(c, PackageRepo DefaultPackagesDir)
  else:
    withDir c, c.workspace:
      let (status, err) = cloneUrl(c, getUrl "https://github.com/nim-lang/packages", DefaultPackagesDir, false)
      if status != Ok:
        error c, PackageRepo(DefaultPackagesDir), err

proc fillPackageLookupTable(c: var AtlasContext) =
  if not c.hasPackageList:
    c.hasPackageList = true
    when not MockupRun:
      if not fileExists(c.workspace / DefaultPackagesDir / "packages.json"):
        updatePackages(c)
    let plist = getPackageInfos(when MockupRun: TestsDir else: c.workspace)
    for entry in plist:
      let url = getUrl(entry.url)
      let pkg = Package(name: PackageName unicode.toLower entry.name,
                        repo: url.toRepo(),
                        url: url)
      c.urlMapping[pkg.name] = pkg

proc resolvePackage*(c: var AtlasContext; rawHandle: string): Package =
  result.new()

  fillPackageLookupTable(c)

  result.name = PackageName unicode.toLower(rawHandle)

  echo "resolvePackage: ", rawHandle

  if rawHandle.isUrl():
    result.url = getUrl(rawHandle)
    result.name = PackageName result.url.toRepo().string
    result.repo = result.url.toRepo()
    echo "resolvePackage: ", "IS URL: ", $result.url

    if UsesOverrides in c.flags:
      let url = c.overrides.substitute(rawHandle)
      if url.len > 0:
        result.url = url.getUrl()

    if not c.urlMapping.hasKey(result.name):
      # package doesn't exit and doesn't conflict
      c.urlMapping[result.name] = result
    elif c.urlMapping[result.name].url != result.url:
      # package conflicts
      # change package repo to `repo.user.host`
      let purl = result.url
      let host = purl.hostname
      let org = purl.path.parentDir.lastPathPart
      let rname = purl.path.lastPathPart
      let pname = [rname, org, host].join(".") 
      warn c, result,
              "conflicting url's for package; renaming package: " &
                result.name.string & " to " & pname
      result.repo = PackageRepo pname
    
    return

  else:
    echo "resolvePackage: not url"
    # the project name can be overwritten too!
    if UsesOverrides in c.flags:
      let name = c.overrides.substitute(rawHandle)
      if name.len > 0:
        result.name = PackageName name

    if not c.urlMapping.hasKey(result.name):
      # great, found package!
      echo "resolvePackage: not url: found!"
      result = c.urlMapping[result.name]
    else:
      echo "resolvePackage: not url: not found"
      # check if rawHandle is a package repo name
      var found = false
      for pkg in c.urlMapping.values:
        if pkg.repo.string == rawHandle:
          found = true
          result = pkg
          echo "resolvePackage: not url: found!"
          break

      if not found:
        let url = getUrlFromGithub(rawHandle)
        if url.len == 0:
          inc c.errors
        else:
          result.url = getUrl url

    if UsesOverrides in c.flags:
      let newUrl = c.overrides.substitute($result.url)
      if newUrl.len > 0:
        echo "resolvePackage: not url: UsesOverrides: ", newUrl
        result.url = getUrl newUrl
