#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Resolves package names and turn them to URLs.

import std / [os, unicode, strutils, osproc, sequtils, options]
import context, osutils, packagesjson, gitops

export options

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
    echo "fillPackageLookupTable"
    for entry in plist:
      let url = getUrl(entry.url)
      let pkg = Package(name: PackageName unicode.toLower entry.name,
                        repo: url.toRepo(),
                        url: url)
      c.urlMapping["name:" & pkg.name.string] = pkg

proc dependencyDir*(c: AtlasContext; pkg: Package): PackageDir =
  if pkg.path.string.len() != 0:
    return pkg.path
  result = PackageDir c.workspace / pkg.repo.string
  if not dirExists(result.string):
    result = PackageDir c.depsDir / pkg.repo.string

proc findNimbleFile*(c: var AtlasContext; pkg: Package): Option[string] =
  when MockupRun:
    result = TestsDir / pkg.name.string & ".nimble"
    doAssert fileExists(result), "file does not exist " & result
  else:
    let dir = dependencyDir(c, pkg).string
    result = some dir / (pkg.name.string & ".nimble")
    if not fileExists(result.get()):
      result = none[string]()
      for x in walkFiles(dir / "*.nimble"):
        if result.isNone:
          result = some x
        else:
          warn c, pkg, "ambiguous .nimble file " & result.get()
          return none[string]()

proc resolvePackageUrl(c: var AtlasContext; url: string): Package =
  result.name = PackageName unicode.toLower(url)
  result.url = getUrl(url)
  result.name = result.url.toRepo().PackageName 
  result.repo = result.url.toRepo()
  echo "resolvePackage: ", "IS URL: ", $result.url

  if UsesOverrides in c.flags:
    let url = c.overrides.substitute(url)
    if url.len > 0:
      result.url = url.getUrl()

  let namePkg = c.urlMapping.getOrDefault("name:" & result.name.string, nil)
  let repoPkg = c.urlMapping.getOrDefault("repo:" & result.name.string, nil)

  if not namePkg.isNil:
    if namePkg.url != result.url:
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
      c.urlMapping["name:" & result.name.string] = result

  elif not repoPkg.isNil:
    discard
  else:
    # package doesn't exit and doesn't conflict
    # set the url with package name as url name
    c.urlMapping["repo:" & result.name.string] = result

proc resolvePackageName(c: var AtlasContext; name: string): Package =
  result.name = PackageName name

  echo "resolvePackage: not url"
  # the project name can be overwritten too!
  if UsesOverrides in c.flags:
    let name = c.overrides.substitute(name)
    if name.len > 0:
      result.name = PackageName name

  echo "URL MAP: ", repr c.urlMapping.keys().toSeq()
  let namePkg = c.urlMapping.getOrDefault("name:" & result.name.string, nil)
  if not namePkg.isNil:
    # great, found package!
    echo "resolvePackage: not url: found!"
    result = namePkg
  else:
    echo "resolvePackage: not url: not found"
    # check if rawHandle is a package repo name
    var found = false
    for pkg in c.urlMapping.values:
      if pkg.repo.string == name:
        found = true
        result = pkg
        echo "resolvePackage: not url: found by repo!"
        break

    if not found:
      let url = getUrlFromGithub(name)
      if url.len == 0:
        inc c.errors
      else:
        result.url = getUrl url

  if UsesOverrides in c.flags:
    let newUrl = c.overrides.substitute($result.url)
    if newUrl.len > 0:
      echo "resolvePackage: not url: UsesOverrides: ", newUrl
      result.url = getUrl newUrl

proc resolvePackage*(c: var AtlasContext; rawHandle: string): Package =
  result.new()

  fillPackageLookupTable(c)

  echo "\nresolvePackage: ", rawHandle

  if rawHandle.isUrl():
    result = c.resolvePackageUrl(rawHandle)
  else:
    result = c.resolvePackageName(unicode.toLower(rawHandle))
  
  let res = c.findNimbleFile(result)
  if res.isSome:
    result.nimblePath = res.get()
    result.path = PackageDir res.get().parentDir()
    result.exists = true

proc resolvePackage*(c: var AtlasContext; dir: string): Package =
  
