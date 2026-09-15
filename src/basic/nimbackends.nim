import std/strutils

const SupportedNimBackends* = ["c", "ic", "cpp", "js"]

proc normalizeNimBackend*(backend: string): string =
  backend.strip.toLowerAscii()

proc isSupportedNimBackend*(backend: string): bool =
  let normalized = normalizeNimBackend(backend)
  for supported in SupportedNimBackends:
    if normalized == supported:
      return true
