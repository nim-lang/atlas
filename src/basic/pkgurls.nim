#
#           Atlas Package Cloner
#        (c) Copyright 2024 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std / [hashes, strutils]
from std / os import `/`, dirExists
import compiledpatterns, gitops

const
  GitSuffix = ".git"

proc isSep(c: char): bool {.inline.} =
  when defined(windows): c == '/' or c == '\\' else: c == '/'

proc extractProjectName*(s: string): string =
  var last = s.len - 1
  while last >= 0 and s[last].isSep: dec last
  var first = last - 1
  while first >= 0 and not s[first].isSep: dec first
  result = s.substr(first+1, last)
  if result.endsWith(GitSuffix):
    result.setLen result.len - len(GitSuffix)

type
  PkgUrl* = object
    projectName*: string
    u: string

proc `$`*(u: PkgUrl): string = u.u

proc createUrlSkipPatterns*(x: string): PkgUrl =
  if "://" notin x:
    if dirExists(x):
      let u2 = if isGitDir(x): getRemoteUrl(x) else: ("file://" & x)
      result = PkgUrl(projectName: extractProjectName(x), u: u2)
    else:
      raise newException(ValueError, "Invalid name or URL: " & x)
  else:
    result = PkgUrl(projectName: extractProjectName(x), u: x)

proc createUrl*(u: string; p: Patterns): PkgUrl =
  var didReplace = false
  let x = substitute(p, u, didReplace)
  if not didReplace:
    result = createUrlSkipPatterns(x)
  else:
    result = PkgUrl(projectName: extractProjectName(x), u: x)

template url*(p: PkgUrl): string = p.u

proc `==`*(a, b: PkgUrl): bool {.inline.} = a.u == b.u
proc hash*(a: PkgUrl): Hash {.inline.} = hash(a.u)

proc isFileProtocol*(s: PkgUrl): bool = s.u.startsWith("file://")

proc dir*(s: PkgUrl): string =
  if isFileProtocol(s):
    result = substr(s.u, len("file://"))
  else:
    result = s.projectName
