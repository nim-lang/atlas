# Small program that runs the test cases

import std / [strutils, os, uri, jsonutils, json, tables, sequtils, algorithm, strformat, unittest]
import std/terminal
import basic/[sattypes, context, reporters, pkgurls, compiledpatterns, versions]
import basic/[deptypes, nimblecontext]
import dependencies
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
    checkpoint "Checking sp versions: " & $sp.versions.keys.toSeq.mapIt(it.vtag)
    check vt in sp.versions
    if vt in sp.versions:
      check sp.versions[vt].status == Normal
      if not skipCount:
        check sp.versions[vt].requirements.len() == 1

      if url != "":
        check $sp.versions[vt].requirements[0][0] == url
      if ver != "":
        check $sp.versions[vt].requirements[0][1] == ver

suite "test expand with git tags":
  setup:
    setAtlasVerbosity(Info)
    context().nameOverrides = Patterns()
    context().urlOverrides = Patterns()
    context().proxy = parseUri "http://localhost:4242"
    context().dumbProxy = true
    context().depsDir = Path "deps"
    setAtlasErrorsColor(fgMagenta)

    # These will change if atlas-tests is regnerated!
    # To update run and use commits not adding a proj_x.nim file
    #    curl http://localhost:4242/buildGraph/ws_generated-logs.txt
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

  test "collect nimbles":
      # setAtlasVerbosity(Trace)
      withDir "tests/ws_testtraverse":
        removeDir("deps")
        context().flags = {UsesOverrides, KeepWorkspace, ListVersions, FullClones}
        context().defaultAlgo = SemVer
        # discard context().overrides.addPattern("$+", "file://./buildGraph/$#")
        workspace() = paths.getCurrentDir()

        let dir = paths.getCurrentDir()
        # writeFile("ws_testtraverse.nimble", "requires \"proj_a\"\n")

        let deps = setupGraph()
        var nc = createNimbleContext()
        nc.put("proj_a", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_a"))
        nc.put("proj_b", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_b"))
        nc.put("proj_c", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_c"))
        nc.put("proj_d", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_d"))
        # var graph = DepGraph(nodes: @[], reqs: defaultReqs())
        echo "DIR: ", dir
        let url = nc.createUrlFromPath(dir)
        echo "URL: ", url

        check url.toDirectoryPath() == Path(workspace())

        var dep0 = Package(url: url, isRoot: true)
        var dep1 = Package(url: nc.createUrl("proj_a"))
        var dep2 = Package(url: nc.createUrl("proj_b"))
        var dep3 = Package(url: nc.createUrl("proj_c"))
        var dep4 = Package(url: nc.createUrl("proj_d"))

        nc.loadDependency(dep0)
        nc.loadDependency(dep1)
        nc.loadDependency(dep2)
        nc.loadDependency(dep3)
        nc.loadDependency(dep4)

        check dep0.state == Found
        check dep0.ondisk == Path(workspace())
        check dep1.state == Found
        check dep1.ondisk == Path(workspace().string / "deps" / "proj_a")
        check dep2.state == Found
        check dep2.ondisk == Path(workspace().string / "deps" / "proj_b")
        check dep3.state == Found
        check dep3.ondisk == Path(workspace().string / "deps" / "proj_c")
        check dep4.state == Found
        check dep4.ondisk == Path(workspace().string / "deps" / "proj_d")

        check collectNimbleVersions(nc, dep0) == newSeq[VersionTag]()
        proc tolist(tags: seq[VersionTag]): seq[string] = tags.mapIt($VersionTag(v: Version"", c: it.c)).sorted()

        echo "projAnimbles: ", collectNimbleVersions(nc, dep1)
        check collectNimbleVersions(nc, dep1).tolist() == projAnimbles.tolist()
        check collectNimbleVersions(nc, dep2).tolist() == projBnimbles.tolist()
        check collectNimbleVersions(nc, dep3).tolist() == projCnimbles.tolist()
        check collectNimbleVersions(nc, dep4).tolist() == projDnimbles.tolist()

  test "expand from file":
      #setAtlasVerbosity(Trace)
      withDir "tests/ws_testtraverse":
        removeDir("deps")
        workspace() = paths.getCurrentDir()
        context().flags = {UsesOverrides, KeepWorkspace, ListVersions, FullClones}
        context().defaultAlgo = SemVer
        discard context().nameOverrides.addPattern("$+", "file://./buildGraph/$#")

        var nc = createNimbleContext()

        let deps = setupGraph()
        let dir = paths.getCurrentDir().absolutePath

        let graph = dir.expand(nc, AllReleases, onClone=DoClone)

        checkpoint "\tgraph:\n" & $graph.toJson(ToJsonOptions(enumMode: joptEnumString))
        let sp = graph.pkgs.values().toSeq()

        check sp.len() == 5
        doAssert sp.len() == 5

        let sp0: Package = sp[0] # proj ws_testtraversal
        let sp1: Package = sp[1] # proj A 
        let sp2: Package = sp[2] # proj B
        let sp3: Package = sp[3] # proj C
        let sp4: Package = sp[4] # proj D

        check $sp0.url == "atlas://workspace/ws_testtraverse.nimble"
        check $sp1.url == "file://$1/buildGraph/proj_a" % [$dir]  
        check $sp2.url == "file://$1/buildGraph/proj_b" % [$dir]
        check $sp3.url == "file://$1/buildGraph/proj_c" % [$dir]
        check $sp4.url == "file://$1/buildGraph/proj_d" % [$dir]

        let vt = toVersionTag

        testRequirements(sp0, @[vt"#head@-"], [
          ("file://$1/buildGraph/proj_a" % [$dir], "*"),
        ])


        # verify that the duplicate releases have been "reduced"
        # check sp1.releases[projAtags[1]] == sp1.releases[projAtags[2]]
        # check cast[pointer](sp1.releases[projAtags[1]]) == cast[pointer](sp1.releases[projAtags[2]])
        testRequirements(sp1, projAtags, [
          ("file://$1/buildGraph/proj_b" % [$dir], ">= 1.1.0"),
          ("file://$1/buildGraph/proj_b" % [$dir], ">= 1.0.0"),
        ])

        testRequirements(sp2, projBtags, [
          ("file://$1/buildGraph/proj_c" % [$dir], ">= 1.1.0"),
          ("file://$1/buildGraph/proj_c" % [$dir], ">= 1.0.0"),
        ])

        testRequirements(sp3, projCtags, [
          ("file://$1/buildGraph/proj_d" % [$dir], ">= 1.0.0"),
        ])

        testRequirements(sp4, projDtags, [
          ("file://$1/buildGraph/does_not_exist" % [$dir], ">= 1.2.0"),
          ("", ""),
        ], true)

  test "expand from http":
      withDir "tests/ws_testtraverse":
        # setAtlasVerbosity(Trace)
        removeDir("deps")
        workspace() = paths.getCurrentDir()
        context().flags = {UsesOverrides, KeepWorkspace, ListVersions, FullClones}
        context().defaultAlgo = SemVer
        context().depsDir = Path "deps_http"
        context().nameOverrides = Patterns()

        # discard context().overrides.addPattern("does_not_exist", "file://./buildGraph/does_not_exist")
        # discard context().overrides.addPattern("$+", "http://localhost:4242/buildGraph/$#")
        var nc = createNimbleContext()
        nc.put("proj_a", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_a"))
        nc.put("proj_b", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_b"))
        nc.put("proj_c", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_c"))
        nc.put("proj_d", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_d"))
        # nc.nameToUrl["does_not_exist"] = toPkgUri(parseUri "https://example.com/buildGraph/does_not_exist")

        let pkgA = nc.createUrl("proj_a")

        check $pkgA == "https://example.com/buildGraph/proj_a"

        # let deps = setupGraph()
        let dir = paths.getCurrentDir().absolutePath

        let graph = dir.expand(nc, AllReleases, onClone=DoClone)

        checkpoint "\tgraph:\n" & $graph.toJson(ToJsonOptions(enumMode: joptEnumString))
        let sp = graph.pkgs.values().toSeq()
        let vt = toVersionTag

        check sp.len() == 5
        check $sp[0].url == "atlas://workspace/ws_testtraverse.nimble"
        check $sp[1].url == "https://example.com/buildGraph/proj_a"
        check $sp[2].url == "https://example.com/buildGraph/proj_b"
        check $sp[3].url == "https://example.com/buildGraph/proj_c"
        check $sp[4].url == "https://example.com/buildGraph/proj_d"

        let sp0: Package = sp[0] # proj ws_testtraversal
        testRequirements(sp0, @[vt"#head@-"], [
          ("https://example.com/buildGraph/proj_a", "*"),
        ])


suite "test expand with no git tags":

  setup:
    setAtlasVerbosity(Warning)
    context().nameOverrides = Patterns()
    context().urlOverrides = Patterns()
    context().proxy = parseUri "http://localhost:4242"
    context().dumbProxy = true
    context().depsDir = Path "deps"
    setAtlasErrorsColor(fgMagenta)

    # These will change if atlas-tests is regnerated!
    # To update run and use commits not adding a proj_x.nim file
    #    curl http://localhost:4242/buildGraph/ws_generated-logs.txt
    let projAnimbles = dedent"""
    61eacba5453392d06ed0e839b52cf17462d94648 1.1.0
    6a1cc178670d372f21c21329d35579e96283eab0
    88d1801bff2e72cdaf2d29b438472336df6aa66d 1.0.0
    """.parseTaggedVersions(false)
    let projAtags = projAnimbles.filterIt(it.v.string != "")

    let projBnimbles = dedent"""
    c70824d8b9b669cc37104d35055fd8c11ecdd680 1.1.0
    bbb208a9cad0d58f85bd00339c85dfeb8a4f7ac0
    289ae9eea432cdab9d681ab69444ae9d439eb6ae 1.0.0
    """.parseTaggedVersions(false)
    let projBtags = projBnimbles.filterIt(it.v.string != "")

    let projCnimbles = dedent"""
    d6c04d67697df7807b8e2b6028d167b517d13440 1.2.0
    8756fa4575bf750d4472ac78ba91520f05a1de60 1.0.0
    """.parseTaggedVersions(false)
    let projCtags = projCnimbles.filterIt(it.v.string != "")

    let projDnimbles = dedent"""
    7ee36fecb09ef33024d3aa198ed87d18c28b3548 2.0.0
    0bd0e77a8cbcc312185c2a1334f7bf2eb7b1241f 1.0.0
    """.parseTaggedVersions(false)
    let projDtags = projDnimbles.filterIt(it.v.string != "")

  test "collect nimbles":
      # setAtlasVerbosity(Trace)
      withDir "tests/ws_testtraverse":
        removeDir("deps")
        workspace() = paths.getCurrentDir()
        context().flags = {UsesOverrides, KeepWorkspace, ListVersions, FullClones}
        context().defaultAlgo = SemVer
        discard context().nameOverrides.addPattern("$+", "file://./buildGraphNoGitTags/$#")

        # writeFile("ws_testtraverse.nimble", "requires \"proj_a\"\n")

        let deps = setupGraphNoGitTags()
        var nc = createNimbleContext()
        # var graph = DepGraph(nodes: @[], reqs: defaultReqs())
        let url = nc.createUrlFromPath(workspace())

        echo "URL: ", url
        var dep0 = Package(url: url, isRoot: true)
        var dep1 = Package(url: nc.createUrl("proj_a"))
        var dep2 = Package(url: nc.createUrl("proj_b"))
        var dep3 = Package(url: nc.createUrl("proj_c"))
        var dep4 = Package(url: nc.createUrl("proj_d"))

        nc.loadDependency(dep0)
        nc.loadDependency(dep1)
        nc.loadDependency(dep2)
        nc.loadDependency(dep3)
        nc.loadDependency(dep4)

        check collectNimbleVersions(nc, dep0) == newSeq[VersionTag]()
        proc tolist(tags: seq[VersionTag]): seq[string] = tags.mapIt($VersionTag(v: Version"", c: it.c)).sorted()

        echo "projAtags: ", collectNimbleVersions(nc, dep1)
        check collectNimbleVersions(nc, dep1).len() == 3
        check collectNimbleVersions(nc, dep1)[2].isTip
        check collectNimbleVersions(nc, dep1).tolist() == projAnimbles.tolist()
        check collectNimbleVersions(nc, dep2).tolist() == projBnimbles.tolist()
        check collectNimbleVersions(nc, dep3).tolist() == projCnimbles.tolist()
        check collectNimbleVersions(nc, dep4).tolist() == projDnimbles.tolist()

  test "expand no git tags":
      # setAtlasVerbosity(Trace)
      withDir "tests/ws_testtraverse":
        removeDir("deps")
        workspace() = paths.getCurrentDir()
        context().flags = {UsesOverrides, KeepWorkspace, ListVersions, FullClones}
        context().defaultAlgo = SemVer

        var nc = createNimbleContext()
        discard nc.nameOverrides.addPattern("$+", "file://./buildGraphNoGitTags/$#")

        let deps = setupGraphNoGitTags()
        let dir = paths.getCurrentDir().absolutePath

        let graph = dir.expand(nc, AllReleases, onClone=DoClone)

        checkpoint "\tgraph:\n" & $graph.toJson(ToJsonOptions(enumMode: joptEnumString))
        let sp = graph.pkgs.values().toSeq()

        doAssert sp.len() == 5

        let sp0: Package = sp[0] # proj ws_testtraversal
        let sp1: Package = sp[1] # proj A
        let sp2: Package = sp[2] # proj B
        let sp3: Package = sp[3] # proj C
        let sp4: Package = sp[4] # proj D

        check $sp[0].url == "atlas://workspace/ws_testtraverse.nimble"
        check $sp[1].url == "file://$1/buildGraphNoGitTags/proj_a" % [$dir]
        check $sp[2].url == "file://$1/buildGraphNoGitTags/proj_b" % [$dir]
        check $sp[3].url == "file://$1/buildGraphNoGitTags/proj_c" % [$dir]
        check $sp[4].url == "file://$1/buildGraphNoGitTags/proj_d" % [$dir]

        let vt = toVersionTag
        proc stripcommits(tags: seq[VersionTag]): seq[VersionTag] = tags.mapIt(VersionTag(v: Version"", c: it.c))

        testRequirements(sp0, @[vt"#head@-"], [
          ("file://$1/buildGraphNoGitTags/proj_a" % [$dir], "*"),
        ])

        testRequirements(sp1, projAtags, [
          ("file://$1/buildGraphNoGitTags/proj_b" % [$dir], ">= 1.1.0"),
          ("file://$1/buildGraphNoGitTags/proj_b" % [$dir], ">= 1.0.0"),
        ])

        testRequirements(sp2, projBtags, [
          ("file://$1/buildGraphNoGitTags/proj_c" % [$dir], ">= 1.1.0"),
          ("file://$1/buildGraphNoGitTags/proj_c" % [$dir], ">= 1.0.0"),
        ])

        testRequirements(sp3, projCtags, [
          ("file://$1/buildGraphNoGitTags/proj_d" % [$dir], ">= 1.0.0"),
          ("file://$1/buildGraphNoGitTags/proj_d" % [$dir], ">= 1.2.0"),
        ])

        testRequirements(sp4, projDtags, [
          ("file://$1/buildGraphNoGitTags/does_not_exist" % [$dir], ">= 1.2.0"),
          ("", ""),
        ], true)

suite "test expand with no git tags and nimble commits max":

  setup:
    setAtlasVerbosity(Warning)
    context().nameOverrides = Patterns()
    context().urlOverrides = Patterns()
    context().proxy = parseUri "http://localhost:4242"
    context().dumbProxy = true
    context().depsDir = Path "deps"
    setAtlasErrorsColor(fgMagenta)

    # These will change if atlas-tests is regnerated!
    # To update run and use commits not adding a proj_x.nim file
    #    curl http://localhost:4242/buildGraph/ws_generated-logs.txt
    let projAnimbles = dedent"""
    61eacba5453392d06ed0e839b52cf17462d94648 1.1.0
    6a1cc178670d372f21c21329d35579e96283eab0 1.0.0
    88d1801bff2e72cdaf2d29b438472336df6aa66d
    """.parseTaggedVersions(false)
    let projAtags = projAnimbles.filterIt(it.v.string != "")

    let projBnimbles = dedent"""
    c70824d8b9b669cc37104d35055fd8c11ecdd680 1.1.0
    bbb208a9cad0d58f85bd00339c85dfeb8a4f7ac0 1.0.0
    289ae9eea432cdab9d681ab69444ae9d439eb6ae
    """.parseTaggedVersions(false)
    let projBtags = projBnimbles.filterIt(it.v.string != "")

    let projCnimbles = dedent"""
    d6c04d67697df7807b8e2b6028d167b517d13440 1.2.0
    8756fa4575bf750d4472ac78ba91520f05a1de60 1.0.0
    """.parseTaggedVersions(false)
    let projCtags = projCnimbles.filterIt(it.v.string != "")

    let projDnimbles = dedent"""
    7ee36fecb09ef33024d3aa198ed87d18c28b3548 2.0.0
    0bd0e77a8cbcc312185c2a1334f7bf2eb7b1241f 1.0.0
    """.parseTaggedVersions(false)
    let projDtags = projDnimbles.filterIt(it.v.string != "")

  test "expand no git tags and nimble commits max":
      # setAtlasVerbosity(Trace)
      withDir "tests/ws_testtraverse":
        removeDir("deps")
        context().nimbleCommitsMax = true
        workspace() = paths.getCurrentDir()
        context().flags = {UsesOverrides, KeepWorkspace, ListVersions, FullClones}
        context().defaultAlgo = SemVer

        var nc = createNimbleContext()
        discard nc.nameOverrides.addPattern("$+", "file://./buildGraphNoGitTags/$#")

        let deps = setupGraphNoGitTags()
        let dir = paths.getCurrentDir().absolutePath

        let graph = dir.expand(nc, AllReleases, onClone=DoClone)

        checkpoint "\tgraph:\n" & $graph.toJson(ToJsonOptions(enumMode: joptEnumString))
        let sp = graph.pkgs.values().toSeq()

        doAssert sp.len() == 5

        let sp0: Package = sp[0] # proj ws_testtraversal
        let sp1: Package = sp[1] # proj A
        let sp2: Package = sp[2] # proj B
        let sp3: Package = sp[3] # proj C
        let sp4: Package = sp[4] # proj D

        check $sp[0].url == "atlas://workspace/ws_testtraverse.nimble"
        check $sp[1].url == "file://$1/buildGraphNoGitTags/proj_a" % [$dir]
        check $sp[2].url == "file://$1/buildGraphNoGitTags/proj_b" % [$dir]
        check $sp[3].url == "file://$1/buildGraphNoGitTags/proj_c" % [$dir]
        check $sp[4].url == "file://$1/buildGraphNoGitTags/proj_d" % [$dir]

        let vt = toVersionTag
        proc stripcommits(tags: seq[VersionTag]): seq[VersionTag] = tags.mapIt(VersionTag(v: Version"", c: it.c))

        testRequirements(sp0, @[vt"#head@-"], [
          ("file://$1/buildGraphNoGitTags/proj_a" % [$dir], "*"),
        ])

        testRequirements(sp1, projAtags, [
          ("file://$1/buildGraphNoGitTags/proj_b" % [$dir], ">= 1.1.0"),
          ("file://$1/buildGraphNoGitTags/proj_b" % [$dir], ">= 1.0.0"),
        ])

        testRequirements(sp2, projBtags, [
          ("file://$1/buildGraphNoGitTags/proj_c" % [$dir], ">= 1.1.0"),
          ("file://$1/buildGraphNoGitTags/proj_c" % [$dir], ">= 1.0.0"),
        ])

        testRequirements(sp3, projCtags, [
          ("file://$1/buildGraphNoGitTags/proj_d" % [$dir], ">= 1.0.0"),
          ("file://$1/buildGraphNoGitTags/proj_d" % [$dir], ">= 1.2.0"),
        ])

        testRequirements(sp4, projDtags, [
          ("file://$1/buildGraphNoGitTags/does_not_exist" % [$dir], ">= 1.2.0"),
          ("", ""),
        ], true)

infoNow "tester", "All tests run successfully"

# if failures > 0: quit($failures & " failures occurred.")

# Normal: create or remotely cloning repos
# nim c -r   1.80s user 0.71s system 60% cpu 4.178 total
# shims/nim c -r   32.00s user 25.11s system 41% cpu 2:18.60 total
# nim c -r   30.83s user 24.67s system 40% cpu 2:17.17 total

# Local repos:
# nim c -r   1.59s user 0.60s system 88% cpu 2.472 total
# w/integration: nim c -r   23.86s user 18.01s system 71% cpu 58.225 total
# w/integration: nim c -r   32.00s user 25.11s system 41% cpu 1:22.80 total
