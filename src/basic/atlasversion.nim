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
  AtlasGitDir = AtlasRootDir / ".git"
  AtlasInstalledWithNimble = (DirSep & ".nimble" & DirSep) in AtlasRootDir

const AtlasIsDirty* =
  if AtlasInstalledWithNimble:
    false
  elif dirExists(AtlasGitDir):
    staticExec("git -C " & quoteShell(AtlasRootDir) & " status --porcelain").strip().len > 0
  else:
    false

const AtlasPackageVersion* =
  block:
    var ver = "0.0.0"
    if fileExists(AtlasNimbleFile):
      for line in staticRead(AtlasNimbleFile).splitLines():
        if line.startsWith("version ="):
          ver = line.split("=")[1].replace("\"", "").strip()
    if AtlasIsDirty:
      ver.add "+dirty"
    ver

const AtlasCommit* =
  if dirExists(AtlasGitDir):
    staticExec("git -C " & quoteShell(AtlasRootDir) & " log -n 1 --format=%H")
  else:
    "unknown"
const AtlasVersion* = AtlasPackageVersion & " (sha: " & AtlasCommit & ")"
