## Utility API for Nim package managers.
## (c) 2021 Andreas Rumpf

import std / [strutils, paths, tables]

import compiler / [ast, idents, msgs, syntaxes, options, pathutils, lineinfos]
import reporters

type
  NimbleFileInfo* = object
    requires*: seq[string]
    features*: Table[string, seq[string]]
    srcDir*: Path
    version*: string
    tasks*: seq[(string, string)]
    hasInstallHooks*: bool
    hasErrors*: bool

proc eqIdent(a, b: string): bool {.inline.} =
  cmpIgnoreCase(a, b) == 0 and a[0] == b[0]

proc handleError(cfg: ConfigRef, li: TLineInfo, mk: TMsgKind, msg: string) =
  {.cast(gcsafe).}:
    info("nimbleparser", "error parsing \"$1\" at $2" % [msg, cfg.toFileLineCol(li), repr mk])

proc handleError(cfg: ConfigRef, mk: TMsgKind, li: TLineInfo, msg: string) =
  handleError(cfg, li, warnUser, msg)

proc handleError(cfg: ConfigRef, li: TLineInfo, msg: string) =
  handleError(cfg, warnUser, li, msg)

proc getDefinedName(n: PNode): string =
  if n.kind == nkCall and n[0].kind == nkIdent and n[0].ident.s == "defined":
    return n[1].ident.s
  else:
    return ""

proc evalBasicDefines(sym: string): bool =
  case sym:
  of "windows":
    when defined(windows): result = true
  of "posix":
    when defined(posix): result = true
  of "linux":
    when defined(linux): result = true
  of "macosx":
    when defined(macosx): result = true
  else:
    discard

proc extract(n: PNode; conf: ConfigRef; currFeature: string; result: var NimbleFileInfo) =
  case n.kind
  of nkStmtList, nkStmtListExpr:
    for child in n:
      extract(child, conf, currFeature, result)
  of nkCallKinds:
    if n[0].kind == nkIdent:
      case n[0].ident.s
      of "requires":
        for i in 1..<n.len:
          var ch = n[i]
          while ch.kind in {nkStmtListExpr, nkStmtList} and ch.len > 0: ch = ch.lastSon
          if ch.kind in {nkStrLit..nkTripleStrLit}:
            if currFeature.len > 0:
              result.features[currFeature].add ch.strVal
            else:
              result.requires.add ch.strVal
          else:
            handleError(conf, ch.info, "'requires' takes string literals")
            result.hasErrors = true
      of "task":
        if n.len >= 3 and n[1].kind == nkIdent and n[2].kind in {nkStrLit..nkTripleStrLit}:
          result.tasks.add((n[1].ident.s, n[2].strVal))
      of "before", "after":
        #[
          before install do:
            exec "git submodule update --init"
            var make = "make"
            when defined(windows):
              make = "mingw32-make"
            exec make
        ]#
        if n.len >= 3 and n[1].kind == nkIdent and n[1].ident.s == "install":
          result.hasInstallHooks = true
      of "feature":
        echo "FEATURE: nimble parser "
        if n.len >= 3:
          var features = newSeq[string]()
          for c in n:
            if c.kind != nkStrLit:
              handleError(conf, n.info, "feature requires string literals")
              result.hasErrors = true
            else:
              features.add(c.strVal)
          for f in features:
            result.features[f] = newSeq[string]()
            extract(n[^1], conf, f, result)
      else:
        discard
  of nkAsgn, nkFastAsgn:
    if n[0].kind == nkIdent and eqIdent(n[0].ident.s, "srcDir"):
      if n[1].kind in {nkStrLit..nkTripleStrLit}:
        result.srcDir = Path n[1].strVal
      else:
        handleError(conf, n[1].info, "assignments to 'srcDir' must be string literals")
        result.hasErrors = true
    elif n[0].kind == nkIdent and eqIdent(n[0].ident.s, "version"):
      if n[1].kind in {nkStrLit..nkTripleStrLit}:
        result.version = n[1].strVal
      else:
        handleError(conf, n[1].info, "assignments to 'version' must be string literals")
        result.hasErrors = true
  of nkWhenStmt:
    # handles basic when statements for os
    if n[0].kind == nkElifBranch:
      let cond = n[0][0]
      let body = n[0][1]

      if cond.kind == nkPrefix: # handle when not defined
        if cond[0].kind == nkIdent and cond[0].ident.s == "not":
          let notCond = cond[1]
          let name = getDefinedName(notCond)
          if name.len > 0:
            if not evalBasicDefines(name):
              extract(body, conf, currFeature, result)
      elif getDefinedName(cond) != "": # handle when defined
        let name = getDefinedName(cond)
        if evalBasicDefines(name):
          extract(body, conf, currFeature, result)
      elif cond.kind == nkInfix: # handle when or
        if cond[0].kind == nkIdent and cond[0].ident.s == "or":
          let orLeft = getDefinedName(cond[1])
          let orRight = getDefinedName(cond[2])
          if orLeft.len > 0 or orRight.len > 0:
            if evalBasicDefines(orLeft):
              extract(body, conf, currFeature, result)
            elif evalBasicDefines(orRight):
              extract(body, conf, currFeature, result)
              
  else:
    discard

proc extractRequiresInfo*(nimbleFile: Path): NimbleFileInfo =
  ## Extract the `requires` information from a Nimble file. This does **not**
  ## evaluate the Nimble file. Errors are produced on stderr/stdout and are
  ## formatted as the Nim compiler does it. The parser uses the Nim compiler
  ## as an API. The result can be empty, this is not an error, only parsing
  ## errors are reported.
  var conf = newConfigRef()
  conf.foreignPackageNotes = {}
  conf.notes = {}
  conf.mainPackageNotes = {}
  conf.errorMax = high(int)
  conf.structuredErrorHook = proc (config: ConfigRef; info: TLineInfo; msg: string;
                                severity: Severity) {.gcsafe.} =
    handleError(config, info, warnUser, msg)

  let fileIdx = fileInfoIdx(conf, AbsoluteFile nimbleFile)
  var parser: Parser
  parser.lex.errorHandler = proc (config: ConfigRef, info: TLineInfo, mk: TMsgKind, msg: string;) {.closure, gcsafe.} =
    handleError(config, info, mk, msg)

  if setupParser(parser, fileIdx, newIdentCache(), conf):
    extract(parseAll(parser), conf, "", result)
    closeParser(parser)
  result.hasErrors = result.hasErrors or conf.errorCounter > 0

type
  PluginInfo* = object
    builderPatterns*: seq[(string, string)]

proc extractPlugin(nimscriptFile: string; n: PNode; conf: ConfigRef; result: var PluginInfo) =
  case n.kind
  of nkStmtList, nkStmtListExpr:
    for child in n:
      extractPlugin(nimscriptFile, child, conf, result)
  of nkCallKinds:
    if n[0].kind == nkIdent:
      case n[0].ident.s
      of "builder":
        if n.len >= 3 and n[1].kind in {nkStrLit..nkTripleStrLit}:
          result.builderPatterns.add((n[1].strVal, nimscriptFile))
      else: discard
  else:
    discard

proc extractPluginInfo*(nimscriptFile: string; info: var PluginInfo) =
  var conf = newConfigRef()
  conf.foreignPackageNotes = {}
  conf.notes = {}
  conf.mainPackageNotes = {}

  let fileIdx = fileInfoIdx(conf, AbsoluteFile nimscriptFile)
  var parser: Parser
  if setupParser(parser, fileIdx, newIdentCache(), conf):
    extractPlugin(nimscriptFile, parseAll(parser), conf, info)
    closeParser(parser)

const Operators* = {'<', '>', '=', '&', '@', '!', '^'}

proc token(s: string; idx: int; lit: var string): int =
  var i = idx
  if i >= s.len: return i
  while s[i] in Whitespace: inc(i)
  case s[i]
  of Letters, '#':
    lit.add s[i]
    inc i
    while i < s.len and s[i] notin (Whitespace + {'@', '#'}):
      lit.add s[i]
      inc i
  of '0'..'9':
    while i < s.len and s[i] in {'0'..'9', '.'}:
      lit.add s[i]
      inc i
  of '"':
    inc i
    while i < s.len and s[i] != '"':
      lit.add s[i]
      inc i
    inc i
  of Operators:
    while i < s.len and s[i] in Operators:
      lit.add s[i]
      inc i
  else:
    lit.add s[i]
    inc i
  result = i

iterator tokenizeRequires*(s: string): string =
  var start = 0
  var tok = ""
  while start < s.len:
    tok.setLen 0
    start = token(s, start, tok)
    yield tok

when isMainModule:
  for x in tokenizeRequires("jester@#head >= 1.5 & <= 1.8"):
    echo x

  let info = extractRequiresInfo(Path"tests/test_data/bad.nimble")
  echo "bad nimble info: ", repr(info)
