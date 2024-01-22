#
#           Atlas Package Cloner
#        (c) Copyright 2021 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std/[os, osproc, sequtils, strutils]
import reporters, osutils, versions

type
  Command* = enum
    GitClone = "git clone",
    GitDiff = "git diff",
    GitFetch = "git fetch",
    GitTag = "git tag",
    GitTags = "git show-ref --tags",
    GitLastTaggedRef = "git rev-list --tags --max-count=1",
    GitDescribe = "git describe",
    GitRevParse = "git rev-parse",
    GitCheckout = "git checkout",
    GitSubModUpdate = "git submodule update --init",
    GitPush = "git push origin",
    GitPull = "git pull",
    GitCurrentCommit = "git log -n 1 --format=%H"
    GitMergeBase = "git merge-base"
    GitLsFiles = "git -C $1 ls-files"
    GitLog = "git log --format=%H"

proc isGitDir*(path: string): bool =
  let gitPath = path / ".git"
  dirExists(gitPath) or fileExists(gitPath)

proc sameVersionAs*(tag, ver: string): bool =
  const VersionChars = {'0'..'9', '.'}

  proc safeCharAt(s: string; i: int): char {.inline.} =
    if i >= 0 and i < s.len: s[i] else: '\0'

  let idx = find(tag, ver)
  if idx >= 0:
    # we found the version as a substring inside the `tag`. But we
    # need to watch out the the boundaries are not part of a
    # larger/different version number:
    result = safeCharAt(tag, idx-1) notin VersionChars and
      safeCharAt(tag, idx+ver.len) notin VersionChars

proc extractVersion*(s: string): string =
  var i = 0
  while i < s.len and s[i] notin {'0'..'9'}: inc i
  result = s.substr(i)

proc exec*(c: var Reporter;
           cmd: Command;
           args: openArray[string]): (string, int) =
  let cmd = $cmd
  #if execDir.len == 0: $cmd else: $(cmd) % [execDir]
  if isGitDir(getCurrentDir()):
    result = silentExec(cmd, args)
  else:
    result = ("not a git repository", 1)

proc checkGitDiffStatus*(c: var Reporter): string =
  let (outp, status) = exec(c, GitDiff, [])
  if outp.len != 0:
    "'git diff' not empty"
  elif status != 0:
    "'git diff' returned non-zero"
  else:
    ""

proc clone*(c: var Reporter; url, dest: string; retries = 5; fullClones=false): bool =
  ## clone git repo.
  ##
  ## note clones don't use `--recursive` but rely in the `checkoutCommit`
  ## stage to setup submodules as this is less fragile on broken submodules.
  ##

  # retry multiple times to avoid annoying github timeouts:
  let extraArgs =
    if not fullClones: "--depth=1"
    else: ""

  let cmd = $GitClone & " " & extraArgs & " " & quoteShell(url) & " " & dest
  for i in 1..retries:
    if execShellCmd(cmd) == 0:
      return true
    os.sleep(i*2_000)

proc gitDescribeRefTag*(c: var Reporter; commit: string): string =
  let (lt, status) = exec(c, GitDescribe, ["--tags", commit])
  result = if status == 0: strutils.strip(lt) else: ""

proc getLastTaggedCommit*(c: var Reporter): string =
  let (ltr, status) = exec(c, GitLastTaggedRef, [])
  if status == 0:
    let lastTaggedRef = ltr.strip()
    let lastTag = gitDescribeRefTag(c, lastTaggedRef)
    if lastTag.len != 0:
      result = lastTag

proc collectTaggedVersions*(c: var Reporter): seq[Commit] =
  let (outp, status) = exec(c, GitTags, [])
  if status == 0:
    result = parseTaggedVersions(outp)
  else:
    result = @[]

proc versionToCommit*(c: var Reporter; algo: ResolutionAlgorithm; query: VersionInterval): string =
  let allVersions = collectTaggedVersions(c)
  case algo
  of MinVer:
    result = selectBestCommitMinVer(allVersions, query)
  of SemVer:
    result = selectBestCommitSemVer(allVersions, query)
  of MaxVer:
    result = selectBestCommitMaxVer(allVersions, query)

proc shortToCommit*(c: var Reporter; short: string): string =
  let (cc, status) = exec(c, GitRevParse, [short])
  result = if status == 0: strutils.strip(cc) else: ""

proc listFiles*(c: var Reporter): seq[string] =
  let (outp, status) = exec(c, GitLsFiles, [])
  if status == 0:
    result = outp.splitLines().mapIt(it.strip())
  else:
    result = @[]

proc checkoutGitCommit*(c: var Reporter; p, commit: string) =
  let (currentCommit, statusA) = exec(c, GitCurrentCommit, [])
  if statusA == 0 and currentCommit.strip() == commit: return

  let (_, statusB) = exec(c, GitCheckout, [commit])
  if statusB != 0:
    error(c, p, "could not checkout commit " & commit)
  else:
    info(c, p, "updated package to " & commit)

proc checkoutGitCommitFull*(c: var Reporter; p, commit: string; fullClones: bool) =
  var smExtraArgs: seq[string] = @[]

  if not fullClones and commit.len == 40:
    smExtraArgs.add "--depth=1"

    let (_, status) = exec(c, GitFetch, ["--update-shallow", "--tags", "origin", commit])
    if status != 0:
      error(c, p, "could not fetch commit " & commit)
    else:
      trace(c, p, "fetched package commit " & commit)
  elif commit.len != 40:
    info(c, p, "found short commit id; doing full fetch to resolve " & commit)
    let (outp, status) = exec(c, GitFetch, ["--unshallow"])
    if status != 0:
      error(c, p, "could not fetch: " & outp)
    else:
      trace(c, p, "fetched package updates ")

  let (_, status) = exec(c, GitCheckout, [commit])
  if status != 0:
    error(c, p, "could not checkout commit " & commit)
  else:
    info(c, p, "updated package to " & commit)

  let (_, subModStatus) = exec(c, GitSubModUpdate, smExtraArgs)
  if subModStatus != 0:
    error(c, p, "could not update submodules")
  else:
    info(c, p, "updated submodules ")

proc gitPull*(c: var Reporter; displayName: string) =
  let (outp, status) = exec(c, GitPull, [])
  if status != 0:
    debug c, displayName, "git pull error: \n" & outp.splitLines().mapIt("\n>>> " & it).join("")
    error(c, displayName, "could not 'git pull'")

proc gitTag*(c: var Reporter; displayName, tag: string) =
  let (_, status) = exec(c, GitTag, [tag])
  if status != 0:
    error(c, displayName, "could not 'git tag " & tag & "'")

proc pushTag*(c: var Reporter; displayName, tag: string) =
  let (outp, status) = exec(c, GitPush, [tag])
  if status != 0:
    error(c, displayName, "could not 'git push " & tag & "'")
  elif outp.strip() == "Everything up-to-date":
    info(c, displayName, "is up-to-date")
  else:
    info(c, displayName, "successfully pushed tag: " & tag)

proc incrementTag*(c: var Reporter; displayName, lastTag: string; field: Natural): string =
  var startPos =
    if lastTag[0] in {'0'..'9'}: 0
    else: 1
  var endPos = lastTag.find('.', startPos)
  if field >= 1:
    for i in 1 .. field:
      if endPos == -1:
        error c, displayName, "the last tag '" & lastTag & "' is missing . periods"
        return ""
      startPos = endPos + 1
      endPos = lastTag.find('.', startPos)
  if endPos == -1:
    endPos = len(lastTag)
  let patchNumber = parseInt(lastTag[startPos..<endPos])
  lastTag[0..<startPos] & $(patchNumber + 1) & lastTag[endPos..^1]

proc incrementLastTag*(c: var Reporter; displayName: string; field: Natural): string =
  let (ltr, status) = exec(c, GitLastTaggedRef, [])
  if status == 0:
    let
      lastTaggedRef = ltr.strip()
      lastTag = gitDescribeRefTag(c, lastTaggedRef)
      currentCommit = exec(c, GitCurrentCommit, [])[0].strip()

    if lastTaggedRef == currentCommit:
      info c, displayName, "the current commit '" & currentCommit & "' is already tagged '" & lastTag & "'"
      lastTag
    else:
      incrementTag(c, displayName, lastTag, field)
  else: "v0.0.1" # assuming no tags have been made yet

proc needsCommitLookup*(commit: string): bool {.inline.} =
  '.' in commit or commit == InvalidCommit

proc isShortCommitHash*(commit: string): bool {.inline.} =
  commit.len >= 4 and commit.len < 40

when false:
  proc getRequiredCommit*(c: var Reporter; w: Dependency): string =
    if needsCommitLookup(w.commit): versionToCommit(c, w)
    elif isShortCommitHash(w.commit): shortToCommit(c, w.commit)
    else: w.commit

proc getCurrentCommit*(): string =
  result = execProcess("git log -1 --pretty=format:%H").strip()

proc isOutdated*(c: var Reporter; displayName: string): bool =
  ## determine if the given git repo `f` is updateable
  ##

  info c, displayName, "checking is package is up to date..."

  # TODO: does --update-shallow fetch tags on a shallow repo?
  let (outp, status) = exec(c, GitFetch, ["--update-shallow", "--tags"])

  if status == 0:
    let (cc, status) = exec(c, GitLastTaggedRef, [])
    let latestVersion = strutils.strip(cc)
    if status == 0 and latestVersion.len > 0:
      # see if we're past that commit:
      let (cc, status) = exec(c, GitCurrentCommit, [])
      if status == 0:
        let currentCommit = strutils.strip(cc)
        if currentCommit != latestVersion:
          # checkout the later commit:
          # git merge-base --is-ancestor <commit> <commit>
          let (cc, status) = exec(c, GitMergeBase, [currentCommit, latestVersion])
          let mergeBase = strutils.strip(cc)
          #if mergeBase != latestVersion:
          #  echo f, " I'm at ", currentCommit, " release is at ", latestVersion, " merge base is ", mergeBase
          if status == 0 and mergeBase == currentCommit:
            let v = extractVersion gitDescribeRefTag(c, latestVersion)
            if v.len > 0:
              info c, displayName, "new version available: " & v
              result = true
  else:
    warn c, displayName, "`git fetch` failed: " & outp

template withDir*(c: var Reporter; dir: string; body: untyped) =
  let oldDir = getCurrentDir()
  debug c, dir, "Current directory is now: " & dir
  try:
    setCurrentDir(dir)
    body
  finally:
    setCurrentDir(oldDir)

template withDir*(dir: string; body: untyped) =
  let oldDir = getCurrentDir()
  try:
    setCurrentDir(dir)
    body
  finally:
    setCurrentDir(oldDir)

proc getRemoteUrl*(): string =
  execProcess("git config --get remote.origin.url").strip()

proc getRemoteUrl*(x: string): string =
  withDir x:
    result = getRemoteUrl()

proc updateDir*(c: var Reporter; file, filter: string) =
  withDir c, file:
    let (remote, _) = osproc.execCmdEx("git remote -v")
    if filter.len == 0 or filter in remote:
      let diff = checkGitDiffStatus(c)
      if diff.len > 0:
        warn(c, file, "has uncommitted changes; skipped")
      else:
        let (branch, _) = osproc.execCmdEx("git rev-parse --abbrev-ref HEAD")
        if branch.strip.len > 0:
          let (output, exitCode) = osproc.execCmdEx("git pull origin " & branch.strip)
          if exitCode != 0:
            error c, file, output
          else:
            info(c, file, "successfully updated")
        else:
          error c, file, "could not fetch current branch name"
