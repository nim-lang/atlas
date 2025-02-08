#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std / [os]
import versions, parse_requires, compiledpatterns, reporters

const
  UnitTests* = defined(atlasUnitTests)
  TestsDir* = "atlas/tests"

const
  AtlasWorkspace* = "atlas.workspace"

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
    projectDir*, workspace*, depsDir*, currentDir*: string
    flags*: set[Flag]
    #urlMapping*: Table[string, Package] # name -> url mapping
    overrides*: Patterns
    defaultAlgo*: ResolutionAlgorithm
    plugins*: PluginInfo
    overridesFile*: string
    pluginsFile*: string
    origDepsDir*: string


proc `==`*(a, b: CfgPath): bool {.borrow.}

proc displayName(c: AtlasContext; p: string): string =
  if p == c.workspace:
    p.absolutePath
  elif c.depsDir != "" and p.isRelativeTo(c.depsDir):
    p.relativePath(c.depsDir)
  elif p.isRelativeTo(c.workspace):
    p.relativePath(c.workspace)
  else:
    p

template projectFromCurrentDir*(): untyped = c.currentDir.absolutePath

template withDir*(c: var AtlasContext; dir: string; body: untyped) =
  let oldDir = getCurrentDir()
  debug c, dir, "Current directory is now: " & dir
  try:
    setCurrentDir(dir)
    body
  finally:
    setCurrentDir(oldDir)

template tryWithDir*(c: var AtlasContext; dir: string; body: untyped) =
  let oldDir = getCurrentDir()
  try:
    if dirExists(dir):
      setCurrentDir(dir)
      debug c, dir, "Current directory is now: " & dir
      body
  finally:
    setCurrentDir(oldDir)
