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

proc projectNameImpl(s: string): string =
  var last = s.len - 1
  while last >= 0 and s[last] == '/': dec last
  var first = last - 1
  while first >= 0 and s[first] != '/': dec first
  result = s.substr(first+1, last)
  if result.endsWith(GitSuffix):
    result.setLen result.len - len(GitSuffix)

type
  PkgUrl* = object
    projectName*: string
    u: string

proc createUrl*(u: string; p: Patterns): PkgUrl =
  var didReplace = false
  let x = substitute(p, u, didReplace)
  if not didReplace:
    if "://" notin x:
      if dirExists(x):
        let u2 = if isGitDir(x): getRemoteUrl(x) else: ("file://" & x)
        result = PkgUrl(projectName: projectNameImpl(x), u: u2)
      else:
        raise newException(ValueError, "Invalid name or URL: " & u)
    else:
      result = PkgUrl(projectName: projectNameImpl(x), u: x)
  else:
    result = PkgUrl(projectName: projectNameImpl(x), u: x)


template url*(p: PkgUrl): string = p.u

proc `==`*(a, b: PkgUrl): bool {.inline.} = a.u == b.u
proc hash*(a: PkgUrl): Hash {.inline.} = hash(a.u)

proc isFileProtocol*(s: PkgUrl): bool = s.u.startsWith("file://")
