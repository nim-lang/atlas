import std/[unittest, os, osproc, strutils, json, jsonutils, terminal, paths]

import basic/[sattypes, context, reporters, pkgurls, compiledpatterns, versions]
import basic/[deptypes, nimblecontext, deptypesjson]
import dependencies
import depgraphs
import testerutils
import atlas, confighandler

suite "nameOverrides: fastrpc + mcu_utils":
  setup:
    # Keep output readable
    setAtlasVerbosity(Debug)
    setAtlasErrorsColor(fgMagenta)
    # Reset patterns each run
    context().nameOverrides = Patterns()
    context().urlOverrides = Patterns()
    context().depsDir = Path "deps"

  test "resolve via nameOverrides with link targets":
    withDir "tests/ws_nameoverrides_fastrpc":
      # Fresh deps folder and set workspace
      # removeDir("deps")
      createDir("deps")
      project(paths.getCurrentDir())

      # Create nimble context and load workspace; solver should honor overrides
      var nc = createNimbleContext()

      # Verify packages are present and named correctly (no stray '@')
      nc.put("fastrpc", toPkgUriRaw(parseUri "https://github.com/EmbeddedNim/fastrpc"))
      nc.put("mcu_utils", toPkgUriRaw(parseUri "https://github.com/EmbeddedNim/mcu_utils"))

      let graph = project().loadWorkspace(nc, AllReleases, onClone=DoClone, doSolve=true)

      checkpoint "\tgraph:\n" & $graph.toJson(ToJsonOptions(enumMode: joptEnumString))

      check graph.root.active
