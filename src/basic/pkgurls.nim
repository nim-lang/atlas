#
#           Atlas Package Cloner
#        (c) Copyright 2024 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std / [hashes, uri, os, strutils, json]
from std / os import `/`, dirExists
import compiledpatterns, gitops, reporters, context

export uri

const
  GitSuffix = ".git"

type
  PkgUrl* = object
    projectName*: string
    u: Uri

proc isFileProtocol*(s: PkgUrl): bool = s.u.scheme == "file"
proc isUrl*(s: string): bool = s.startsWith("git@") or parseUri(s).scheme != ""
proc isEmpty*(s: PkgUrl): bool = s.projectName.len() == 0

proc toUri*(u: PkgUrl): Uri = result = u.u
proc url*(p: PkgUrl): Uri = p.u
proc `==`*(a, b: PkgUrl): bool {.inline.} = a.u == b.u
proc `$`*(u: PkgUrl): string = $u.u
proc toJsonHook*(v: PkgUrl): JsonNode = %($(v))
proc hash*(a: PkgUrl): Hash {.inline.} = hash(a.u)

proc extractProjectName*(url: Uri): string =
  var u = url
  var (p, n, e) = u.path.splitFile()
  p.removePrefix(DirSep)
  if u.scheme in ["http", "https"] and e == GitSuffix:
    e = ""

  if u.scheme == "atlas":
    echo "EXTRACT: ", "p: ", p, " n: ", n, " e: ", e, " url: ", url.repr
    result = n
  elif u.scheme == "file":
    result = n & e
  else:
    result = [n & e, p, u.hostname].join(".")

proc toDirectoryPath*(pkgUrl: PkgUrl, ): Path =
  if pkgUrl.url.scheme == "atlas":
    result = workspace()
  elif pkgUrl.url.scheme == "file":
    # result = workspace() / Path(pkgUrl.url.path)
    result = workspace() / context().depsDir / Path(pkgUrl.projectName)
  else:
    result = workspace() / context().depsDir / Path(pkgUrl.projectName)
  result = result.absolutePath
  trace pkgUrl.projectName, "found directory path:", $result
  doAssert result.len() > 0

proc toLinkPath*(pkgUrl: PkgUrl): Path =
  if pkgUrl.url.scheme == "atlas":
    Path""
  else:
    Path(pkgUrl.toDirectoryPath().string & ".link")

proc toPkgUriRaw*(u: Uri): PkgUrl =
  result = PkgUrl(projectName: extractProjectName(u), u: u)

proc createUrlSkipPatterns*(x: string, skipDirTest = false): PkgUrl =
  if not x.isUrl():
    if dirExists(x) or skipDirTest:
      let x =
        if isGitDir(x):
          getRemoteUrl(Path(x))
        else:
          ("file://" & x)
      let u = parseUri(x)
      result = PkgUrl(projectName: extractProjectName(u), u: u)
    else:
      raise newException(ValueError, "Invalid name or URL: " & x)
  elif x.startsWith("git@"): # special case git@server.com
    let u = parseUri("ssh://" & x.replace(":", "/"))
    result = PkgUrl(projectName: extractProjectName(u), u: u)
  else:
    var u = parseUri(x)
    if u.scheme == "file" and u.hostname != "":
      echo "CREATE URL: ", u.repr
      echo "CREATE URL: ", parseUri("file:///tmp/test").repr
      echo "CREATE URL: ", parseUri("file://tmp/test").repr
      u = parseUri("file://" & (workspace().string / (u.hostname & u.path)).absolutePath)
    result = PkgUrl(projectName: extractProjectName(u), u: u)


# proc dir*(s: PkgUrl): string =
#   if isFileProtocol(s):
#     result = substr(s.u, len("file://"))
#   else:
#     result = s.projectName
