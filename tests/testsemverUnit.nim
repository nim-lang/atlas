# Small program that runs the test cases

import std / [strutils, os, uri, jsonutils, json, tables, sequtils, strformat, unittest]
import basic/[sattypes, context, reporters, pkgurls, compiledpatterns, versions]
import basic/[deptypes, nimblecontext]
import dependencies
import depgraphs
import testerutils

if not dirExists("tests/ws_testtraverse/buildGraph"):
  ensureGitHttpServer()

# proc createGraph*(s: PkgUrl): DepGraph =
#   result = DepGraph(nodes: @[], reqs: defaultReqs())
#   result.packageToDependency[s] = result.nodes.len
#   result.nodes.add Package(pkg: s, versions: @[], isRoot: true, isTopLevel: true, activeRelease: -1)

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

template testRequirements(sp: Package,
                          projTags: seq[VersionTag],
                          vers: openArray[(string, string)];
                          skipCount = false) =
  checkpoint "Checking Requirements: " & astToStr(sp)
  if not skipCount:
    check sp.versions.len() == vers.len()

  for idx, vt in projTags:
    # let vt = projTags[idx]
    let vt = vt.toPkgVer
    checkpoint "Checking requirements item: " & $vers[idx] & " version: " & $vt
    check idx < vers.len()
    let (url, ver) = vers[idx]
    check sp.state == Processed
    check vt in sp.versions
    if vt in sp.versions:
      if vers[idx][0].endsWith("does_not_exist"):
        check sp.versions[vt].status == HasBrokenDep
      else:
        check sp.versions[vt].status == Normal
      if sp.versions[vt].status != Normal:
        continue
      if not skipCount:
        check sp.versions[vt].requirements.len() == 1

      if url != "":
        check $sp.versions[vt].requirements[0][0] == url
      if ver != "":
        check $sp.versions[vt].requirements[0][1] == ver

suite "graph solve":
  setup:
    setAtlasVerbosity(Debug)
    context().overrides = Patterns()
    context().proxy = parseUri "http://localhost:4242"
    context().dumbProxy = true
    context().depsDir = Path "deps"

    let projAnimbles = dedent"""
    fb3804df03c3c414d98d1f57deeb44c8a223ba44 1.1.0
    7ca5581cd5355f6b5461a23f9683f19378bd268a
    e479b438015e734bea67a9c63d783e78cab5746e 1.0.0
    """.parseTaggedVersions(false)
    let projAtags = projAnimbles.filterIt(it.v.string != "")

    let projBnimbles = dedent"""
    ee875baecee161ed053b87b583b2f08526838bd6 1.1.0
    cd3ad76043e5f983f704be6bf61e57d187fe070f
    af4275109d60caaeacf2912a37c2339aca40a922 1.0.0
    """.parseTaggedVersions(false)
    let projBtags = projBnimbles.filterIt(it.v.string != "")

    let projCnimbles = dedent"""
    9331e14f3fa20ed75b7d5c0ab93aa5fb0293192f 1.2.0
    c7540297c01dc57a98cb1fce7660ab6f2a0cee5f
    """.parseTaggedVersions(false)
    let projCtags = projCnimbles.filterIt(it.v.string != "")

    let projDnimbles = dedent"""
    dd98f775ae33d450dc7f936f850e247e820e31ad 2.0.0
    0dec9c9733129919972416f04e73b1fb2cbf3bd3 1.0.0
    """.parseTaggedVersions(false)
    let projDtags = projDnimbles.filterIt(it.v.string != "")

  test "ws_semver_unit traverseDependency":
      # setAtlasVerbosity(Info)
      withDir "tests/ws_semver_unit":
        removeDir("deps")
        workspace() = paths.getCurrentDir()
        context().flags = {UsesOverrides, KeepWorkspace, ListVersions, FullClones}
        context().defaultAlgo = SemVer

        var nc = createNimbleContext()
        nc.put("proj_a", parseUri "https://example.com/buildGraph/proj_a")
        nc.put("proj_b", parseUri "https://example.com/buildGraph/proj_b")
        nc.put("proj_c", parseUri "https://example.com/buildGraph/proj_c")
        nc.put("proj_d", parseUri "https://example.com/buildGraph/proj_d")

        let dir = paths.getCurrentDir().absolutePath

        var graph = dir.expand(nc, AllReleases, onClone=DoClone)

        let sp = graph.pkgs.values().toSeq()
        let sp0: Package = sp[0] # proj ws_testtraversal
        let vt = toVersionTag
        testRequirements(sp0, @[vt"#head@-"], [
          ("https://example.com/buildGraph/proj_a", "*"),
        ])

        let sp1: Package = sp[1] # proj A
        testRequirements(sp1, projAtags, [
          ("https://example.com/buildGraph/proj_b", ">= 1.1.0"),
          ("https://example.com/buildGraph/proj_b", ">= 1.0.0"),
        ])
        let sp2 = sp[2] # proj B
        testRequirements(sp2, projBtags, [
          ("https://example.com/buildGraph/proj_c", ">= 1.1.0"),
          ("https://example.com/buildGraph/proj_c", ">= 1.0.0"),
        ])
        let sp3 = sp[3] # proj C
        testRequirements(sp3, projCtags, [
          ("https://example.com/buildGraph/proj_d", ">= 1.0.0"),
        ])
        let sp4 = sp[4] # proj C
        testRequirements(sp4, projDtags, [
          ("https://example.com/buildGraph/does_not_exist", ">= 1.2.0"),
          ("", ""),
        ], true)

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
        check $graph.pkgs[nc.createUrl("proj_a")].activeVersion == "1.1.0@fb3804df"
        check $graph.pkgs[nc.createUrl("proj_b")].activeVersion == "1.1.0@ee875bae"
        check $graph.pkgs[nc.createUrl("proj_c")].activeVersion == "1.2.0@9331e14f"
        check $graph.pkgs[nc.createUrl("proj_d")].activeVersion == "1.0.0@0dec9c97"

        let formMinVer = graph.toFormular(MinVer)
        context().dumpGraphs = true
        var solMinVer: Solution
        solve(graph, formMinVer)

        check $graph.root.activeVersion == "#head@-"
        check $graph.pkgs[nc.createUrl("proj_a")].activeVersion == "1.0.0@e479b438"
        check $graph.pkgs[nc.createUrl("proj_b")].activeVersion == "1.0.0@af427510"
        check $graph.pkgs[nc.createUrl("proj_c")].activeVersion == "1.2.0@9331e14f"
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
      # setAtlasVerbosity(Info)
      withDir "tests/ws_semver_unit":
        removeDir("deps")
        workspace() = paths.getCurrentDir()
        context().flags = {UsesOverrides, KeepWorkspace, ListVersions, FullClones}
        context().defaultAlgo = SemVer
        discard context().overrides.addPattern("$+", "-> http://example.com/buildGraph/$#")

        var nc = createNimbleContext()

        let dir = paths.getCurrentDir().absolutePath

        var graph = dir.expand(nc, AllReleases, onClone=DoClone)

        let sp = graph.pkgs.values().toSeq()

        doAssert sp.len() == 5

        let sp0 = sp[0] # proj ws_testtraversal
        let sp1 = sp[1] # proj ws_testtraversal
        let sp2 = sp[2] # proj B
        let sp3 = sp[3] # proj C
        let sp4 = sp[4] # proj D

        let vt = toVersionTag
        testRequirements(sp0, @[vt"#head@-"], [
          ("https://example.com/buildGraph/proj_a", "*"),
        ])

        testRequirements(sp1, projAtags, [
          ("https://example.com/buildGraph/proj_b", ">= 1.1.0"),
          ("https://example.com/buildGraph/proj_b", ">= 1.0.0"),
        ])
        testRequirements(sp2, projBtags, [
          ("https://example.com/buildGraph/proj_c", ">= 1.1.0"),
          ("https://example.com/buildGraph/proj_c", ">= 1.0.0"),
        ])
        testRequirements(sp3, projCtags, [
          ("https://example.com/buildGraph/proj_d", ">= 1.0.0"),
        ])
        testRequirements(sp4, projDtags, [
          ("https://example.com/buildGraph/does_not_exist", ">= 1.2.0"),
          ("", ""),
        ], true)

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
        check $graph.pkgs[nc.createUrl("proj_a")].activeVersion == "1.1.0@fb3804df"
        check $graph.pkgs[nc.createUrl("proj_b")].activeVersion == "1.1.0@ee875bae"
        check $graph.pkgs[nc.createUrl("proj_c")].activeVersion == "1.2.0@9331e14f"
        check $graph.pkgs[nc.createUrl("proj_d")].activeVersion == "1.0.0@0dec9c97"

        let formMinVer = graph.toFormular(MinVer)
        context().dumpGraphs = true
        var solMinVer: Solution
        solve(graph, formMinVer)


        check $graph.root.activeVersion == "#head@-"
        check $graph.pkgs[nc.createUrl("proj_a")].activeVersion == "1.0.0@e479b438"
        check $graph.pkgs[nc.createUrl("proj_b")].activeVersion == "1.0.0@af427510"
        check $graph.pkgs[nc.createUrl("proj_c")].activeVersion == "1.2.0@9331e14f"
        check $graph.pkgs[nc.createUrl("proj_d")].activeVersion == "1.0.0@0dec9c97"

        check graph.validateDependencyGraph()
        let topo = graph.toposorted()

        check topo[0].url.projectName == "proj_d"
        check topo[1].url.projectName == "proj_c"
        check topo[2].url.projectName == "proj_b"
        check topo[3].url.projectName == "proj_a"

        for pkg in topo:
          echo "PKG: ", pkg.url.projectName

infoNow "tester", "All tests run successfully"
