#
#           Atlas Package Cloner
#        (c) Copyright 2021 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## CLI for harvesting Atlas package release caches from a packages.json list.

import std / [parseopt, os, paths, strutils]
import basic / [context, packageinfos]
import cacheharvest

proc usage(versionString: string): string =
  "atlas-packager - Atlas Packager Version " & versionString & """

  (c) 2021 Andreas Rumpf
Usage:
  atlas-packager [packages.json] [metadata-dir]

Options:
  --help, -h            show this help
  --version, -v         show the version
"""

proc writeHelp(versionString: string; code = 2) =
  stdout.write(usage(versionString))
  stdout.flushFile()
  quit(code)

proc writeVersion(versionString: string) =
  stdout.write("version: " & versionString & "\n")
  stdout.flushFile()
  quit(0)

proc parseAtlasPackagerOptions(params: seq[string]; versionString: string): seq[string] =
  for kind, key, _ in getopt(params):
    case kind
    of cmdLongOption, cmdShortOption:
      case normalize(key)
      of "help", "h":
        writeHelp(versionString, 0)
      of "version", "v":
        writeVersion(versionString)
      else:
        writeHelp(versionString)
    of cmdArgument:
      result.add key
    of cmdEnd:
      assert false, "cannot happen"

proc resolvePackagesFile(args: seq[string]): Path =
  if args.len >= 1:
    result = Path(args[0])
  else:
    result = packageInfosFile()

proc resolveMetadataDir(args: seq[string]): Path =
  if args.len >= 2:
    result = Path(args[1])
  else:
    result = Path"metadata"

proc main*(versionString = "unknown") =
  setContext AtlasContext()
  let args = parseAtlasPackagerOptions(commandLineParams(), versionString)
  if args.len > 2:
    writeHelp(versionString)

  let packagesFile = resolvePackagesFile(args)
  let metadataDir = resolveMetadataDir(args)

  if not fileExists($packagesFile):
    updatePackages()
  if not fileExists($packagesFile):
    stderr.writeLine("packages.json not found: " & $packagesFile)
    quit(1)

  let summary = harvestRegistryCaches(packagesFile, metadataDir)
  stdout.writeLine(
    "processed " & $summary.packagesProcessed &
    " packages, failed " & $summary.packagesFailed &
    ", skipped " & $summary.aliasesSkipped &
    " aliases"
  )

when isMainModule:
  main()
