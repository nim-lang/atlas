#
#           Atlas Package Cloner
#        (c) Copyright 2026 The Atlas contributors
#

## Batch-check GitHub default-branch HEAD commits for retained package metadata.

import std/[algorithm, httpclient, json, os, paths, sets, streams, strutils, tables]

import ../basic/[dependencycache, httpclientutils, packageinfos, pkgurls, reporters]
import ./cacheharvest

const
  GitHubGraphqlEndpoint* = "https://api.github.com/graphql"
  DefaultGitHubGraphqlBatchSize* = 80
  DefaultGitHubTagProbeCount* = 80
  DefaultGitHubGraphqlRetries* = 3

type
  RetainedPackageState* = object
    latestCommit*: string
    releasesMetadataPath*: string

  RetainedIndexState* = object
    releaseCacheVersion*: int
    compressions*: seq[string]
    packages*: Table[string, RetainedPackageState]

  GitHubRepoTarget = object
    packageName: string
    owner: string
    repo: string
    latestCommit: string
    retainedVersions: HashSet[string]

  GitHubRepoState = object
    headOid: string
    tagNames: seq[string]

  GitHubProbeFatalError = object of CatchableError

proc loadPackageList(packagesFile: Path): seq[PackageInfo] =
  let root = parseFile($packagesFile)
  for node in root:
    let info = packageinfos.fromJson(node)
    if info != nil:
      result.add info

proc normalizeCompressions(compressions: openArray[string]): seq[string] =
  for compression in compressions:
    let normalized = compression.strip().toLowerAscii()
    if normalized.len > 0 and normalized notin result:
      result.add normalized
  result.sort()

proc sameCompressions(a, b: openArray[string]): bool =
  normalizeCompressions(a) == normalizeCompressions(b)

proc loadRetainedIndexState*(metadataDir: Path): RetainedIndexState =
  let indexPath = metadataDir / Path"index.json"
  if not fileExists($indexPath):
    return

  try:
    let index = parseFile($indexPath)
    result.releaseCacheVersion = index{"releaseCacheVersion"}.getInt()
    if "compressions" in index and index["compressions"].kind == JArray:
      for compression in index["compressions"]:
        result.compressions.add compression.getStr()

    if "packages" in index and index["packages"].kind == JArray:
      for entry in index["packages"]:
        if entry.kind != JObject or "name" notin entry:
          continue
        let name = entry["name"].getStr()
        if name.len == 0:
          continue
        result.packages[name] = RetainedPackageState(
          latestCommit: entry{"latestCommit"}.getStr(),
          releasesMetadataPath: entry{"releasesMetadata"}.getStr()
        )
  except CatchableError as e:
    warn "atlas:pkger", "cannot read retained index for GitHub HEAD check:", e.msg

proc hasRetainedArtifacts(metadataDir: Path; state: RetainedPackageState): bool =
  state.latestCommit.len > 0 and
    state.releasesMetadataPath.len > 0 and
    fileExists($(metadataDir / Path(state.releasesMetadataPath)))

proc retainedReleaseCacheVersionMatches*(metadataDir: Path): bool =
  let retainedIndex = loadRetainedIndexState(metadataDir)
  retainedIndex.releaseCacheVersion == PackageReleaseCacheVersion

proc loadRetainedVersions(metadataDir: Path; state: RetainedPackageState): HashSet[string] =
  let releasesPath = metadataDir / Path(state.releasesMetadataPath)
  if not fileExists($releasesPath):
    return

  try:
    let root = parseFile($releasesPath)
    let releases =
      if root.hasKey("releases") and root["releases"].kind == JArray: root["releases"]
      else: nil
    if releases.isNil:
      return
    for entry in releases:
      let vtag = entry{"v"}.getStr()
      if vtag.len == 0:
        continue
      let at = vtag.find('@')
      let version =
        if at >= 0: vtag[0 ..< at]
        else: vtag
      if version.len > 0 and version != "#head":
        result.incl version
  except CatchableError:
    discard

proc toGitHubRepoTarget(
    info: PackageInfo;
    metadataDir: Path;
    state: RetainedPackageState
): GitHubRepoTarget =
  let url = createUrlSkipPatterns(info.url, skipDirTest = true)
  let host = url.cloneUri().hostname.toLowerAscii()
  if host != "github.com":
    return
  let owner = url.qualifiedName.user.strip(chars = {'/', '\\'})
  let repo = url.qualifiedName.name
  if owner.len == 0 or repo.len == 0:
    return
  result = GitHubRepoTarget(
    packageName: info.name,
    owner: owner,
    repo: repo,
    latestCommit: state.latestCommit,
    retainedVersions: loadRetainedVersions(metadataDir, state)
  )

proc graphqlEscape(value: string): string =
  result = value.replace("\\", "\\\\")
  result = result.replace("\"", "\\\"")

proc buildGitHubHeadQuery(targets: openArray[GitHubRepoTarget]): string =
  result = "query AtlasPackagerRepoHeads {\n"
  for i, target in targets:
    result.add(
      "  r" & $i &
      ": repository(owner: \"" & graphqlEscape(target.owner) &
      "\", name: \"" & graphqlEscape(target.repo) &
      "\") { defaultBranchRef { target { ... on Commit { oid } } } refs(refPrefix: \"refs/tags/\", first: " &
      $DefaultGitHubTagProbeCount &
      ", orderBy: {field: TAG_COMMIT_DATE, direction: DESC}) { nodes { name } } }\n"
    )
  result.add("}")

proc fetchGitHubHeadBatch(
    targets: openArray[GitHubRepoTarget];
    token: string
): Table[string, GitHubRepoState] =
  if targets.len == 0:
    return

  let client = newHttpClient(headers = newHttpHeaders({
    "User-Agent": AtlasUserAgent,
    "Authorization": "Bearer " & token,
    "Content-Type": "application/json",
    "Accept": "application/json"
  }))
  try:
    let body = %*{"query": buildGitHubHeadQuery(targets)}
    let response = client.request(
      GitHubGraphqlEndpoint,
      httpMethod = HttpPost,
      body = $body
    )
    let responseBody = response.bodyStream.readAll()
    if response.code.is4xx or response.code.is5xx:
      raise newException(
        IOError,
        "GitHub GraphQL returned " & response.status & ": " &
          responseBody.replace('\n', ' ').replace('\r', ' ').strip()
      )
    if responseBody.strip().len == 0:
      raise newException(IOError, "GitHub GraphQL returned an empty response body")

    let root =
      try:
        parseJson(responseBody)
      except JsonParsingError as e:
        let snippet = responseBody.replace('\n', ' ').replace('\r', ' ').strip()
        raise newException(
          IOError,
          "GitHub GraphQL returned non-JSON response: " &
            (if snippet.len > 200: snippet[0 .. 199] & "..." else: snippet) &
            " (" & e.msg & ")"
        )
    let errors = root{"errors"}
    if not errors.isNil and errors.kind == JArray and errors.len > 0:
      var summaries: seq[string]
      for err in errors:
        let msg = err{"message"}.getStr()
        if msg.len > 0:
          summaries.add msg
      if summaries.len > 0:
        warn "atlas:pkger", "github api check graphql errors:", summaries.join(" | ")
    let data = root{"data"}
    if data.isNil or data.kind != JObject:
      return

    for i, target in targets:
      let repoNode = data{"r" & $i}
      if repoNode.isNil or repoNode.kind != JObject:
        continue
      var state: GitHubRepoState
      state.headOid = repoNode{"defaultBranchRef", "target", "oid"}.getStr()
      let tags = repoNode{"refs", "nodes"}
      if not tags.isNil and tags.kind == JArray:
        for tag in tags:
          let tagName = tag{"name"}.getStr()
          if tagName.len > 0:
            state.tagNames.add tagName
      if state.headOid.len > 0 or state.tagNames.len > 0:
        result[target.packageName] = state
  finally:
    client.close()

proc isFatalGitHubProbeError(message: string): bool =
  let normalized = message.toLowerAscii()
  "401 unauthorized" in normalized or
    "bad credentials" in normalized or
    "403 forbidden" in normalized

proc isTransientGitHubProbeError(message: string): bool =
  let normalized = message.toLowerAscii()
  "502 bad gateway" in normalized or
    "503 service unavailable" in normalized or
    "504 gateway timeout" in normalized or
    "timeout" in normalized or
    "timed out" in normalized or
    "connection reset" in normalized or
    "connection refused" in normalized or
    "temporarily unavailable" in normalized or
    "unexpected eof" in normalized

proc fetchGitHubHeadBatchWithRetries(
    targets: openArray[GitHubRepoTarget];
    token: string;
    batchLabel: string
): Table[string, GitHubRepoState] =
  var lastError = ""
  for attempt in 1..DefaultGitHubGraphqlRetries:
    try:
      return fetchGitHubHeadBatch(targets, token)
    except CatchableError as e:
      lastError = e.msg
      if isFatalGitHubProbeError(e.msg):
        raise newException(GitHubProbeFatalError, e.msg)
      if not isTransientGitHubProbeError(e.msg):
        break
      if attempt < DefaultGitHubGraphqlRetries:
        warn "atlas:pkger",
          "github api check retry:",
          batchLabel,
          "attempt:", $attempt, "of", $DefaultGitHubGraphqlRetries,
          "packages:", targets[0].packageName, "->", targets[^1].packageName,
          "error:", e.msg
        sleep(attempt * 1000)
  warn "atlas:pkger",
    "github api check batch failed:",
    batchLabel,
    "packages:", targets[0].packageName, "->", targets[^1].packageName,
    "error:", lastError

proc batchedGitHubHeads(
    targets: openArray[GitHubRepoTarget];
    token: string;
    batchSize = DefaultGitHubGraphqlBatchSize
): Table[string, GitHubRepoState] =
  var i = 0
  let totalBatchs =
    if targets.len == 0: 0
    else: (targets.len + max(1, batchSize) - 1) div max(1, batchSize)
  var batchIndex = 0
  while i < targets.len:
    let j = min(targets.len, i + max(1, batchSize))
    inc batchIndex
    notice "atlas:pkger",
      "github api check batch:", $batchIndex, "of", $totalBatchs,
      "packages:", targets[i].packageName, "->", targets[j - 1].packageName
    let batchHeads =
      try:
        fetchGitHubHeadBatchWithRetries(
          targets[i ..< j],
          token,
          $batchIndex & "/" & $totalBatchs
        )
      except GitHubProbeFatalError as e:
        warn "atlas:pkger", "github api check disabled:", e.msg
        return
    for packageName, oid in batchHeads.pairs:
      result[packageName] = oid
    i = j

proc findUnchangedGitHubPackages*(
    packagesFile: Path;
    metadataDir: Path;
    packageNames: seq[string];
    packagePrefixes: seq[string];
    ignoredPackageNames: seq[string];
    currentCompressions: openArray[string];
    batchSize = DefaultGitHubGraphqlBatchSize
): seq[string] =
  let token = getEnv("GITHUB_API_KEY")
  if token.len == 0:
    info "atlas:pkger", "github api check skipped: missing GITHUB_API_KEY"
    return

  let retainedIndex = loadRetainedIndexState(metadataDir)
  if retainedIndex.packages.len == 0:
    info "atlas:pkger", "github api check skipped: missing retained index package state"
    return
  if retainedIndex.releaseCacheVersion != PackageReleaseCacheVersion:
    info "atlas:pkger",
      "github api check skipped: release cache version changed",
      "cached:", $retainedIndex.releaseCacheVersion,
      "current:", $PackageReleaseCacheVersion
    return
  if not sameCompressions(retainedIndex.compressions, currentCompressions):
    info "atlas:pkger", "github api check skipped: compressions changed"
    return

  let ignored = ignoredPackageNames.toHashSet()
  var targets: seq[GitHubRepoTarget]
  for info in loadPackageList(packagesFile):
    if info.kind != pkPackage:
      continue
    if not matchesPackageFilters(info.name, packageNames, packagePrefixes):
      continue
    if info.name in ignored:
      continue
    if not retainedIndex.packages.hasKey(info.name):
      continue
    let state = retainedIndex.packages[info.name]
    if not hasRetainedArtifacts(metadataDir, state):
      continue
    let target = toGitHubRepoTarget(info, metadataDir, state)
    if target.packageName.len > 0:
      targets.add target

  targets.sort(proc (a, b: GitHubRepoTarget): int = cmp(a.packageName, b.packageName))

  if targets.len == 0:
    info "atlas:pkger", "github api check skipped: no eligible github packages"
    return

  notice "atlas:pkger", "github api check: probing", $targets.len, "package(s)"
  let heads = batchedGitHubHeads(targets, token, batchSize)
  for target in targets:
    if not heads.hasKey(target.packageName):
      info "atlas:pkger",
        "github api check unavailable:",
        target.packageName
      continue
    let remoteState = heads.getOrDefault(target.packageName)
    if remoteState.headOid != target.latestCommit:
      info "atlas:pkger",
        "github api check refresh:",
        target.packageName,
        "head changed",
        "cached:", target.latestCommit,
        "remote:", remoteState.headOid
      continue
    var hasUnseenTag = false
    var unseenTag = ""
    for tagName in remoteState.tagNames:
      if tagName notin target.retainedVersions:
        hasUnseenTag = true
        unseenTag = tagName
        break
    if not hasUnseenTag:
      notice "atlas:pkger",
        "github api check up to date:",
        target.packageName,
        "head:", remoteState.headOid,
        "tags checked:", $remoteState.tagNames.len
      result.add target.packageName
    else:
      info "atlas:pkger",
        "github api check refresh:",
        target.packageName,
        "new tag:", unseenTag,
        "cached head:", target.latestCommit
