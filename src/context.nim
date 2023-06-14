
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

  MsgKind = enum
    Info = "[Info] ",
    Warning = "[Warning] ",
    Error = "[Error] "

  AtlasContext* = object
    projectDir*, workspace*, depsDir*, currentDir*: string
    hasPackageList*: bool
    flags*: set[Flag]
    p*: Table[string, string] # name -> url mapping
    errors*, warnings*: int
    messages: seq[(MsgKind, PackageName, string)] # delayed output
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


proc message(c: var AtlasContext; category: string; p: PackageName; arg: string) =
  var msg = category & "(" & p.string & ") " & arg
  stdout.writeLine msg

proc warn*(c: var AtlasContext; p: PackageName; arg: string) =
  c.messages.add (Warning, p, arg)
  inc c.warnings

proc error*(c: var AtlasContext; p: PackageName; arg: string) =
  c.messages.add (Error, p, arg)
  inc c.errors

proc info*(c: var AtlasContext; p: PackageName; arg: string) =
  c.messages.add (Info, p, arg)

proc writeMessage(c: var AtlasContext; k: MsgKind; p: PackageName; arg: string) =
  if NoColors in c.flags:
    message(c, $k, p, arg)
  else:
    let color = case k
                of Info: fgGreen
                of Warning: fgYellow
                of Error: fgRed
    stdout.styledWriteLine(color, styleBright, $k, resetStyle, fgCyan, "(", p.string, ")", resetStyle, " ", arg)

proc writePendingMessages*(c: var AtlasContext) =
  for i in 0..<c.messages.len:
    let (k, p, arg) = c.messages[i]
    writeMessage c, k, p, arg
  c.messages.setLen 0

proc infoNow*(c: var AtlasContext; p: PackageName; arg: string) =
  writeMessage c, Info, p, arg

proc fatal*(msg: string) =
  when defined(debug):
    writeStackTrace()
  quit "[Error] " & msg

proc toName*(p: PackageUrl): PackageName =
  result = PackageName splitFile(p.path).name

proc toName*(p: string): PackageName =
  #assert not p.startsWith("http") # a package name can be `httpx`...
  result = PackageName p
