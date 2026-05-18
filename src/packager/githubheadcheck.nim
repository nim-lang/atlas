#
#           Atlas Package Cloner
#        (c) Copyright 2026 The Atlas contributors
#

## Batch-check GitHub default-branch HEAD commits for retained package metadata.

import std/[algorithm, httpclient, json, os, paths, sets, strutils, tables]

import ../basic/[httpclientutils, packageinfos, pkgurls, reporters]

const
  GitHubGraphqlEndpoint* = "https://api.github.com/graphql"
  DefaultGitHubGraphqlChunkSize* = 40
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
    "Accept-Encoding": "gzip",
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
    if response.code.is4xx or response.code.is5xx:
      raise newException(IOError, "GitHub GraphQL returned " & response.status)

    let root = parseJson(response.body)
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

proc batchedGitHubHeads(
    targets: openArray[GitHubRepoTarget];
    token: string;
    chunkSize = DefaultGitHubGraphqlChunkSize
): Table[string, GitHubRepoState] =
  var i = 0
  while i < targets.len:
    let j = min(targets.len, i + max(1, chunkSize))
    let chunkHeads = fetchGitHubHeadChunk(targets[i ..< j], token)
    for packageName, oid in chunkHeads.pairs:
      result[packageName] = oid
    i = j

proc findUnchangedGitHubPackages*(
    packagesFile: Path;
    metadataDir: Path;
    packageNames: seq[string];
    ignoredPackageNames: seq[string];
    currentCompressions: openArray[string]
): seq[string] =
  let token = getEnv("GITHUB_API_KEY")
  if token.len == 0:
    return

  let retainedIndex = loadRetainedIndexState(metadataDir)
  if retainedIndex.packages.len == 0:
    return
  if not sameCompressions(retainedIndex.compressions, currentCompressions):
    info "atlas:pkger", "skipping GitHub HEAD check because compressions changed"
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
    return

  let heads = batchedGitHubHeads(targets, token)
  for target in targets:
    let remoteState = heads.getOrDefault(target.packageName)
    if remoteState.headOid != target.latestCommit:
      continue
    var hasUnseenTag = false
    for tagName in remoteState.tagNames:
      if tagName notin target.retainedVersions:
        hasUnseenTag = true
        break
    if not hasUnseenTag:
      result.add target.packageName
