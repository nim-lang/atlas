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
    debug c, toRepo("fillPackageLookupTable"), "initializing..."
    for entry in plist:
      let url = getUrl(entry.url)
      let pkg = Package(name: PackageName unicode.toLower entry.name,
                        repo: url.toRepo(),
                        url: url)
      c.urlMapping["name:" & pkg.name.string] = pkg

proc dependencyDir*(c: var AtlasContext; pkg: Package): PackageDir =
  template checkDir(dir: string) =
    debug c, pkg, "dependencyDir: find: " & dir
    if dir.len() > 0 and dirExists(dir):
      debug c, pkg, "dependencyDir: found: " & dir
      return PackageDir dir
  
  if pkg.exists:
    return pkg.path
  checkDir pkg.path.string
  checkDir c.workspace / pkg.path.string
  checkDir c.depsDir / pkg.path.string
  checkDir c.workspace / pkg.repo.string
  checkDir c.depsDir / pkg.repo.string

proc findNimbleFile*(c: var AtlasContext; pkg: Package): Option[string] =
  when MockupRun:
    result = TestsDir / pkg.name.string & ".nimble"
    doAssert fileExists(result), "file does not exist " & result
  else:
    debug c, pkg, "findNimbleFile: find: " & pkg.path.string
    let dir = dependencyDir(c, pkg).string
    debug c, pkg, "findNimbleFile: depDir: " & dir
    result = some dir / (pkg.name.string & ".nimble")
    debug c, pkg, "findNimbleFile: depDir: " & result.get()
    if not fileExists(result.get()):
      debug c, pkg, "findNimbleFile: not found: " & result.get()
      result = none[string]()
      for x in walkFiles(dir / "*.nimble"):
        if result.isNone:
          debug c, pkg, "findNimbleFile: found: " & result.get()
          result = some x
        else:
          error c, pkg, "ambiguous .nimble file " & result.get()
          return none[string]()
    else:
      debug c, pkg, "findNimbleFile: found: " & result.get()

import pretty

proc resolvePackageUrl(c: var AtlasContext; url: string, checkOverrides = true): Package =
  result = Package(url: getUrl(url),
                   name: url.toRepo().PackageName,
                   repo: url.toRepo())
  
  echo "resolvePackage: ", "IS URL: ", $result.url

  if checkOverrides and UsesOverrides in c.flags:
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
  
  if result.url.scheme == "file":
    result.path = PackageDir result.url.hostname & result.url.path
    debug c, result, "resolvePackageName: set path: " & result.path.string

proc resolvePackageName(c: var AtlasContext; name: string): Package =
  result = Package(name: PackageName name,
                   repo: PackageRepo name)
                   

  debug c, result, "resolvePackageName: searching for package name: " & result.name.string
  # the project name can be overwritten too!
  if UsesOverrides in c.flags:
    print c.overrides
    let name = c.overrides.substitute(name)
    if name.len > 0:
      if name.isUrl():
        return c.resolvePackageUrl(name, checkOverrides=false)

  # echo "URL MAP: ", repr c.urlMapping.keys().toSeq()
  let namePkg = c.urlMapping.getOrDefault("name:" & result.name.string, nil)
  let repoPkg = c.urlMapping.getOrDefault("repo:" & result.name.string, nil)

  debug c, result, "resolvePackageName: searching for package name: " & result.name.string
  if not namePkg.isNil:
    # great, found package!
    debug c, result, "resolvePackageName: found!"
    result = namePkg
  elif not repoPkg.isNil:
    # check if rawHandle is a package repo name
    debug c, result, "resolvePackageName: found by repo!"
    result = repoPkg
  else:
    debug c, result, "resolvePackageName: not found by name or repo: " & result.name.string
    let url = getUrlFromGithub(name)
    if url.len == 0:
      error c, result, "resolvePackageName: package not found by github search"
    else:
      result.url = getUrl url

  if UsesOverrides in c.flags:
    let newUrl = c.overrides.substitute($result.url)
    if newUrl.len > 0:
      debug c, result, "resolvePackageName: not url: UsesOverrides: " & $newUrl
      result.url = getUrl newUrl

proc resolvePackage*(c: var AtlasContext; rawHandle: string): Package =
  result.new()

  fillPackageLookupTable(c)

  if rawHandle.isUrl():
    result = c.resolvePackageUrl(rawHandle)
  else:
    result = c.resolvePackageName(unicode.toLower(rawHandle))
  
  print result

  let res = c.findNimbleFile(result)
  debug c, result, "resolvePackageName: find nimble: " & repr res
  if res.isSome:
    let nimble = PackageNimble res.get()
    let path = PackageDir res.get().parentDir()
    result = Package(url: result.url,
                     name: result.name,
                     repo: result.repo,
                     path: path,
                     exists: true,
                     nimble: nimble)

proc resolvePackage*(c: var AtlasContext; dir: PackageDir): Package =

  # let destDir = toDestDir(w.pkg.name)
  # let dir =
  #   if destDir == start.string: c.currentDir
  #   else: selectDir(c.workspace / destDir, c.depsDir / destDir)
  
  discard