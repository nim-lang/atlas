#
#           Atlas Packager
#        (c) Copyright 2026 Atlas Contributors
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## CLI for harvesting Atlas package release caches from a packages.json list.

import std / [cpuinfo, monotimes, parseopt, os, paths, strutils, times]
when defined(posix):
  import std / posix
import ../basic / [context, packageinfos, reporters]
import ./cacheharvest

proc usage*(versionString: string): string =
  "atlas-packager - Atlas Packager Version " & versionString & """
Experimental packager based on Atlas package parser.

  (c) 2026 Atlas Contributors
Usage:
  atlas-packager [options] [packages.json] [metadata-dir]

Options:
  --help, -h            show this help
  --version, -v         show the version
  --packages=path       use the given packages.json file
  --metadata=path       write copied cache files to the given directory
  --package=name[,name] process only the named package(s) from packages.json
  --ignore=name[,name]  skip the named package(s) from packages.json
  --update-repos        run `gitops.updateRepo` for existing repos before harvest
  --regenerate-tarballs rebuild all tarballs instead of reusing matching archives
  --compression=type    archive compression(s): gzip, xz, or comma-separated list
                        default: gzip
  --threads=count, -j   number of package processing threads
                        default: number of processors
  --ephemeral           delete each cloned repo from pkgs/ after its metadata is produced
"""

type
  PackagerCliOptions* = object
    packagesFile: Path
    metadataDir: Path
    packageNames: seq[string]
    ignoredPackageNames: seq[string]
    compressions: seq[ArchiveCompression]
    threadCount: int
    updateRepos: bool
    regenerateTarballs: bool
    ephemeral: bool

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
  result.threadCount = max(1, countProcessors())
  var compressionWasSet = false
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
        result.packagesFile = Path(val)
      of "metadata":
        if val.len == 0:
          writeHelp(versionString)
        result.metadataDir = Path(val)
      of "package":
        if val.len == 0:
          writeHelp(versionString)
        result.packageNames.addPackageNames(val)
      of "ignore":
        if val.len == 0:
          writeHelp(versionString)
        result.ignoredPackageNames.addPackageNames(val)
      of "update-repos":
        result.updateRepos = true
      of "regenerate-tarballs":
        result.regenerateTarballs = true
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
  putEnv("GIT_TERMINAL_PROMPT", "0")
  putEnv("GIT_ASKPASS", "/bin/false")
  putEnv("SSH_ASKPASS", "/bin/false")
  putEnv("GCM_INTERACTIVE", "never")
  putEnv("GIT_SSH_COMMAND", "ssh -oBatchMode=yes -oNumberOfPasswordPrompts=0")

proc exitImmediatelyOnCtrlC*() {.noconv.} =
  echo "Quitting.."
  when defined(posix):
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
  notice "atlas:pkger", "compressions:", archiveCompressionNames(opts.compressions).join(",")
  notice "atlas:pkger", "update repos:", $opts.updateRepos
  notice "atlas:pkger", "regenerate tarballs:", $opts.regenerateTarballs
  notice "atlas:pkger", "ephemeral:", $opts.ephemeral
  if opts.packageNames.len > 0:
    notice "atlas:pkger", "package filter:", opts.packageNames.join(",")
  else:
    notice "atlas:pkger", "package filter:", "all"
  if opts.ignoredPackageNames.len > 0:
    notice "atlas:pkger", "ignore filter:", opts.ignoredPackageNames.join(",")
  else:
    notice "atlas:pkger", "ignore filter:", "none"

proc summarizeErrorLine(message: string): string =
  result = message.replace('\n', ' ').replace('\r', ' ')
  while "  " in result:
    result = result.replace("  ", " ")
  result = result.strip()

proc main*(versionString = "unknown") =
  installControlCHandler()
  let startedAt = getMonoTime()
  var args: seq[string]
  let opts = parseAtlasPackagerOptions(commandLineParams(), versionString, args)
  if args.len > 2:
    writeHelp(versionString)

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
    quit(1)

  writeSettings(packagesFile, metadataDir, opts)
  let summary = harvestRegistryCaches(
    packagesFile,
    metadataDir,
    opts.ephemeral,
    opts.packageNames,
    opts.ignoredPackageNames,
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
  let elapsed = getMonoTime() - startedAt
  notice "atlas:pkger", "elapsed:", $initDuration(milliseconds = int(elapsed.inMilliseconds))

when isMainModule:
  main()
