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

  PackageName* = distinct string
  PackageDir* = distinct string
  PackageNimble* = distinct string
  PackageRepo* = distinct string

  Package* = ref object
    name*: PackageName
    repo*: PackageRepo
    url*: PackageUrl
    path*: PackageDir
    inPackages*: bool
    exists*: bool
    nimble*: PackageNimble

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

proc nimble*(a: Package): PackageNimble =
  assert a.exists == true
  a.nimble


proc `==`*(a, b: CfgPath): bool {.borrow.}

proc `==`*(a, b: PackageName): bool {.borrow.}
proc `==`*(a, b: PackageRepo): bool {.borrow.}
proc `==`*(a, b: PackageDir): bool {.borrow.}
proc `==`*(a, b: PackageNimble): bool {.borrow.}

proc hash*(a: PackageName): Hash {.borrow.}
proc hash*(a: PackageRepo): Hash {.borrow.}
proc hash*(a: PackageDir): Hash {.borrow.}
proc hash*(a: PackageNimble): Hash {.borrow.}

proc hash*(a: Package): Hash =
  result = 0
  result = result !& hash a.name
  result = result !& hash a.repo
  result = result !& hash a.url

proc `$`*(a: PackageName): string {.borrow.}
proc `$`*(a: PackageRepo): string {.borrow.}
proc `$`*(a: PackageDir): string {.borrow.}
proc `$`*(a: PackageNimble): string {.borrow.}

proc `$`*(a: Package): string =
  result = "Package("
  result &= "name:"
  result &= a.name.string
  result &= ", repo:"
  result &= a.repo.string
  result &= ", url:"
  result &= $(a.url)
  result &= ", p:"
  result &= a.path.string
  result &= ", x:"
  result &= $(a.exists)
  result &= ", nbl:"
  if a.exists:
    result &= $(a.nimble.string)
  result &= ")"

proc displayName(c: AtlasContext; p: PackageRepo): string =
  if p.string == c.workspace:
    p.string.absolutePath
  elif c.depsDir != "" and p.string.isRelativeTo(c.depsDir):
    p.string.relativePath(c.depsDir)
  elif p.string.isRelativeTo(c.workspace):
    p.string.relativePath(c.workspace)
  else:
    p.string

proc warn*(c: var AtlasContext; p: Package; arg: string) =
  c.warn(displayName(c, p.repo), arg)

proc error*(c: var AtlasContext; p: Package; arg: string) =
  c.error(displayName(c, p.repo), arg)

proc info*(c: var AtlasContext; p: Package; arg: string) =
  c.info(displayName(c, p.repo), arg)

proc trace*(c: var AtlasContext; p: Package; arg: string) =
  c.trace(displayName(c, p.repo), arg)

proc debug*(c: var AtlasContext; p: Package; arg: string) =
  c.debug(displayName(c, p.repo), arg)

proc infoNow*(c: var AtlasContext; p: Package; arg: string) =
  infoNow c, displayName(c, p.repo), arg

# proc toRepo*(p: PackageUrl): PackageRepo =
#   result = PackageRepo(lastPathComponent($p))
#   result.string.removeSuffix(".git")

proc toRepo*(p: string): PackageRepo =
  if p.contains("://"):
    result = toRepo lastPathComponent($getUrl(p))
  else:
    result = PackageRepo p

proc toRepo*(p: Package): PackageRepo =
  result = p.repo

proc toRepo*(p: PackageDir): PackageRepo =
  result = PackageRepo p.string

template projectFromCurrentDir*(): PackageRepo =
  PackageRepo(c.currentDir.absolutePath())

proc toDestDir*(pkg: Package): PackageDir =
  pkg.path

template toDir(pkg: Package): string = pkg.path.string
template toDir(dir: string): string = dir

template withDir*(c: var AtlasContext; dir: string | Package; body: untyped) =
  let oldDir = getCurrentDir()
  debug c, toDir(dir), "Current directory is now: " & dir.toDir()
  try:
    setCurrentDir(dir.toDir())
    body
  finally:
    setCurrentDir(oldDir)

template tryWithDir*(c: var AtlasContext, dir: string | Package; body: untyped) =
  let oldDir = getCurrentDir()
  try:
    if dirExists(dir.toDir()):
      setCurrentDir(dir.toDir())
      debug c, toDir(dir), "Current directory is now: " & dir.toDir()
      body
  finally:
    setCurrentDir(oldDir)
