#
#           Atlas Package Cloner
#        (c) Copyright 2021 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Minimal scaffold for the Atlas packager CLI.

import std / [parseopt, os, strutils]
import basic / [atlasversion]

const
  Usage = "atlas-pkger - Atlas Packager Version " & AtlasVersion & """

  (c) 2021 Andreas Rumpf
Usage:
  atlas-pkger [options]

Options:
  --help, -h            show this help
  --version, -v         show the version
"""

proc writeHelp(code = 2) =
  stdout.write(Usage)
  stdout.flushFile()
  quit(code)

proc writeVersion() =
  stdout.write("version: " & AtlasVersion & "\n")
  stdout.flushFile()
  quit(0)

proc parseAtlasPackagerOptions(params: seq[string]) =
  for kind, key, _ in getopt(params):
    case kind
    of cmdLongOption, cmdShortOption:
      case normalize(key)
      of "help", "h":
        writeHelp(0)
      of "version", "v":
        writeVersion()
      else:
        writeHelp()
    of cmdArgument:
      writeHelp()
    of cmdEnd:
      assert false, "cannot happen"

proc main() =
  parseAtlasPackagerOptions(commandLineParams())

when isMainModule:
  main()
