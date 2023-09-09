import std/[os, strutils]
import context, osutils, parse_requires

export parse_requires

const
  configPatternBegin = "############# begin Atlas config section ##########\n"
  configPatternEnd =   "############# end Atlas config section   ##########\n"

proc parseNimble*(c: var AtlasContext; nimble: PackageNimble): NimbleFileInfo =
  result = extractRequiresInfo(nimble.string)
  when ProduceTest:
    echo "nimble ", nimbleFile, " info ", result

proc findCfgDir*(c: var AtlasContext): CfgPath =
  for nimbleFile in walkPattern(c.currentDir / "*.nimble"):
    let nimbleInfo = parseNimble(c, PackageNimble nimbleFile)
    return CfgPath c.currentDir / nimbleInfo.srcDir
  return CfgPath c.currentDir

proc findCfgDir*(c: var AtlasContext, pkg: Package): CfgPath =
  let nimbleInfo = parseNimble(c, pkg.nimble)
  return CfgPath c.currentDir / nimbleInfo.srcDir

proc patchNimCfg*(c: var AtlasContext; deps: seq[CfgPath]; cfgPath: CfgPath) =
  var paths = "--noNimblePath\n"
  for d in deps:
    let x = relativePath(d.string, cfgPath.string, '/')
    paths.add "--path:\"" & x & "\"\n"
  var cfgContent = configPatternBegin & paths & configPatternEnd

  when MockupRun:
    assert readFile(TestsDir / "nim.cfg") == cfgContent
    c.mockupSuccess = true
  else:
    let cfg = cfgPath.string / "nim.cfg"
    assert cfgPath.string.len > 0
    if cfgPath.string.len > 0 and not dirExists(cfgPath.string):
      error(c, c.projectDir.toRepo, "could not write the nim.cfg")
    elif not fileExists(cfg):
      writeFile(cfg, cfgContent)
      info(c, projectFromCurrentDir(), "created: " & cfg.readableFile)
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
        info(c, projectFromCurrentDir(), "updated: " & cfg.readableFile)
