#
#           Atlas Package Cloner
#        (c) Copyright 2021 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std/[os, strutils, files]
import context, osutils, parse_requires, reporters

export parse_requires

const
  configPatternBegin = "############# begin Atlas config section ##########\n"
  configPatternEnd =   "############# end Atlas config section   ##########\n"

proc findCfgDir*(dir: Path): CfgPath =
  for nimbleFile in walkPattern($dir / "*.nimble"):
    let nimbleInfo = extractRequiresInfo(Path nimbleFile)
    return CfgPath dir / nimbleInfo.srcDir
  return CfgPath dir

proc patchNimCfg*(deps: seq[CfgPath]; cfgPath: CfgPath; features: seq[string] = @[]) =
  var paths = "--noNimblePath\n"
  for d in deps:
    let x = relativePath(d.string, cfgPath.string, '/')
    if x.len > 0 and x != ".":
      paths.add "--path:\"" & x & "\"\n"
  for feature in features:
    paths.add "--define:\"" & feature & "\"\n"
  var cfgContent = configPatternBegin & paths & configPatternEnd

  let cfg = Path(cfgPath.string / "nim.cfg")
  assert cfgPath.string.len > 0
  if cfgPath.string.len > 0 and not dirExists(cfgPath.string):
    error($project(), "could not write the nim.cfg")
  elif not fileExists(cfg):
    writeFile($cfg, cfgContent)
    info(project(), "created: " & $cfg.readableFile(project()))
  else:
    let content = readFile($cfg)
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
      writeFile($cfg, cfgContent)
      info(project(), "updated: " & $cfg.readableFile(project()))

  let nimblePaths = Path(cfgPath.string / "nimble.paths")
  if fileExists(nimblePaths):
    warn(project(), "removing obsolete nimble.paths next to nim.cfg:", $nimblePaths.readableFile(project()))
    removeFile($nimblePaths)

proc parseNimCfgFeatures*(cfgPath: CfgPath): seq[string] =
  let cfg = Path(cfgPath.string / "nim.cfg")
  if not fileExists(cfg):
    return

  for line in readFile($cfg).splitLines():
    var x = line.strip()
    if x.startsWith("--define:"):
      x = x["--define:".len .. ^1].strip()
    elif x.startsWith("-d:"):
      x = x["-d:".len .. ^1].strip()
    else:
      continue

    if x.len >= 2 and x[0] == '"' and x[^1] == '"':
      x = x[1 .. ^2]
    if x.startsWith("feature.") and x notin result:
      result.add x.toLowerAscii()
