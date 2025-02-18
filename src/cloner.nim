#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Resolves package names and turn them to URLs.

import std / [os, paths, strutils, osproc]
import basic/[context, gitops, reporters, pkgurls]

proc retryUrl(cmd, urlstr: string; displayName: string;
              tryBeforeSleep = true): bool =
  ## Retries a url-based command `cmd` with an increasing delay.
  ## Performs an initial request when `tryBeforeSLeep` is `true`.
  const Pauses = [0, 1000, 2000, 3000, 4000, 6000]
  let firstPause = if tryBeforeSleep: 0 else: 1
  for i in firstPause..<Pauses.len:
    if i > firstPause: infoNow displayName, "Retrying remote URL: " & urlstr
    os.sleep(Pauses[i])
    if execCmdEx(cmd)[1] == QuitSuccess: return true
  return false

const
  GitProtocol = "git://"

proc hasHostnameOf(url: string; host: string): bool =
  var i = 0
  while i < url.len and url[i] in Letters: inc i
  result = i > 0 and url.continuesWith("://", i) and url.continuesWith(host, i + 3)

proc cloneUrl*(url: PkgUrl,
                  dest: Path;
                  cloneUsingHttps: bool): (CloneStatus, string) =
  ## Returns an error message on error or else "".
  assert not dest.string.contains("://")

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
  infoNow url.projectName, "Cloning url: " & modurl

  # Checking repo with git
  let gitCmdStr = "git ls-remote --quiet --tags " & modurl
  var success = execCmdEx(gitCmdStr)[1] == QuitSuccess
  if not success and isGitHub:
    infoNow url.projectName, "Trying to clone url again: " & modurl
    # retry multiple times to avoid annoying GitHub timeouts:
    success = retryUrl(gitCmdStr, modurl, url.projectName, false)

  if not success:
    if isGitHub:
      (NotFound, "Unable to identify url: " & modurl)
    else:
      # Checking repo with Mercurial
      if retryUrl("hg identify " & modurl, modurl, url.projectName, true):
        (NotFound, "Unable to identify url: " & modurl)
      else:
        let hgCmdStr = "hg clone " & modurl & " " & $dest
        if retryUrl(hgCmdStr, modurl, url.projectName, true):
          (Ok, "")
        else:
          (OtherError, "exernal program failed: " & hgCmdStr)
  else:
    if gitops.clone(url.url, dest, fullClones=true): # gitops.clone has buit-in retrying
      (Ok, "")
    else:
      (OtherError, "exernal program failed: " & $GitClone)

  # proc updatePackages*() =
  #   if dirExists(c.depsDir / DefaultPackagesSubDir):
  #     withDir(c, c.depsDir / DefaultPackagesSubDir):
  #       gitPull(c, DefaultPackagesSubDir)
  #   else:
  #     withDir c, c.depsDir:
  #       let (status, err) = cloneUrl(c, PkgUrl"https://github.com/nim-lang/packages", DefaultPackagesSubDir, false)
  #       if status != Ok:
  #         error c, DefaultPackagesSubDir, err

  # proc fillPackageLookupTable() =
  #   if not c.hasPackageList:
  #     c.hasPackageList = true
  #     if not fileExists(c.depsDir / DefaultPackagesSubDir / "packages.json"):
  #       updatePackages(c)
  #     let plist = getPackageInfos(c.depsDir)
  #     debug "fillPackageLookupTable", "initializing..."
  #     for entry in plist:
  #       let url = getUrl(entry.url)
  #       let pkg = Package(name: PackageName unicode.toLower entry.name,
  #                         repo: PackageRepo lastPathComponent($url),
  #                         url: url)
  #       c.urlMapping["name:" & pkg.name.string] = pkg

  # # proc dependencyDir*(pkg: Package): PackageDir =
  # #   template checkDir(dir: string) =
  # #     if dir.len > 0 and dirExists(dir):
  # #       debug pkg, "dependencyDir: found: " & dir
  # #       return PackageDir dir
  # #     else:
  # #       debug pkg, "dependencyDir: not found: " & dir

  # #   debug pkg, "dependencyDir: check: pth: " & pkg.path.string & " cd: " & getCurrentDir() & " ws: " & c.workspace
  # #   if pkg.exists:
  # #     debug pkg, "dependencyDir: exists: " & pkg.path.string
  # #     return PackageDir pkg.path.string.absolutePath
  # #   if c.workspace.lastPathComponent == pkg.repo.string:
  # #     debug pkg, "dependencyDir: workspace: " & c.workspace
  # #     return PackageDir c.workspace

  # #   if pkg.path.string.len > 0:
  # #     checkDir pkg.path.string
  # #     checkDir c.workspace / pkg.path.string
  # #     checkDir c.depsDir / pkg.path.string

  # #   checkDir c.workspace / pkg.repo.string
  # #   checkDir c.depsDir / pkg.repo.string
  # #   checkDir c.workspace / pkg.name.string
  # #   checkDir c.depsDir / pkg.name.string
  # #   result = PackageDir c.depsDir / pkg.repo.string
  # #   trace pkg, "dependency not found using default"

  # # proc findNimbleFile*(pkg: Package; depDir = PackageDir""): Path =
  # #   let dir = if depDir.string.len == 0: dependencyDir(c, pkg).string
  # #             else: depDir.string
  # #   result = dir / (pkg.name.string & ".nimble")
  # #   debug pkg, "findNimbleFile: searching: " & pkg.repo.string & " path: " & pkg.path.string & " dir: " & dir & " curr: " & result
  # #   if not fileExists(result):
  # #     debug pkg, "findNimbleFile: not found: " & result
  # #     result = ""
  # #     for file in walkFiles(dir / "*.nimble"):
  # #       if result.len == 0:
  # #         result = file
  # #         trace pkg, "nimble file found " & result
  # #       else:
  # #         error c, pkg, "ambiguous .nimble file " & result
  # #         return ""
  # #   else:
  # #     trace pkg, "nimble file found " & result

  # # proc resolvePackageUrl(url: string, checkOverrides = true): Package =
  # #   result = Package(url: getUrl(url),
  # #                   name: url.toRepo().PackageName,
  # #                   repo: url.toRepo())

  # #   debug result, "resolvePackageUrl: search: " & url

  # #   let isFile = result.url.scheme == "file"
  # #   var isUrlOverriden = false
  # #   if not isFile and checkOverrides and UsesOverrides in c.flags:
  # #     let url = c.overrides.substitute($result.url)
  # #     if url.len > 0:
  # #       warn result, "resolvePackageUrl: url override found: " & $url
  # #       result.url = url.getUrl()
  # #       isUrlOverriden = true

  # #   let namePkg = c.urlMapping.getOrDefault("name:" & result.name.string, nil)
  # #   let repoPkg = c.urlMapping.getOrDefault("repo:" & result.repo.string, nil)

  # #   if not namePkg.isNil:
  # #     debug result, "resolvePackageUrl: found by name: " & $result.name.string
  # #     if namePkg.url != result.url and isUrlOverriden:
  # #       namePkg.url = result.url # update package url to match
  # #       result = namePkg
  # #     elif namePkg.url != result.url:
  # #       # package conflicts
  # #       # change package repo to `repo.user.host`
  # #       let purl = result.url
  # #       let host = purl.hostname
  # #       let org = purl.path.parentDir.lastPathPart
  # #       let rname = purl.path.lastPathPart
  # #       let pname = [rname, org, host].join(".")
  # #       warn result,
  # #               "conflicting url's for package; renaming package: " &
  # #                 result.name.string & " to " & pname
  # #       result.repo = PackageRepo pname
  # #       c.urlMapping["name:" & result.name.string] = result
  # #     else:
  # #       result = namePkg
  # #   elif not repoPkg.isNil:
  # #     debug result, "resolvePackageUrl: found by repo: " & $result.repo.string
  # #     result = repoPkg
  # #   else:
  # #     # package doesn't exit and doesn't conflict
  # #     # set the url with package name as url name
  # #     c.urlMapping["repo:" & result.name.string] = result
  # #     trace result, "resolvePackageUrl: not found; set pkg: " & $result.repo.string

  # #   #if result.url.scheme == "file":
  # #   #  result.path = PackageDir result.url.hostname & result.url.path
  # #   #  trace result, "resolvePackageUrl: setting manual path: " & $result.path.string

  # # proc resolvePackageName(name: string): Package =
  # #   result = Package(name: PackageName name,
  # #                   repo: PackageRepo name)

  # #   # the project name can be overwritten too!
  # #   if UsesOverrides in c.flags:
  # #     let name = c.overrides.substitute(name)
  # #     if name.len > 0:
  # #       if name.isUrl():
  # #         return resolvePackageUrl(name, checkOverrides=false)

  # #   # echo "URL MAP: ", repr c.urlMapping.keys().toSeq()
  # #   let namePkg = c.urlMapping.getOrDefault("name:" & result.name.string, nil)
  # #   let repoPkg = c.urlMapping.getOrDefault("repo:" & result.name.string, nil)

  # #   debug result, "resolvePackageName: searching for package name: " & result.name.string
  # #   if not namePkg.isNil:
  # #     # great, found package!
  # #     debug result, "resolvePackageName: found!"
  # #     result = namePkg
  # #     result.inPackages = true
  # #   elif not repoPkg.isNil:
  # #     # check if rawHandle is a package repo name
  # #     debug result, "resolvePackageName: found by repo!"
  # #     result = repoPkg
  # #     result.inPackages = true

  # #   if UsesOverrides in c.flags:
  # #     let newUrl = c.overrides.substitute($result.url)
  # #     if newUrl.len > 0:
  # #       trace result, "resolvePackageName: not url: UsesOverrides: " & $newUrl
  # #       result.url = getUrl newUrl

  # # proc resolvePackage*(rawHandle: string): Package =
  # #   ## Takes a raw handle which can be a name, a repo name, or a url
  # #   ## and resolves it into a package. If not found it will create
  # #   ## a new one.
  # #   ##
  # #   ## Note that Package should be unique globally. This happens
  # #   ## by updating the packages list when new packages are added or
  # #   ## loaded from a packages.json.
  # #   ##
  # #   result = Package()

  # #   fillPackageLookupTable(c)

  # #   trace rawHandle, "resolving package"

  # #   if rawHandle.isUrl:
  # #     result = resolvePackageUrl(rawHandle)
  # #   else:
  # #     result = resolvePackageName(unicode.toLower(rawHandle))

  # #   result.path = dependencyDir(c, result)
  # #   let res = findNimbleFile(result, result.path)
  # #   if res.len > 0:
  # #     let nimble = PackageNimble res
  # #     result.exists = true
  # #     result.nimble = nimble
  # #     # the nimble package name is <name>.nimble
  # #     result.name = PackageName nimble.string.splitFile().name
  # #     debug result, "resolvePackageName: nimble: found: " & $result
  # #   else:
  # #     debug result, "resolvePackageName: nimble: not found: " & $result


  # # proc resolveNimble*(pkg: Package) =
  # #   ## Try to resolve the nimble file for the given package.
  # #   ##
  # #   ## This should be done after cloning a new repo.
  # #   ##
  # #   if pkg.exists: return

  # #   pkg.path = dependencyDir(c, pkg)
  # #   let res = findNimbleFile(pkg)
  # #   if res.len > 0:
  # #     let nimble = PackageNimble res
  # #     # let path = PackageDir res.parentDir()
  # #     pkg.exists = true
  # #     pkg.nimble = nimble
  # #     info pkg, "resolvePackageName: nimble: found: " & $pkg
  # #   else:
  # #     info pkg, "resolvePackageName: nimble: not found: " & $pkg
