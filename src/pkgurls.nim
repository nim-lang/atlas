#
#           Atlas Package Cloner
#        (c) Copyright 2024 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std / [hashes, strutils]

type
  PkgUrl* = distinct string

proc `==`*(a, b: PkgUrl): bool {.borrow.}
proc hash*(a: PkgUrl): Hash {.borrow.}

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

proc projectName*(s: PkgUrl): string = projectNameImpl(s.string)

proc isFileProtocol*(s: PkgUrl): bool = s.string.startsWith("file://")
