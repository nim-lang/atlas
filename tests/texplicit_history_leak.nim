import std/[os, osproc, strutils, terminal, unittest]

import basic/[compiledpatterns, context, deptypes, gitops, nimblecontext, pkgurls, reporters, versions]
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

proc addOrigin(url: string) =
  exec("git remote add origin " & url)

proc setRemoteTip(url, branch, commit: string) =
  let remote = remoteNameFromGitUrl(url)
  exec("git update-ref refs/remotes/" & remote & "/" & branch & " " & commit)
  exec("git symbolic-ref refs/remotes/" & remote & "/HEAD refs/remotes/" & remote & "/" & branch)

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

  test "latest sarcophagus resolves jwt from current non-default nim-jwt checkout":
    let ws = "tests/ws_explicit_history_leak"
    removeDir(ws)
    createDir(ws)

    withDir ws:
      project(paths.getCurrentDir())
      context().flags = {KeepWorkspace, ListVersions}
      context().defaultAlgo = SemVer

      createDir("deps")

      let sarcophagusUrlString = "https://example.invalid/elcritch/sarcophagus"
      let jwtUrlString = "https://example.invalid/yglukhov/nim-jwt"
      let mummyUrlString = "https://example.invalid/guzba/mummy"

      var latestJwtCommit = ""

      withDir "deps":
        createDir("mummy")
        withDir "mummy":
          writePackage("mummy", "1.0.0")
          initGitRepo()
          addOrigin(mummyUrlString)
          commitAll("mummy")
          let mummyCommit = gitHead()
          setRemoteTip(mummyUrlString, "main", mummyCommit)

        createDir("jwt")
        withDir "jwt":
          writePackage("jwt", "0.0.1")
          initGitRepo()
          addOrigin(jwtUrlString)
          commitAll("jwt-old")

          writePackage("jwt", "0.2")
          commitAll("jwt-remote-tip")
          let remoteTipCommit = gitHead()
          setRemoteTip(jwtUrlString, "master", remoteTipCommit)

          exec("git checkout -b tmp")
          writePackage("jwt", "0.3")
          commitAll("jwt-new")
          latestJwtCommit = gitHead()

        createDir("sarcophagus")
        withDir "sarcophagus":
          writePackage("sarcophagus", "0.4.0", [
            "mummy",
            jwtUrlString
          ])
          initGitRepo()
          addOrigin(sarcophagusUrlString)
          commitAll("sarcophagus-old-explicit-nim-jwt")

          writePackage("sarcophagus", "0.6.3", [
            "mummy",
            "jwt >= 0.3"
          ])
          commitAll("sarcophagus-latest-bare-jwt")
          let sarcophagusCommit = gitHead()
          setRemoteTip(sarcophagusUrlString, "main", sarcophagusCommit)

      writeFile("ws_explicit_history_leak.nimble", [
        "version = \"0.1.0\"",
        "requires \"" & sarcophagusUrlString & " >= 0.6.3\"",
        ""
      ].join("\n"))

      var nc = createUnfilledNimbleContext()
      discard nc.put("mummy", createUrlSkipPatterns(mummyUrlString))

      var canonicalJwtUrl = createUrlSkipPatterns(jwtUrlString)
      discard nc.put("jwt", canonicalJwtUrl)

      var graph = loadWorkspace(project(), nc, AllReleases, DoClone, doSolve = true)

      checkpoint "\tgraph:\n" & $graph.toJson()

      let sarcophagusUrl = nc.createUrl(sarcophagusUrlString)

      check graph.root.active
      check sarcophagusUrl in graph.pkgs
      check canonicalJwtUrl in graph.pkgs

      if sarcophagusUrl in graph.pkgs:
        check graph.pkgs[sarcophagusUrl].active
        if graph.pkgs[sarcophagusUrl].active:
          check $graph.pkgs[sarcophagusUrl].activeNimbleRelease.version == "0.6.3"

      if canonicalJwtUrl in graph.pkgs:
        check graph.pkgs[canonicalJwtUrl].active
        if graph.pkgs[canonicalJwtUrl].active:
          check $graph.pkgs[canonicalJwtUrl].activeNimbleRelease.version == "0.3"
          check graph.pkgs[canonicalJwtUrl].activeVersion.commit.h == latestJwtCommit

  test "unofficial packages with matching nimble names keep separate checkouts":
    let ws = "tests/ws_explicit_history_leak"
    removeDir(ws)
    createDir(ws)

    withDir ws:
      project(paths.getCurrentDir())
      context().flags = {KeepWorkspace, ListVersions}
      context().defaultAlgo = SemVer

      createDir("remotes/upstream/shared")
      createDir("remotes/fork/shared")

      withDir "remotes/upstream/shared":
        writePackage("shared", "1.0.0")
        initGitRepo()
        commitAll("upstream shared")

      withDir "remotes/fork/shared":
        writePackage("shared", "2.0.0")
        initGitRepo()
        commitAll("fork shared")

      let remotesUrl = "file://" & $(Path("remotes").absolutePath()) & "/"
      putEnv("GIT_CONFIG_COUNT", "1")
      putEnv("GIT_CONFIG_KEY_0", "url." & remotesUrl & ".insteadOf")
      putEnv("GIT_CONFIG_VALUE_0", "https://example.invalid/")

      let upstreamUrlString = "https://example.invalid/upstream/shared"
      let forkUrlString = "https://example.invalid/fork/shared"
      writeFile("ws_explicit_history_leak.nimble", [
        "version = \"0.1.0\"",
        "requires \"" & upstreamUrlString & "\"",
        "requires \"" & forkUrlString & "\"",
        ""
      ].join("\n"))

      var nc = createUnfilledNimbleContext()
      let upstreamUrl = nc.createUrl(upstreamUrlString)
      let forkUrl = nc.createUrl(forkUrlString)

      var graph = loadWorkspace(project(), nc, AllReleases, DoClone, doSolve = false)

      checkpoint "\tgraph:\n" & $graph.toJson()

      check upstreamUrl in graph.pkgs
      check forkUrl in graph.pkgs

      if upstreamUrl in graph.pkgs and forkUrl in graph.pkgs:
        let upstream = graph.pkgs[upstreamUrl]
        let fork = graph.pkgs[forkUrl]

        check upstream.state == Processed
        check fork.state == Processed
        check upstream.ondisk != fork.ondisk
        check gitops.getCanonicalUrl(upstream.ondisk) == upstreamUrlString
        check gitops.getCanonicalUrl(fork.ondisk) == forkUrlString

        var nc2 = createUnfilledNimbleContext()
        let upstreamUrl2 = nc2.createUrl(upstreamUrlString)
        let forkUrl2 = nc2.createUrl(forkUrlString)
        var graph2 = loadWorkspace(project(), nc2, AllReleases, DoClone, doSolve = false)

        check upstreamUrl2 in graph2.pkgs
        check forkUrl2 in graph2.pkgs
        if upstreamUrl2 in graph2.pkgs and forkUrl2 in graph2.pkgs:
          check graph2.pkgs[upstreamUrl2].ondisk == upstream.ondisk
          check graph2.pkgs[forkUrl2].ondisk == fork.ondisk
          check gitops.getCanonicalUrl(graph2.pkgs[forkUrl2].ondisk) == forkUrlString
