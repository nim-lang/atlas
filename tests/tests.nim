

import std/unittest
import std/uri
import std/os

import atlas

let
  basicExamples = {
    "balls": "https://github.com/disruptek/balls/tree/master",
    "npeg": "https://github.com/zevv/npeg",
    "sync": "https://github.com/planetis-m/sync",
    "bytes2human": "https://github.com/juancarlospaco/nim-bytes2human",
  }

proc initBasicWorkspace(typ: type AtlasContext): AtlasContext =
    result.workspace = currentSourcePath().parentDir / "ws_basic"

suite "urls and naming":

  test "basic urls":

    var c = AtlasContext.initBasicWorkspace()

    for name, url in basicExamples.items:
      echo "\nname: ", name
      let ures = toUrl(c, url)
      echo "ures: ", $ures
      check ures.hostname == "github.com"

      let nres = toUrl(c, name)
      echo "nres: ", $nres