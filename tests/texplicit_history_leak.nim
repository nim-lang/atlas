import std/[os, osproc, strutils, terminal, unittest]

import basic/[compiledpatterns, context, deptypes, nimblecontext, pkgurls, reporters, versions]
import dependencies
import depgraphs
import integration_test_utils

proc initGitRepo() =
  exec("git init -b master")
  exec("git config user.name test-user")
  exec("git config user.email test@example.com")

proc gitHead(): string =
  execProcess("git rev-parse HEAD").strip()

proc writePackage(name, version: string; requires: openArray[string] = []) =
  var lines = @[
    "version = \"" & version & "\""
  ]
  for dep in requires:
    lines.add("requires \"" & dep & "\"")

  writeFile(name & ".nimble", lines.join("\n") & "\n")
  writeFile(name & ".nim", "discard\n")

proc commitAll(msg: string) =
  exec("git add .")
  exec("git commit -m \"" & msg & "\"")

suite "historical explicit transitive pins":
  setup:
    setAtlasVerbosity(Warning)
    context().nameOverrides = Patterns()
    context().urlOverrides = Patterns()
    context().depsDir = Path "deps"
    setAtlasErrorsColor(fgMagenta)

  test "root explicit commit selects pinned release over newer semver releases":
    let ws = "tests/ws_explicit_history_leak"
    removeDir(ws)
    createDir(ws)

    withDir ws:
      project(paths.getCurrentDir())
      context().flags = {KeepWorkspace, ListVersions}
      context().defaultAlgo = SemVer
      discard context().nameOverrides.addPattern("$+", "file://./buildGraph/$#")

      createDir("buildGraph")

      var pinnedCommit = ""
      var newerCommit = ""

      withDir "buildGraph":
        createDir("widget")
        withDir "widget":
          writePackage("widget", "1.0.0")
          initGitRepo()
          commitAll("widget-pinned")
          pinnedCommit = gitHead()

          writePackage("widget", "2.0.0")
          commitAll("widget-newer")
          newerCommit = gitHead()

      writeFile("ws_explicit_history_leak.nimble", [
        "version = \"0.1.0\"",
        "requires \"widget#" & pinnedCommit[0..7] & "\"",
        ""
      ].join("\n"))

      var nc = createNimbleContext()
      var graph = loadWorkspace(project(), nc, AllReleases, DoClone, doSolve = true)

      checkpoint "\tgraph:\n" & $graph.toJson()

      let widgetUrl = nc.createUrl("widget")

      check graph.root.active
      check widgetUrl in graph.pkgs

      if widgetUrl in graph.pkgs:
        check graph.pkgs[widgetUrl].active
        if graph.pkgs[widgetUrl].active:
          check $graph.pkgs[widgetUrl].activeVersion.version == "1.0.0"
          check graph.pkgs[widgetUrl].activeVersion.commit.h == pinnedCommit
          check graph.pkgs[widgetUrl].activeVersion.commit.h != newerCommit

  test "old explicit transitive pin from historical release does not leak into selected explicit commit":
    let ws = "tests/ws_explicit_history_leak"
    removeDir(ws)
    createDir(ws)

    withDir ws:
      project(paths.getCurrentDir())
      context().flags = {KeepWorkspace, ListVersions}
      context().defaultAlgo = SemVer
      discard context().nameOverrides.addPattern("$+", "file://./buildGraph/$#")

      createDir("buildGraph")

      var oldBearsslCommit = ""
      var newBearsslCommit = ""
      var newJwtCommit = ""

      withDir "buildGraph":
        createDir("bearssl")
        withDir "bearssl":
          writePackage("bearssl", "0.1.5")
          initGitRepo()
          commitAll("bearssl-old")
          oldBearsslCommit = gitHead()
          exec("git tag v0.1.5")

          writePackage("bearssl", "0.2.8")
          commitAll("bearssl-new")
          newBearsslCommit = gitHead()
          exec("git tag v0.2.8")

        createDir("decoder")
        withDir "decoder":
          writePackage("decoder", "0.1.0", ["bearssl"])
          initGitRepo()
          commitAll("decoder")

        createDir("jwt")
        withDir "jwt":
          # Historical release hard-pins an old BearSSL commit.
          writePackage("jwt", "0.2", ["bearssl#" & oldBearsslCommit, "decoder"])
          initGitRepo()
          commitAll("jwt-old")

          # Selected explicit commit only requires BearSSL semver >= 0.2.8.
          writePackage("jwt", "0.3", ["bearssl >= 0.2.8", "decoder#head"])
          commitAll("jwt-new")
          newJwtCommit = gitHead()

      writeFile("ws_explicit_history_leak.nimble", "requires \"jwt#" & newJwtCommit[0..7] & "\"\n")

      var nc = createNimbleContext()
      var graph = loadWorkspace(project(), nc, AllReleases, DoClone, doSolve = true)

      checkpoint "\tgraph:\n" & $graph.toJson()

      let jwtUrl = nc.createUrl("jwt")
      let decoderUrl = nc.createUrl("decoder")
      let bearsslUrl = nc.createUrl("bearssl")

      check graph.root.active
      check jwtUrl in graph.pkgs
      check decoderUrl in graph.pkgs
      check bearsslUrl in graph.pkgs

      if jwtUrl in graph.pkgs:
        check graph.pkgs[jwtUrl].active

      if decoderUrl in graph.pkgs:
        check graph.pkgs[decoderUrl].active

      if bearsslUrl in graph.pkgs:
        check graph.pkgs[bearsslUrl].active
        if graph.pkgs[bearsslUrl].active:
          check $graph.pkgs[bearsslUrl].activeVersion.version == "0.2.8"
          check graph.pkgs[bearsslUrl].activeVersion.commit.h == newBearsslCommit
          check graph.pkgs[bearsslUrl].activeVersion.commit.h != oldBearsslCommit

  test "historical jwt bearssl pin does not override root bearssl semver":
    let ws = "tests/ws_explicit_history_leak"
    removeDir(ws)
    createDir(ws)

    withDir ws:
      project(paths.getCurrentDir())
      context().flags = {KeepWorkspace, ListVersions}
      context().defaultAlgo = SemVer
      discard context().nameOverrides.addPattern("$+", "file://./buildGraph/$#")

      createDir("buildGraph")

      var oldBearsslCommit = ""
      var newBearsslCommit = ""

      withDir "buildGraph":
        createDir("bearssl")
        withDir "bearssl":
          writePackage("bearssl", "0.1.5")
          initGitRepo()
          commitAll("bearssl-old")
          oldBearsslCommit = gitHead()

          writePackage("bearssl", "0.2.8")
          commitAll("bearssl-new")
          newBearsslCommit = gitHead()

        createDir("bearssl_pkey_decoder")
        withDir "bearssl_pkey_decoder":
          writePackage("bearssl_pkey_decoder", "0.1.0")
          initGitRepo()
          commitAll("bearssl-pkey-decoder")

        createDir("jwt")
        withDir "jwt":
          writePackage("jwt", "0.2", [
            "bearssl#" & oldBearsslCommit,
            "bearssl_pkey_decoder"
          ])
          initGitRepo()
          commitAll("jwt-old")

          writePackage("jwt", "0.3", [
            "bearssl >= 0.2.8",
            "bearssl_pkey_decoder"
          ])
          commitAll("jwt-new")

      writeFile("ws_explicit_history_leak.nimble", [
        "version = \"0.1.0\"",
        "requires \"jwt >= 0.3\"",
        "requires \"bearssl >= 0.2.8\"",
        ""
      ].join("\n"))

      var nc = createNimbleContext()
      var graph = loadWorkspace(project(), nc, AllReleases, DoClone, doSolve = true)

      checkpoint "\tgraph:\n" & $graph.toJson()

      let jwtUrl = nc.createUrl("jwt")
      let bearsslUrl = nc.createUrl("bearssl")

      check graph.root.active
      check jwtUrl in graph.pkgs
      check bearsslUrl in graph.pkgs

      if jwtUrl in graph.pkgs:
        check graph.pkgs[jwtUrl].active
        if graph.pkgs[jwtUrl].active:
          check $graph.pkgs[jwtUrl].activeVersion.version == "0.3"

      if bearsslUrl in graph.pkgs:
        check graph.pkgs[bearsslUrl].active
        if graph.pkgs[bearsslUrl].active:
          check $graph.pkgs[bearsslUrl].activeVersion.version == "0.2.8"
          check graph.pkgs[bearsslUrl].activeVersion.commit.h == newBearsslCommit
          check graph.pkgs[bearsslUrl].activeVersion.commit.h != oldBearsslCommit
