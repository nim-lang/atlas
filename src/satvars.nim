## SAT solver variables
## (c) 2024 Andreas Rumpf

import std / hashes

# Thanks to this encoding `x or y` always produces the correct outcome for variable
# bindings:
const
  DontCare* = 0b00'u64
  SetToTrue* = 0b01'u64
  SetToFalse* = 0b10'u64
  IsInvalid* = 0b11'u64

  Mask = 0b11'u64

  BitsPerWord = 64
  VarsPerWord = BitsPerWord div 2

type
  BaseType* = int32
  VarId* = distinct BaseType

  Solution* = object
    x: seq[uint64]
    invalid*: bool

const
  NoVar* = VarId(-1)

proc `==`*(a, b: VarId): bool {.borrow.}
proc hash*(a: VarId): Hash {.borrow.}

proc createSolution*(maxVars: int): Solution =
  var space = maxVars div VarsPerWord
  if (maxVars mod VarsPerWord) != 0: inc space
  result = Solution(x: newSeq[uint64](space))

proc index(v: VarId): (int32, int32) {.inline.} =
  result = (v.BaseType div VarsPerWord, (v.BaseType mod VarsPerWord) * 2)

proc setVar*(b: var Solution; v: VarId; val: uint64) =
  let (va, vb) = index(v)
  b.x[va] = b.x[va] and not (Mask shl vb) or (val shl vb)

proc getVar*(b: Solution; v: VarId): uint64 =
  let (va, vb) = index(v)
  (b.x[va] shr vb) and Mask

proc isTrue*(b: Solution; v: VarId): bool {.inline.} =
  b.getVar(v) == SetToTrue

proc containsInvalid(x: uint64): bool =
  var x = x
  while x != 0'u64:
    if (x and 0b1111_1111) == 0b0000_0000: x = x shr 8
    if (x and 0b1111) == 0b0000: x = x shr 4

    if (x and Mask) == IsInvalid: return true
    x = x shr 2

proc combine*(dest: var Solution; other: Solution) =
  assert dest.x.len == other.x.len
  if dest.invalid: return
  dest.invalid = other.invalid
  for i in 0..<dest.x.len:
    dest.x[i] = dest.x[i] or other.x[i]
    if containsInvalid(dest.x[i]):
      dest.invalid = true
      # break: no `break` here hoping for vectorization.

when isMainModule:
  var b = createSolution(900)
  b.setVar VarId(899), SetToTrue
  echo getVar(b, VarId(1))

  var b2 = createSolution(900)
  b2.setVar VarId(899), SetToFalse

  combine(b, b2)

  echo b.invalid
