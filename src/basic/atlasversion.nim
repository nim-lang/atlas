#
#           Atlas Package Cloner
#        (c) Copyright 2021 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Atlas version information shared by CLI and library helpers.

import std / [os, osproc, strutils]

const
  AtlasRootDir = currentSourcePath().parentDir().parentDir().parentDir()
  AtlasNimbleFile = AtlasRootDir / "atlas.nimble"

const AtlasPackageVersion* =
  block:
    var ver = "0.0.0"
    for line in staticRead(AtlasNimbleFile).splitLines():
      if line.startsWith("version ="):
        ver = line.split("=")[1].replace("\"", "").strip()
    ver

const AtlasCommit* = staticExec("git -C " & quoteShell(AtlasRootDir) & " log -n 1 --format=%H")
const AtlasVersion* = AtlasPackageVersion & " (sha: " & AtlasCommit & ")"
