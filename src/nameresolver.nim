#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Resolves package names and turn them to URLs.

import std / [os, unicode]
import context, osutils, packagesjson, gitops

proc cloneUrl*(c: var AtlasContext;
               url: PackageUrl,
               dest: string;
               cloneUsingHttps: bool): (CloneStatus, string) =
  when MockupRun:
    result = (Ok, "")
  else:
    result = osutils.cloneUrl(url, dest, cloneUsingHttps)
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

proc resolveUrl*(c: var AtlasContext; p: string): (PackageName, PackageUrl) =
  proc lookup(c: var AtlasContext; p: string): tuple[name: string, url: string] =
    fillPackageLookupTable(c)

    if p.isUrl:
      echo "IS URL: ", p
      if UsesOverrides in c.flags:
        result.url = c.overrides.substitute(p)
        if result.url.len > 0: return result
      let name = unicode.toLower p.toName().string
      if not c.urlMapping.hasKey(name):
        c.urlMapping[name] = p
      else:
        assert c.urlMapping[name] == p
        echo "RESOLV URL: already found! ", c.urlMapping[name]
      result = (name, p)
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
  echo "RESOLVE URL: ", p, " to: ", urlstr
  result = (name.toName(), urlstr.getUrl())
