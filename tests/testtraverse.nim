# Small program that runs the test cases

import std / [strutils, os, uri, jsonutils, json, sets, tables, sequtils, algorithm, strformat, unittest]
import std/terminal
import basic/[sattypes, context, reporters, pkgurls, compiledpatterns, versions]
import basic/[deptypes, nimblecontext]
import dependencies, depgraphs
import testerutils

# if not dirExists("tests/ws_testtraverse/buildGraph"):
ensureGitHttpServer()

# proc createGraph*(s: PkgUrl): DepGraph =
#   result = DepGraph(nodes: @[], reqs: defaultReqs())
#   result.packageToDependency[s] = result.nodes.len
#   result.nodes.add Package(pkg: s, versions: @[], isRoot: true, isTopLevel: true, activeRelease: -1)

template expectedVersionWithGitTags*() =
    # These will change if atlas-tests is regnerated!
    # To update run and use commits not adding a proj_x.nim file
    #    curl http://localhost:4242/buildGraph/ws_generated-logs.txt
    let projAnimbles {.inject.} = dedent"""
    1aeb8db7c1955af43d458ccbbf65358b0a1a4fab 1.1.0
    e4c0ff66740bf604fc050b783c4ee61af05be36b
    43cdb67b93331a45dd82628c4cc7f3876dc2af91 1.0.0
    """.parseTaggedVersions(false)
    let projAtags {.inject.} = projAnimbles.filterIt(it.v.string != "")

    let projBnimbles {.inject.} = dedent"""
    ecb875d651b205412c880bf6eadbdd9f2a8fc6a3 1.1.0
    185ab2a8ecfca2944e51b38ea66339181e676072
    c0c5fe710e7c274642f8e95a9d7c155ede95d57e 1.0.0
    """.parseTaggedVersions(false)
    let projBtags {.inject.} = projBnimbles.filterIt(it.v.string != "")

    let projCnimbles {.inject.} = dedent"""
    41135038965b204de40ac7b90ef1fcae2acdbf08 1.2.0
    76b20c1e28280f35c9a0122776d0d8b2b7c53d46
    """.parseTaggedVersions(false)
    let projCtags {.inject.} = projCnimbles.filterIt(it.v.string != "")

    let projDnimbles {.inject.} = dedent"""
    a376d2152e86998cfb450e354e83697ccc9fc91f 2.0.0
    7c64075acb954fffd2318cee66113ac2ddad39cf 1.0.0
    """.parseTaggedVersions(false)
    let projDtags {.inject.} = projDnimbles.filterIt(it.v.string != "")

template expectedVersionWithNoGitTags*() =
    # These will change if atlas-tests is regnerated!
    # To update run and use commits not adding a proj_x.nim file
    #    curl http://localhost:4242/buildGraphNoGitTags/ws_generated-logs.txt
    let projAnimbles {.inject.} = dedent"""
    2a475375e473d9dc3163da8c8e67b21da27bcfbe 1.1.0
    af49e004c3de040598c3c174f73cc168255d9272
    26b7db63c1432791812d32dd7b748e90c9bf1b5c 1.0.0
    """.parseTaggedVersions(false)
    let projAtags {.inject.} = projAnimbles.filterIt(it.v.string != "")

    let projBnimbles {.inject.} = dedent"""
    ef7bcc3ec9c5921506390795642281aa69bc0267 1.1.0
    fc92c20321d2c645821601bd0a97169cb8d8f3d4
    4839843c715b1cb48e4a8d8b1ff1a3f2253f63e2 1.0.0
    """.parseTaggedVersions(false)
    let projBtags {.inject.} = projBnimbles.filterIt(it.v.string != "")

    let projCnimbles {.inject.} = dedent"""
    d4722de3342de848cf80afad309b0e1bc918a020 1.2.0
    cfb20bf3770d4f527010637856f8d0f7b62f6f98 1.0.0
    """.parseTaggedVersions(false)
    let projCtags {.inject.} = projCnimbles.filterIt(it.v.string != "")

    let projDnimbles {.inject.} = dedent"""
    cd972f754f7ed0cbc89038375157cfc69e8504dd 2.0.0
    cf22977a771494b0a6923142121121ed451c9bca 1.0.0
    """.parseTaggedVersions(false)
    let projDtags {.inject.} = projDnimbles.filterIt(it.v.string != "")


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
    setAtlasVerbosity(Error)
    context().nameOverrides = Patterns()
    context().urlOverrides = Patterns()
    context().proxy = parseUri "http://localhost:4242"
    context().flags.incl DumbProxy
    context().depsDir = Path "deps"
    setAtlasErrorsColor(fgMagenta)

    expectedVersionWithGitTags()

  test "collect nimbles":
      # setAtlasVerbosity(Trace)
      withDir "tests/ws_testtraverse":
        removeDir("deps")
        context().flags = {KeepWorkspace, ListVersions}
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
        context().flags = {KeepWorkspace, ListVersions}
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
        context().flags = {KeepWorkspace, ListVersions}
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

  test "expand and then enrich with specific versions from requirements":
    # setAtlasVerbosity(Trace)
    withDir "tests//ws_testtraverse_explicit":
      removeDir("deps")
      workspace() = paths.getCurrentDir()
      context().flags = {KeepWorkspace, ListVersions}
      context().defaultAlgo = SemVer

      let deps = setupGraph()
      var nc = createNimbleContext()
      nc.put("proj_a", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_a"))
      nc.put("proj_b", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_b"))
      nc.put("proj_c", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_c"))
      nc.put("proj_d", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_d"))

      # TODO: add a specific version to the requirements for a to include non-tagged 7ca5581cd
      # TODO: then check that the expanded graph has the correct version
      let graph = workspace().expand(nc, AllReleases, onClone=DoClone)

      checkpoint "\tgraph:\n" & $graph.toJson(ToJsonOptions(enumMode: joptEnumString))

      let sp = graph.pkgs.values().toSeq()
      doAssert sp.len() == 5
      let sp0: Package = sp[0] # proj ws_testtraversal
      let sp1: Package = sp[1] # proj A
      let sp1Commit = projAnimbles[1].c

      var err = false
      let query = parseVersionInterval("#" & sp1Commit.h[0..7], 0, err)

      let reqs = sp0.versions.pairs().toSeq()[0][1].requirements
      echo "reqs: ", reqs.repr

      var foundMatch = false
      for depVer, relVer in sp1.validVersions():
        let matches = query.matches(depVer)
        echo "MATCHES: ", matches, " ", depVer.version()
        if matches:
          foundMatch = true
          

      check foundMatch
      echo "explicit versions: "
      for pkgUrl, commits in nc.explicitVersions.pairs:
        echo "\tversions: ", pkgUrl, " commits: ", commits.toSeq().mapIt($it).join("; ")

      

suite "test expand with no git tags":

  setup:
    setAtlasVerbosity(Warning)
    context().nameOverrides = Patterns()
    context().urlOverrides = Patterns()
    context().proxy = parseUri "http://localhost:4242"
    context().flags.incl DumbProxy
    context().depsDir = Path "deps"
    setAtlasErrorsColor(fgMagenta)

    expectedVersionWithNoGitTags()

  test "collect nimbles":
      # setAtlasVerbosity(Trace)
      withDir "tests/ws_testtraverse":
        removeDir("deps")
        workspace() = paths.getCurrentDir()
        context().flags = {KeepWorkspace, ListVersions}
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
        context().flags = {KeepWorkspace, ListVersions}
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
    setAtlasVerbosity(Error)
    context().nameOverrides = Patterns()
    context().urlOverrides = Patterns()
    context().proxy = parseUri "http://localhost:4242"
    context().flags.incl DumbProxy
    context().depsDir = Path "deps"
    setAtlasErrorsColor(fgMagenta)

    expectedVersionWithNoGitTags()

  test "expand no git tags and nimble commits max":
      # setAtlasVerbosity(Trace)
      withDir "tests/ws_testtraverse":
        removeDir("deps")
        context().nimbleCommitsMax = true
        workspace() = paths.getCurrentDir()
        context().flags = {KeepWorkspace, ListVersions}
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
