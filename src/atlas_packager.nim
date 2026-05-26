#
#           Atlas Package Cloner
#        (c) Copyright 2026 The Atlas contributors
#

## Top-level wrapper for the Atlas packager CLI.

import std/[algorithm, cpuinfo, monotimes, os, osproc, parseopt, paths, strutils, times]

import basic/[reporters, subprocessgroups]
import packager/[githubheadcheck, packager]

const
  AtlasRootDir = currentSourcePath().parentDir().parentDir()
  AtlasNimbleFile = AtlasRootDir / "atlas.nimble"
  AtlasGitDir = AtlasRootDir / ".git"
  DefaultDaemonIntervalSeconds* = 60 * 60
  EnvPackages* = "ATLAS_PACKAGER_PACKAGES"
  EnvOnly* = "ATLAS_PACKAGER_ONLY"
  EnvIgnore* = "ATLAS_PACKAGER_IGNORE"
  EnvUpdateRepos* = "ATLAS_PACKAGER_UPDATE_REPOS"
  EnvNoTarballs* = "ATLAS_PACKAGER_NO_TARBALLS"
  EnvGitHubApiChunkSize* = "ATLAS_PACKAGER_GITHUB_API_CHUNK_SIZE"
  EnvCompression* = "ATLAS_PACKAGER_COMPRESSION"
  EnvThreads* = "ATLAS_PACKAGER_THREADS"
  EnvEphemeral* = "ATLAS_PACKAGER_EPHEMERAL"

const AtlasIsDirty =
  if dirExists(AtlasGitDir):
    staticExec("git -C " & quoteShell(AtlasRootDir) & " status --porcelain").strip().len > 0
  else:
    false

const AtlasPackageVersion =
  block:
    var ver = "0.0.0"
    if fileExists(AtlasNimbleFile):
      for line in staticRead(AtlasNimbleFile).splitLines():
        if line.startsWith("version ="):
          ver = line.split("=")[1].replace("\"", "").strip()
    if AtlasIsDirty:
      ver.add "+dirty"
    ver

const AtlasCommit =
  if dirExists(AtlasGitDir):
    staticExec("git -C " & quoteShell(AtlasRootDir) & " log -n 1 --format=%H")
  else:
    "unknown"

const AtlasPackagerVersion = AtlasPackageVersion & " (sha: " & AtlasCommit & ")"

proc usage*(versionString: string): string =
  "atlas-packager - Atlas Packager Version " & versionString & """
Experimental packager based on Atlas package parser.

  (c) 2026 Atlas Contributors
Usage:
  atlas-packager [options]

Options:
  --help, -h            show this help
  --version, -v         show the version
  --packages=path       write copied cache files to the given directory
  --packages-file=path  read package definitions from the given packages.json
  --only=name[,name]    process only the named package(s) from packages.json
  --only-starts-with=s  process only package(s) whose names start with prefix s
  --ignore=name[,name]  skip the named package(s) from packages.json
  --update-repos, -u    run `gitops.updateRepo` for existing repos before harvest
  --regenerate-tarballs rebuild all tarballs instead of reusing matching archives
  --no-tarballs        refresh metadata without creating or pruning tarballs
  --retry-missing       retry repos previously classified as missing
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
  ATLAS_PACKAGER_NO_TARBALLS          same as --no-tarballs
  ATLAS_PACKAGER_GITHUB_API_CHUNK_SIZE
                                      same as --github-api-chunk-size
  ATLAS_PACKAGER_COMPRESSION          same as --compression
  ATLAS_PACKAGER_THREADS              same as --threads
  ATLAS_PACKAGER_EPHEMERAL            same as --ephemeral
"""

proc writeHelp*(versionString: string; code = 2) =
  stdout.write(usage(versionString))
  stdout.flushFile()
  quit(code)

proc writeVersion*(versionString: string) =
  stdout.write("version: " & versionString & "\n")
  stdout.flushFile()
  quit(0)

proc parseEnvBool(value: string; label: string): bool =
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

  if existsEnv(EnvNoTarballs):
    opts.createTarballs = not parseEnvBool(getEnv(EnvNoTarballs), "no tarballs env var")

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

proc parseAtlasPackagerOptions*(
    params: seq[string];
    versionString: string;
    positional: var seq[string]
): PackagerCliOptions =
  result.compressions = @[parseArchiveCompression("xz")]
  result.createTarballs = true
  result.githubApiChunkSize = DefaultGitHubGraphqlBatchSize
  result.threadCount = max(1, cpuinfo.countProcessors())
  result.daemon.intervalSeconds = DefaultDaemonIntervalSeconds
  try:
    result.applyPackagerEnvDefaults()
  except ValueError:
    writeHelp(versionString)
  var compressionWasSet = false
  var onlyWasSet = false
  var onlyStartsWithWasSet = false
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
      of "packages-file", "packagesfile":
        if val.len == 0:
          writeHelp(versionString)
        result.packagesFile = Path(val)
      of "only":
        if val.len == 0:
          writeHelp(versionString)
        if not onlyWasSet:
          result.packageNames.setLen(0)
          onlyWasSet = true
        result.packageNames.addPackageNames(val)
      of "only-starts-with", "onlystartswith":
        if val.len == 0:
          writeHelp(versionString)
        if not onlyStartsWithWasSet:
          result.packagePrefixes.setLen(0)
          onlyStartsWithWasSet = true
        result.packagePrefixes.addPackagePrefixes(val)
      of "ignore":
        if val.len == 0:
          writeHelp(versionString)
        if not ignoreWasSet:
          result.ignoredPackageNames.setLen(0)
          ignoreWasSet = true
        result.ignoredPackageNames.addPackageNames(val)
      of "update-repos", "u":
        result.updateRepos = true
      of "regenerate-tarballs", "regeneratetarballs":
        result.regenerateTarballs = true
        result.createTarballs = true
      of "no-tarballs", "notarballs":
        result.createTarballs = false
      of "retry-missing":
        result.retryMissing = true
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
      writeHelp(versionString)
    of cmdEnd:
      assert false, "cannot happen"

proc main*() =
  setAtlasVerbosity(Notice)
  enableManagedSubprocessGroups()
  installControlCHandler()
  var args: seq[string]
  let opts = parseAtlasPackagerOptions(commandLineParams(), AtlasPackagerVersion, args)
  if args.len > 0:
    writeHelp(AtlasPackagerVersion)

  var nextRunAt = getMonoTime()
  let daemonInterval = initDuration(seconds = opts.daemon.intervalSeconds)
  while true:
    let runOk = runPackagerOnce(opts)
    if not opts.daemon.enabled:
      if not runOk:
        quit(1)
      break

    nextRunAt = nextRunAt + daemonInterval
    let now = getMonoTime()
    while nextRunAt <= now:
      nextRunAt = nextRunAt + daemonInterval
    let sleepMs = daemonSleepMilliseconds(nextRunAt - now)
    if runOk:
      notice "atlas:pkger", "daemon sleeping for", $(sleepMs div 1000), "seconds"
    else:
      warn "atlas:pkger", "run failed; retrying in", $(sleepMs div 1000), "seconds"
    if sleepMs > 0:
      sleep sleepMs

when isMainModule:
  main()
