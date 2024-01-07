#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std / [os, strutils, tables, unicode]
import versions, sat, packagesjson, reporters, gitops, parse_requires, pkgurls, compiledpatterns

type
  DependencyStatus* = enum
    Normal, HasBrokenNimbleFile, HasUnknownNimbleFile, HasBrokenDep

  Requirements* = ref object
    deps*: seq[(PkgUrl, VersionInterval)]
    hasInstallHooks*: bool
    srcDir*: string
    nimVersion*: Version
    v*: VarId
    status*: DependencyStatus
    err*: string

  NimbleContext* = object
    hasPackageList: bool
    nameToUrl: Table[string, string]

proc updatePackages*(c: var Reporter; depsDir: string) =
  if dirExists(depsDir / DefaultPackagesSubDir):
    withDir(c, depsDir / DefaultPackagesSubDir):
      gitPull(c, DefaultPackagesSubDir)
  else:
    withDir c, depsDir:
      let success = clone(c, "https://github.com/nim-lang/packages", DefaultPackagesSubDir)
      if not success:
        error c, DefaultPackagesSubDir, "cannot clone packages repo"

proc fillPackageLookupTable(c: var NimbleContext; r: var Reporter; depsdir: string) =
  if not c.hasPackageList:
    c.hasPackageList = true
    if not fileExists(depsDir / DefaultPackagesSubDir / "packages.json"):
      updatePackages(r, depsdir)
    let packages = getPackageInfos(depsDir)
    for entry in packages:
      c.nameToUrl[unicode.toLower entry.name] = entry.url

proc createNimbleContext*(r: var Reporter; depsdir: string): NimbleContext =
  result = NimbleContext()
  fillPackageLookupTable(result, r, depsdir)

proc addError*(err: var string; nimbleFile: string; msg: string) =
  if err.len > 0: err.add "\n"
  else: err.add "in file: " & nimbleFile & "\n"
  err.add msg

proc isUrl(s: string): bool {.inline.} = s.len > 5 and s.contains "://"

proc parseNimbleFile*(c: NimbleContext; nimbleFile: string; p: Patterns): Requirements =
  let nimbleInfo = extractRequiresInfo(nimbleFile)

  result = Requirements(
    hasInstallHooks: nimbleInfo.hasInstallHooks,
    srcDir: nimbleInfo.srcDir,
    status: Normal
  )
  for r in nimbleInfo.requires:
    var i = 0
    while i < r.len and r[i] notin {'#', '<', '=', '>'} + Whitespace: inc i
    let name = r.substr(0, i-1)

    var didReplace = false
    var u = substitute(p, name, didReplace)
    if not didReplace:
      u = (if name.isUrl: name else: c.nameToUrl.getOrDefault(unicode.toLower name, ""))

    if u.len == 0:
      result.status = HasBrokenDep
      result.err.addError nimbleFile, "cannot resolve package name: " & name
    else:
      var err = false
      let query = parseVersionInterval(r, i, err) # update err

      if err:
        if result.status != HasBrokenDep:
          result.status = HasBrokenNimbleFile
          result.err.addError nimbleFile, "invalid 'requires' syntax in nimble file: " & r
      else:
        if cmpIgnoreCase(name, "nim") == 0:
          let v = extractGeQuery(query)
          if v != Version"":
            result.nimVersion = v
        else:
          result.deps.add (createUrlSkipPatterns(u), query)

proc findNimbleFile*(c: var Reporter; dir: string; ambiguous: var bool): string =
  result = ""
  var counter = 0
  for x in walkFiles(dir / "*.nimble"):
    inc counter
    if result.len == 0:
      result = x
  if counter > 1:
    ambiguous = true
    result = ""

#  if counter > 1:
#    warn c, dir, "cannot determine `.nimble` file; there are multiple to choose from"
#    result = ""

proc genRequiresLine*(u: string): string = "requires \"$1\"\n" % u.escape("", "")

proc patchNimbleFile*(c: var NimbleContext; r: var Reporter; p: Patterns; nimbleFile, name: string) =
  let u = (if name.isUrl: name else: c.nameToUrl.getOrDefault(unicode.toLower name, ""))
  if u.len == 0:
    error r, name, "cannot resolve package name"
    return

  let req = parseNimbleFile(c, nimbleFile, p)
  # see if we have this requirement already listed. If so, do nothing:
  for d in req.deps:
    if d[0].url == u:
      info(r, nimbleFile, "up to date")
      return

  let line = genRequiresLine(u)
  var f = open(nimbleFile, fmAppend)
  try:
    f.writeLine line
  finally:
    f.close()
  info(r, nimbleFile, "updated")
