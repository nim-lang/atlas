#
#           Atlas Package Cloner
#        (c) Copyright 2021 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## CLI for harvesting Atlas package release caches from a packages.json list.

import std / [parseopt, os, paths, strutils]
import ../basic / [context, packageinfos]
import ./cacheharvest

proc usage(versionString: string): string =
  "atlas-packager - Atlas Packager Version " & versionString & """

  (c) 2021 Andreas Rumpf
Usage:
  atlas-packager [options] [packages.json] [metadata-dir]

Options:
  --help, -h            show this help
  --version, -v         show the version
  --packages=path       use the given packages.json file
  --metadata=path       write copied cache files to the given directory
  --package=name        process only the named package from packages.json
  --ephemeral           delete each cloned repo from pkgs/ after its metadata is produced
"""

type
  PackagerCliOptions = object
    packagesFile: Path
    metadataDir: Path
    packageName: string
    ephemeral: bool

proc writeHelp(versionString: string; code = 2) =
  stdout.write(usage(versionString))
  stdout.flushFile()
  quit(code)

proc writeVersion(versionString: string) =
  stdout.write("version: " & versionString & "\n")
  stdout.flushFile()
  quit(0)

proc parseAtlasPackagerOptions(
    params: seq[string];
    versionString: string;
    positional: var seq[string]
): PackagerCliOptions =
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
        result.packageName = val
      of "ephemeral":
        result.ephemeral = true
      else:
        writeHelp(versionString)
    of cmdArgument:
      positional.add key
    of cmdEnd:
      assert false, "cannot happen"

proc resolvePackagesFile(opts: PackagerCliOptions; args: seq[string]): Path =
  if opts.packagesFile.len > 0:
    result = opts.packagesFile
  elif args.len >= 1:
    result = Path(args[0])
  else:
    result = Path"pkgs-meta" / Path"packages.json"

proc resolveMetadataDir(opts: PackagerCliOptions; args: seq[string]): Path =
  if opts.metadataDir.len > 0:
    result = opts.metadataDir
  elif args.len >= 2:
    result = Path(args[1])
  else:
    result = Path"pkgs-meta"

proc initPackagerWorkspace() =
  var ctx = AtlasContext()
  ctx.depsDir = Path"pkgs"
  createDir($ctx.depsDir)
  setContext(ctx)

proc main*(versionString = "unknown") =
  var args: seq[string]
  let opts = parseAtlasPackagerOptions(commandLineParams(), versionString, args)
  if args.len > 2:
    writeHelp(versionString)

  initPackagerWorkspace()
  defer:
    cleanupPackagerJsonCacheFiles()

  let packagesFile = resolvePackagesFile(opts, args)
  let metadataDir = resolveMetadataDir(opts, args)

  if not fileExists($packagesFile):
    updatePackages(cacheDir = packagesFile.parentDir())
  if not fileExists($packagesFile):
    stderr.writeLine("packages.json not found: " & $packagesFile)
    quit(1)

  let summary =
    if opts.packageName.len > 0:
      harvestRegistryCacheForPackage(packagesFile, metadataDir, opts.packageName, opts.ephemeral)
    else:
      harvestRegistryCaches(packagesFile, metadataDir, opts.ephemeral)
  stdout.writeLine(
    "processed " & $summary.packagesProcessed &
    " packages, failed " & $summary.packagesFailed &
    ", skipped " & $summary.aliasesSkipped &
    " aliases"
  )

when isMainModule:
  main()
