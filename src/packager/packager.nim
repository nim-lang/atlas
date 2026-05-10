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
  --package=name[,name] process only the named package(s) from packages.json
  --ephemeral           delete each cloned repo from pkgs/ after its metadata is produced
"""

type
  PackagerCliOptions = object
    packagesFile: Path
    metadataDir: Path
    packageNames: seq[string]
    ephemeral: bool

proc parsePackageNames(value: string): seq[string] =
  for rawName in value.split(','):
    let packageName = rawName.strip()
    if packageName.len > 0 and packageName notin result:
      result.add packageName

proc addPackageNames(dest: var seq[string]; value: string) =
  for packageName in parsePackageNames(value):
    if packageName notin dest:
      dest.add packageName

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
        result.packageNames.addPackageNames(val)
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
    result = opts.packagesFile.absolutePath()
  elif args.len >= 1:
    result = Path(args[0]).absolutePath()

proc resolveMetadataDir(opts: PackagerCliOptions; args: seq[string]): Path =
  if opts.metadataDir.len > 0:
    result = opts.metadataDir.absolutePath()
  elif args.len >= 2:
    result = Path(args[1]).absolutePath()
  else:
    result = Path"pkgs".absolutePath()

proc initPackagerWorkspace(metadataDir: Path) =
  var ctx = AtlasContext()
  ctx.depsDir = metadataDir
  ctx.cacheDir = metadataDir
  createDir($metadataDir)
  setContext(ctx)

proc main*(versionString = "unknown") =
  var args: seq[string]
  let opts = parseAtlasPackagerOptions(commandLineParams(), versionString, args)
  if args.len > 2:
    writeHelp(versionString)

  let metadataDir = resolveMetadataDir(opts, args)
  initPackagerWorkspace(metadataDir)
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

  let summary = harvestRegistryCaches(packagesFile, metadataDir, opts.ephemeral, opts.packageNames)
  stdout.writeLine(
    "processed " & $summary.packagesProcessed &
    " packages, failed " & $summary.packagesFailed &
    ", skipped " & $summary.aliasesSkipped &
    " aliases"
  )

when isMainModule:
  main()
