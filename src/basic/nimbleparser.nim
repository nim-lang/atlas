#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std / [os, paths, strutils, tables, unicode, hashes]
import sattypes, versions, reporters, reporters, gitops, parserequires, pkgurls, compiledpatterns

type
  DependencyStatus* = enum
    Normal, HasBrokenNimbleFile, HasUnknownNimbleFile, HasBrokenDep

  Requirements* = object
    deps*: seq[(PkgUrl, VersionInterval)]
    hasInstallHooks*: bool
    srcDir*: Path
    version*: Version
    nimVersion*: Version
    v*: VarId
    status*: DependencyStatus
    err*: string

  NimbleContext* = object
    hasPackageList*: bool
    nameToUrl*: Table[string, string]

proc hash*(r: Requirements): Hash =
  var h: Hash = 0
  h = h !& hash(r.deps)
  h = h !& hash(r.hasInstallHooks)
  h = h !& hash($r.srcDir)
  #h = h !& hash(r.version)
  h = h !& hash(r.nimVersion)
  result = !$h

proc `==`*(a, b: Requirements): bool =
  result = a.deps == b.deps and a.hasInstallHooks == b.hasInstallHooks and
      a.srcDir == b.srcDir and a.nimVersion == b.nimVersion
  #and a.version == b.version

proc addError*(err: var string; nimbleFile: string; msg: string) =
  if err.len > 0: err.add "\n"
  else: err.add "in file: " & nimbleFile & "\n"
  err.add msg

proc isUrl(s: string): bool {.inline.} = s.len > 5 and s.contains "://"

proc parseNimbleFile*(cc: var Reporter, nc: NimbleContext; nimbleFile: string; p: Patterns): Requirements =
  let nimbleInfo = extractRequiresInfo(nimbleFile)

  result = Requirements(
    hasInstallHooks: nimbleInfo.hasInstallHooks,
    srcDir: nimbleInfo.srcDir,
    status: if nimbleInfo.hasErrors: HasBrokenNimbleFile else: Normal,
    v: NoVar,
    version: parseExplicitVersion(nimbleInfo.version)
  )
  for r in nimbleInfo.requires:
    var i = 0
    while i < r.len and r[i] notin {'#', '<', '=', '>'} + Whitespace: inc i
    let name = r.substr(0, i-1)

    var didReplace = false
    var u = substitute(p, name, didReplace)
    if not didReplace:
      u = (if name.isUrl: name else: nc.nameToUrl.getOrDefault(unicode.toLower name, ""))

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
          result.deps.add (cc.createUrlSkipPatterns(u), query)

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

proc genRequiresLine(u: string): string = "requires \"$1\"\n" % u.escape("", "")

proc patchNimbleFile*(c: var Reporter, nc: var NimbleContext; r: var Reporter; p: Patterns; nimbleFile, name: string) =
  var didReplace = false
  var u = substitute(p, name, didReplace)
  if not didReplace:
    u = (if name.isUrl: name else: nc.nameToUrl.getOrDefault(unicode.toLower name, ""))

  if u.len == 0:
    error r, name, "cannot resolve package name: " & name
    return

  let req = parseNimbleFile(c, nc, nimbleFile, p)
  # see if we have this requirement already listed. If so, do nothing:
  for d in req.deps:
    if d[0].url == u:
      info(r, nimbleFile, "up to date")
      return

  let line = genRequiresLine(if didReplace: name else: u)
  var f = open(nimbleFile, fmAppend)
  try:
    f.writeLine line
  finally:
    f.close()
  info(r, nimbleFile, "updated")
