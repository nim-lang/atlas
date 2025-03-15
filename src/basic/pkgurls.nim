#
#           Atlas Package Cloner
#        (c) Copyright 2024 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std / [hashes, uri, os, strutils, os, sequtils, json]
import compiledpatterns, gitops, reporters, context

export uri

const
  GitSuffix = ".git"

type
  PkgUrl* = object
    qualifiedName*: tuple[name: string, user: string, host: string]
    hasShortName*: bool
    u: Uri

proc isFileProtocol*(s: PkgUrl): bool = s.u.scheme == "file"
proc isEmpty*(s: PkgUrl): bool = s.qualifiedName[0].len() == 0 or $s.u == ""
proc isUrl*(s: string): bool = s.startsWith("git@") or "://" in s

proc fullName*(u: PkgUrl): string =
  if u.qualifiedName.host.len() > 0 or u.qualifiedName.user.len() > 0:  
    result = u.qualifiedName.name & "." & u.qualifiedName.user & "." & u.qualifiedName.host
  else:
    result = u.qualifiedName.name

proc shortName*(u: PkgUrl): string =
  u.qualifiedName.name

proc projectName*(u: PkgUrl): string =
  if u.hasShortName or u.qualifiedName.host == "":
    u.qualifiedName.name
  else:
    u.qualifiedName.name & "." & u.qualifiedName.user & "." & u.qualifiedName.host

proc requiresName*(u: PkgUrl): string =
  if u.hasShortName:
    u.qualifiedName.name
  else:
    $u.u

proc toUri*(u: PkgUrl): Uri = result = u.u
proc url*(p: PkgUrl): Uri = p.u
proc `$`*(u: PkgUrl): string = $u.u
proc toJsonHook*(v: PkgUrl): JsonNode = %($(v))
proc hash*(a: PkgUrl): Hash {.inline.} = hash(a.u)
proc `==`*(a, b: PkgUrl): bool {.inline.} = a.u == b.u

proc toReporterName(u: PkgUrl): string = u.projectName()

proc extractProjectName*(url: Uri): tuple[name: string, user: string, host: string] =
  var u = url
  var (p, n, e) = u.path.splitFile()
  p.removePrefix(DirSep)
  p.removePrefix(AltSep)
  if u.scheme in ["http", "https"] and e == GitSuffix:
    e = ""

  if u.scheme == "atlas":
    result = (n, "", "")
  elif u.scheme == "file":
    result = (n & e, "", "")
  else:
    result = (n & e, p, u.hostname)

proc toOriginalPath*(pkgUrl: PkgUrl): Path =
  if pkgUrl.url.scheme == "file":
    result = Path(pkgUrl.url.hostname & pkgUrl.url.path)
  else:
    raise newException(ValueError, "Invalid file path: " & $pkgUrl.url)

proc toDirectoryPath*(pkgUrl: PkgUrl): Path =
  if pkgUrl.url.scheme == "atlas":
    result = workspace()
  elif pkgUrl.url.scheme == "file":
    # file:// urls are used for local source paths, not dependencies paths
    # result = Path(pkgUrl.url.path)
    result = workspace() / context().depsDir / Path(pkgUrl.projectName())
  else:
    result = workspace() / context().depsDir / Path(pkgUrl.projectName())
  result = result.absolutePath
  trace pkgUrl, "found directory path:", $result
  doAssert result.len() > 0

proc toLinkPath*(pkgUrl: PkgUrl): Path =
  if pkgUrl.url.scheme == "atlas":
    Path""
  else:
    Path(pkgUrl.toDirectoryPath().string & ".link")

proc createUrlSkipPatterns*(raw: string, skipDirTest = false): PkgUrl =
  template cleanupUrl(u: Uri) =
    if u.path.endsWith(".git") and (u.scheme in ["http", "https"] or u.hostname in ["github.com", "gitlab.com", "bitbucket.org"]):
      u.path.removeSuffix(".git")

    u.path = u.path.strip(leading=false, trailing=true, {'/'})

  if not raw.isUrl():
    if dirExists(raw) or skipDirTest:
      let raw =
        if isGitDir(raw):
          getRemoteUrl(Path(raw))
        else:
          ("file://" & raw)
      when defined(windows):
        if raw.startsWith("file://"):
          raw.replace(":\\", "/")
          raw.replace(DirSep, AltSep)
      let u = parseUri(raw)
      result = PkgUrl(qualifiedName: extractProjectName(u), u: u, hasShortName: true)
    else:
      raise newException(ValueError, "Invalid name or URL: " & raw)
  elif raw.startsWith("git@"): # special case git@server.com
    var u = parseUri("ssh://" & raw.replace(":", "/"))
    cleanupUrl(u)
    result = PkgUrl(qualifiedName: extractProjectName(u), u: u, hasShortName: false)
  else:
    var u = parseUri(raw)
    var hasShortName = false

    if u.scheme == "git":
      if u.port.anyIt(not it.isDigit()):
        u.path = "/" & u.port & u.path
        u.port = ""

      u.scheme = "ssh"
      echo "git scheme: url: ", raw, "u: ", repr(u)

    if u.scheme == "file" and u.hostname != "":
      # fix absolute paths
      var url = "file://" & ((workspace().string / (u.hostname & u.path)).absolutePath)
      when defined(windows):
        url.replace(DirSep, AltSep)
      u = parseUri(url)
      hasShortName = true

    if u.scheme == "file":
      warn "atlas:createUrlSkipPatterns: url: ", $u

    cleanupUrl(u)
    result = PkgUrl(qualifiedName: extractProjectName(u), u: u, hasShortName: hasShortName)

  # trace result, "created url raw:", repr(raw), "url:", repr(result)

proc toPkgUriRaw*(u: Uri, hasShortName: bool = false): PkgUrl =
  result = createUrlSkipPatterns($u, true)
  result.hasShortName = hasShortName

# proc dir*(s: PkgUrl): string =
#   if isFileProtocol(s):
#     result = substr(s.u, len("file://"))
#   else:
#     result = s.projectName
