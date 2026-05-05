#
#           Atlas Package Cloner
#        (c) Copyright 2024 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std / [hashes, uri, os, strutils, files, dirs, sequtils, pegs, tables]
import gitops, reporters, context

export uri

const
  GitSuffix = ".git"

type
  PkgUrl* = object
    qualifiedName*: tuple[name: string, user: string, host: string]
    u: Uri

proc isFileProtocol*(s: PkgUrl): bool = s.u.scheme == "file"
proc isEmpty*(s: PkgUrl): bool = s.qualifiedName[0].len() == 0 or $s.u == ""
type
  ForgeKind = enum
    ForgeGitHub, ForgeGitLab, ForgeSourceHut, ForgeCodeberg

const
  forgePrefixes = {
    "gh": ForgeGitHub, "github": ForgeGitHub,
    "gl": ForgeGitLab, "gitlab": ForgeGitLab,
    "srht": ForgeSourceHut, "sourcehut": ForgeSourceHut, "shart": ForgeSourceHut,
    "cb": ForgeCodeberg, "cberg": ForgeCodeberg, "codeberg": ForgeCodeberg
  }.toTable()

proc isForgeAlias*(s: string): bool =
  let colon = s.find(':')
  if colon < 0: return false
  if "://" in s: return false
  let prefix = s.substr(0, colon - 1).toLowerAscii()
  prefix in forgePrefixes

proc expandForgeAlias*(s: string): string =
  let colon = s.find(':')
  doAssert colon >= 0
  let prefix = s.substr(0, colon - 1).toLowerAscii()
  let rest = s.substr(colon + 1)
  let slash = rest.find('/')
  if slash < 0:
    raise newException(ValueError, "Invalid forge alias format, expected <alias>:<user>/<repo>: " & s)
  let user = rest.substr(0, slash - 1)
  let repo = rest.substr(slash + 1)
  if user.len == 0 or repo.len == 0:
    raise newException(ValueError, "Invalid forge alias format, expected <alias>:<user>/<repo>: " & s)
  let kind = forgePrefixes.getOrDefault(prefix)
  result = "https://"
  case kind
  of ForgeGitHub:
    result &= "github.com/" & user & "/" & repo
  of ForgeGitLab:
    result &= "gitlab.com/" & user & "/" & repo
  of ForgeSourceHut:
    let tildeUser = if user.startsWith('~'): user else: '~' & user
    result &= "git.sr.ht/" & tildeUser & "/" & repo
  of ForgeCodeberg:
    result &= "codeberg.org/" & user & "/" & repo

proc isUrl*(s: string): bool = s.startsWith("git@") or "://" in s or isForgeAlias(s)

proc extractProjectName*(url: Uri): tuple[name: string, user: string, host: string]

proc fullName*(u: PkgUrl): string =
  if u.qualifiedName.host.len() > 0 or u.qualifiedName.user.len() > 0:  
    result = u.qualifiedName.name & "." & u.qualifiedName.user & "." & u.qualifiedName.host
  else:
    result = u.qualifiedName.name

proc shortName*(u: PkgUrl): string =
  u.qualifiedName.name

proc queryValue(u: PkgUrl; key: string): string =
  for k, v in decodeQuery(u.u.query):
    if k == key:
      return v

proc subdir*(u: PkgUrl): Path =
  Path(u.queryValue("subdir"))

proc cloneUri*(u: PkgUrl): Uri =
  result = u.u
  result.query = ""
  result.anchor = ""

proc withoutPackageNameQuery(u: Uri): Uri =
  result = u
  var query: seq[(string, string)]
  for k, v in decodeQuery(result.query):
    if k != "name":
      query.add (k, v)
  result.query = encodeQuery(query)

proc withSubdir*(u: PkgUrl; subdir = ""): PkgUrl =
  var uri = u.u
  var query: seq[(string, string)]
  for k, v in decodeQuery(uri.query):
    if k notin ["name", "subdir"]:
      query.add (k, v)
  if subdir.len > 0:
    query.add ("subdir", subdir)
  uri.query = encodeQuery(query)
  result = PkgUrl(qualifiedName: extractProjectName(uri), u: uri)

proc projectName*(u: PkgUrl): string =
  let subdir = u.subdir()
  if subdir.len > 0:
    $subdir.splitPath().tail
  elif u.qualifiedName.host == "":
    u.qualifiedName.name
  else:
    u.qualifiedName.name

proc requiresName*(u: PkgUrl): string =
  if u.u.scheme in ["file", "link", "atlas"]:
    u.shortName()
  else:
    $u.u

proc toUri*(u: PkgUrl): Uri = result = u.u
proc url*(p: PkgUrl): Uri = p.u
proc `$`*(u: PkgUrl): string = $u.u

proc hash*(a: PkgUrl): Hash {.inline.} =
  hash(a.u)

proc `==`*(a, b: PkgUrl): bool {.inline.} =
  a.u == b.u

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
  elif u.scheme == "link":
    result = (n, "", "")
  else:
    result = (n & e, p, u.hostname)

proc toOriginalPath*(pkgUrl: PkgUrl, isWindowsTest: bool = false): Path =
  let url = pkgUrl.cloneUri()
  if url.scheme in ["file", "link", "atlas"]:
    result = Path(url.hostname & url.path)
    if defined(windows) or isWindowsTest:
      var p = result.string.replace('/', '\\')
      p.removePrefix('\\')
      result = p.Path
  else:
    raise newException(ValueError, "Invalid file path: " & $pkgUrl.url)

proc linkPath*(path: Path): Path =
  result = Path(path.string & ".nimble-link")

proc toDirectoryPath(pkgUrl: PkgUrl, packageName: string, isLinkFile: bool): Path =
  trace pkgUrl, "directory path from:", $pkgUrl.url

  let dirName =
    if packageName.len > 0: packageName
    else: pkgUrl.projectName()
  let url = pkgUrl.cloneUri()
  if url.scheme == "atlas":
    result = project()
  elif url.scheme == "link":
    result = pkgUrl.toOriginalPath().parentDir()
  elif url.scheme == "file":
    # file:// urls are used for local source paths, not dependency paths
    result = depsDir() / Path(dirName)
  else:
    result = depsDir() / Path(dirName)
  
  if not isLinkFile and not dirExists(result) and fileExists(result.linkPath()):
    # prefer the directory path if it exists (?)
    let linkPath = result.linkPath()
    let link = readFile($linkPath)
    let lines = link.split("\n")
    if lines.len != 2:
      warn pkgUrl.projectName(), "invalid link file:", $linkPath
    else:
      let nimble = Path(lines[0])
      result = nimble.splitFile().dir
      if not result.isAbsolute():
        result = linkPath.parentDir() / result
      debug pkgUrl.projectName(), "link file to:", $result

  result = result.absolutePath
  trace pkgUrl, "found directory path:", $result
  doAssert result.len() > 0

proc toDirectoryPath*(pkgUrl: PkgUrl): Path =
  toDirectoryPath(pkgUrl, "", false)

proc toDirectoryPath*(pkgUrl: PkgUrl, packageName: string): Path =
  toDirectoryPath(pkgUrl, packageName, false)

proc toLinkPath*(pkgUrl: PkgUrl): Path =
  if pkgUrl.cloneUri().scheme == "atlas":
    result = Path("")
  elif pkgUrl.cloneUri().scheme == "link":
    result = depsDir() / Path(pkgUrl.projectName() & ".nimble-link")
  else:
    result = Path(toDirectoryPath(pkgUrl, "", true).string & ".nimble-link")

proc isLinkPath*(pkgUrl: PkgUrl): bool =
  result = fileExists(toLinkPath(pkgUrl))

proc isAtlasProject*(pkgUrl: PkgUrl): bool =
  result = pkgUrl.cloneUri().scheme == "link"

proc isNimbleLink*(pkgUrl: PkgUrl): bool =
  pkgUrl.cloneUri().scheme == "link" or pkgUrl.isLinkPath()

proc createNimbleLink*(pkgUrl: PkgUrl, nimblePath: Path, cfgPath: CfgPath) =
  let nimbleLink = toLinkPath(pkgUrl)
  trace "nimble:link", "creating link at:", $nimbleLink, "from:", $nimblePath
  if nimbleLink.len() == 0:
    raise newException(ValueError, "Invalid link path: " & $nimbleLink)

  if nimbleLink.fileExists():
    return

  let nimblePath = nimblePath.absolutePath()
  let cfgPath = cfgPath.Path.absolutePath()

  writeFile($nimbleLink, "$1\n$2" % [$nimblePath, $cfgPath])

proc isWindowsAbsoluteFile*(raw: string): bool =
  raw.match(peg"^ {'file://'?} {[A-Z] ':' ['/'\\]} .*") or
  raw.match(peg"^ {'link://'?} {[A-Z] ':' ['/'\\]} .*") or
  raw.match(peg"^ {'atlas://'?} {[A-Z] ':' ['/'\\]} .*")

proc toWindowsFileUrl*(raw: string): string =
  let rawPath = raw.replace('\\', '/')
  if rawPath.isWindowsAbsoluteFile():
    result = rawPath
    result = result.replace("file://", "file:///")
    result = result.replace("link://", "link:///")
    result = result.replace("atlas://", "atlas:///")
  else:
    result = rawPath

proc fixFileRelativeUrl*(u: Uri, isWindowsTest: bool = false): Uri =
  if isWindowsTest or defined(windows) and u.scheme in ["file", "link", "atlas"] and u.hostname.len() > 0:
    result = parseUri(toWindowsFileUrl($u))
  else:
    result = u

  if result.scheme in ["file", "link", "atlas"] and result.hostname.len() > 0:
    # fix relative paths
    var url = (project().string / (result.hostname & result.path)).absolutePath
    url = result.scheme & "://" & url
    if isWindowsTest or defined(windows):
      url = toWindowsFileUrl(url)
    result = parseUri(url)

proc createUrlSkipPatterns*(raw: string, skipDirTest = false, forceWindows: bool = false): PkgUrl =
  template cleanupUrl(u: Uri) =
    if u.path.endsWith(".git") and (u.scheme in ["http", "https"] or u.hostname in ["github.com", "gitlab.com", "bitbucket.org"]):
      u.path.removeSuffix(".git")

    u.path = u.path.strip(leading=false, trailing=true, {'/'})

  if raw.isForgeAlias():
    let expanded = expandForgeAlias(raw)
    result = createUrlSkipPatterns(expanded, skipDirTest, forceWindows)
  elif not raw.isUrl():
    if dirExists(raw) or skipDirTest:
      var raw: string = raw
      if isGitDir(raw):
        raw = getCanonicalUrl(Path(raw))
      else:
        if not forceWindows:
          raw = raw.absolutePath()
        if forceWindows or defined(windows) or defined(atlasUnitTests):
          raw = toWindowsFileUrl("file:///" & raw)
        else:
          raw = "file://" & raw
      let u = parseUri(raw)
      result = PkgUrl(qualifiedName: extractProjectName(u), u: u)
    else:
      raise newException(ValueError, "Invalid name or URL: " & raw)
  elif raw.startsWith("git@"): # special case git@server.com
    var u = parseUri("ssh://" & raw.replace(":", "/"))
    cleanupUrl(u)
    u = withoutPackageNameQuery(u)
    result = PkgUrl(qualifiedName: extractProjectName(u), u: u)
  else:
    var u = parseUri(raw)

    if u.scheme == "git":
      if u.port.anyIt(not it.isDigit()):
        u.path = "/" & u.port & u.path
        u.port = ""

      u.scheme = "ssh"

    if u.scheme in ["file", "link", "atlas"]:
      # fix missing absolute paths
      u = fixFileRelativeUrl(u, isWindowsTest = forceWindows)

    cleanupUrl(u)
    u = withoutPackageNameQuery(u)
    result = PkgUrl(qualifiedName: extractProjectName(u), u: u)
  # trace result, "created url raw:", repr(raw), "url:", repr(result)

proc toPkgUriRaw*(u: Uri): PkgUrl =
  result = createUrlSkipPatterns($u, true)
