#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Small, dependency-free SHA-256 implementation for downloaded release files.

type Sha256State = object
  buffer: array[64, byte]
  bufferLen: int
  bitLen: uint64
  hash: array[8, uint32]

const RoundConstants: array[64, uint32] = [
  0x428a2f98'u32, 0x71374491'u32, 0xb5c0fbcf'u32, 0xe9b5dba5'u32,
  0x3956c25b'u32, 0x59f111f1'u32, 0x923f82a4'u32, 0xab1c5ed5'u32,
  0xd807aa98'u32, 0x12835b01'u32, 0x243185be'u32, 0x550c7dc3'u32,
  0x72be5d74'u32, 0x80deb1fe'u32, 0x9bdc06a7'u32, 0xc19bf174'u32,
  0xe49b69c1'u32, 0xefbe4786'u32, 0x0fc19dc6'u32, 0x240ca1cc'u32,
  0x2de92c6f'u32, 0x4a7484aa'u32, 0x5cb0a9dc'u32, 0x76f988da'u32,
  0x983e5152'u32, 0xa831c66d'u32, 0xb00327c8'u32, 0xbf597fc7'u32,
  0xc6e00bf3'u32, 0xd5a79147'u32, 0x06ca6351'u32, 0x14292967'u32,
  0x27b70a85'u32, 0x2e1b2138'u32, 0x4d2c6dfc'u32, 0x53380d13'u32,
  0x650a7354'u32, 0x766a0abb'u32, 0x81c2c92e'u32, 0x92722c85'u32,
  0xa2bfe8a1'u32, 0xa81a664b'u32, 0xc24b8b70'u32, 0xc76c51a3'u32,
  0xd192e819'u32, 0xd6990624'u32, 0xf40e3585'u32, 0x106aa070'u32,
  0x19a4c116'u32, 0x1e376c08'u32, 0x2748774c'u32, 0x34b0bcb5'u32,
  0x391c0cb3'u32, 0x4ed8aa4a'u32, 0x5b9cca4f'u32, 0x682e6ff3'u32,
  0x748f82ee'u32, 0x78a5636f'u32, 0x84c87814'u32, 0x8cc70208'u32,
  0x90befffa'u32, 0xa4506ceb'u32, 0xbef9a3f7'u32, 0xc67178f2'u32
]

func rotateRight(value: uint32; bits: int): uint32 =
  (value shr bits) or (value shl (32 - bits))

proc transform(state: var Sha256State) =
  var schedule: array[64, uint32]
  for i in 0..<16:
    let offset = i * 4
    schedule[i] =
      (uint32(state.buffer[offset]) shl 24) or
      (uint32(state.buffer[offset + 1]) shl 16) or
      (uint32(state.buffer[offset + 2]) shl 8) or
      uint32(state.buffer[offset + 3])
  for i in 16..<64:
    let s0 = rotateRight(schedule[i - 15], 7) xor
      rotateRight(schedule[i - 15], 18) xor (schedule[i - 15] shr 3)
    let s1 = rotateRight(schedule[i - 2], 17) xor
      rotateRight(schedule[i - 2], 19) xor (schedule[i - 2] shr 10)
    schedule[i] = schedule[i - 16] + s0 + schedule[i - 7] + s1

  var a = state.hash[0]
  var b = state.hash[1]
  var c = state.hash[2]
  var d = state.hash[3]
  var e = state.hash[4]
  var f = state.hash[5]
  var g = state.hash[6]
  var h = state.hash[7]

  for i in 0..<64:
    let s1 = rotateRight(e, 6) xor rotateRight(e, 11) xor rotateRight(e, 25)
    let choice = (e and f) xor ((not e) and g)
    let temp1 = h + s1 + choice + RoundConstants[i] + schedule[i]
    let s0 = rotateRight(a, 2) xor rotateRight(a, 13) xor rotateRight(a, 22)
    let majority = (a and b) xor (a and c) xor (b and c)
    let temp2 = s0 + majority

    h = g
    g = f
    f = e
    e = d + temp1
    d = c
    c = b
    b = a
    a = temp1 + temp2

  state.hash[0] += a
  state.hash[1] += b
  state.hash[2] += c
  state.hash[3] += d
  state.hash[4] += e
  state.hash[5] += f
  state.hash[6] += g
  state.hash[7] += h

proc initSha256(): Sha256State =
  result.hash = [
    0x6a09e667'u32, 0xbb67ae85'u32, 0x3c6ef372'u32, 0xa54ff53a'u32,
    0x510e527f'u32, 0x9b05688c'u32, 0x1f83d9ab'u32, 0x5be0cd19'u32
  ]

proc update(state: var Sha256State; data: openArray[byte]) =
  for value in data:
    state.buffer[state.bufferLen] = value
    inc state.bufferLen
    if state.bufferLen == state.buffer.len:
      state.transform()
      state.bitLen += 512
      state.bufferLen = 0

proc finish(state: var Sha256State): array[32, byte] =
  let messageBits = state.bitLen + uint64(state.bufferLen * 8)
  state.buffer[state.bufferLen] = 0x80
  inc state.bufferLen

  if state.bufferLen > 56:
    while state.bufferLen < state.buffer.len:
      state.buffer[state.bufferLen] = 0
      inc state.bufferLen
    state.transform()
    state.bufferLen = 0

  while state.bufferLen < 56:
    state.buffer[state.bufferLen] = 0
    inc state.bufferLen
  for i in 0..<8:
    state.buffer[63 - i] = byte(messageBits shr (i * 8))
  state.transform()

  for i, value in state.hash:
    result[i * 4] = byte(value shr 24)
    result[i * 4 + 1] = byte(value shr 16)
    result[i * 4 + 2] = byte(value shr 8)
    result[i * 4 + 3] = byte(value)

proc sha256File*(path: string): string =
  var state = initSha256()
  var file = open(path, fmRead)
  defer:
    file.close()

  var buffer: array[64 * 1024, byte]
  while true:
    let count = file.readBuffer(addr buffer[0], buffer.len)
    if count == 0:
      break
    state.update(buffer.toOpenArray(0, count - 1))

  const HexDigits = "0123456789abcdef"
  for value in state.finish():
    result.add HexDigits[int(value shr 4)]
    result.add HexDigits[int(value and 0x0f)]
