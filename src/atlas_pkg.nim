#
#           Atlas Package Cloner
#        (c) Copyright 2026 The Atlas contributors
#

## Top-level wrapper for the Atlas local project packager CLI.

import std/[algorithm, cpuinfo, monotimes, os, osproc, parseopt, paths, strutils, times]

import basic/[reporters, subprocessgroups]
import packager/packager
import packager/projpkg

const
  AtlasRootDir = currentSourcePath().parentDir().parentDir()
  AtlasNimbleFile = AtlasRootDir / "atlas.nimble"
  AtlasGitDir = AtlasRootDir / ".git"

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

const AtlasPackageCliVersion = AtlasPackageVersion & " (sha: " & AtlasCommit & ")"

proc usage*(versionString: string): string =
  "atlas-package - Atlas Local Project Packager Version " & versionString & """

  (c) 2026 Atlas Contributors
Usage:
  atlas-package [options] [project-dir]

Options:
  --help, -h            show this help
  --version, -v         show the version
  --project=path, -p    package the given local project
  --output=path         write releases.json and archives to the given directory
                        default: project directory
  --head                package the current git commit as a #head release
                        default packages the latest tagged/versioned release
  --all                 package tarballs for all discovered releases
  --compression=type    archive compression(s): gzip, xz, zip, or comma-separated list
                        default: xz,gzip,zip
  --tarballs            create tarballs alongside releases.json
  --no-tarballs         refresh releases.json without creating tarballs
"""

proc writeHelp*(versionString: string; code = 2) =
  stdout.write(usage(versionString))
  stdout.flushFile()
  quit(code)

proc writeVersion*(versionString: string) =
  stdout.write("version: " & versionString & "\n")
  stdout.flushFile()
  quit(0)

proc parseAtlasPackageOptions*(
    params: seq[string];
    versionString: string;
    positional: var seq[string]
): ProjectPackageCliOptions =
  result.compressions = parseArchiveCompressions("xz,gzip,zip")
  result.createTarballs = false
  var compressionWasSet = false
  for kind, key, val in getopt(params):
    case kind
    of cmdLongOption, cmdShortOption:
      case normalize(key)
      of "help", "h":
        writeHelp(versionString, 0)
      of "version", "v":
        writeVersion(versionString)
      of "project", "p":
        if val.len == 0:
          writeHelp(versionString)
        result.projectDir = Path(val)
      of "output", "o":
        if val.len == 0:
          writeHelp(versionString)
        result.outputDir = Path(val)
      of "head":
        result.releaseMode = prmHead
      of "all":
        result.selectionMode = psmAllReleases
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
      of "tarballs":
        result.createTarballs = true
      of "no-tarballs", "notarballs":
        result.createTarballs = false
      else:
        writeHelp(versionString)
    of cmdArgument:
      positional.add key
    of cmdEnd:
      assert false, "cannot happen"

proc main*() =
  setAtlasVerbosity(Notice)
  enableManagedSubprocessGroups()
  installControlCHandler()
  var args: seq[string]
  let opts = parseAtlasPackageOptions(commandLineParams(), AtlasPackageCliVersion, args)
  if args.len > 1:
    writeHelp(AtlasPackageCliVersion)
  if not runAtlasPackageOnce(opts, args):
    quit(1)

when isMainModule:
  main()
