#
#           Atlas Package Cloner
#        (c) Copyright 2021 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Atlas version information shared by CLI and library helpers.

import std / strutils

const AtlasPackageVersion* =
  block:
    var ver = ""
    for line in staticRead("../../atlas.nimble").splitLines():
      if line.startsWith("version ="):
        ver = line.split("=")[1].replace("\"", "").strip()
    assert ver.len > 0
    ver

const AtlasCommit* = staticExec("git log -n 1 --format=%H")
const AtlasVersion* = AtlasPackageVersion & " (sha: " & AtlasCommit & ")"
