# Small program that runs the test cases

import std / [strutils, os, uri, jsonutils, json, tables, sequtils, unittest]
import std/terminal

import basic/[sattypes, context, reporters, pkgurls, compiledpatterns, versions]
import basic/[deptypes, nimblecontext, deptypesjson]
import dependencies
import depgraphs
import testerutils
import atlas, confighandler

ensureGitHttpServer()

proc setupProjTest() =
  withDir "deps" / "proj_a":
    writeFile("proj_a.nimble", dedent"""
    requires "proj_b >= 1.1.0"
    feature "testing":
      requires "proj_feature_dep >= 1.0.0"
    """)
    exec "git commit -a -m \"feat: add proj_a.nimble\""
    exec "git tag v1.2.0"

  removeDir "proj_feature_dep"
  createDir "proj_feature_dep"
  withDir "proj_feature_dep":
    writeFile("proj_feature_dep.nimble", dedent"""
    version "1.0.0"
    """)
    exec "git init"
    exec "git add proj_feature_dep.nimble"
    exec "git commit -m \"feat: add proj_feature_dep.nimble\""
    exec "git tag v1.0.0"

suite "test features":
  setup:
    # setAtlasVerbosity(Trace)
    context().nameOverrides = Patterns()
    context().urlOverrides = Patterns()
    context().proxy = parseUri "http://localhost:4242"
    context().flags.incl DumbProxy
    context().depsDir = Path "deps"
    setAtlasErrorsColor(fgMagenta)

  test "setup and test target project":
      # setAtlasVerbosity(Info)
      setAtlasVerbosity(Error)
      withDir "tests/ws_features":
        removeDir("deps")
        project(paths.getCurrentDir())
        context().flags = {ListVersions}
        context().defaultAlgo = SemVer

        expectedVersionWithGitTags()
        var nc = createNimbleContext()
        nc.put("proj_a", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_a", true))
        nc.put("proj_b", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_b", true))
        nc.put("proj_c", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_c", true))
        nc.put("proj_d", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_d", true))
        # nc.put("proj_feature_dep", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_feature_dep", true))
        nc.put("proj_feature_dep", toPkgUriRaw(parseUri "file://" & (ospaths2.getCurrentDir() / "proj_feature_dep").absolutePath, true))

        check nc.lookup("proj_a").hasShortName
        check nc.lookup("proj_a").projectName == "proj_a"

        let dir = paths.getCurrentDir().absolutePath

        var graph0 = dir.loadWorkspace(nc, AllReleases, onClone=DoClone, doSolve=false)
        writeDepGraph(graph0)

        setupProjTest()

  test "setup and test target project":
      # setAtlasVerbosity(Info)
      setAtlasVerbosity(Trace)
      withDir "tests/ws_features":
        # removeDir("deps")
        project(paths.getCurrentDir())
        context().flags = {ListVersions}
        context().defaultAlgo = SemVer
        context().flags.incl DumpFormular

        expectedVersionWithGitTags()
        var nc = createNimbleContext()
        nc.put("proj_a", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_a", true))
        nc.put("proj_b", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_b", true))
        nc.put("proj_c", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_c", true))
        nc.put("proj_d", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_d", true))
        # nc.put("proj_feature_dep", toPkgUriRaw(parseUri "deps/proj_feature_dep_git", true))
        nc.put("proj_feature_dep", toPkgUriRaw(parseUri "file://" & (ospaths2.getCurrentDir() / "proj_feature_dep").absolutePath, true))

        check nc.lookup("proj_a").hasShortName
        check nc.lookup("proj_a").projectName == "proj_a"

        let dir = paths.getCurrentDir().absolutePath

        var graph = dir.loadWorkspace(nc, AllReleases, onClone=DoClone, doSolve=true)
        writeDepGraph(graph)

        # checkpoint "\tgraph:\n" & $graph.toJson(ToJsonOptions(enumMode: joptEnumString))

        # check false

        # let form = graph.toFormular(SemVer)
        # context().flags.incl DumpGraphs
        # var sol: Solution
        # solve(graph, form)

        check graph.root.active
        check graph.pkgs[nc.createUrl("proj_a")].active
        check graph.pkgs[nc.createUrl("proj_b")].active
        check graph.pkgs[nc.createUrl("proj_c")].active
        check graph.pkgs[nc.createUrl("proj_d")].active

        check $graph.root.activeVersion == "#head@-"
        # check $graph.pkgs[nc.createUrl("proj_a")].activeVersion == $findCommit("proj_a", "1.1.0")
        check $graph.pkgs[nc.createUrl("proj_a")].activeVersion.vtag.version == "1.2.0"
        check $graph.pkgs[nc.createUrl("proj_b")].activeVersion == $findCommit("proj_b", "1.1.0")
        check $graph.pkgs[nc.createUrl("proj_c")].activeVersion == $findCommit("proj_c", "1.2.0")
        check $graph.pkgs[nc.createUrl("proj_d")].activeVersion == $findCommit("proj_d", "1.0.0")

        # let graph2 = loadJson("graph-solved.json")

        let jnRoot = toJson(graph.root)
        var graphRoot: Package
        graphRoot.fromJson(jnRoot)
        echo "graphRoot: ", $graphRoot.toJson(ToJsonOptions(enumMode: joptEnumString))

        # check graph.toJson(ToJsonOptions(enumMode: joptEnumString)) == graph2.toJson(ToJsonOptions(enumMode: joptEnumString))

suite "test global features":
  setup:
    # setAtlasVerbosity(Trace)
    context().nameOverrides = Patterns()
    context().urlOverrides = Patterns()
    context().proxy = parseUri "http://localhost:4242"
    context().flags.incl DumbProxy
    context().depsDir = Path "deps"
    setAtlasErrorsColor(fgMagenta)

  test "setup and test target project":
      # setAtlasVerbosity(Info)
      setAtlasVerbosity(Error)
      withDir "tests/ws_features_global":
        removeDir("deps")
        project(paths.getCurrentDir())
        context().flags = {ListVersions}
        context().defaultAlgo = SemVer

        expectedVersionWithGitTags()
        var nc = createNimbleContext()
        nc.put("proj_a", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_a", true))
        nc.put("proj_b", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_b", true))
        nc.put("proj_c", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_c", true))
        nc.put("proj_d", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_d", true))
        # nc.put("proj_feature_dep", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_feature_dep", true))
        nc.put("proj_feature_dep", toPkgUriRaw(parseUri "file://" & (ospaths2.getCurrentDir() / "proj_feature_dep").absolutePath, true))

        check nc.lookup("proj_a").hasShortName
        check nc.lookup("proj_a").projectName == "proj_a"

        let dir = paths.getCurrentDir().absolutePath

        var graph0 = dir.loadWorkspace(nc, AllReleases, onClone=DoClone, doSolve=false)
        writeDepGraph(graph0)

        setupProjTest()

  test "setup and test target project":
      # setAtlasVerbosity(Info)
      setAtlasVerbosity(Trace)
      withDir "tests/ws_features_global":
        # removeDir("deps")
        project(paths.getCurrentDir())
        context().flags = {ListVersions}
        context().defaultAlgo = SemVer
        context().flags.incl DumpFormular

        expectedVersionWithGitTags()
        var nc = createNimbleContext()
        nc.put("proj_a", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_a", true))
        nc.put("proj_b", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_b", true))
        nc.put("proj_c", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_c", true))
        nc.put("proj_d", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_d", true))
        # nc.put("proj_feature_dep", toPkgUriRaw(parseUri "deps/proj_feature_dep_git", true))
        nc.put("proj_feature_dep", toPkgUriRaw(parseUri "file://" & (ospaths2.getCurrentDir() / "proj_feature_dep").absolutePath, true))

        check nc.lookup("proj_a").hasShortName
        check nc.lookup("proj_a").projectName == "proj_a"

        let dir = paths.getCurrentDir().absolutePath

        var graph = dir.loadWorkspace(nc, AllReleases, onClone=DoClone, doSolve=true)
        writeDepGraph(graph)

        # checkpoint "\tgraph:\n" & $graph.toJson(ToJsonOptions(enumMode: joptEnumString))

        # check false

        # let form = graph.toFormular(SemVer)
        # context().flags.incl DumpGraphs
        # var sol: Solution
        # solve(graph, form)

        check graph.root.active
        check graph.pkgs[nc.createUrl("proj_a")].active
        check graph.pkgs[nc.createUrl("proj_b")].active
        check graph.pkgs[nc.createUrl("proj_c")].active
        check graph.pkgs[nc.createUrl("proj_d")].active

        check $graph.root.activeVersion == "#head@-"
        # check $graph.pkgs[nc.createUrl("proj_a")].activeVersion == $findCommit("proj_a", "1.1.0")
        check $graph.pkgs[nc.createUrl("proj_a")].activeVersion.vtag.version == "1.2.0"
        check $graph.pkgs[nc.createUrl("proj_b")].activeVersion == $findCommit("proj_b", "1.1.0")
        check $graph.pkgs[nc.createUrl("proj_c")].activeVersion == $findCommit("proj_c", "1.2.0")
        check $graph.pkgs[nc.createUrl("proj_d")].activeVersion == $findCommit("proj_d", "1.0.0")

        # let graph2 = loadJson("graph-solved.json")

        let jnRoot = toJson(graph.root)
        var graphRoot: Package
        graphRoot.fromJson(jnRoot)
        echo "graphRoot: ", $graphRoot.toJson(ToJsonOptions(enumMode: joptEnumString))

        # check graph.toJson(ToJsonOptions(enumMode: joptEnumString)) == graph2.toJson(ToJsonOptions(enumMode: joptEnumString))
