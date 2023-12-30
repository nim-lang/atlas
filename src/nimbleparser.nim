#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std / [os, strutils, tables, unicode]
import versions, sat, packagesjson, reporters, gitops, parse_requires

type
  DependencyStatus* = enum
    Normal, HasBrokenNimbleFile, HasUnknownNimbleFile, HasBrokenDep

  Requirements* = ref object
    deps*: seq[(string, VersionInterval)] # URL. use `lastPathComponent(url)`
                                          # to get a directory name suggestion
    hasInstallHooks*: bool
    srcDir: string
    nimVersion: Version
    v: VarId
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

proc addError*(err: var string; nimbleFile: string; msg: string) =
  if err.len > 0: err.add "\n"
  else: err.add "in file: " & nimbleFile & "\n"
  err.add msg

proc parseNimbleFile(c: NimbleContext; nimbleFile: string): Requirements =
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

    let u = (if "://" in name: name else: c.nameToUrl.getOrDefault(unicode.toLower name, ""))
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
          result.deps.add (u, query)


proc patchNimbleFile*(c: var AtlasContext; dep: string): string =
  let thisProject = c.currentDir.lastPathComponent
  let oldErrors = c.errors
  let pkg = resolvePackage(c, dep)
  result = ""
  if oldErrors != c.errors:
    warn c, dep, "cannot resolve package name"
  else:
    for x in walkFiles(c.currentDir / "*.nimble"):
      if result.len == 0:
        result = x
      else:
        # ambiguous .nimble file
        warn c, dep, "cannot determine `.nimble` file; there are multiple to choose from"
        return ""
    # see if we have this requirement already listed. If so, do nothing:
    var found = false
    if result.len > 0:
      let nimbleInfo = parseNimble(c, PackageNimble result)
      for r in nimbleInfo.requires:
        var tokens: seq[string] = @[]
        for token in tokenizeRequires(r):
          tokens.add token
        if tokens.len > 0:
          let oldErrors = c.errors
          let pkgB = resolvePackage(c, tokens[0])
          if oldErrors != c.errors:
            warn c, tokens[0], "cannot resolve package name; found in: " & result
          if pkg == pkgB:
            found = true
            break

    if not found:
      let reqName = if pkg.inPackages: pkg.name.string else: $pkg.url
      let line = "requires \"$1\"\n" % reqName.escape("", "")
      if reqName.len == 0:
        discard "don't produce requires <empty string>"
      elif result.len > 0:
        var oldContent = readFile(result).splitLines()
        var idx = oldContent.len()
        var endsWithComma = false
        for i, line in oldContent:
          if endsWithComma:
            endsWithComma = line.strip().endsWith(",")
            if not endsWithComma:
              idx = i
          if line.startsWith "requires":
            idx = i
            endsWithComma = line.strip().endsWith(",")

        oldContent.insert(line, idx+1)
        writeFile result, oldContent.join("\n")
        info(c, thisProject, "updated: " & result.readableFile)
      else:
        result = c.currentDir / thisProject & ".nimble"
        writeFile result, line
        info(c, thisProject, "created: " & result.readableFile)
    else:
      info(c, thisProject, "up to date: " & result.readableFile)
