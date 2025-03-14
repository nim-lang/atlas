#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std / [os, uri, paths, files, tables]
import versions, parse_requires, compiledpatterns, reporters

export reporters

const
  UnitTests* = defined(atlasUnitTests)
  TestsDir* = "atlas/tests"

const
  AtlasWorkspaceFile = Path "atlas.workspace"

type
  CfgPath* = distinct string # put into a config `--path:"../x"`

  SemVerField* = enum
    major, minor, patch

  CloneStatus* = enum
    Ok, NotFound, OtherError

  Flag* = enum
    KeepCommits
    CfgHere
    Keep
    KeepWorkspace
    ShowGraph
    AutoEnv
    NoExec
    ListVersions
    ListVersionsOff
    GlobalWorkspace
    ShallowClones
    IgnoreGitRemoteUrls
    IgnoreErrors

  AtlasContext* = object
    workspace*: Path = Path"."
    depsDir*: Path = Path"deps"
    flags*: set[Flag]
    dumpGraphs*: bool = true # TODO: debugging, plumb cli option later
    dumpFormular*: bool = false
    nameOverrides*: Patterns
    urlOverrides*: Patterns
    defaultAlgo*: ResolutionAlgorithm = SemVer
    plugins*: PluginInfo
    overridesFile*: Path
    pluginsFile*: Path
    proxy*: Uri
    ignoreErrors*: bool = false
    dumbProxy*: bool = false
    forceGitToHttps*: bool = false
    includeTagsAndNimbleCommits*: bool = false # include nimble commits and tags in the solver
    nimbleCommitsMax*: bool = false # takes the newest commit for each version

var atlasContext = AtlasContext()

proc setContext*(ctx: AtlasContext) =
  atlasContext = ctx
proc context*(): var AtlasContext =
  atlasContext

proc workspace*(): var Path =
  atlasContext.workspace

proc depsDir*(): Path =
  result = atlasContext.workspace / atlasContext.depsDir

proc getWorkspaceConfig*(workspace = workspace()): Path =
  ## prefer workspace atlas.config if found
  ## otherwise default to one in deps/
  ## the deps path will be the default for auto-created ones
  result = workspace / AtlasWorkspaceFile
  if fileExists(result): return
  result = workspace / context().depsDir / AtlasWorkspaceFile

proc isWorkspace*(dir: Path): bool =
  fileExists(getWorkspaceConfig(dir))

proc `==`*(a, b: CfgPath): bool {.borrow.}

proc displayName(c: AtlasContext; p: string): string =
  if p == c.workspace.string:
    p.absolutePath
  elif $c.depsDir != "" and p.isRelativeTo($c.depsDir):
    p.relativePath($c.depsDir)
  elif p.isRelativeTo($c.workspace):
    p.relativePath($c.workspace)
  else:
    p
