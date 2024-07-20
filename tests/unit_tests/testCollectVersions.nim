
import std/unittest
import std/strutils
import std/os
import std/tempfiles
import std/options

import ../setups

import context, reporters, nimbleparser, pkgurls
import compiledpatterns
import compiledpatterns
import pkgurls
import depgraphs

proc toDirSep(s: string): string =
  result = s.replace("/", $DirSep)

template setupDepsAndGraph(dir: string) =
  var
    p {.inject.} = initPatterns()
    u {.inject.} = createUrl("file://" & dir, p)
    c {.inject.} = AtlasContext()
    g {.inject.} = createGraph(c, u, readConfig = false)

  c.depsDir = "source"
  c.workspace = dir.toDirSep
  c.projectDir = dir.toDirSep
  c.verbosity = 3

suite "test pkgurls":

  test "basic url":
    withTempTestDir "basic_url":
      buildGraphNoGitTags()
      echo "\n"
      setupDepsAndGraph(dir)
      var d = Dependency()
      let depDir = "source" / "proj_a/"
      ## TODOX: how to handle this relative or not thing?
      let nimble = "proj_a.nimble"
      setCurrentDir(depDir)
      d.pkg = createUrl("file://" & $depDir, p)
      d.nimbleFile = some nimble
      echo "D: ", d
      let versions = collectNimbleVersions(c, d)
      echo "VERSIONS: ", versions

