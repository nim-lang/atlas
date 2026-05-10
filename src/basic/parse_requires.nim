## Utility API for Nim package managers.
## (c) 2021 Andreas Rumpf

import std / [strutils, paths, tables, options]

import compiler / [ast, idents, msgs, syntaxes, options, pathutils, lineinfos]
import reporters

type
  NimbleFileInfo* = object
    requires*: seq[string]
    features*: Table[string, seq[string]]
    name*: string
    author*: string
    description*: string
    license*: string
    srcDir*: Path
    binDir*: Path
    skipDirs*: seq[string]
    skipFiles*: seq[string]
    skipExt*: seq[string]
    installDirs*: seq[string]
    installFiles*: seq[string]
    installExt*: seq[string]
    bin*: seq[string]
    namedBin*: Table[string, string]
    backend*: string
    hasBin*: bool
    version*: string
    tasks*: seq[(string, string)]
    hasInstallHooks*: bool
    hasErrors*: bool

proc eqIdent(a, b: string): bool {.inline.} =
  cmpIgnoreCase(a, b) == 0 and a[0] == b[0]

proc isIdent(n: PNode; name: string): bool {.inline.} =
  n.kind == nkIdent and eqIdent(n.ident.s, name)

proc stringLit(n: PNode; value: var string): bool =
  if n.kind in {nkStrLit..nkTripleStrLit}:
    value = n.strVal
    result = true

proc boolLit(n: PNode; value: var bool): bool =
  if n.kind == nkIdent:
    if eqIdent(n.ident.s, "true"):
      value = true
      result = true
    elif eqIdent(n.ident.s, "false"):
      value = false
      result = true

proc extractStringSeq(n: PNode; values: var seq[string]): bool =
  case n.kind
  of nkPrefix:
    if n.len == 2 and isIdent(n[0], "@"):
      result = extractStringSeq(n[1], values)
  of nkBracket:
    result = true
    for child in n:
      var value = ""
      if child.stringLit(value):
        values.add value
      else:
        result = false
        break
  of nkStmtList, nkStmtListExpr:
    if n.len > 0:
      result = extractStringSeq(n.lastSon, values)
  else:
    discard

proc extractStringTable(n: PNode; values: var Table[string, string]): bool =
  case n.kind
  of nkDotExpr:
    if n.len == 2 and isIdent(n[1], "toTable"):
      result = extractStringTable(n[0], values)
  of nkCall:
    if n.len == 1 and n[0].kind == nkDotExpr and n[0].len == 2 and
        isIdent(n[0][1], "toTable"):
      result = extractStringTable(n[0][0], values)
  of nkTableConstr:
    result = true
    for child in n:
      if child.kind == nkExprColonExpr and child.len == 2:
        var key, value = ""
        if child[0].stringLit(key) and child[1].stringLit(value):
          values[key] = value
        else:
          result = false
          break
      else:
        result = false
        break
  of nkStmtList, nkStmtListExpr:
    if n.len > 0:
      result = extractStringTable(n.lastSon, values)
  else:
    discard

proc handleError(cfg: ConfigRef, li: TLineInfo, mk: TMsgKind, msg: string) =
  {.cast(gcsafe).}:
    info("atlas:nimbleparser", "error parsing \"$1\" at $2" % [msg, cfg.toFileLineCol(li), repr mk])

proc handleError(cfg: ConfigRef, mk: TMsgKind, li: TLineInfo, msg: string) =
  handleError(cfg, li, warnUser, msg)

proc handleError(cfg: ConfigRef, li: TLineInfo, msg: string) =
  handleError(cfg, warnUser, li, msg)

proc compileDefines(): Table[string, bool] =
  result = initTable[string, bool]()
  result["windows"] = defined(windows)
  result["posix"] = defined(posix)
  result["linux"] = defined(linux)
  result["android"] = defined(android)
  result["macosx"] = defined(macosx)
  result["freebsd"] = defined(freebsd)
  result["openbsd"] = defined(openbsd)
  result["netbsd"] = defined(netbsd)
  result["solaris"] = defined(solaris)
  result["bsd"] = defined(bsd)
  result["unix"] = defined(unix)
  result["amd64"] = defined(amd64)
  result["x86_64"] = defined(x86_64)
  result["i386"] = defined(i386)
  result["arm"] = defined(arm)
  result["arm64"] = defined(arm64)
  result["mips"] = defined(mips)
  result["powerpc"] = defined(powerpc)
  # Common additional switches used in nimble files
  result["js"] = defined(js)
  result["emscripten"] = defined(emscripten)
  result["wasm32"] = defined(wasm32)
  result["mingw"] = defined(mingw)

var definedSymbols: Table[string, bool] = compileDefines()

proc compileIntegerDefines(): Table[string, int] =
  result = initTable[string, int]()
  result["NimMajor"] = NimMajor
  result["NimMinor"] = NimMinor
  result["NimPatch"] = NimPatch

var definedIntegerSymbols: Table[string, int] = compileIntegerDefines()

proc getBasicDefines*(): Table[string, bool] =
  return definedSymbols

proc setBasicDefines*(sym: string, value: bool) {.inline.} =
  definedSymbols[sym] = value

proc getBasicIntegerDefines*(): Table[string, int] =
  return definedIntegerSymbols

proc setBasicIntegerDefines*(sym: string, value: int) {.inline.} =
  definedIntegerSymbols[sym] = value

proc evalBasicDefines(sym: string; conf: ConfigRef; n: PNode): Option[bool] =
  if sym in definedSymbols:
    return some(definedSymbols[sym])
  else:
    handleError(conf, n.info, "undefined symbol: " & sym)
    return none(bool)

proc evalIntegerSymbol(sym: string; conf: ConfigRef; n: PNode): Option[int] =
  if sym in definedIntegerSymbols:
    return some(definedIntegerSymbols[sym])
  else:
    handleError(conf, n.info, "undefined integer symbol: " & sym)
    return none(int)

proc evalIntegerExpression(n: PNode; conf: ConfigRef): Option[int] =
  case n.kind
  of nkIntLit..nkUInt64Lit:
    return some(int(n.intVal))
  of nkIdent:
    return evalIntegerSymbol(n.ident.s, conf, n)
  of nkPar:
    if n.len == 1:
      return evalIntegerExpression(n[0], conf)
  else:
    discard
  return none(int)

proc evalIntegerTupleExpression(n: PNode; conf: ConfigRef): Option[seq[int]] =
  case n.kind
  of nkPar, nkTupleConstr:
    if n.len == 1:
      let value = evalIntegerExpression(n[0], conf)
      if value.isSome:
        return some(@[value.get])
    else:
      var values: seq[int]
      for child in n:
        let value = evalIntegerExpression(child, conf)
        if value.isNone:
          return none(seq[int])
        values.add value.get
      return some(values)
  else:
    let value = evalIntegerExpression(n, conf)
    if value.isSome:
      return some(@[value.get])
  return none(seq[int])

proc cmpIntegerTuple(a, b: seq[int]): int =
  for i in 0 ..< min(a.len, b.len):
    result = cmp(a[i], b[i])
    if result != 0:
      return
  result = cmp(a.len, b.len)

proc evalIntegerComparison(op: string; left, right: seq[int]): Option[bool] =
  let c = cmpIntegerTuple(left, right)
  case op
  of "==": some(c == 0)
  of "!=": some(c != 0)
  of "<": some(c < 0)
  of "<=": some(c <= 0)
  of ">": some(c > 0)
  of ">=": some(c >= 0)
  else: none(bool)

proc evalBooleanCondition(n: PNode; conf: ConfigRef): Option[bool] =
  ## Recursively evaluate boolean conditions in when statements
  case n.kind
  of nkCall:
    # Handle defined(platform) calls
    if n[0].kind == nkIdent and n[0].ident.s == "defined" and n.len == 2:
      if n[1].kind == nkIdent:
        return evalBasicDefines(n[1].ident.s, conf, n)
    return none(bool)
  of nkInfix:
    # Handle binary operators: and, or
    if n[0].kind == nkIdent and n.len == 3:
      case n[0].ident.s
      of "and":
        let left = evalBooleanCondition(n[1], conf)
        let right = evalBooleanCondition(n[2], conf)
        if left.isSome and right.isSome:
          return some(left.get and right.get)
        else:
          return none(bool)
      of "or":
        let left = evalBooleanCondition(n[1], conf)
        let right = evalBooleanCondition(n[2], conf)
        if left.isSome and right.isSome:
          return some(left.get or right.get)
        else:
          return none(bool)
      of "xor":
        let left = evalBooleanCondition(n[1], conf)
        let right = evalBooleanCondition(n[2], conf)
        if left.isSome and right.isSome:
          return some(left.get xor right.get)
        else:
          return none(bool)
      of "==", "!=", "<", "<=", ">", ">=":
        let left = evalIntegerTupleExpression(n[1], conf)
        let right = evalIntegerTupleExpression(n[2], conf)
        if left.isSome and right.isSome:
          return evalIntegerComparison(n[0].ident.s, left.get, right.get)
        else:
          return none(bool)
    return none(bool)
  of nkPrefix:
    # Handle unary operators: not
    if n[0].kind == nkIdent and n[0].ident.s == "not" and n.len == 2:
      let inner = evalBooleanCondition(n[1], conf)
      if inner.isSome:
        return some(not inner.get)
      else:
        return none(bool)
    return none(bool)
  of nkPar:
    # Handle parentheses - evaluate the content
    if n.len == 1:
      return evalBooleanCondition(n[0], conf)
    return none(bool)
  of nkIdent:
    # Handle direct identifiers (though this shouldn't happen in practice)
    return evalBasicDefines(n.ident.s, conf, n)
  else:
    return none(bool)

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
            # result.hasErrors = true
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
        if n.len >= 3:
          var features = newSeq[string]()
          for i in 1 ..< n.len - 1:
            let c = n[i]
            if c.kind == nkStrLit:
              features.add(c.strVal)
            else:
              handleError(conf, n.info, "feature requires string literals")
              # result.hasErrors = true
          for f in features:
            result.features[f] = newSeq[string]()
            extract(n[^1], conf, f, result)
      else:
        discard
  of nkAsgn, nkFastAsgn:
    if n[0].kind == nkIdent and (eqIdent(n[0].ident.s, "packageName") or
        eqIdent(n[0].ident.s, "name")):
      if n[1].kind in {nkStrLit..nkTripleStrLit}:
        result.name = n[1].strVal
      else:
        handleError(conf, n[1].info, "assignments to 'packageName' must be string literals")
        # result.hasErrors = true
    elif n[0].kind == nkIdent and eqIdent(n[0].ident.s, "author"):
      if n[1].kind in {nkStrLit..nkTripleStrLit}:
        result.author = n[1].strVal
      else:
        handleError(conf, n[1].info, "assignments to 'author' must be string literals")
        # result.hasErrors = true
    elif n[0].kind == nkIdent and eqIdent(n[0].ident.s, "description"):
      if n[1].kind in {nkStrLit..nkTripleStrLit}:
        result.description = n[1].strVal
      else:
        handleError(conf, n[1].info, "assignments to 'description' must be string literals")
        # result.hasErrors = true
    elif n[0].kind == nkIdent and eqIdent(n[0].ident.s, "license"):
      if n[1].kind in {nkStrLit..nkTripleStrLit}:
        result.license = n[1].strVal
      else:
        handleError(conf, n[1].info, "assignments to 'license' must be string literals")
        # result.hasErrors = true
    elif n[0].kind == nkIdent and eqIdent(n[0].ident.s, "srcDir"):
      if n[1].kind in {nkStrLit..nkTripleStrLit}:
        result.srcDir = Path n[1].strVal
      else:
        handleError(conf, n[1].info, "assignments to 'srcDir' must be string literals")
        # result.hasErrors = true
    elif n[0].kind == nkIdent and eqIdent(n[0].ident.s, "version"):
      if n[1].kind in {nkStrLit..nkTripleStrLit}:
        result.version = n[1].strVal
      else:
        handleError(conf, n[1].info, "assignments to 'version' must be string literals")
        # result.hasErrors = true
    elif n[0].kind == nkIdent and eqIdent(n[0].ident.s, "binDir"):
      if n[1].kind in {nkStrLit..nkTripleStrLit}:
        result.binDir = Path n[1].strVal
      else:
        handleError(conf, n[1].info, "assignments to 'binDir' must be string literals")
        # result.hasErrors = true
    elif n[0].kind == nkIdent and eqIdent(n[0].ident.s, "skipDirs"):
      if not extractStringSeq(n[1], result.skipDirs):
        handleError(conf, n[1].info, "assignments to 'skipDirs' must be string literal sequences")
        # result.hasErrors = true
    elif n[0].kind == nkIdent and eqIdent(n[0].ident.s, "skipFiles"):
      if not extractStringSeq(n[1], result.skipFiles):
        handleError(conf, n[1].info, "assignments to 'skipFiles' must be string literal sequences")
        # result.hasErrors = true
    elif n[0].kind == nkIdent and eqIdent(n[0].ident.s, "skipExt"):
      if not extractStringSeq(n[1], result.skipExt):
        handleError(conf, n[1].info, "assignments to 'skipExt' must be string literal sequences")
        # result.hasErrors = true
    elif n[0].kind == nkIdent and eqIdent(n[0].ident.s, "installDirs"):
      if not extractStringSeq(n[1], result.installDirs):
        handleError(conf, n[1].info, "assignments to 'installDirs' must be string literal sequences")
        # result.hasErrors = true
    elif n[0].kind == nkIdent and eqIdent(n[0].ident.s, "installFiles"):
      if not extractStringSeq(n[1], result.installFiles):
        handleError(conf, n[1].info, "assignments to 'installFiles' must be string literal sequences")
        # result.hasErrors = true
    elif n[0].kind == nkIdent and eqIdent(n[0].ident.s, "installExt"):
      if not extractStringSeq(n[1], result.installExt):
        handleError(conf, n[1].info, "assignments to 'installExt' must be string literal sequences")
        # result.hasErrors = true
    elif n[0].kind == nkIdent and eqIdent(n[0].ident.s, "bin"):
      var bin: seq[string]
      if extractStringSeq(n[1], bin):
        result.bin = bin
        if bin.len > 0:
          result.hasBin = true
      else:
        handleError(conf, n[1].info, "assignments to 'bin' must be string literal sequences")
        # result.hasErrors = true
    elif n[0].kind == nkIdent and eqIdent(n[0].ident.s, "namedBin"):
      var namedBin: Table[string, string]
      if extractStringTable(n[1], namedBin):
        result.namedBin = namedBin
        if namedBin.len > 0:
          result.hasBin = true
      else:
        handleError(conf, n[1].info, "assignments to 'namedBin' must be string tables")
        # result.hasErrors = true
    elif n[0].kind == nkBracketExpr and n[0].len == 2 and isIdent(n[0][0], "namedBin"):
      var key, value = ""
      if n[0][1].stringLit(key) and n[1].stringLit(value):
        result.namedBin[key] = value
        result.hasBin = true
      else:
        handleError(conf, n.info, "assignments to 'namedBin[...]' must use string literals")
        # result.hasErrors = true
    elif n[0].kind == nkIdent and eqIdent(n[0].ident.s, "backend"):
      if n[1].kind in {nkStrLit..nkTripleStrLit}:
        result.backend = n[1].strVal
      else:
        handleError(conf, n[1].info, "assignments to 'backend' must be string literals")
        # result.hasErrors = true
    elif n[0].kind == nkIdent and eqIdent(n[0].ident.s, "hasBin"):
      var hasBin = false
      if boolLit(n[1], hasBin):
        result.hasBin = hasBin
      else:
        handleError(conf, n[1].info, "assignments to 'hasBin' must be boolean literals")
        # result.hasErrors = true
  of nkWhenStmt:
    # Handle full when/elif/else chains.
    var taken = false
    var hasElse = false

    # Iterate all branches; choose the first with condition evaluating to true.
    for i in 0 ..< n.len:
      let br = n[i]
      case br.kind
      of nkElifBranch:
        if br.len >= 2:
          let cond = br[0]
          let body = br[1]
          let condResult = evalBooleanCondition(cond, conf)
          if condResult.isSome:
            if condResult.get and not taken:
              extract(body, conf, currFeature, result)
              taken = true
          else:
            handleError(conf, br.info, "when condition is not boolean or uses undefined symbols")
            # Unknown condition -> treat as not taken; continue scanning.
      of nkElse:
        hasElse = true
        # Process later only if no prior branch was taken.
      else:
        discard

    # If no condition was satisfied and an else branch exists, process it.
    if not taken and hasElse:
      let elseBr = n[^1]
      if elseBr.kind == nkElse and elseBr.len >= 1:
        extract(elseBr[0], conf, currFeature, result)
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

  let badInfo = extractRequiresInfo(Path"tests/test_data/bad.nimble")
  echo "bad nimble info: ", repr(badInfo)
  
  echo "\n--- Testing boolean logic parsing ---"
  let jesterInfo = extractRequiresInfo(Path"tests/test_data/jester_boolean.nimble")
  echo "jester boolean nimble info: ", repr(jesterInfo)
