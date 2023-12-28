#
#           Atlas Package Cloner
#        (c) Copyright 2021 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std/[os, strutils]
import context, osutils, parse_requires, nameresolver, reporters

export parse_requires

const
  configPatternBegin = "############# begin Atlas config section ##########\n"
  configPatternEnd =   "############# end Atlas config section   ##########\n"

proc parseNimble*(c: var AtlasContext; nimble: PackageNimble): NimbleFileInfo =
  result = extractRequiresInfo(nimble.string)

proc findCfgDir*(c: var AtlasContext): CfgPath =
  for nimbleFile in walkPattern(c.currentDir / "*.nimble"):
    let nimbleInfo = parseNimble(c, PackageNimble nimbleFile)
    return CfgPath c.currentDir / nimbleInfo.srcDir
  return CfgPath c.currentDir

proc findCfgDir*(c: var AtlasContext, pkg: Package): CfgPath =
  let nimbleInfo = parseNimble(c, pkg.nimble)
  let pth = pkg.nimble.string.splitPath().head
  return CfgPath pth.relativePath(c.currentDir) / nimbleInfo.srcDir

proc patchNimCfg*(c: var AtlasContext; deps: seq[CfgPath]; cfgPath: CfgPath) =
  var paths = "--noNimblePath\n"
  for d in deps:
    let x = relativePath(d.string, cfgPath.string, '/')
    paths.add "--path:\"" & x & "\"\n"
  var cfgContent = configPatternBegin & paths & configPatternEnd

  let cfg = cfgPath.string / "nim.cfg"
  assert cfgPath.string.len > 0
  if cfgPath.string.len > 0 and not dirExists(cfgPath.string):
    error(c, c.projectDir, "could not write the nim.cfg")
  elif not fileExists(cfg):
    writeFile(cfg, cfgContent)
    info(c, projectFromCurrentDir().string, "created: " & cfg.readableFile)
  else:
    let content = readFile(cfg)
    let start = content.find(configPatternBegin)
    if start >= 0:
      cfgContent = content.substr(0, start-1) & cfgContent
      let theEnd = content.find(configPatternEnd, start)
      if theEnd >= 0:
        cfgContent.add content.substr(theEnd+len(configPatternEnd))
    else:
      cfgContent = content & "\n" & cfgContent
    if cfgContent != content:
      # do not touch the file if nothing changed
      # (preserves the file date information):
      writeFile(cfg, cfgContent)
      info(c, projectFromCurrentDir().string, "updated: " & cfg.readableFile)

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
