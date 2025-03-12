# Small program that runs the test cases

import std / [strutils, os, uri, jsonutils, json, sets, tables, sequtils, strformat, unittest]
import std/terminal
import basic/[sattypes, context, reporters, pkgurls, compiledpatterns, versions]
import basic/[deptypes, nimblecontext]
import dependencies
import depgraphs
import testerutils

if not dirExists("tests/ws_testtraverse/buildGraph"):
  ensureGitHttpServer()

proc setupGraph*(): seq[string] =
  let projs = @["proj_a", "proj_b", "proj_c", "proj_d"]
  if not dirExists("buildGraph"):
    createDir "buildGraph"
    withDir "buildGraph":
      for proj in projs:
        exec("git clone http://localhost:4242/buildGraph/$1" % [proj])
  for proj in projs:
    result.add(ospaths2.getCurrentDir() / "buildGraph" / proj)

proc setupGraphNoGitTags*(): seq[string] =
  let projs = @["proj_a", "proj_b", "proj_c", "proj_d"]
  if not dirExists("buildGraphNoGitTags"):
    createDir "buildGraphNoGitTags"
    withDir "buildGraphNoGitTags":
      for proj in projs:
        exec("git clone http://localhost:4242/buildGraphNoGitTags/$1" % [proj])
  for proj in projs:
    result.add(ospaths2.getCurrentDir() / "buildGraphNoGitTags" / proj)

suite "graph solve":
  setup:
    # setAtlasVerbosity(Warning)
    # setAtlasVerbosity(Trace)
    context().nameOverrides = Patterns()
    context().urlOverrides = Patterns()
    context().proxy = parseUri "http://localhost:4242"
    context().dumbProxy = true
    context().depsDir = Path "deps"
    setAtlasErrorsColor(fgMagenta)


  test "expand using http urls":
      # setAtlasVerbosity(Info)
      withDir "tests/ws_semver_unit":
        removeDir("deps")
        workspace() = paths.getCurrentDir()
        context().flags = {UsesOverrides, KeepWorkspace, ListVersions, FullClones}
        context().defaultAlgo = SemVer

        var nc = createNimbleContext()
        nc.put("proj_a", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_a"))
        nc.put("proj_b", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_b"))
        nc.put("proj_c", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_c"))
        nc.put("proj_d", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_d"))

        let dir = paths.getCurrentDir().absolutePath

        var graph = dir.expand(nc, AllReleases, onClone=DoClone)

        echo "\tgraph:\n", graph.toJson(ToJsonOptions(enumMode: joptEnumString))

        let form = graph.toFormular(SemVer)
        context().dumpGraphs = true
        var sol: Solution
        solve(graph, form)

        check graph.root.active
        check graph.pkgs[nc.createUrl("proj_a")].active
        check graph.pkgs[nc.createUrl("proj_b")].active
        check graph.pkgs[nc.createUrl("proj_c")].active
        check graph.pkgs[nc.createUrl("proj_d")].active

        check $graph.root.activeVersion == "#head@-"
        check $graph.pkgs[nc.createUrl("proj_a")].activeVersion == "1.1.0@fb3804df^"
        check $graph.pkgs[nc.createUrl("proj_b")].activeVersion == "1.1.0@ee875bae^"
        check $graph.pkgs[nc.createUrl("proj_c")].activeVersion == "1.2.0@9331e14f^"
        check $graph.pkgs[nc.createUrl("proj_d")].activeVersion == "1.0.0@0dec9c97"

        let formMinVer = graph.toFormular(MinVer)
        context().dumpGraphs = true
        var solMinVer: Solution
        solve(graph, formMinVer)

        check $graph.root.activeVersion == "#head@-"
        check $graph.pkgs[nc.createUrl("proj_a")].activeVersion == "1.0.0@e479b438"
        check $graph.pkgs[nc.createUrl("proj_b")].activeVersion == "1.0.0@af427510"
        check $graph.pkgs[nc.createUrl("proj_c")].activeVersion == "1.2.0@9331e14f^"
        check $graph.pkgs[nc.createUrl("proj_d")].activeVersion == "1.0.0@0dec9c97"

        check graph.validateDependencyGraph()
        let topo = graph.toposorted()

        check topo[0].url.projectName == "proj_d"
        check topo[1].url.projectName == "proj_c"
        check topo[2].url.projectName == "proj_b"
        check topo[3].url.projectName == "proj_a"

        for pkg in topo:
          echo "PKG: ", pkg.url.projectName

  test "ws_semver_unit with patterns":
      ## Supporting Patterns suck, so here's a test to ensure they work
      # setAtlasVerbosity(Trace)
      withDir "tests/ws_semver_unit":
        removeDir("deps")
        workspace() = paths.getCurrentDir()
        context().flags = {UsesOverrides, KeepWorkspace, ListVersions, FullClones}
        context().defaultAlgo = SemVer
        discard context().nameOverrides.addPattern("proj$+", "https://example.com/buildGraph/proj$#")

        var nc = createNimbleContext()

        let dir = paths.getCurrentDir().absolutePath

        var graph = dir.expand(nc, AllReleases, onClone=DoClone)

        let sp = graph.pkgs.values().toSeq()

        doAssert sp.len() == 5

        echo "\tgraph:\n", graph.toJson(ToJsonOptions(enumMode: joptEnumString))

        let form = graph.toFormular(SemVer)
        context().dumpGraphs = true
        var sol: Solution
        solve(graph, form)

        check graph.root.active
        check graph.pkgs[nc.createUrl("proj_a")].active
        check graph.pkgs[nc.createUrl("proj_b")].active
        check graph.pkgs[nc.createUrl("proj_c")].active
        check graph.pkgs[nc.createUrl("proj_d")].active

        check $graph.root.activeVersion == "#head@-"
        check $graph.pkgs[nc.createUrl("proj_a")].activeVersion == "1.1.0@fb3804df^"
        check $graph.pkgs[nc.createUrl("proj_b")].activeVersion == "1.1.0@ee875bae^"
        check $graph.pkgs[nc.createUrl("proj_c")].activeVersion == "1.2.0@9331e14f^"
        check $graph.pkgs[nc.createUrl("proj_d")].activeVersion == "1.0.0@0dec9c97"

        let formMinVer = graph.toFormular(MinVer)
        context().dumpGraphs = true
        var solMinVer: Solution
        solve(graph, formMinVer)


        check $graph.root.activeVersion == "#head@-"
        check $graph.pkgs[nc.createUrl("proj_a")].activeVersion == "1.0.0@e479b438"
        check $graph.pkgs[nc.createUrl("proj_b")].activeVersion == "1.0.0@af427510"
        check $graph.pkgs[nc.createUrl("proj_c")].activeVersion == "1.2.0@9331e14f^"
        check $graph.pkgs[nc.createUrl("proj_d")].activeVersion == "1.0.0@0dec9c97"

        check graph.validateDependencyGraph()
        let topo = graph.toposorted()

        check topo[0].url.projectName == "proj_d.buildGraph.example.com"
        check topo[1].url.projectName == "proj_c.buildGraph.example.com"
        check topo[2].url.projectName == "proj_b.buildGraph.example.com"
        check topo[3].url.projectName == "proj_a.buildGraph.example.com"

        for pkg in topo:
          echo "PKG: ", pkg.url.projectName

suite "test expand with no git tags":
  setup:
    setAtlasVerbosity(Warning)
    context().nameOverrides = Patterns()
    context().urlOverrides = Patterns()
    context().proxy = parseUri "http://localhost:4242"
    context().dumbProxy = true
    context().depsDir = Path "deps"
    setAtlasErrorsColor(fgMagenta)

  test "expand using buildGraphNoGitTags":
      # setAtlasVerbosity(Info)
      withDir "tests/ws_semver_unit":
        removeDir("deps")
        workspace() = paths.getCurrentDir()
        context().flags = {UsesOverrides, KeepWorkspace, ListVersions, FullClones}
        context().defaultAlgo = SemVer

        var nc = createNimbleContext()
        nc.put("proj_a", toPkgUriRaw(parseUri "https://example.com/buildGraphNoGitTags/proj_a"))
        nc.put("proj_b", toPkgUriRaw(parseUri "https://example.com/buildGraphNoGitTags/proj_b"))
        nc.put("proj_c", toPkgUriRaw(parseUri "https://example.com/buildGraphNoGitTags/proj_c"))
        nc.put("proj_d", toPkgUriRaw(parseUri "https://example.com/buildGraphNoGitTags/proj_d"))

        let dir = paths.getCurrentDir().absolutePath

        var graph = dir.expand(nc, AllReleases, onClone=DoClone)

        echo "\tgraph:\n", graph.toJson(ToJsonOptions(enumMode: joptEnumString))

        let form = graph.toFormular(SemVer)
        context().dumpGraphs = true
        var sol: Solution
        solve(graph, form)

        check graph.root.active
        check graph.pkgs[nc.createUrl("proj_a")].active
        check graph.pkgs[nc.createUrl("proj_b")].active
        check graph.pkgs[nc.createUrl("proj_c")].active
        check graph.pkgs[nc.createUrl("proj_d")].active

        check $graph.root.activeVersion == "#head@-"
        check $graph.pkgs[nc.createUrl("proj_a")].activeVersion.version == "1.1.0"
        check $graph.pkgs[nc.createUrl("proj_b")].activeVersion.version == "1.1.0"
        check $graph.pkgs[nc.createUrl("proj_c")].activeVersion.version == "1.2.0"
        check $graph.pkgs[nc.createUrl("proj_d")].activeVersion.version == "1.0.0"

        let formMinVer = graph.toFormular(MinVer)
        context().dumpGraphs = true
        var solMinVer: Solution
        solve(graph, formMinVer)

        check $graph.root.activeVersion == "#head@-"
        check $graph.pkgs[nc.createUrl("proj_a")].activeVersion.version == "1.0.0"
        check $graph.pkgs[nc.createUrl("proj_b")].activeVersion.version == "1.0.0"
        check $graph.pkgs[nc.createUrl("proj_c")].activeVersion.version == "1.2.0"
        check $graph.pkgs[nc.createUrl("proj_d")].activeVersion.version == "1.0.0"

        check graph.validateDependencyGraph()
        let topo = graph.toposorted()

        check topo[0].url.projectName == "proj_d"
        check topo[1].url.projectName == "proj_c"
        check topo[2].url.projectName == "proj_b"
        check topo[3].url.projectName == "proj_a"

        for pkg in topo:
          echo "PKG: ", pkg.url.projectName


  test "expand using buildGraphNoGitTags with explicit versions":
      setAtlasVerbosity(Trace)
      withDir "tests/ws_testtraverse_explicit":
        removeDir("deps")
        workspace() = paths.getCurrentDir()
        context().flags = {UsesOverrides, KeepWorkspace, ListVersions, FullClones}
        context().defaultAlgo = SemVer

        var nc = createNimbleContext()
        nc.put("proj_a", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_a"))
        nc.put("proj_b", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_b"))
        nc.put("proj_c", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_c"))
        nc.put("proj_d", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_d"))

        let dir = paths.getCurrentDir().absolutePath

        var graph = dir.expand(nc, AllReleases, onClone=DoClone)

        echo "\tgraph:\n", graph.toJson(ToJsonOptions(enumMode: joptEnumString))

        echo "explicit versions: "
        for pkgUrl, commits in nc.explicitVersions.pairs:
          echo "\tversions: ", pkgUrl, " commits: ", commits.toSeq().mapIt($it).join("; ")

        let form = graph.toFormular(SemVer)
        context().dumpGraphs = true
        var sol: Solution
        solve(graph, form)

        check graph.root.active
        check graph.pkgs[nc.createUrl("proj_a")].active
        check graph.pkgs[nc.createUrl("proj_b")].active
        check graph.pkgs[nc.createUrl("proj_c")].active
        check graph.pkgs[nc.createUrl("proj_d")].active

        check $graph.root.activeVersion == "#head@-"
        check $graph.pkgs[nc.createUrl("proj_a")].activeVersion.version == "#7ca5581cd"
        check $graph.pkgs[nc.createUrl("proj_b")].activeVersion.version == "1.1.0"
        check $graph.pkgs[nc.createUrl("proj_c")].activeVersion.version == "1.2.0"
        check $graph.pkgs[nc.createUrl("proj_d")].activeVersion.version == "1.0.0"


        check $graph.root.activeVersion == "#head@-"


infoNow "tester", "All tests run successfully"
