#
#           Atlas Package Cloner
#        (c) Copyright 2026 The Atlas contributors
#

## Top-level wrapper for the Atlas packager CLI.

import std/[os, osproc, strutils]

import packager/packager

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

const AtlasPackagerVersion = AtlasPackageVersion & " (sha: " & AtlasCommit & ")"

proc main() =
  packager.main(AtlasPackagerVersion)

when isMainModule:
  main()
