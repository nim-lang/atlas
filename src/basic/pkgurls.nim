#
#           Atlas Package Cloner
#        (c) Copyright 2024 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std / [hashes, uri, paths, strutils, json]
from std / os import `/`, dirExists
import compiledpatterns, gitops, reporters

const
  GitSuffix = ".git"

type
  PkgUrl* = object
    projectName*: string
    u: string

proc isSep(c: char): bool {.inline.} =
  when defined(windows): c == '/' or c == '\\' else: c == '/'

proc isFileProtocol*(s: PkgUrl): bool = s.u.startsWith("file://")
proc isUrl*(s: string): bool {.inline.} = s.len > 5 and s.contains "://"

proc extractProjectName*(s: string): string =
  var last = s.len - 1
  while last >= 0 and s[last].isSep: dec last
  var first = last - 1
  while first >= 0 and not s[first].isSep: dec first
  result = s.substr(first+1, last)
  if result.endsWith(GitSuffix):
    result.setLen result.len - len(GitSuffix)

proc `$`*(u: PkgUrl): string = u.u
proc toJsonHook*(v: PkgUrl): JsonNode = %($(v))

proc createUrlSkipPatterns*(x: string, skipDirTest = false): PkgUrl =
  if not x.isUrl():
    if dirExists(x) or skipDirTest:
      let u2 =
        if isGitDir(x):
          getRemoteUrl(Path(x))
        else:
          ("file://" & x)
      result = PkgUrl(projectName: extractProjectName(x), u: u2)
    else:
      raise newException(ValueError, "Invalid name or URL: " & x)
  else:
    result = PkgUrl(projectName: extractProjectName(x), u: x)

proc toPkgUri*(u: Uri): PkgUrl =
  result = PkgUrl(projectName: extractProjectName($u), u: $u)

proc toUri*(u: PkgUrl): Uri =
  result = parseUri(u.u)

template url*(p: PkgUrl): string = p.u

proc `==`*(a, b: PkgUrl): bool {.inline.} = a.u == b.u
# proc hash*(a: PkgUrl): Hash {.inline.} = hash(a.u)


proc dir*(s: PkgUrl): string =
  if isFileProtocol(s):
    result = substr(s.u, len("file://"))
  else:
    result = s.projectName
