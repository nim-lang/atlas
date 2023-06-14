import std/[os, osproc, strutils]
import context, osutils

type
  Command* = enum
    GitDiff = "git diff",
    GitTag = "git tag",
    GitTags = "git show-ref --tags",
    GitLastTaggedRef = "git rev-list --tags --max-count=1",
    GitDescribe = "git describe",
    GitRevParse = "git rev-parse",
    GitCheckout = "git checkout",
    GitPush = "git push origin",
    GitPull = "git pull",
    GitCurrentCommit = "git log -n 1 --format=%H"
    GitMergeBase = "git merge-base"

proc isGitDir*(path: string): bool = dirExists(path / ".git")

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

proc exec*(c: var AtlasContext; cmd: Command; args: openArray[string]): (string, int) =
  when MockupRun:
    assert TestLog[c.step].cmd == cmd, $(TestLog[c.step].cmd, cmd, c.step)
    case cmd
    of GitDiff, GitTag, GitTags, GitLastTaggedRef, GitDescribe, GitRevParse, GitPush, GitPull, GitCurrentCommit:
      result = (TestLog[c.step].output, TestLog[c.step].exitCode)
    of GitCheckout:
      assert args[0] == TestLog[c.step].output
    of GitMergeBase:
      let tmp = TestLog[c.step].output.splitLines()
      assert tmp.len == 4, $tmp.len
      assert tmp[0] == args[0]
      assert tmp[1] == args[1]
      assert tmp[3] == ""
      result[0] = tmp[2]
      result[1] = TestLog[c.step].exitCode
    inc c.step
  else:
    result = silentExec($cmd, args)
    when ProduceTest:
      echo "cmd ", cmd, " args ", args, " --> ", result

proc isCleanGit*(c: var AtlasContext): string =
  result = ""
  let (outp, status) = exec(c, GitDiff, [])
  if outp.len != 0:
    result = "'git diff' not empty"
  elif status != 0:
    result = "'git diff' returned non-zero"

proc gitDescribeRefTag*(c: var AtlasContext; commit: string): string =
  let (lt, status) = exec(c, GitDescribe, ["--tags", commit])
  result = if status == 0: strutils.strip(lt) else: ""

proc getLastTaggedCommit*(c: var AtlasContext): string =
  let (ltr, status) = exec(c, GitLastTaggedRef, [])
  if status == 0:
    let lastTaggedRef = ltr.strip()
    let lastTag = gitDescribeRefTag(c, lastTaggedRef)
    if lastTag.len != 0:
      result = lastTag

proc collectTaggedVersions*(c: var AtlasContext): seq[(string, Version)] =
  let (outp, status) = exec(c, GitTags, [])
  if status == 0:
    result = parseTaggedVersions(outp)
  else:
    result = @[]

proc versionToCommit*(c: var AtlasContext; d: Dependency): string =
  let allVersions = collectTaggedVersions(c)
  case d.algo
  of MinVer:
    result = selectBestCommitMinVer(allVersions, d.query)
  of SemVer:
    result = selectBestCommitSemVer(allVersions, d.query)
  of MaxVer:
    result = selectBestCommitMaxVer(allVersions, d.query)

proc shortToCommit*(c: var AtlasContext; short: string): string =
  let (cc, status) = exec(c, GitRevParse, [short])
  result = if status == 0: strutils.strip(cc) else: ""

proc checkoutGitCommit*(c: var AtlasContext; p: PackageName; commit: string) =
  let (_, status) = exec(c, GitCheckout, [commit])
  if status != 0:
    error(c, p, "could not checkout commit " & commit)

proc gitPull*(c: var AtlasContext; p: PackageName) =
  let (_, status) = exec(c, GitPull, [])
  if status != 0:
    error(c, p, "could not 'git pull'")

proc gitTag*(c: var AtlasContext; tag: string) =
  let (_, status) = exec(c, GitTag, [tag])
  if status != 0:
    error(c, c.projectDir.PackageName, "could not 'git tag " & tag & "'")

proc pushTag*(c: var AtlasContext; tag: string) =
  let (outp, status) = exec(c, GitPush, [tag])
  if status != 0:
    error(c, c.projectDir.PackageName, "could not 'git push " & tag & "'")
  elif outp.strip() == "Everything up-to-date":
    info(c, c.projectDir.PackageName, "is up-to-date")
  else:
    info(c, c.projectDir.PackageName, "successfully pushed tag: " & tag)

proc incrementTag*(c: var AtlasContext; lastTag: string; field: Natural): string =
  var startPos =
    if lastTag[0] in {'0'..'9'}: 0
    else: 1
  var endPos = lastTag.find('.', startPos)
  if field >= 1:
    for i in 1 .. field:
      if endPos == -1:
        error c, projectFromCurrentDir(), "the last tag '" & lastTag & "' is missing . periods"
        return ""
      startPos = endPos + 1
      endPos = lastTag.find('.', startPos)
  if endPos == -1:
    endPos = len(lastTag)
  let patchNumber = parseInt(lastTag[startPos..<endPos])
  lastTag[0..<startPos] & $(patchNumber + 1) & lastTag[endPos..^1]

proc incrementLastTag*(c: var AtlasContext; field: Natural): string =
  let (ltr, status) = exec(c, GitLastTaggedRef, [])
  if status == 0:
    let
      lastTaggedRef = ltr.strip()
      lastTag = gitDescribeRefTag(c, lastTaggedRef)
      currentCommit = exec(c, GitCurrentCommit, [])[0].strip()

    if lastTaggedRef == currentCommit:
      info c, c.projectDir.PackageName, "the current commit '" & currentCommit & "' is already tagged '" & lastTag & "'"
      lastTag
    else:
      incrementTag(c, lastTag, field)
  else: "v0.0.1" # assuming no tags have been made yet

proc needsCommitLookup*(commit: string): bool {.inline.} =
  '.' in commit or commit == InvalidCommit

proc isShortCommitHash*(commit: string): bool {.inline.} =
  commit.len >= 4 and commit.len < 40

proc getRequiredCommit*(c: var AtlasContext; w: Dependency): string =
  if needsCommitLookup(w.commit): versionToCommit(c, w)
  elif isShortCommitHash(w.commit): shortToCommit(c, w.commit)
  else: w.commit

proc getRemoteUrl*(): PackageUrl =
  execProcess("git config --get remote.origin.url").strip().getUrl()

proc genLockEntry*(c: var AtlasContext; w: Dependency) =
  let url = getRemoteUrl()
  var commit = getRequiredCommit(c, w)
  if commit.len == 0 or needsCommitLookup(commit):
    commit = execProcess("git log -1 --pretty=format:%H").strip()
  c.lockFile.items[w.name.string] = LockFileEntry(url: $url, commit: commit)