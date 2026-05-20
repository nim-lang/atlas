#
#           Atlas Packager
#        (c) Copyright 2026 Atlas Contributors
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## CLI for harvesting Atlas package release caches from a packages.json list.

import std / [algorithm, cpuinfo, json, monotimes, parseopt, os, paths, strutils, times]
when defined(posix):
  import std / posix
import ../basic / [context, dependencycache, packageinfos, reporters]
import ../basic/subprocessgroups
import ./cacheharvest
import ./githubheadcheck

proc usage*(versionString: string): string =
  "atlas-packager - Atlas Packager Version " & versionString & """
Experimental packager based on Atlas package parser.

  (c) 2026 Atlas Contributors
Usage:
  atlas-packager [options] [packages.json] [packages-dir]

Options:
  --help, -h            show this help
  --version, -v         show the version
  --packages=path       write copied cache files to the given directory
  --only=name[,name]    process only the named package(s) from packages.json
  --ignore=name[,name]  skip the named package(s) from packages.json
  --update-repos, -u    run `gitops.updateRepo` for existing repos before harvest
  --regenerate-tarballs rebuild all tarballs instead of reusing matching archives
  --github-api-chunk-size=count
                        github api batch size for precheck
                        default: 64
  --compression=type    archive compression(s): gzip, xz, or comma-separated list
                        default: gzip
  --threads=count, -j   number of package processing threads
                        default: number of processors
  --ephemeral           delete each cloned repo from pkgs/ after its metadata is produced
  --daemon              repeat the harvest run on a schedule
  --interval=duration   set daemon interval, default is 1h; accepts
                        plain seconds or a suffix of s, m, h, or d

Environment:
  ATLAS_PACKAGER_PACKAGES             same as --packages
  ATLAS_PACKAGER_ONLY                 same as --only
  ATLAS_PACKAGER_IGNORE               same as --ignore
  ATLAS_PACKAGER_UPDATE_REPOS         same as --update-repos
  ATLAS_PACKAGER_GITHUB_API_CHUNK_SIZE
                                      same as --github-api-chunk-size
  ATLAS_PACKAGER_COMPRESSION          same as --compression
  ATLAS_PACKAGER_THREADS              same as --threads
  ATLAS_PACKAGER_EPHEMERAL            same as --ephemeral
"""

type
  PackagerDaemonSchedule* = object
    enabled*: bool
    intervalSeconds*: int

  PackagerCliOptions* = object
    packagesFile*: Path
    metadataDir*: Path
    packageNames*: seq[string]
    ignoredPackageNames*: seq[string]
    compressions*: seq[ArchiveCompression]
    githubApiChunkSize*: int
    threadCount*: int
    updateRepos*: bool
    regenerateTarballs*: bool
    ephemeral*: bool
    daemon*: PackagerDaemonSchedule

const
  DefaultDaemonIntervalSeconds* = 60 * 60
  EnvPackages* = "ATLAS_PACKAGER_PACKAGES"
  EnvOnly* = "ATLAS_PACKAGER_ONLY"
  EnvIgnore* = "ATLAS_PACKAGER_IGNORE"
  EnvUpdateRepos* = "ATLAS_PACKAGER_UPDATE_REPOS"
  EnvGitHubApiChunkSize* = "ATLAS_PACKAGER_GITHUB_API_CHUNK_SIZE"
  EnvCompression* = "ATLAS_PACKAGER_COMPRESSION"
  EnvThreads* = "ATLAS_PACKAGER_THREADS"
  EnvEphemeral* = "ATLAS_PACKAGER_EPHEMERAL"

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

  (kind in ["git", "access"] and (looksInaccessible or looksMissing)) or
    (kind == "unknown" and looksInaccessible)

proc loadAutoIgnoredPackages(metadataDir: Path): seq[string] =
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

proc parseArchiveCompression*(value: string): ArchiveCompression =
  case value.normalize()
  of "xz":
    acXz
  of "gzip", "gz":
    acGzip
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

proc parseEnvBool*(value: string; label: string): bool =
  case value.strip().toLowerAscii()
  of "1", "true", "yes", "on":
    true
  of "0", "false", "no", "off":
    false
  else:
    raise newException(ValueError, "invalid " & label & ": " & value)

proc applyPackagerEnvDefaults*(opts: var PackagerCliOptions) =
  if existsEnv(EnvPackages):
    let val = getEnv(EnvPackages).strip()
    if val.len > 0:
      opts.metadataDir = Path(val)

  if existsEnv(EnvOnly):
    let val = getEnv(EnvOnly).strip()
    if val.len > 0:
      opts.packageNames = parsePackageNames(val)

  if existsEnv(EnvIgnore):
    let val = getEnv(EnvIgnore).strip()
    if val.len > 0:
      opts.ignoredPackageNames = parsePackageNames(val)

  if existsEnv(EnvUpdateRepos):
    opts.updateRepos = parseEnvBool(getEnv(EnvUpdateRepos), "update repos env var")

  if existsEnv(EnvGitHubApiChunkSize):
    opts.githubApiChunkSize =
      parsePositiveCount(getEnv(EnvGitHubApiChunkSize), "github api chunk size env var")

  if existsEnv(EnvCompression):
    let val = getEnv(EnvCompression).strip()
    if val.len > 0:
      opts.compressions = parseArchiveCompressions(val)

  if existsEnv(EnvThreads):
    opts.threadCount = parseThreadCount(getEnv(EnvThreads))

  if existsEnv(EnvEphemeral):
    opts.ephemeral = parseEnvBool(getEnv(EnvEphemeral), "ephemeral env var")

proc writeHelp*(versionString: string; code = 2) =
  stdout.write(usage(versionString))
  stdout.flushFile()
  quit(code)

proc writeVersion*(versionString: string) =
  stdout.write("version: " & versionString & "\n")
  stdout.flushFile()
  quit(0)

proc parseAtlasPackagerOptions*(
    params: seq[string];
    versionString: string;
    positional: var seq[string]
): PackagerCliOptions =
  result.compressions = @[acGzip]
  result.githubApiChunkSize = DefaultGitHubGraphqlBatchSize
  result.threadCount = max(1, countProcessors())
  result.daemon.intervalSeconds = DefaultDaemonIntervalSeconds
  try:
    result.applyPackagerEnvDefaults()
  except ValueError:
    writeHelp(versionString)
  var compressionWasSet = false
  var onlyWasSet = false
  var ignoreWasSet = false
  for kind, key, val in getopt(params):
    case kind
    of cmdLongOption, cmdShortOption:
      case normalize(key)
      of "help", "h":
        writeHelp(versionString, 0)
      of "version", "v":
        writeVersion(versionString)
      of "packages":
        if val.len == 0:
          writeHelp(versionString)
        result.metadataDir = Path(val)
      of "only":
        if val.len == 0:
          writeHelp(versionString)
        if not onlyWasSet:
          result.packageNames.setLen(0)
          onlyWasSet = true
        result.packageNames.addPackageNames(val)
      of "ignore":
        if val.len == 0:
          writeHelp(versionString)
        if not ignoreWasSet:
          result.ignoredPackageNames.setLen(0)
          ignoreWasSet = true
        result.ignoredPackageNames.addPackageNames(val)
      of "update-repos", "u":
        result.updateRepos = true
      of "regenerate-tarballs":
        result.regenerateTarballs = true
      of "github-api-chunk-size":
        if val.len == 0:
          writeHelp(versionString)
        try:
          result.githubApiChunkSize = parsePositiveCount(val, "github api chunk size")
        except ValueError:
          writeHelp(versionString)
      of "compression":
        if val.len == 0:
          writeHelp(versionString)
        try:
          if not compressionWasSet:
            result.compressions.setLen(0)
            compressionWasSet = true
          result.compressions.addArchiveCompressions(val)
        except ValueError:
          writeHelp(versionString)
      of "threads", "j":
        if val.len == 0:
          writeHelp(versionString)
        try:
          result.threadCount = parseThreadCount(val)
        except ValueError:
          writeHelp(versionString)
      of "ephemeral":
        result.ephemeral = true
      of "daemon", "d":
        result.daemon.enabled = true
      of "interval", "daemon-interval", "daemoninterval":
        if val.len == 0:
          writeHelp(versionString)
        try:
          result.daemon.intervalSeconds = parseDaemonInterval(val)
        except ValueError:
          writeHelp(versionString)
      else:
        writeHelp(versionString)
    of cmdArgument:
      positional.add key
    of cmdEnd:
      assert false, "cannot happen"

proc resolvePackagesFile*(opts: PackagerCliOptions; args: seq[string]): Path =
  if opts.packagesFile.len > 0:
    result = opts.packagesFile.absolutePath()
  elif args.len >= 1:
    result = Path(args[0]).absolutePath()

proc resolveMetadataDir*(opts: PackagerCliOptions; args: seq[string]): Path =
  if opts.metadataDir.len > 0:
    result = opts.metadataDir.absolutePath()
  elif args.len >= 2:
    result = Path(args[1]).absolutePath()
  else:
    result = Path"pkgs".absolutePath()

proc initPackagerWorkspace*(metadataDir: Path) =
  var ctx = AtlasContext()
  ctx.depsDir = metadataDir
  ctx.cacheDir = metadataDir
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
  notice "atlas:pkger", "regenerate tarballs:", $opts.regenerateTarballs
  notice "atlas:pkger", "ephemeral:", $opts.ephemeral
  notice "atlas:pkger", "daemon:", $opts.daemon.enabled
  if opts.daemon.enabled:
    notice "atlas:pkger", "interval:", $opts.daemon.intervalSeconds, "seconds"
  if opts.packageNames.len > 0:
    notice "atlas:pkger", "only filter:", opts.packageNames.join(",")
  else:
    notice "atlas:pkger", "only filter:", "all"
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

proc runPackagerOnce*(
    opts: PackagerCliOptions;
    args: seq[string]
): bool =
  let startedAt = getMonoTime()
  let metadataDir = resolveMetadataDir(opts, args)
  initPackagerWorkspace(metadataDir)
  configurePackagerContext(opts)
  configureNonInteractiveGit()
  let packagesFile =
    if opts.packagesFile.len == 0 and args.len == 0:
      metadataDir / Path"packages.json"
    else:
      resolvePackagesFile(opts, args)

  if not fileExists($packagesFile):
    updatePackages()
  if not fileExists($packagesFile):
    stderr.writeLine("packages.json not found: " & $packagesFile)
    return false

  writeSettings(packagesFile, metadataDir, opts)
  var ignoredPackages = opts.ignoredPackageNames
  for packageName in loadAutoIgnoredPackages(metadataDir):
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
  if opts.updateRepos and not opts.regenerateTarballs and not refreshAllPackages:
    let githubSkipped = findUnchangedGitHubPackages(
      packagesFile,
      metadataDir,
      opts.packageNames,
      ignoredPackages,
      archiveCompressionNames(opts.compressions),
      opts.githubApiChunkSize
    )
    if githubSkipped.len > 0:
      for packageName in githubSkipped:
        if packageName notin ignoredPackages:
          ignoredPackages.add packageName
      notice "atlas:pkger", "auto-skipping unchanged github packages:", $githubSkipped.len()
  let summary = harvestRegistryCaches(
    packagesFile,
    metadataDir,
    opts.ephemeral,
    opts.updateRepos,
    opts.packageNames,
    ignoredPackages,
    opts.compressions,
    opts.threadCount,
    opts.regenerateTarballs
  )
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

proc main*(versionString = "unknown") =
  setAtlasVerbosity(Notice)
  enableManagedSubprocessGroups()
  installControlCHandler()
  var args: seq[string]
  let opts = parseAtlasPackagerOptions(commandLineParams(), versionString, args)
  if args.len > 2:
    writeHelp(versionString)

  while true:
    let runOk = runPackagerOnce(opts, args)
    if not opts.daemon.enabled:
      if not runOk:
        quit(1)
      break

    if runOk:
      notice "atlas:pkger", "daemon sleeping for", $opts.daemon.intervalSeconds, "seconds"
    else:
      warn "atlas:pkger", "run failed; retrying in", $opts.daemon.intervalSeconds, "seconds"
    sleep opts.daemon.intervalSeconds * 1000

when isMainModule:
  main()
