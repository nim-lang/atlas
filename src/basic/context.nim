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
  AtlasProjectConfig = Path"atlas.config"
  DefaultPackagesSubDir* = Path"_packages"
  DefaultCachesSubDir* = Path"_caches"
  DefaultNimbleCachesSubDir* = Path"_nimbles"


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
    DumpFormular
    DumpGraphs
    DumbProxy
    ForceGitToHttps
    IncludeTagsAndNimbleCommits # include nimble commits and tags in the solver
    NimbleCommitsMax # takes the newest commit for each version

  AtlasContext* = object
    projectDir*: Path = Path"."
    depsDir*: Path = Path"deps"
    flags*: set[Flag] = {}
    nameOverrides*: Patterns
    urlOverrides*: Patterns
    pkgOverrides*: Table[string, Uri]
    defaultAlgo*: ResolutionAlgorithm = SemVer
    plugins*: PluginInfo
    overridesFile*: Path
    pluginsFile*: Path
    proxy*: Uri

var atlasContext = AtlasContext()

proc setContext*(ctx: AtlasContext) =
  atlasContext = ctx
proc context*(): var AtlasContext =
  atlasContext

proc project*(): Path =
  atlasContext.projectDir

proc project*(ws: Path) =
  atlasContext.projectDir = ws

proc depsDir*(relative = false): Path =
  if atlasContext.depsDir == Path"":
    result = Path""
  elif relative or atlasContext.depsDir.isAbsolute:
    result = atlasContext.depsDir
  else:
    result = atlasContext.projectDir / atlasContext.depsDir

proc packagesDirectory*(): Path =
  depsDir() / DefaultPackagesSubDir

proc cachesDirectory*(): Path =
  depsDir() / DefaultCachesSubDir

proc nimbleCachesDirectory*(): Path =
  depsDir() / DefaultNimbleCachesSubDir

proc depGraphCacheFile*(ctx: AtlasContext): Path =
  ctx.projectDir / ctx.depsDir / Path"atlas.cache.json"

proc relativeToWorkspace*(path: Path): string =
  result = "$project/" & $path.relativePath(project())

proc getProjectConfig*(dir = project()): Path =
  ## prefer project atlas.config if found
  ## otherwise default to one in deps/
  ## the deps path will be the default for auto-created ones
  result = dir / AtlasProjectConfig
  if fileExists(result): return
  result = depsDir() / AtlasProjectConfig

proc isProject*(dir: Path): bool =
  fileExists(getProjectConfig(dir))

proc `==`*(a, b: CfgPath): bool {.borrow.}

proc displayName(c: AtlasContext; p: string): string =
  if p == c.projectDir.string:
    p.absolutePath
  elif $c.depsDir != "" and p.isRelativeTo($c.depsDir):
    p.relativePath($c.depsDir)
  elif p.isRelativeTo($c.projectDir):
    p.relativePath($c.projectDir)
  else:
    p
