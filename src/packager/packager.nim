#
#           Atlas Packager
#        (c) Copyright 2026 Atlas Contributors
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## CLI for harvesting Atlas package release caches from a packages.json list.

import std / [algorithm, json, monotimes, os, paths, sets, strutils, tables, times]
when defined(posix):
  import std / posix
import ../basic / [context, dependencycache, packageinfos, reporters]
import ../basic/subprocessgroups
import ./alldeps
import ./cacheharvest
import ./githubheadcheck

type
  PackagerDaemonSchedule* = object
    enabled*: bool
    intervalSeconds*: int

  PackagerCliOptions* = object
    packagesFile*: Path
    metadataDir*: Path
    packageNames*: seq[string]
    packagePrefixes*: seq[string]
    ignoredPackageNames*: seq[string]
    compressions*: seq[ArchiveCompression]
    githubApiChunkSize*: int
    threadCount*: int
    updateRepos*: bool
    regenerateTarballs*: bool
    createTarballs*: bool
    retryMissing*: bool
    ephemeral*: bool
    daemon*: PackagerDaemonSchedule

proc summarizeErrorLine(message: string): string =
  result = message.replace('\n', ' ').replace('\r', ' ')
  while "  " in result:
    result = result.replace("  ", " ")
  result = result.strip()

proc shouldSkipRetriedRepo(errorType: string; details: string): bool =
  let kind = errorType.toLowerAscii()
  let normalized = summarizeErrorLine(details).toLowerAscii()
  let looksInaccessible =
    "terminal prompts disabled" in normalized or
    "could not read username" in normalized or
    "repository not found" in normalized or
    "unable to access" in normalized or
    "failed to connect" in normalized or
    "could not resolve host" in normalized or
    "permission denied" in normalized or
    "access denied" in normalized or
    "authentication failed" in normalized or
    "not a valid remote name" in normalized or
    "fatal: cannot exec '/bin/false'" in normalized

  let looksMissing =
    "notfound:" in normalized or
    " not found" in normalized or
    "missing canonical remote" in normalized

  if kind == "missing":
    return true

  (kind in ["git", "access"] and (looksInaccessible or looksMissing)) or
    (kind == "unknown" and looksInaccessible)

proc loadAutoIgnoredPackages(
    metadataDir: Path;
    includeMissing: bool;
    includeOther: bool
): seq[string] =
  let errorsPath = metadataDir / Path"index-errors.json"
  if not fileExists($errorsPath):
    return

  try:
    let errors = parseFile($errorsPath)
    if errors.isNil or errors.kind != JObject:
      return

    for topKey, value in errors:
      if value.kind != JObject:
        continue
      let errorType = topKey
      let isMissing = errorType.toLowerAscii() == "missing"
      if (isMissing and not includeMissing) or (not isMissing and not includeOther):
        continue
      for packageName, errInfo in value:
        if errInfo.kind != JObject:
          continue
        let details = errInfo{"details"}.getStr()
        if shouldSkipRetriedRepo(errorType, details) and packageName notin result:
          result.add packageName
  except CatchableError:
    discard

proc shouldRefreshAllPackagesForReleaseCacheVersion(metadataDir: Path): bool =
  if not fileExists($(metadataDir / Path"index.json")):
    return false
  not retainedReleaseCacheVersionMatches(metadataDir)

proc parsePackageNames*(value: string): seq[string] =
  for rawName in value.split(','):
    let packageName = rawName.strip()
    if packageName.len > 0 and packageName notin result:
      result.add packageName

proc addPackageNames*(dest: var seq[string]; value: string) =
  for packageName in parsePackageNames(value):
    if packageName notin dest:
      dest.add packageName

proc parsePackagePrefixes*(value: string): seq[string] =
  for rawPrefix in value.split(','):
    let prefix = rawPrefix.strip()
    if prefix.len > 0 and prefix notin result:
      result.add prefix

proc addPackagePrefixes*(dest: var seq[string]; value: string) =
  for prefix in parsePackagePrefixes(value):
    if prefix notin dest:
      dest.add prefix

proc parseArchiveCompression*(value: string): ArchiveCompression =
  case value.normalize()
  of "xz":
    acXz
  of "gzip", "gz":
    acGzip
  of "zip":
    acZip
  else:
    raise newException(ValueError, "unknown compression: " & value)

proc parseArchiveCompressions*(value: string): seq[ArchiveCompression] =
  for rawName in value.split(','):
    let name = rawName.strip()
    if name.len == 0:
      continue
    let compression = parseArchiveCompression(name)
    if compression notin result:
      result.add compression

  if result.len == 0:
    raise newException(ValueError, "missing compression")

proc addArchiveCompressions*(dest: var seq[ArchiveCompression]; value: string) =
  for compression in parseArchiveCompressions(value):
    if compression notin dest:
      dest.add compression

proc parseThreadCount*(value: string): int =
  try:
    result = parseInt(value)
  except ValueError:
    raise newException(ValueError, "invalid thread count: " & value)
  if result < 1:
    raise newException(ValueError, "thread count must be at least 1")

proc parsePositiveCount*(value: string; label: string): int =
  try:
    result = parseInt(value)
  except ValueError:
    raise newException(ValueError, "invalid " & label & ": " & value)
  if result < 1:
    raise newException(ValueError, label & " must be at least 1")

proc parseDaemonInterval*(value: string): int =
  let raw = value.strip().toLowerAscii()
  if raw.len == 0:
    raise newException(ValueError, "missing daemon interval")

  var multiplier = 1
  var number = raw
  case raw[^1]
  of 's':
    number.setLen(number.len - 1)
  of 'm':
    multiplier = 60
    number.setLen(number.len - 1)
  of 'h':
    multiplier = 60 * 60
    number.setLen(number.len - 1)
  of 'd':
    multiplier = 60 * 60 * 24
    number.setLen(number.len - 1)
  else:
    discard

  if number.len == 0 or not number.allCharsInSet({'0'..'9'}):
    raise newException(ValueError, "invalid daemon interval: " & value)

  try:
    result = parseInt(number) * multiplier
  except ValueError:
    raise newException(ValueError, "invalid daemon interval: " & value)

  if result < 1:
    raise newException(ValueError, "daemon interval must be at least 1 second")

proc resolvePackagesFile*(opts: PackagerCliOptions): Path =
  if opts.packagesFile.len > 0:
    result = opts.packagesFile.absolutePath()

proc resolveMetadataDir*(opts: PackagerCliOptions): Path =
  if opts.metadataDir.len > 0:
    result = opts.metadataDir.absolutePath()
  else:
    result = Path"pkgs".absolutePath()

proc initPackagerWorkspace*(metadataDir: Path; packagesFile = Path"") =
  var ctx = AtlasContext()
  ctx.depsDir = metadataDir
  ctx.cacheDir = metadataDir
  ctx.packagesFileOverride = packagesFile
  createDir($metadataDir)
  setContext(ctx)

proc configurePackagerContext*(opts: PackagerCliOptions) =
  if opts.updateRepos:
    context().flags.incl UpdateRepos

proc configureNonInteractiveGit*() =
  const askPassPath =
    when defined(freebsd):
      "/usr/bin/false"
    else:
      "/bin/false"
  putEnv("GIT_TERMINAL_PROMPT", "0")
  putEnv("GIT_ASKPASS", askPassPath)
  putEnv("SSH_ASKPASS", askPassPath)
  putEnv("GCM_INTERACTIVE", "never")
  putEnv("GIT_SSH_COMMAND", "ssh -oBatchMode=yes -oNumberOfPasswordPrompts=0")

proc exitImmediatelyOnCtrlC*() {.noconv.} =
  echo "Quitting.."
  when defined(posix):
    terminateManagedSubprocessGroups()
    exitnow(130)
  else:
    quit(130)

proc installControlCHandler*() =
  setControlCHook(exitImmediatelyOnCtrlC)

proc writeSettings*(
    packagesFile: Path;
    metadataDir: Path;
    opts: PackagerCliOptions
) =
  notice "atlas:pkger", "settings"
  notice "atlas:pkger", "packages:", $packagesFile
  notice "atlas:pkger", "metadata:", $metadataDir
  notice "atlas:pkger", "threads:", $opts.threadCount
  notice "atlas:pkger", "github api chunk size:", $opts.githubApiChunkSize
  notice "atlas:pkger", "compressions:", archiveCompressionNames(opts.compressions).join(",")
  notice "atlas:pkger", "update repos:", $opts.updateRepos
  notice "atlas:pkger", "create tarballs:", $opts.createTarballs
  notice "atlas:pkger", "regenerate tarballs:", $opts.regenerateTarballs
  notice "atlas:pkger", "retry missing:", $opts.retryMissing
  notice "atlas:pkger", "ephemeral:", $opts.ephemeral
  notice "atlas:pkger", "daemon:", $opts.daemon.enabled
  if opts.daemon.enabled:
    notice "atlas:pkger", "interval:", $opts.daemon.intervalSeconds, "seconds"
  if opts.packageNames.len > 0:
    notice "atlas:pkger", "only filter:", opts.packageNames.join(",")
  else:
    notice "atlas:pkger", "only filter:", "all"
  if opts.packagePrefixes.len > 0:
    notice "atlas:pkger", "only starts with:", opts.packagePrefixes.join(",")
  else:
    notice "atlas:pkger", "only starts with:", "all"
  if opts.ignoredPackageNames.len > 0:
    notice "atlas:pkger", "ignore filter:", opts.ignoredPackageNames.join(",")
  else:
    notice "atlas:pkger", "ignore filter:", "none"

proc writeStats*(summary: HarvestSummary) =
  if summary.releaseCounts.len == 0:
    notice "atlas:pkger", "stats:", "no processed package release stats"
    return

  var counts = summary.releaseCounts
  counts.sort()
  var totalReleases = 0
  for count in counts:
    totalReleases += count
  let average = totalReleases.float / counts.len.float
  let median =
    if counts.len mod 2 == 1:
      counts[counts.len div 2].float
    else:
      (counts[counts.len div 2 - 1].float + counts[counts.len div 2].float) / 2.0

  notice "atlas:pkger",
    "stats tagged repos:", $summary.taggedPackages,
    "releases:", $summary.taggedReleases
  notice "atlas:pkger",
    "stats untagged repos:", $summary.untaggedPackages,
    "releases:", $summary.untaggedReleases
  notice "atlas:pkger",
    "stats releases per package avg:", formatFloat(average, ffDecimal, 2),
    "median:", formatFloat(median, ffDecimal, 2)

proc daemonSleepMilliseconds*(remaining: Duration): int =
  let remainingMilliseconds = remaining.inMilliseconds
  if remainingMilliseconds <= 0:
    result = 0
  else:
    result = int(remainingMilliseconds)

proc buildPackageForgeMetadata(
    repoStates: Table[string, GitHubRepoState]
): Table[string, PackageForgeMetadata] =
  var forgeCount = 0
  var forgeReleaseTotal = 0
  for packageName, repoState in repoStates.pairs:
    let forgeReleases = buildForgeReleaseMetadata(repoState)
    result[packageName] = PackageForgeMetadata(
      tags: repoState.tagNames.len > 0,
      forgeReleases: forgeReleases
    )
    if not forgeReleases.isNil and forgeReleases.kind != JNull:
      forgeCount += 1
      if forgeReleases.hasKey("releases") and forgeReleases["releases"].kind == JArray:
        forgeReleaseTotal += forgeReleases["releases"].len
  notice "atlas:pkger",
    "forge metadata summary:",
    "packages with forge releases:", $forgeCount,
    "total forge releases:", $forgeReleaseTotal

proc runPackagerOnce*(
    opts: PackagerCliOptions
): bool =
  let startedAt = getMonoTime()
  let metadataDir = resolveMetadataDir(opts)
  let packagesFile =
    if opts.packagesFile.len == 0:
      metadataDir / Path"packages.json"
    else:
      resolvePackagesFile(opts)
  initPackagerWorkspace(metadataDir, packagesFile)
  configurePackagerContext(opts)
  configureNonInteractiveGit()

  if not fileExists($packagesFile):
    if opts.packagesFile.len == 0:
      updatePackages()
  if not fileExists($packagesFile):
    stderr.writeLine("packages.json not found: " & $packagesFile)
    return false

  writeSettings(packagesFile, metadataDir, opts)
  var ignoredPackages = opts.ignoredPackageNames
  let githubRepoStates =
    if getEnv("GITHUB_API_KEY").len > 0:
      fetchGitHubRepoStates(
        packagesFile,
        opts.packageNames,
        opts.packagePrefixes,
        ignoredPackages,
        opts.githubApiChunkSize
      )
    else:
      initTable[string, GitHubRepoState]()
  let includeMissingAutoSkips = not opts.retryMissing
  let includeOtherAutoSkips = not opts.updateRepos and not opts.regenerateTarballs
  let packageForgeMetadata = buildPackageForgeMetadata(githubRepoStates)
  if includeMissingAutoSkips or includeOtherAutoSkips:
    for packageName in loadAutoIgnoredPackages(
        metadataDir,
        includeMissingAutoSkips,
        includeOtherAutoSkips
    ):
      if packageName notin ignoredPackages:
        ignoredPackages.add packageName
    if ignoredPackages.len > opts.ignoredPackageNames.len:
      var autoIgnored: seq[string]
      for packageName in ignoredPackages:
        if packageName notin opts.ignoredPackageNames:
          autoIgnored.add packageName
      notice "atlas:pkger", "auto-skipping inaccessible packages:", autoIgnored.join(",")
  let refreshAllPackages = shouldRefreshAllPackagesForReleaseCacheVersion(metadataDir)
  if refreshAllPackages:
    notice "atlas:pkger",
      "release cache version changed; reprocessing all packages",
      "current:", $PackageReleaseCacheVersion
  var skipRepoUpdatePackages = initHashSet[string]()
  if opts.updateRepos and githubRepoStates.len > 0 and
      not opts.regenerateTarballs and not refreshAllPackages:
    let githubSkipped = findUnchangedGitHubPackages(
      packagesFile,
      metadataDir,
      opts.packageNames,
      opts.packagePrefixes,
      ignoredPackages,
      githubRepoStates,
      archiveCompressionNames(opts.compressions),
    )
    if githubSkipped.len > 0:
      for packageName in githubSkipped:
        skipRepoUpdatePackages.incl packageName
      notice "atlas:pkger", "auto-skipping repo updates for unchanged github packages:", $githubSkipped.len()
  let summary = harvestRegistryCaches(
    packagesFile,
    metadataDir,
    opts.ephemeral,
    opts.updateRepos,
    skipRepoUpdatePackages,
    packageForgeMetadata,
    opts.packageNames,
    opts.packagePrefixes,
    ignoredPackages,
    opts.compressions,
    opts.threadCount,
    opts.regenerateTarballs,
    opts.createTarballs
  )
  let allDepsSummary = updatePackageAllDeps(
    packagesFile,
    metadataDir,
    opts.packageNames,
    opts.packagePrefixes,
    opts.ignoredPackageNames,
    opts.threadCount
  )
  notice "atlas:pkger",
    "allDeps:",
    "processed", $allDepsSummary.packagesProcessed,
    "updated", $allDepsSummary.packagesUpdated,
    "missing", $allDepsSummary.packagesSkipped,
    "failed", $allDepsSummary.packagesFailed
  stdout.writeLine(
    "processed " & $summary.packagesProcessed &
    " packages, failed " & $summary.packagesFailed &
    ", skipped " & $summary.aliasesSkipped &
    " aliases"
  )
  if summary.failures.len > 0:
    notice "atlas:pkger", "failed packages summary:"
    for failure in summary.failures:
      notice "atlas:pkger", failure.packageName & ":", summarizeErrorLine(failure.errorMessage)
  writeStats(summary)
  let elapsed = getMonoTime() - startedAt
  notice "atlas:pkger", "elapsed:", $initDuration(milliseconds = int(elapsed.inMilliseconds))
  true
