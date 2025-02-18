#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std / [os, uri, paths]
import versions, parserequires, compiledpatterns, reporters

export reporters

const
  UnitTests* = defined(atlasUnitTests)
  TestsDir* = "atlas/tests"

const
  AtlasWorkspace* = Path "atlas.workspace"

type
  CfgPath* = distinct string # put into a config `--path:"../x"`

  SemVerField* = enum
    major, minor, patch

  CloneStatus* = enum
    Ok, NotFound, OtherError

  Flag* = enum
    KeepCommits
    CfgHere
    UsesOverrides
    Keep
    KeepWorkspace
    ShowGraph
    AutoEnv
    NoExec
    ListVersions
    GlobalWorkspace
    FullClones
    IgnoreUrls

  AtlasContext* = object of Reporter
    projectDir*, workspace*, origDepsDir*, currentDir*: Path
    flags*: set[Flag]
    #urlMapping*: Table[string, Package] # name -> url mapping
    overrides*: Patterns
    defaultAlgo*: ResolutionAlgorithm
    plugins*: PluginInfo
    overridesFile*: Path
    pluginsFile*: Path
    proxy*: Uri
    dumbProxy*: bool

var atlasContext: AtlasContext

proc setContext*(ctx: AtlasContext) =
  atlasContext = ctx
proc context*(): var AtlasContext =
  atlasContext

proc errors*(): int =
  atlasContext.errors

proc `==`*(a, b: CfgPath): bool {.borrow.}

proc depsDir*(c: AtlasContext): Path =
  if c.origDepsDir == Path "":
    c.workspace
  elif c.origDepsDir.isAbsolute:
    c.origDepsDir
  else:
    (c.workspace / c.origDepsDir).absolutePath

proc displayName(c: AtlasContext; p: string): string =
  if p == c.workspace.string:
    p.absolutePath
  elif $c.depsDir != "" and p.isRelativeTo($c.depsDir):
    p.relativePath($c.depsDir)
  elif p.isRelativeTo($c.workspace):
    p.relativePath($c.workspace)
  else:
    p

proc projectFromCurrentDir*(): Path = context().currentDir.absolutePath

# template withDir*(dir: string; body: untyped) =
#   let oldDir = ospaths2.getCurrentDir()
#   debug dir, "Current directory is now: " & dir
#   try:
#     setCurrentDir(dir)
#     body
#   finally:
#     setCurrentDir(oldDir)

# template tryWithDir*(dir: string; body: untyped) =
#   let oldDir = ospaths2.getCurrentDir()
#   try:
#     if dirExists(dir):
#       setCurrentDir(dir)
#       debug dir, "Current directory is now: " & dir
#       body
#   finally:
#     setCurrentDir(oldDir)

proc warn*(p: Path | string, arg: string) =
  warn(atlasContext, $p, arg)

proc error*(p: Path | string, arg: string) =
  error(atlasContext, $p, arg)

proc info*(p: Path | string, arg: string) =
  info(atlasContext, $p, arg)

proc trace*(p: Path | string, arg: string) =
  trace(atlasContext, $p, arg)

proc debug*(p: Path | string, arg: string) =
  debug(atlasContext, $p, arg)

proc fatal*(msg: string | Path, prefix = "fatal", code = 1) =
  fatal(atlasContext, msg, prefix, code)

proc infoNow*(p: Path | string, arg: string) =
  infoNow(atlasContext, $p, arg)