#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std / [strutils, os, tables, sets, json,
  terminal, hashes, uri]
import versions, parse_requires, compiledpatterns, osutils

export tables, sets, json
export versions, parse_requires, compiledpatterns

const
  MockupRun* = defined(atlasTests)
  UnitTests* = defined(atlasUnitTests)
  TestsDir* = "atlas/tests"

const
  AtlasWorkspace* = "atlas.workspace"

proc getUrl*(x: string): PackageUrl =
  try:
    let u = parseUri(x).PackageUrl
    if u.scheme in ["git", "https", "http", "hg", "file"]:
      result = u
  except UriParseError:
    discard

export uri.`$`, uri.`/`, uri.UriParseError

type
  CfgPath* = distinct string # put into a config `--path:"../x"`

  SemVerField* = enum
    major, minor, patch

  ResolutionAlgorithm* = enum
    MinVer, SemVer, MaxVer

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
    exists*: bool
    nimble*: PackageNimble

  Dependency* = object
    pkg*: Package
    commit*: string
    query*: VersionInterval
    self*: int # position in the graph
    parents*: seq[int] # why we need this dependency
    active*: bool
    hasInstallHooks*: bool
    algo*: ResolutionAlgorithm
    status*: CloneStatus

  DepGraph* = object
    nodes*: seq[Dependency]
    processed*: Table[string, int] # the key is (url / commit)
    byName*: Table[PackageName, seq[int]]
    availableVersions*: Table[PackageName, seq[(string, Version)]] # sorted, latest version comes first
    bestNimVersion*: Version # Nim is a special snowflake

  Flag* = enum
    KeepCommits
    CfgHere
    UsesOverrides
    Keep
    NoColors
    ShowGraph
    AutoEnv
    NoExec
    ListVersions
    GlobalWorkspace
    AssertOnError

  MsgKind = enum
    Info = "[Info] ",
    Warning = "[Warning] ",
    Error = "[Error] "
    Debug = "[Debug] "
    ExtraDebug = "[ExtraDebug] "

  AtlasContext* = object
    projectDir*, workspace*, depsDir*, currentDir*: string
    hasPackageList*: bool
    verbosity*: int
    flags*: set[Flag]
    urlMapping*: Table[string, Package] # name -> url mapping
    errors*: int
    warnings*: int
    messages: seq[(MsgKind, PackageRepo, string)] # delayed output
    overrides*: Patterns
    defaultAlgo*: ResolutionAlgorithm
    when MockupRun:
      step*: int
      mockupSuccess*: bool
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

const
  InvalidCommit* = "#head" #"<invalid commit>"
  ProduceTest* = false

proc writeMessage(c: var AtlasContext; category: string; p: PackageRepo; arg: string) =
  var msg = category & "(" & p.string & ") " & arg
  stdout.writeLine msg

proc writeMessage(c: var AtlasContext; k: MsgKind; p: PackageRepo; arg: string) =
  if k == Debug and c.verbosity < 1: return
  elif k == ExtraDebug and c.verbosity < 2: return

  if NoColors in c.flags:
    writeMessage(c, $k, p, arg)
  else:
    let pn = p.string.relativePath(c.workspace)
    let color = case k
                of ExtraDebug: fgDefault
                of Debug: fgWhite
                of Info: fgGreen
                of Warning: fgYellow
                of Error: fgRed
    stdout.styledWriteLine(color, styleBright, $k, resetStyle, fgCyan, "(", pn, ")", resetStyle, " ", arg)

proc message(c: var AtlasContext; k: MsgKind; p: PackageRepo; arg: string) =
  # c.messages.add (k, p, arg)
  writeMessage c, k, p, arg


proc warn*(c: var AtlasContext; p: PackageRepo; arg: string) =
  c.message(Warning, p, arg)
  writeMessage c, Warning, p, arg
  inc c.warnings

proc error*(c: var AtlasContext; p: PackageRepo; arg: string) =
  if AssertOnError in c.flags:
    raise newException(AssertionDefect, p.string & ": " & arg)
  c.message(Error, p, arg)
  inc c.errors

proc info*(c: var AtlasContext; p: PackageRepo; arg: string) =
  c.message(Info, p, arg)

proc debug*(c: var AtlasContext; p: PackageRepo; arg: string) =
  c.message(Debug, p, arg)

proc debugExtra*(c: var AtlasContext; p: PackageRepo; arg: string) =
  c.message(ExtraDebug, p, arg)

proc warn*(c: var AtlasContext; p: Package; arg: string) =
  c.warn(p.repo, arg)

proc error*(c: var AtlasContext; p: Package; arg: string) =
  c.error(p.repo, arg)

proc info*(c: var AtlasContext; p: Package; arg: string) =
  c.info(p.repo, arg)

proc debug*(c: var AtlasContext; p: Package; arg: string) =
  c.debug(p.repo, arg)

proc debugExtra*(c: var AtlasContext; p: Package; arg: string) =
  c.debugExtra(p.repo, arg)

proc writePendingMessages*(c: var AtlasContext) =
  for i in 0..<c.messages.len:
    let (k, p, arg) = c.messages[i]
    writeMessage c, k, p, arg
  c.messages.setLen 0

proc infoNow*(c: var AtlasContext; p: PackageRepo; arg: string) =
  writeMessage c, Info, p, arg
proc infoNow*(c: var AtlasContext; p: Package; arg: string) =
  infoNow c, p.repo, arg

proc fatal*(msg: string) =
  when defined(debug):
    writeStackTrace()
  quit "[Error] " & msg

proc toRepo*(p: PackageUrl): PackageRepo =
  result = PackageRepo lastPathComponent($p)
  result.string.removeSuffix(".git")

proc toRepo*(p: string): PackageRepo =
  if p.contains("://"):
    result = toRepo getUrl(p)
  else:
    result = PackageRepo p

template projectFromCurrentDir*(): PackageRepo =
  PackageRepo(c.currentDir.lastPathComponent())

proc toDestDir*(pkg: Package): PackageDir =
  pkg.path

template withDir*(c: var AtlasContext; dir: string; body: untyped) =
  when MockupRun:
    body
  else:
    let oldDir = getCurrentDir()
    info c, toRepo(dir), "Current directory is now: " & dir
    try:
      when ProduceTest:
        echo "Current directory is now ", dir
      setCurrentDir(dir)
      body
    finally:
      setCurrentDir(oldDir)
