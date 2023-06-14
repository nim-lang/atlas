
import std / [strutils, os, osproc, tables, sets, json, jsonutils,
  parsecfg, streams, terminal, strscans, hashes, options, uri]
import versions, parse_requires, compiledpatterns

export tables, sets, json
export versions, parse_requires, compiledpatterns

const
  MockupRun* = defined(atlasTests)
  UnitTests* = defined(atlasUnitTests)
  TestsDir* = "atlas/tests"

type
  PackageUrl* = Uri

export uri.`$`, uri.`/`, uri.UriParseError

type
  LockMode* = enum
    noLock, genLock, useLock

  LockFileEntry* = object
    url*: string
    commit*: string

  PackageName* = distinct string
  CfgPath* = distinct string # put into a config `--path:"../x"`
  DepRelation* = enum
    normal, strictlyLess, strictlyGreater

  SemVerField* = enum
    major, minor, patch

  ResolutionAlgorithm* = enum
    MinVer, SemVer, MaxVer

  Dependency* = object
    name*: PackageName
    url*: PackageUrl
    commit*: string
    query*: VersionInterval
    self*: int # position in the graph
    parents*: seq[int] # why we need this dependency
    active*: bool
    hasInstallHooks*: bool
    algo*: ResolutionAlgorithm

  DepGraph* = object
    nodes*: seq[Dependency]
    processed*: Table[string, int] # the key is (url / commit)
    byName*: Table[PackageName, seq[int]]
    availableVersions*: Table[PackageName, seq[(string, Version)]] # sorted, latest version comes first
    bestNimVersion*: Version # Nim is a special snowflake

  LockFile* = object # serialized as JSON so an object for extensibility
    items*: OrderedTable[string, LockFileEntry]

  Flag* = enum
    KeepCommits
    CfgHere
    UsesOverrides
    Keep
    NoColors
    ShowGraph
    AutoEnv
    NoExec

  AtlasContext* = object
    projectDir*, workspace*, depsDir*, currentDir*: string
    hasPackageList*: bool
    flags*: set[Flag]
    p*: Table[string, string] # name -> url mapping
    errors*, warnings*: int
    overrides*: Patterns
    lockMode*: LockMode
    lockFile*: LockFile
    defaultAlgo*: ResolutionAlgorithm
    when MockupRun:
      step*: int
      mockupSuccess*: bool
    plugins*: PluginInfo

proc `==`*(a, b: CfgPath): bool {.borrow.}

proc `==`*(a, b: PackageName): bool {.borrow.}
proc hash*(a: PackageName): Hash {.borrow.}

const
  InvalidCommit* = "#head" #"<invalid commit>"
  ProduceTest* = false


proc message*(c: var AtlasContext; category: string; p: PackageName; arg: string) =
  var msg = category & "(" & p.string & ") " & arg
  stdout.writeLine msg

proc warn*(c: var AtlasContext; p: PackageName; arg: string) =
  if NoColors in c.flags:
    message(c, "[Warning] ", p, arg)
  else:
    stdout.styledWriteLine(fgYellow, styleBright, "[Warning] ", resetStyle, fgCyan, "(", p.string, ")", resetStyle, " ", arg)
  inc c.warnings

proc error*(c: var AtlasContext; p: PackageName; arg: string) =
  if NoColors in c.flags:
    message(c, "[Error] ", p, arg)
  else:
    stdout.styledWriteLine(fgRed, styleBright, "[Error] ", resetStyle, fgCyan, "(", p.string, ")", resetStyle, " ", arg)
  inc c.errors

proc info*(c: var AtlasContext; p: PackageName; arg: string) =
  if NoColors in c.flags:
    message(c, "[Info] ", p, arg)
  else:
    stdout.styledWriteLine(fgGreen, styleBright, "[Info] ", resetStyle, fgCyan, "(", p.string, ")", resetStyle, " ", arg)


proc fatal*(msg: string) =
  when defined(debug):
    writeStackTrace()
  quit "[Error] " & msg

proc toName*(p: PackageUrl): PackageName =
  result = PackageName splitFile(p.path).name

proc toName*(p: string): PackageName =
  assert not p.startsWith("http")
  result = PackageName p
