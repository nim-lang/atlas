#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std / [strutils, os, tables, sets, json, hashes, uri]
import versions, parse_requires, compiledpatterns, osutils, reporters

export tables, sets, json
export versions, parse_requires, compiledpatterns

const
  UnitTests* = defined(atlasUnitTests)
  TestsDir* = "atlas/tests"

const
  AtlasWorkspace* = "atlas.workspace"

proc getUrl*(input: string): PackageUrl =
  try:
    var input = input
    input.removeSuffix(".git")
    let u = PackageUrl(parseUri(input))
    if u.scheme in ["git", "https", "http", "hg", "file"]:
      result = u
  except UriParseError:
    discard

export uri.`$`, uri.`/`, uri.UriParseError

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
