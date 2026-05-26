#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std / [os, uri, paths, files, tables, sets]
import versions, parse_requires, compiledpatterns, reporters

export reporters

const
  UnitTests* = defined(atlasUnitTests)
  TestsDir* = "atlas/tests"

const
  AtlasProjectConfig = Path"atlas.config"
  DefaultPackagesSubDir* = Path"_packages"
  DefaultCachesSubDir* = Path".cache"
  DefaultNimbleCachesSubDir* = Path"_nimbles"
  DefaultParallelCloneWorkers* = 3


type
  CfgPath* = distinct string # put into a config `--path:"../x"`

  SemVerField* = enum
    major, minor, patch

  CloneStatus* = enum
    Ok, NotFound, OtherError

  Flag* = enum
    KeepCommits
    CfgHere
    KeepNimEnv
    KeepWorkspace
    ShowGraph
    AutoEnv
    NoExec
    UpdateRepos
    PackagesGit
    ListVersions
    ListVersionsOff
    GlobalWorkspace
    ManualProjectArg
    ShallowClones
    IgnoreGitRemoteUrls
    IgnoreErrors
    DumpFormular
    DumpGraphs
    DumbProxy
    ForceGitToHttps
    NoLazyDeps
    ParallelClones
    UpdateBeforeInstall
    KeepFeatures
    AllFeatures
    TreeView
    IncludeTagsAndNimbleCommits # include nimble commits and tags in the solver
    NimbleCommitsMax # takes the newest commit for each version

  AtlasContext* = object
    projectDir*: Path = Path"."
    depsDir*: Path = Path"deps"
    confDirOverride*: Path = Path""
    flags*: set[Flag] = {}
    nameOverrides*: Patterns
    urlOverrides*: Patterns
    pkgOverrides*: Table[string, Uri]
    defaultAlgo*: ResolutionAlgorithm = SemVer
    plugins*: PluginInfo
    overridesFile*: Path
    pluginsFile*: Path
    proxy*: Uri
    parallelCloneWorkers*: int = DefaultParallelCloneWorkers
    features*: HashSet[string]

var
  atlasContext {.threadvar.}: AtlasContext
  atlasContextInitialized {.threadvar.}: bool

proc initAtlasContext() =
  if not atlasContextInitialized:
    atlasContext = AtlasContext()
    atlasContextInitialized = true

proc setContext*(ctx: AtlasContext) =
  atlasContext = ctx
  atlasContextInitialized = true
proc context*(): var AtlasContext =
  initAtlasContext()
  atlasContext

proc project*(): Path =
  initAtlasContext()
  atlasContext.projectDir

proc project*(ws: Path) =
  initAtlasContext()
  atlasContext.projectDir = ws

proc depsDir*(ctx: AtlasContext, relative = false): Path =
  if ctx.depsDir == Path"":
    result = Path""
  elif relative or ctx.depsDir.isAbsolute:
    result = ctx.depsDir
  else:
    result = ctx.projectDir / ctx.depsDir

proc depsDir*(relative = false): Path =
  initAtlasContext()
  depsDir(atlasContext, relative)

proc allFeaturesRequested*(): bool =
  initAtlasContext()
  AllFeatures in atlasContext.flags

proc hasRequestedFeature*(pkgShortName, pkgProjectName, feature: string): bool =
  initAtlasContext()
  if AllFeatures in atlasContext.flags:
    return true
  if feature in atlasContext.features:
    return true
  let scopedByShortName = "feature." & pkgShortName & "." & feature
  let scopedByProjectName = "feature." & pkgProjectName & "." & feature
  result =
    scopedByShortName in atlasContext.features or
    scopedByProjectName in atlasContext.features

proc packagesDirectory*(): Path =
  depsDir() / DefaultPackagesSubDir

proc cachesDirectory*(): Path =
  depsDir() / DefaultCachesSubDir

proc nimbleCachesDirectory*(): Path =
  depsDir() / DefaultNimbleCachesSubDir

proc depGraphCacheFile*(ctx: AtlasContext): Path =
  ctx.depsDir() / Path"atlas.cache.json"

proc activationCacheFile*(ctx: AtlasContext): Path =
  ctx.depsDir() / DefaultCachesSubDir / Path"atlas.active.json"

proc activationCacheFile*(): Path =
  activationCacheFile(context())

proc relativeToWorkspace*(path: Path): string =
  result = "$project/" & $path.relativePath(project())

proc getProjectConfig*(dir = project()): Path =
  ## prefer project atlas.config if found
  ## otherwise default to one in deps/
  ## the deps path will be the default for auto-created ones
  if context().confDirOverride.len() > 0:
    return context().confDirOverride / AtlasProjectConfig
  result = dir / AtlasProjectConfig
  if fileExists(result): return
  result = depsDir() / AtlasProjectConfig

proc isMainProject*(dir: Path): bool =
  fileExists(getProjectConfig(dir))

proc `==`*(a, b: CfgPath): bool {.borrow.}

proc isGitDir*(path: string): bool =
  let gitPath = path / ".git"
  dirExists(gitPath) or fileExists(gitPath)

proc isGitDir*(path: Path): bool =
  isGitDir($(path))
