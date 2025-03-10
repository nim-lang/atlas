#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std / [os, sha1, uri, paths, strutils, tables, unicode, hashes, json, jsonutils]
import sattypes, deptypes, nimblecontext, versions, context, reporters, gitops, parse_requires, pkgurls, compiledpatterns

proc addError*(err: var string; nimbleFile: string; msg: string) =
  if err.len > 0: err.add "\n"
  else: err.add "in file: " & nimbleFile & "\n"
  err.add msg

proc isUrl(s: string): bool {.inline.} = s.len > 5 and s.contains "://"

proc parseNimbleFile*(nc: var NimbleContext;
                      nimbleFile: Path;
                      p: Patterns): NimbleRelease =
  let nimbleInfo = extractRequiresInfo(nimbleFile)
  # let nimbleHash = secureHashFile($nimbleFile)

  result = NimbleRelease(
    hasInstallHooks: nimbleInfo.hasInstallHooks,
    srcDir: nimbleInfo.srcDir,
    status: if nimbleInfo.hasErrors: HasBrokenNimbleFile else: Normal,
    # nimbleHash: nimbleHash,
    version: parseExplicitVersion(nimbleInfo.version)
  )

  for r in nimbleInfo.requires:
    var i = 0
    while i < r.len and r[i] notin {'#', '<', '=', '>'} + Whitespace: inc i
    let name = r.substr(0, i-1)

    var url: PkgUrl
    try:
      url = nc.createUrl(name)
    except ValueError, IOError, OSError:
      let err = getCurrentExceptionMsg()
      result.status = HasBrokenDep
      warn nimbleFile, "cannot resolve dependency package name: " & name & " error: " & $err
      result.err.addError $nimbleFile, "cannot resolve package name: " & name
      url = toPkgUriRaw(parseUri("error://" & name))

    var err = false
    let query = parseVersionInterval(r, i, err) # update err
    if err:
      if result.status != HasBrokenDep:
        warn nimbleFile, "broken nimble file: " & name
        result.status = HasBrokenNimbleFile
        result.err.addError $nimbleFile, "invalid 'requires' syntax in nimble file: " & r
    else:
      if cmpIgnoreCase(name, "nim") == 0:
        let v = extractGeQuery(query)
        if v != Version"":
          result.nimVersion = v
      else:
        result.requirements.add (url, query)


proc genRequiresLine(u: string): string =
  result = "requires \"$1\"\n" % u.escape("", "")

proc patchNimbleFile*(nc: var NimbleContext;
                      p: Patterns; nimbleFile: Path, name: string) =
  let url = nc.createUrl(name)
  debug nimbleFile, "patching nimble file to use package:", name, "url:", $url

  if url.isEmpty:
    error name, "cannot resolve package name: " & name
    return

  let release = parseNimbleFile(nc, nimbleFile, p)
  # see if we have this requirement already listed. If so, do nothing:
  for (dep, ver) in release.requirements:
    debug nimbleFile, "checking if dep url:", $url, "matches:", $dep
    if url == dep:
      info(nimbleFile, "nimble fileup to date")
      return

  debug nimbleFile, "patching nimble file using:", $url.projectName

  let line = genRequiresLine(url.projectName)
  var f = open($nimbleFile, fmAppend)
  try:
    f.writeLine line
  finally:
    f.close()
  info(nimbleFile, "updated")
