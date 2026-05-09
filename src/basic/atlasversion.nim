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
  NimbleMetaFile = "nimblemeta.json"

func changedPath(line: string): string =
  if line.len <= 3:
    return ""
  let path = line[3..^1].strip()
  let renameSep = path.rfind(" -> ")
  if renameSep >= 0:
    path[renameSep + 4 .. ^1]
  else:
    path

func hasMeaningfulGitChanges(statusOutput: string): bool =
  ## special case check for installing from nimble to keep a clean version 
  ## e.g. ignores nimblemeta.json
  for line in statusOutput.splitLines():
    let cleanLine = line.strip()
    if cleanLine.len == 0:
      continue
    if changedPath(cleanLine) != NimbleMetaFile:
      return true
  false

const AtlasIsDirty* =
  if dirExists(AtlasGitDir):
    hasMeaningfulGitChanges(
      staticExec("git -C " & quoteShell(AtlasRootDir) & " status --porcelain"))
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

static:
  echo "AtlasCommit: ", AtlasCommit
  echo "AtlasIsDirty: ", AtlasIsDirty
  

