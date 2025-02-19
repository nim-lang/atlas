#
#           Atlas Package Cloner
#        (c) Copyright 2021 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std/[os, files, dirs, paths, osproc, sequtils, strutils, uri]
import reporters, osutils, versions, context

type
  Command* = enum
    GitClone = "git clone $EXTRAARGS $URL $DEST",
    GitRemoteUrl = "git -C $DIR config --get remote.origin.url",
    GitDiff = "git -C $DIR diff",
    GitFetch = "git -C $DIR fetch",
    GitTag = "git -C $DIR tag",
    GitTags = "git -C $DIR show-ref --tags",
    GitLastTaggedRef = "git -C $DIR rev-list --tags --max-count=1",
    GitDescribe = "git -C $DIR describe",
    GitRevParse = "git -C $DIR rev-parse",
    GitCheckout = "git -C $DIR checkout",
    GitSubModUpdate = "git submodule update --init",
    GitPush = "git -C $DIR push origin",
    GitPull = "git -C $DIR pull",
    GitCurrentCommit = "git -C $DIR log -n 1 --format=%H"
    GitMergeBase = "git -C $DIR merge-base"
    GitLsFiles = "git -C $DIR ls-files"
    GitLog = "git -C $DIR log --format=%H"
    GitCurrentBranch = "git rev-parse --abbrev-ref HEAD"

proc isGitDir*(path: Path): bool =
  let gitPath = path / Path(".git")
  dirExists(gitPath) or fileExists(gitPath)
proc isGitDir*(path: string): bool =
  isGitDir(Path(path))

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

proc exec*(cmd: Command;
           path: Path;
           args: openArray[string],
           ignoreError = false,
           ): (string, int) =
  let cmd = $cmd % ["DIR", $path]
  #if execDir.len == 0: $cmd else: $(cmd) % [execDir]
  debug "gitops", "Running Git command `$1`" % [ join(@[cmd] & @args, " ")]
  if isGitDir(path):
    result = silentExec(cmd, args)
  else:
    result = ("not a git repository", 1)
  if not ignoreError and result[1] != 0:
    error "gitops", "Git command failed `$1` failed with code: $2" % [cmd, $result[1]]

proc checkGitDiffStatus*(path: Path): string =
  let (outp, status) = exec(GitDiff, path, [])
  if outp.len != 0:
    "'git diff' not empty"
  elif status != 0:
    "'git diff' returned non-zero"
  else:
    ""

proc maybeUrlProxy*(url: Uri): Uri =
  result = url
  if $context().proxy != "":
    result = context().proxy
    result.path = url.path
    result.query = url.query
    result.anchor = url.anchor

proc clone*(url: string, dest: Path; retries = 5; fullClones=false): bool =
  ## clone git repo.
  ##
  ## note clones don't use `--recursive` but rely in the `checkoutCommit`
  ## stage to setup submodules as this is less fragile on broken submodules.
  ##

  # retry multiple times to avoid annoying github timeouts:
  let extraArgs =
    if $context().proxy != "" and context().dumbProxy: ""
    elif not fullClones: "--depth=1"
    else: ""

  var url = maybeUrlProxy(url.parseUri())

  let cmd = $GitClone % [ "EXTRAARGS", extraArgs, "URL", quoteShell($url), "DEST", $dest]
  for i in 1..retries:
    if execShellCmd(cmd) == 0:
      return true
    os.sleep(i*2_000)

proc gitDescribeRefTag*(path: Path, commit: string): string =
  let (lt, status) = exec(GitDescribe, path, ["--tags", commit])
  result = if status == 0: strutils.strip(lt) else: ""

proc collectTaggedVersions*(path: Path): seq[Commit] =
  let (outp, status) = exec(GitTags, path, [])
  if status == 0:
    result = parseTaggedVersions(outp)
  else:
    result = @[]

proc versionToCommit*(path: Path, algo: ResolutionAlgorithm; query: VersionInterval): string =
  let allVersions = collectTaggedVersions(path)
  case algo
  of MinVer:
    result = selectBestCommitMinVer(allVersions, query)
  of SemVer:
    result = selectBestCommitSemVer(allVersions, query)
  of MaxVer:
    result = selectBestCommitMaxVer(allVersions, query)

proc shortToCommit*(path: Path, short: string): string =
  let (cc, status) = exec(GitRevParse, path, [short])
  result = if status == 0: strutils.strip(cc) else: ""

proc listFiles*(path: Path): seq[string] =
  let (outp, status) = exec(GitLsFiles, path, [])
  if status == 0:
    result = outp.splitLines().mapIt(it.strip())
  else:
    result = @[]

proc checkoutGitCommit*(path: Path, commit: string) =
  let (currentCommit, statusA) = exec(GitCurrentCommit, path, [])
  if statusA == 0 and currentCommit.strip() == commit: return

  let (_, statusB) = exec(GitCheckout, path, [commit])
  if statusB != 0:
    error($path, "could not checkout commit " & commit)
  else:
    info($path, "updated package to " & commit)

proc checkoutGitCommitFull*(path: Path, commit: string; fullClones: bool) =
  var smExtraArgs: seq[string] = @[]

  if not fullClones and commit.len == 40:
    smExtraArgs.add "--depth=1"

    let extraArgs =
      if context().dumbProxy: ""
      elif not fullClones: "--update-shallow"
      else: ""
    let (_, status) = exec(GitFetch, path, [extraArgs, "--tags", "origin", commit])
    if status != 0:
      error($path, "could not fetch commit " & commit)
    else:
      trace($path, "fetched package commit " & commit)
  elif commit.len != 40:
    info($path, "found short commit id; doing full fetch to resolve " & commit)
    let (outp, status) = exec(GitFetch, path, ["--unshallow"])
    if status != 0:
      error($path, "could not fetch: " & outp)
    else:
      trace($path, "fetched package updates ")

  let (_, status) = exec(GitCheckout, path, [commit])
  if status != 0:
    error($path, "could not checkout commit " & commit)
  else:
    info($path, "updated package to " & commit)

  let (_, subModStatus) = exec(GitSubModUpdate, path, smExtraArgs)
  if subModStatus != 0:
    error($path, "could not update submodules")
  else:
    info($path, "updated submodules ")

proc gitPull*(path: Path) =
  let (outp, status) = exec(GitPull, path, [])
  if status != 0:
    debug path, "git pull error: \n" & outp.splitLines().mapIt("\n>>> " & it).join("")
    error(path, "could not 'git pull'")

proc gitTag*(path: Path, tag: string) =
  let (_, status) = exec(GitTag, path, [tag])
  if status != 0:
    error(path, "could not 'git tag " & tag & "'")

proc pushTag*(path: Path, tag: string) =
  let (outp, status) = exec(GitPush, path, [tag])
  if status != 0:
    error(path, "could not 'git push " & tag & "'")
  elif outp.strip() == "Everything up-to-date":
    info(path, "is up-to-date")
  else:
    info(path, "successfully pushed tag: " & tag)

proc incrementTag*(displayName, lastTag: string; field: Natural): string =
  var startPos =
    if lastTag[0] in {'0'..'9'}: 0
    else: 1
  var endPos = lastTag.find('.', startPos)
  if field >= 1:
    for i in 1 .. field:
      if endPos == -1:
        error displayName, "the last tag '" & lastTag & "' is missing . periods"
        return ""
      startPos = endPos + 1
      endPos = lastTag.find('.', startPos)
  if endPos == -1:
    endPos = len(lastTag)
  let patchNumber = parseInt(lastTag[startPos..<endPos])
  lastTag[0..<startPos] & $(patchNumber + 1) & lastTag[endPos..^1]

proc incrementLastTag*(path: Path, field: Natural): string =
  let (ltr, status) = exec(GitLastTaggedRef, path, [])
  echo "incrementLastTag: `$1`" % [ltr]
  if status != 0 or ltr == "":
    "v0.0.1" # assuming no tags have been made yet
  else:
    let
      lastTaggedRef = ltr.strip()
      lastTag = gitDescribeRefTag(path, lastTaggedRef)
      currentCommit = exec(GitCurrentCommit, path, [])[0].strip()

    echo "lastTaggedRef: ", lastTaggedRef 
    echo "currentCommit: ", currentCommit 
    if lastTaggedRef == "":
      "v0.0.1" # assuming no tags have been made yet
    elif lastTaggedRef == "" or lastTaggedRef == currentCommit:
      info path, "the current commit '" & currentCommit & "' is already tagged '" & lastTag & "'"
      lastTag
    else:
      incrementTag($path, lastTag, field)

proc needsCommitLookup*(commit: string): bool {.inline.} =
  '.' in commit or commit == InvalidCommit

proc isShortCommitHash*(commit: string): bool {.inline.} =
  commit.len >= 4 and commit.len < 40

when false:
  proc getRequiredCommit*(w: Dependency): string =
    if needsCommitLookup(w.commit): versionToCommit(c, w)
    elif isShortCommitHash(w.commit): shortToCommit(c, w.commit)
    else: w.commit

proc getCurrentCommit*(): string =
  result = execProcess("git log -1 --pretty=format:%H").strip()

proc isOutdated*(path: Path): bool =
  ## determine if the given git repo `f` is updateable
  ##

  info path, "checking is package is up to date..."

  # TODO: does --update-shallow fetch tags on a shallow repo?
  let extraArgs =
    if context().dumbProxy: ""
    else: "--update-shallow"
  let (outp, status) = exec(GitFetch, path, [extraArgs, "--tags"])

  if status == 0:
    let (cc, status) = exec(GitLastTaggedRef, path, [])
    let latestVersion = strutils.strip(cc)
    if status == 0 and latestVersion.len > 0:
      # see if we're past that commit:
      let (cc, status) = exec(GitCurrentCommit, path, [])
      if status == 0:
        let currentCommit = strutils.strip(cc)
        if currentCommit != latestVersion:
          # checkout the later commit:
          # git merge-base --is-ancestor <commit> <commit>
          let (cc, status) = exec(GitMergeBase, path, [currentCommit, latestVersion])
          let mergeBase = strutils.strip(cc)
          #if mergeBase != latestVersion:
          #  echo f, " I'm at ", currentCommit, " release is at ", latestVersion, " merge base is ", mergeBase
          if status == 0 and mergeBase == currentCommit:
            let v = extractVersion gitDescribeRefTag(path, latestVersion)
            if v.len > 0:
              info path, "new version available: " & v
              result = true
  else:
    warn path, "`git fetch` failed: " & outp

proc getRemoteUrl*(path: Path): string =
  let (cc, status) = exec(GitRemoteUrl, path, [])
  if status != 0:
    return ""
  else:
    return cc.strip()

proc updateDir*(path: Path, filter: string) =
  let (remote, _) = osproc.execCmdEx("git remote -v")
  if filter.len == 0 or filter in remote:
    let diff = checkGitDiffStatus(path)
    if diff.len > 0:
      warn($path, "has uncommitted changes; skipped")
    else:
      let (branch, status) = exec(GitCurrentBranch, path, [])
      if branch.strip.len > 0:
        let (output, exitCode) = osproc.execCmdEx("git pull origin " & branch.strip)
        if exitCode != 0:
          error $path, output
        else:
          info($path, "successfully updated")
      else:
        error $path, "could not fetch current branch name"
