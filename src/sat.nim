## SAT solver
## (c) 2021 Andreas Rumpf
## Based on explanations and Haskell code from
## https://andrew.gibiansky.com/blog/verification/writing-a-sat-solver/

## Formulars as packed ASTs, no pointers no cry. Solves formulars with many
## thousands of variables in no time.

import satvars

type
  FormKind* = enum
    FalseForm, TrueForm, VarForm, NotForm, AndForm, OrForm, ExactlyOneOfForm, EqForm # 8 so the last 3 bits
  Atom = distinct BaseType
  Formular* = seq[Atom] # linear storage

const
  KindBits = 3
  KindMask = 0b111

template kind(a: Atom): FormKind = FormKind(BaseType(a) and KindMask)
template intVal(a: Atom): BaseType = BaseType(a) shr KindBits

proc newVar*(val: VarId): Atom {.inline.} =
  Atom((BaseType(val) shl KindBits) or BaseType(VarForm))

proc newOperation(k: FormKind; val: BaseType): Atom {.inline.} =
  Atom((val shl KindBits) or BaseType(k))

proc trueLit(): Atom {.inline.} = Atom(TrueForm)
proc falseLit(): Atom {.inline.} = Atom(FalseForm)

proc lit(k: FormKind): Atom {.inline.} = Atom(k)

when false:
  proc isTrueLit(a: Atom): bool {.inline.} = a.kind == TrueForm
  proc isFalseLit(a: Atom): bool {.inline.} = a.kind == FalseForm

proc varId(a: Atom): VarId =
  assert a.kind == VarForm
  result = VarId(BaseType(a) shr KindBits)

type
  PatchPos = distinct int
  FormPos = distinct int

proc prepare(dest: var Formular; source: Formular; sourcePos: FormPos): PatchPos =
  result = PatchPos dest.len
  dest.add source[sourcePos.int]

proc prepare(dest: var Formular; k: FormKind): PatchPos =
  result = PatchPos dest.len
  dest.add newOperation(k, 1)

proc patch(f: var Formular; pos: PatchPos) =
  let pos = pos.int
  let k = f[pos].kind
  assert k > VarForm
  let distance = int32(f.len - pos)
  f[pos] = newOperation(k, distance)

proc nextChild(f: Formular; pos: var int) {.inline.} =
  let x = f[int pos]
  pos += (if x.kind <= VarForm: 1 else: int(intVal(x)))

iterator sonsReadonly(f: Formular; n: FormPos): FormPos =
  var pos = n.int
  assert f[pos].kind > VarForm
  let last = pos + f[pos].intVal
  inc pos
  while pos < last:
    yield FormPos pos
    nextChild f, pos

iterator sons(dest: var Formular; source: Formular; n: FormPos): FormPos =
  let patchPos = prepare(dest, source, n)
  for x in sonsReadonly(source, n): yield x
  patch dest, patchPos

proc copyTree(dest: var Formular; source: Formular; n: FormPos) =
  let x = source[int n]
  let len = (if x.kind <= VarForm: 1 else: int(intVal(x)))
  for i in 0..<len:
    dest.add source[i+n.int]

# String representation

proc toString(dest: var string; f: Formular; n: FormPos; varRepr: proc (dest: var string; i: int)) =
  assert n.int >= 0
  assert n.int < f.len
  case f[n.int].kind
  of FalseForm: dest.add 'F'
  of TrueForm: dest.add 'T'
  of VarForm:
    varRepr dest, varId(f[n.int]).int
  else:
    case f[n.int].kind
    of AndForm:
      dest.add "(&"
    of OrForm:
      dest.add "(|"
    of ExactlyOneOfForm:
      dest.add "(1=="
    of NotForm:
      dest.add "(~"
    of EqForm:
      dest.add "(<->"
    else: assert false, "cannot happen"
    var i = 0
    for child in sonsReadonly(f, n):
      if i > 0: dest.add ' '
      toString(dest, f, child, varRepr)
      inc i
    dest.add ')'

proc `$`*(f: Formular): string =
  assert f.len > 0
  toString(result, f, FormPos 0, proc (dest: var string; x: int) =
    dest.add 'v'
    dest.addInt x
  )

proc `$`*(f: Formular; varRepr: proc (dest: var string; i: int)): string =
  assert f.len > 0
  toString(result, f, FormPos 0, varRepr)

type
  Builder* = object
    f: Formular
    toPatch: seq[PatchPos]

proc isEmpty*(b: Builder): bool {.inline.} =
  b.f.len == 0 or b.f.len == 1 and b.f[0].kind in {NotForm, AndForm, OrForm, ExactlyOneOfForm, EqForm}

proc openOpr*(b: var Builder; k: FormKind) =
  b.toPatch.add PatchPos b.f.len
  b.f.add newOperation(k, 0)

proc closeOpr*(b: var Builder) =
  patch(b.f, b.toPatch.pop())

proc add*(b: var Builder; a: Atom) =
  b.f.add a

proc add*(b: var Builder; a: VarId) =
  b.f.add newVar(a)

proc addNegated*(b: var Builder; a: VarId) =
  b.openOpr NotForm
  b.f.add newVar(a)
  b.closeOpr

proc getPatchPos*(b: Builder): PatchPos =
  PatchPos b.f.len

proc resetToPatchPos*(b: var Builder; p: PatchPos) =
  b.f.setLen p.int

proc deleteLastNode*(b: var Builder) =
  b.f.setLen b.f.len - 1

type
  BuilderPos* = distinct int

proc rememberPos*(b: Builder): BuilderPos {.inline.} = BuilderPos b.f.len
proc rewind*(b: var Builder; pos: BuilderPos) {.inline.} = setLen b.f, int(pos)

proc toForm*(b: var Builder): Formular =
  assert b.toPatch.len == 0, "missing `closeOpr` calls"
  result = move b.f

proc isValid*(v: VarId): bool {.inline.} = v.int32 >= 0

proc freeVariable(f: Formular): VarId =
  ## returns NoVar if there is no free variable.
  for i in 0..<f.len:
    if f[i].kind == VarForm: return varId(f[i])
  return NoVar

proc maxVariable*(f: Formular): int =
  result = -1
  for i in 0..<f.len:
    if f[i].kind == VarForm: result = max(result, int varId(f[i]))
  inc result

proc createSolution*(f: Formular): Solution =
  satvars.createSolution(maxVariable f)

proc simplify(dest: var Formular; source: Formular; n: FormPos; sol: Solution): FormKind =
  ## Returns either a Const constructor or a simplified expression;
  ## if the result is not a Const constructor, it guarantees that there
  ## are no Const constructors in the source tree further down.
  let s = source[n.int]
  result = s.kind
  case result
  of FalseForm, TrueForm:
    # nothing interesting to do:
    dest.add s
  of VarForm:
    let v = sol.getVar(varId(s))
    case v
    of SetToFalse:
      dest.add falseLit()
      result = FalseForm
    of SetToTrue:
      dest.add trueLit()
      result = TrueForm
    else:
      dest.add s
  of NotForm:
    let oldLen = dest.len
    var inner: FormKind
    for child in sons(dest, source, n):
      inner = simplify(dest, source, child, sol)
    if inner in {FalseForm, TrueForm}:
      setLen dest, oldLen
      result = (if inner == FalseForm: TrueForm else: FalseForm)
      dest.add lit(result)
  of AndForm, OrForm:
    let (tForm, fForm) = if result == AndForm: (TrueForm, FalseForm)
                         else:                 (FalseForm, TrueForm)

    let initialLen = dest.len
    var childCount = 0
    for child in sons(dest, source, n):
      let oldLen = dest.len

      let inner = simplify(dest, source, child, sol)
      # ignore 'and T' or 'or F' subexpressions:
      if inner == tForm:
        setLen dest, oldLen
      elif inner == fForm:
        # 'and F' is always false and 'or T' is always true:
        result = fForm
        break
      else:
        inc childCount

    if result == fForm:
      setLen dest, initialLen
      dest.add lit(result)
    elif childCount == 1:
      for i in initialLen..<dest.len-1:
        dest[i] = dest[i+1]
      setLen dest, dest.len-1
      result = dest[initialLen].kind
    elif childCount == 0:
      # that means all subexpressions where ignored:
      setLen dest, initialLen
      result = tForm
      dest.add lit(result)
  of EqForm:
    let oldLen = dest.len
    var inner: FormKind
    var childCount = 0
    var interestingChild = FormPos(n.int+1)
    for child in sons(dest, source, n):
      inner = simplify(dest, source, child, sol)
      if inner notin {TrueForm, FalseForm}:
        interestingChild = child
      inc childCount

    assert childCount == 2, "EqForm must have exactly 2 children"
    # simplify: `T == x` to `x` and `F == x` to `not x`:
    if inner == TrueForm:
      setLen dest, oldLen
      copyTree dest, source, interestingChild
    elif inner == FalseForm:
      setLen dest, oldLen
      let pp = prepare(dest, NotForm)
      copyTree dest, source, interestingChild
      dest.patch pp
  of ExactlyOneOfForm:
    let initialLen = dest.len
    var childCount = 0
    var couldEval = 0
    for child in sons(dest, source, n):
      let oldLen = dest.len

      let inner = simplify(dest, source, child, sol)
      # ignore 'exactlyOneOf F' subexpressions:
      if inner == FalseForm:
        setLen dest, oldLen
      else:
        if inner == TrueForm:
          inc couldEval
        inc childCount

    if couldEval == childCount:
      setLen dest, initialLen
      if couldEval != 1:
        dest.add lit FalseForm
      else:
        dest.add lit TrueForm
    elif childCount == 1:
      for i in initialLen..<dest.len-1:
        dest[i] = dest[i+1]
      setLen dest, dest.len-1
      result = dest[initialLen].kind

proc satisfiable*(f: Formular; s: var Solution): bool =
  let v = freeVariable(f)
  if v == NoVar:
    result = f[0].kind == TrueForm
  else:
    result = false
    # We have a variable to guess.
    # Construct the two guesses.
    # Return whether either one of them works.
    let prevValue = s.getVar(v)
    s.setVar(v, SetToFalse)

    var falseGuess: Formular
    let res = simplify(falseGuess, f, FormPos 0, s)

    if res == TrueForm:
      result = true
    else:
      result = satisfiable(falseGuess, s)
      if not result:
        s.setVar(v, SetToTrue)

        var trueGuess: Formular
        let res = simplify(trueGuess, f, FormPos 0, s)

        if res == TrueForm:
          result = true
        else:
          result = satisfiable(trueGuess, s)
          if not result:
            # Revert the assignment after trying the second option
            s.setVar(v, prevValue)

proc appender(dest: var string; x: int) =
  dest.add 'v'
  dest.addInt x

proc tos(f: Formular; n: FormPos): string =
  result = ""
  toString(result, f, n, appender)

proc eval(f: Formular; n: FormPos; s: Solution): bool =
  assert n.int >= 0
  assert n.int < f.len
  case f[n.int].kind
  of FalseForm: result = false
  of TrueForm: result = true
  of VarForm:
    let v = varId(f[n.int])
    result = s.isTrue(v)
  else:
    case f[n.int].kind
    of AndForm:
      for child in sonsReadonly(f, n):
        if not eval(f, child, s): return false
      return true
    of OrForm:
      for child in sonsReadonly(f, n):
        if eval(f, child, s): return true
      return false
    of ExactlyOneOfForm:
      var conds = 0
      for child in sonsReadonly(f, n):
        if eval(f, child, s): inc conds
      result = conds == 1
    of NotForm:
      for child in sonsReadonly(f, n):
        if not eval(f, child, s): return true
      return false
    of EqForm:
      var last = -1
      for child in sonsReadonly(f, n):
        if last == -1:
          last = ord(eval(f, child, s))
        else:
          let now = ord(eval(f, child, s))
          return last == now
      return false
    else: assert false, "cannot happen"

proc eval*(f: Formular; s: Solution): bool =
  eval(f, FormPos(0), s)

import std / [strutils, parseutils]

proc parseFormular*(s: string; i: int; b: var Builder): int

proc parseOpr(s: string; i: int; b: var Builder; kind: FormKind; opr: string): int =
  result = i
  if not continuesWith(s, opr, result):
    quit "expected: " & opr
  inc result, opr.len
  b.openOpr kind
  while result < s.len and s[result] != ')':
    result = parseFormular(s, result, b)
  b.closeOpr
  if result < s.len and s[result] == ')':
    inc result
  else:
    quit "exptected: )"

proc parseFormular(s: string; i: int; b: var Builder): int =
  result = i
  while result < s.len and s[result] in Whitespace: inc result
  if s[result] == 'v':
    var number = 0
    inc result
    let span = parseInt(s, number, result)
    if span == 0: quit "invalid variable name"
    inc result, span
    b.add VarId(number)
  elif s[result] == 'T':
    b.add trueLit()
    inc result
  elif s[result] == 'F':
    b.add falseLit()
    inc result
  elif s[result] == '(':
    inc result
    case s[result]
    of '~':
      inc result
      b.openOpr NotForm
      result = parseFormular(s, result, b)
      b.closeOpr
      if s[result] == ')': inc result
      else: quit ") expected"
    of '<':
      result = parseOpr(s, result, b, EqForm, "<->")
    of '|':
      result = parseOpr(s, result, b, OrForm, "|")
    of '&':
      result = parseOpr(s, result, b, AndForm, "&")
    of '1':
      result = parseOpr(s, result, b, ExactlyOneOfForm, "1==")
    else:
      quit "unknown operator: " & s[result]
  else:
    quit "( expected, but got: " & s[result]

when isMainModule:
  proc main =
    var b: Builder
    b.openOpr(AndForm)

    b.openOpr(OrForm)
    b.add newVar(VarId 1)
    b.add newVar(VarId 2)
    b.add newVar(VarId 3)
    b.add newVar(VarId 4)
    b.closeOpr

    b.openOpr(ExactlyOneOfForm)
    b.add newVar(VarId 5)
    b.add newVar(VarId 6)
    b.add newVar(VarId 7)

    #b.openOpr(NotForm)
    b.add newVar(VarId 8)
    #b.closeOpr
    b.closeOpr

    b.add newVar(VarId 5)
    b.add newVar(VarId 6)
    b.closeOpr

    let f = toForm(b)
    echo "original: "
    echo f

    let m = maxVariable(f)
    var s = createSolution(m)
    echo "is solvable? ", satisfiable(f, s)
    echo "solution"
    for i in 0..<m:
      echo "v", i, " ", s.getVar(VarId(m))

  proc main2 =
    var b: Builder
    b.openOpr(AndForm)

    b.openOpr(EqForm)
    b.add newVar(VarId 9)

    b.openOpr(OrForm)
    b.add newVar(VarId 1)
    b.add newVar(VarId 2)
    b.add newVar(VarId 3)
    b.add newVar(VarId 4)
    b.closeOpr # OrForm
    b.closeOpr # EqForm

    b.openOpr(ExactlyOneOfForm)
    b.add newVar(VarId 5)
    b.add newVar(VarId 6)
    b.add newVar(VarId 7)

    #b.openOpr(NotForm)
    b.add newVar(VarId 8)
    #b.closeOpr
    b.closeOpr

    b.add newVar(VarId 6)
    b.add newVar(VarId 1)
    b.closeOpr

    let f = toForm(b)
    echo "original: "
    echo f

    let m = maxVariable(f)
    var s = createSolution(m)
    echo "is solvable? ", satisfiable(f, s)
    echo "solution"
    for i in 0..<m:
      echo "v", i, " ", s.getVar(VarId(m))

  main()
  main2()

  const
    myFormularU = """(&v0 v1 (~v5) (<->v0 (1==v6)) (<->v1 (1==v7 v8)) (<->v2 (1==v9 v10)) (<->v3 (1==v11)) (<->v4 (1==v12 v13)) (<->v14 (1==v8 v7)) (<->v15 (1==v9)) (<->v16 (1==v10 v9)) (<->v17 (1==v11)) (<->v18 (1==v11)) (<->v19 (1==v13)) (|(~v6) v14) (|(~v7) v15) (|(~v8) v16) (|(~v9) v17) (|(~v10) v18) (|(~v11) v19) (|(~v12) v20))"""
    myFormular = """(&(1==v0) (1==v1 v2) (|(1==v3 v4) (&(~v3) (~v4))) (|(1==v5)
(&(~v5))) (|(1==v6 v7) (&(~v6) (~v7))) (|(~v8) (1==v2 v1)) (|(~v9) (1==v3))
(|(~v10) (1==v4 v3)) (|(~v11) (1==v5)) (|(~v12) (1==v5)) (|(~v13) (1==v7))
(|(~v0) v8) (|(~v1) v9) (|(~v2) v10) (|(~v3) v11) (|(~v4) v12) (|(~v5) v13) (|(~v6) v14))"""

    mySol = @[
      SetToTrue, #v0
      SetToFalse, #v1
      SetToTrue, #v2
      SetToFalse, #v3
      SetToTrue, #v4
      SetToTrue, #v5
      SetToFalse, #v6
      SetToTrue, #v7
      SetToTrue, #v8
      SetToFalse, #v9
      SetToTrue, # v10
      SetToFalse, # v11
      SetToTrue, # v12
      SetToTrue, # v13
      SetToFalse,
      SetToFalse,
      SetToFalse,
      SetToFalse,
      SetToFalse,
      SetToFalse,
      SetToFalse
    ]

  proc main3() =
    var b: Builder

    discard parseFormular(myFormular, 0, b)

    let f = toForm(b)
    echo "original: "
    echo f

    var s = createSolution(f)
    echo "is solvable? ", satisfiable(f, s)


    echo f.eval(s)

    var mx = createSolution(mySol.len)
    for i in 0..<mySol.len:
      mx.setVar VarId(i), mySol[i]
    echo f.eval(mx)

  main3()

