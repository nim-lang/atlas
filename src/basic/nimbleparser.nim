#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std / [os, uri, paths, strutils, json, sets]
import deptypes, nimblecontext, versions, context, reporters, parse_requires, pkgurls

proc addError*(err: var string; nimbleFile: string; msg: string) =
  if err.len > 0: err.add "\n"
  else: err.add "in file: " & nimbleFile & "\n"
  err.add msg

proc processRequirement(nc: var NimbleContext;
                        nimbleFile: Path;
                        req: string;
                        feature: string;
                        result: var NimbleRelease) =
    let (name, reqsByFeatures, verIdx) = extractRequirementName(req)

    var url: PkgUrl
    try:
      url = nc.createUrl(name)  # This will handle both name and URL overrides internally
    except ValueError, IOError, OSError:
      let err = getCurrentExceptionMsg()
      result.status = HasBrokenDep
      warn nimbleFile, "cannot resolve dependency package name:", name, "error:", $err
      result.err.addError $nimbleFile, "cannot resolve package name: " & name
      url = toPkgUriRaw(parseUri("error://" & name))

    var err = false
    let query = parseVersionInterval(req, verIdx, err) # update err
    if err:
      if result.status != HasBrokenDep:
        warn nimbleFile, "broken nimble file: " & name
        result.status = HasBrokenNimbleFile
        result.err.addError $nimbleFile, "invalid 'requires' syntax in nimble file: " & req
    else:
      if cmpIgnoreCase(name, "nim") == 0 or cmpIgnoreCase($url, "https://github.com/nim-lang/Nim") == 0:
        let v = extractGeQuery(query)
        if v != Version"":
          result.nimVersion = v
      elif feature.len > 0:
        result.features.mgetOrPut(feature, @[]).add((url, query))
      else:
        result.requirements.add((url, query))
        for feature in reqsByFeatures:
          result.reqsByFeatures.mgetOrPut(url, initHashSet[string]()).incl(feature)

proc parseNimbleFile*(nc: var NimbleContext;
                      nimbleFile: Path): NimbleRelease =
  let nimbleInfo = extractRequiresInfo(nimbleFile)
  # let nimbleHash = secureHashFile($nimbleFile)

  result = NimbleRelease(
    name: nimbleInfo.name,
    hasInstallHooks: nimbleInfo.hasInstallHooks,
    author: nimbleInfo.author,
    description: nimbleInfo.description,
    license: nimbleInfo.license,
    srcDir: nimbleInfo.srcDir,
    binDir: nimbleInfo.binDir,
    bin: nimbleInfo.bin,
    namedBin: nimbleInfo.namedBin,
    backend: nimbleInfo.backend,
    hasBin: nimbleInfo.hasBin,
    status: if nimbleInfo.hasErrors: HasBrokenNimbleFile else: Normal,
    # nimbleHash: nimbleHash,
    version: parseExplicitVersion(nimbleInfo.version)
  )

  for req in nimbleInfo.requires:
    processRequirement(nc, nimbleFile, req, "", result)
  
  for feature, reqs in nimbleInfo.features:
    for req in reqs:
      processRequirement(nc, nimbleFile, req, feature, result)

proc genRequiresLine(u: string): string =
  result = "requires \"$1\"\n" % u.escape("", "")

proc hasNimbleRequirement*(nimbleFile: Path; url: PkgUrl): bool =
  doAssert nimbleFile.string.fileExists()

  let names = [
    url.shortName().toLowerAscii(),
    url.projectName().toLowerAscii(),
    url.fullName().toLowerAscii(),
    url.requiresName().toLowerAscii()
  ]

  for req in extractRequiresInfo(nimbleFile).requires:
    let (name, _, _) = extractRequirementName(req)
    if name.toLowerAscii() in names:
      return true
    if name.isUrl():
      let reqUrl = createUrlSkipPatterns(name)
      if reqUrl.shortName().toLowerAscii() == url.shortName().toLowerAscii() or
          reqUrl.projectName().toLowerAscii() == url.projectName().toLowerAscii():
        return true

proc patchNimbleFile*(nc: var NimbleContext;
                      nimbleFile: Path, name: string) =
  var url = nc.createUrl(name)  # This will handle both name and URL overrides internally
  
  debug nimbleFile, "patching nimble file:", $nimbleFile, "to use package:", name, "url:", $url

  if url.isEmpty:
    error name, "cannot resolve package name: " & name
    return

  doAssert nimbleFile.string.fileExists()

  if hasNimbleRequirement(nimbleFile, url):
    info(nimbleFile, "nimble file up to date")
    return

  let name = url.requiresName()
  debug nimbleFile, "patching nimble file using:", $name

  let line = genRequiresLine(name)
  var f = open($nimbleFile, fmAppend)
  try:
    f.writeLine line
  finally:
    f.close()
  info(nimbleFile, "updated")
