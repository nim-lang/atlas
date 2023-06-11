

import std/unittest
import std/uri
import std/os

import atlas

let
  basicExamples = {
    "balls": (
      # input: "https://github.com/disruptek/balls/tree/master",
      input: "https://github.com/disruptek/balls",
      output: "https://github.com/disruptek/balls",
    ),
    "npeg": (
      input: "https://github.com/zevv/npeg",
      output: "https://github.com/zevv/npeg",
    ),
    "sync": (
      input: "https://github.com/planetis-m/sync",
      output: "https://github.com/planetis-m/sync",
    ),
    "bytes2human": (
      input: "https://github.com/juancarlospaco/nim-bytes2human",
      output: "https://github.com/juancarlospaco/nim-bytes2human",
    )
  }

proc initBasicWorkspace(typ: type AtlasContext): AtlasContext =
    result.workspace = currentSourcePath().parentDir / "ws_basic"

suite "urls and naming":

  test "basic urls":

    var c = AtlasContext.initBasicWorkspace()

    for name, url in basicExamples.items:
      let ures = toUrl(c, url.input)
      check ures.hostname == "github.com"
      check $ures == url.output

      let nres = toUrl(c, name)
      check nres.hostname == "github.com"
      check $nres == url.output
