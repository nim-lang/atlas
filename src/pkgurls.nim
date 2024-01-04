#
#           Atlas Package Cloner
#        (c) Copyright 2024 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std / [hashes, strutils]
from std / os import `/`

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

proc createUrl*(u: sink string): PkgUrl =
  assert "://" in u
  PkgUrl(projectName: projectNameImpl(u), u: u)

template url*(p: PkgUrl): string = p.u

proc `==`*(a, b: PkgUrl): bool {.inline.} = a.u == b.u
proc hash*(a: PkgUrl): Hash {.inline.} = hash(a.u)

proc isFileProtocol*(s: PkgUrl): bool = s.u.startsWith("file://")
