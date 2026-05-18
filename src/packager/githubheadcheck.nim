#
#           Atlas Package Cloner
#        (c) Copyright 2026 The Atlas contributors
#

## Batch-check GitHub default-branch HEAD commits for retained package metadata.

import std/[algorithm, httpclient, json, os, paths, sets, streams, strutils, tables]

import ../basic/[httpclientutils, packageinfos, pkgurls, reporters]

const
  GitHubGraphqlEndpoint* = "https://api.github.com/graphql"
  DefaultGitHubGraphqlChunkSize* = 64
  DefaultGitHubTagProbeCount* = 100

type
  RetainedPackageState* = object
    latestCommit*: string
    digestPath*: string
    releasesMetadataPath*: string

  RetainedIndexState* = object
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
          digestPath: entry{"digest"}.getStr(),
          releasesMetadataPath: entry{"releasesMetadata"}.getStr()
        )
  except CatchableError as e:
    warn "atlas:pkger", "cannot read retained index for GitHub HEAD check:", e.msg

proc hasRetainedArtifacts(metadataDir: Path; state: RetainedPackageState): bool =
  state.latestCommit.len > 0 and
    state.digestPath.len > 0 and
    state.releasesMetadataPath.len > 0 and
    fileExists($(metadataDir / Path(state.digestPath))) and
    fileExists($(metadataDir / Path(state.releasesMetadataPath)))

proc loadRetainedVersions(metadataDir: Path; state: RetainedPackageState): HashSet[string] =
  let releasesPath = metadataDir / Path(state.releasesMetadataPath)
  if not fileExists($releasesPath):
    return

  try:
    let root = parseFile($releasesPath)
    if "releases" notin root or root["releases"].kind != JArray:
      return
    for entry in root["releases"]:
      let vtag = entry{"vtag"}.getStr()
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

proc fetchGitHubHeadChunk(
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

proc mergeGitHubRepoStates(
    dest: var Table[string, GitHubRepoState];
    src: Table[string, GitHubRepoState]
) =
  for packageName, state in src.pairs:
    dest[packageName] = state

proc isFatalGitHubProbeError(message: string): bool =
  let normalized = message.toLowerAscii()
  "401 unauthorized" in normalized or
    "bad credentials" in normalized or
    "403 forbidden" in normalized

proc fetchGitHubHeadChunkAdaptive(
    targets: seq[GitHubRepoTarget];
    token: string;
    chunkLabel: string
): Table[string, GitHubRepoState] =
  try:
    return fetchGitHubHeadChunk(targets, token)
  except CatchableError as e:
    if isFatalGitHubProbeError(e.msg):
      raise newException(GitHubProbeFatalError, e.msg)
    if targets.len <= 1:
      warn "atlas:pkger",
        "github api check package probe failed:",
        chunkLabel,
        "package:", targets[0].packageName,
        "error:", e.msg
      return

    let mid = targets.len div 2
    let left = targets[0 ..< mid]
    let right = targets[mid .. ^1]
    warn "atlas:pkger",
      "github api check chunk split:",
      chunkLabel,
      "packages:", targets[0].packageName, "->", targets[^1].packageName,
      "error:", e.msg
    result.mergeGitHubRepoStates(
      fetchGitHubHeadChunkAdaptive(left, token, chunkLabel & ".1")
    )
    result.mergeGitHubRepoStates(
      fetchGitHubHeadChunkAdaptive(right, token, chunkLabel & ".2")
    )

proc batchedGitHubHeads(
    targets: openArray[GitHubRepoTarget];
    token: string;
    chunkSize = DefaultGitHubGraphqlChunkSize
): Table[string, GitHubRepoState] =
  var i = 0
  let totalChunks =
    if targets.len == 0: 0
    else: (targets.len + max(1, chunkSize) - 1) div max(1, chunkSize)
  var chunkIndex = 0
  while i < targets.len:
    let j = min(targets.len, i + max(1, chunkSize))
    inc chunkIndex
    notice "atlas:pkger",
      "github api check chunk:", $chunkIndex, "of", $totalChunks,
      "packages:", targets[i].packageName, "->", targets[j - 1].packageName
    let chunkHeads =
      try:
        fetchGitHubHeadChunkAdaptive(
          targets[i ..< j],
          token,
          $chunkIndex & "/" & $totalChunks
        )
      except GitHubProbeFatalError as e:
        warn "atlas:pkger", "github api check disabled:", e.msg
        return
    for packageName, oid in chunkHeads.pairs:
      result[packageName] = oid
    i = j

proc findUnchangedGitHubPackages*(
    packagesFile: Path;
    metadataDir: Path;
    packageNames: seq[string];
    ignoredPackageNames: seq[string];
    currentCompressions: openArray[string];
    chunkSize = DefaultGitHubGraphqlChunkSize
): seq[string] =
  let token = getEnv("GITHUB_API_KEY")
  if token.len == 0:
    info "atlas:pkger", "github api check skipped: missing GITHUB_API_KEY"
    return

  let retainedIndex = loadRetainedIndexState(metadataDir)
  if retainedIndex.packages.len == 0:
    info "atlas:pkger", "github api check skipped: missing retained index package state"
    return
  if not sameCompressions(retainedIndex.compressions, currentCompressions):
    info "atlas:pkger", "github api check skipped: compressions changed"
    return

  let ignored = ignoredPackageNames.toHashSet()
  var targets: seq[GitHubRepoTarget]
  for info in loadPackageList(packagesFile):
    if info.kind != pkPackage:
      continue
    if packageNames.len > 0 and info.name notin packageNames:
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

  if targets.len == 0:
    info "atlas:pkger", "github api check skipped: no eligible github packages"
    return

  notice "atlas:pkger", "github api check: probing", $targets.len, "package(s)"
  let heads = batchedGitHubHeads(targets, token, chunkSize)
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
