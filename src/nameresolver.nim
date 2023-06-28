#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Resolves package names and turn them to URLs.

import std / [os, unicode, strutils]
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
          var pname = purl.path
          pname.removePrefix("/")
          pname = pname.replace("/", ".").replace("\\", ".")
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
