import std/[sets, strutils, tables, unittest, uri]

import basic/[context, deptypes, pkgurls, reporters, versions]
import depgraphs, resolver_eager


proc pkgUrl(name: string): PkgUrl =
  parseUri("https://example.com/" & name).toPkgUriRaw()

proc requirement(spec: string): VersionInterval =
  var hasError = false
  result = parseVersionInterval(spec, 0, hasError)
  doAssert not hasError

proc newPackage(name: string; isRoot = false): Package =
  Package(url: pkgUrl(name), state: Processed, isRoot: isRoot)

proc addRelease(pkg: Package; version: string;
                requirements: seq[(PkgUrl, VersionInterval)] = @[]):
                NimbleRelease {.discardable.} =
  let parsedVersion = toVersion(version)
  let packageVersion = VersionTag(
    v: parsedVersion,
    c: initCommitHash("", FromNone)
  ).toPkgVer()
  result = NimbleRelease(
    version: parsedVersion,
    status: Normal,
    requirements: requirements
  )
  pkg.versions[packageVersion] = result

proc addPackage(graph: var DepGraph; pkg: Package) =
  graph.pkgs[pkg.url] = pkg

proc selectedVersion(pkg: Package): Version =
  pkg.activeNimbleRelease().version


suite "breadth-first dependency resolver":
  setup:
    setContext(AtlasContext())
    resetAtlasReporter()

  test "a nearer incompatible requirement wins":
    let root = newPackage("root", isRoot = true)
    let a = newPackage("a")
    let b = newPackage("b")
    let c = newPackage("c")
    let d = newPackage("d")

    root.addRelease("#head", @[
      (a.url, requirement("*")),
      (b.url, requirement("*"))
    ])
    a.addRelease("1.0.0", @[(c.url, requirement("< 2.0.0"))])
    b.addRelease("1.0.0", @[(d.url, requirement("*"))])
    d.addRelease("1.0.0", @[(c.url, requirement(">= 2.0.0"))])
    c.addRelease("1.5.0")
    c.addRelease("2.0.0")

    var graph = DepGraph(root: root)
    for pkg in [root, a, b, c, d]:
      graph.addPackage(pkg)

    check graph.resolveBreadthFirst()
    check c.selectedVersion() == Version"1.5.0"

  test "declaration order breaks ties at the same depth":
    let root = newPackage("root", isRoot = true)
    let first = newPackage("first")
    let second = newPackage("second")
    let shared = newPackage("shared")

    root.addRelease("#head", @[
      (first.url, requirement("*")),
      (second.url, requirement("*"))
    ])
    first.addRelease("1.0.0", @[(shared.url, requirement("< 2.0.0"))])
    second.addRelease("1.0.0", @[(shared.url, requirement(">= 2.0.0"))])
    shared.addRelease("1.8.0")
    shared.addRelease("2.1.0")

    var graph = DepGraph(root: root)
    for pkg in [root, first, second, shared]:
      graph.addPackage(pkg)

    check graph.resolveBreadthFirst()
    check shared.selectedVersion() == Version"1.8.0"

  test "the highest version matching the winning requirement is selected":
    let root = newPackage("root", isRoot = true)
    let dep = newPackage("dep")
    root.addRelease("#head", @[
      (dep.url, requirement(">= 1.0.0 & < 2.0.0"))
    ])
    dep.addRelease("1.0.0")
    dep.addRelease("1.9.0")
    dep.addRelease("2.0.0")

    var graph = DepGraph(root: root)
    for pkg in [root, dep]:
      graph.addPackage(pkg)

    check graph.resolveBreadthFirst()
    check dep.selectedVersion() == Version"1.9.0"

  test "cycles terminate without selecting a package twice":
    let root = newPackage("root", isRoot = true)
    let a = newPackage("a")
    let b = newPackage("b")
    root.addRelease("#head", @[(a.url, requirement("*"))])
    a.addRelease("1.0.0", @[(b.url, requirement("*"))])
    b.addRelease("1.0.0", @[(root.url, requirement("*"))])

    var graph = DepGraph(root: root)
    for pkg in [root, a, b]:
      graph.addPackage(pkg)

    check graph.resolveBreadthFirst()
    check a.active
    check b.active
    check a.selectedVersion() == Version"1.0.0"

  test "features requested on a dependency enqueue their requirements":
    let root = newPackage("root", isRoot = true)
    let toolkit = newPackage("toolkit")
    let leaf = newPackage("leaf")
    let rootRelease = root.addRelease(
      "#head", @[(toolkit.url, requirement("*"))])
    rootRelease.reqsByFeatures[toolkit.url] = ["extras"].toHashSet()
    let toolkitRelease = toolkit.addRelease("1.0.0")
    toolkitRelease.features["extras"] = @[(leaf.url, requirement("*"))]
    leaf.addRelease("1.0.0")

    var graph = DepGraph(root: root)
    for pkg in [root, toolkit, leaf]:
      graph.addPackage(pkg)

    check graph.resolveBreadthFirst()
    check toolkit.activeFeatures == @["extras"]
    check leaf.active

  test "undeclared dependency features remain active":
    let root = newPackage("root", isRoot = true)
    let toolkit = newPackage("toolkit")
    let rootRelease = root.addRelease(
      "#head", @[(toolkit.url, requirement("*"))])
    rootRelease.reqsByFeatures[toolkit.url] = ["future"].toHashSet()
    let toolkitRelease = toolkit.addRelease("1.0.0")
    toolkitRelease.name = "declared_toolkit"

    var graph = DepGraph(root: root)
    for pkg in [root, toolkit]:
      graph.addPackage(pkg)

    check graph.resolveBreadthFirst()
    check toolkit.activeFeatures == @["future"]

  test "root dev and patch features activate automatically":
    let root = newPackage("root", isRoot = true)
    let shared = newPackage("shared")
    let rootRelease = root.addRelease("#head")
    rootRelease.name = "declared_root"
    rootRelease.features["dev"] = @[(shared.url, requirement("*"))]
    rootRelease.features["patch"] = @[(shared.url, requirement("*"))]
    shared.addRelease("1.0.0")

    var graph = DepGraph(root: root)
    for pkg in [root, shared]:
      graph.addPackage(pkg)

    check graph.resolveBreadthFirst()
    check root.activeFeatures.toHashSet() == ["dev", "patch"].toHashSet()
    check shared.active

  test "only reached lazy feature dependencies are requested for loading":
    let root = newPackage("root", isRoot = true)
    let toolkit = newPackage("toolkit")
    let enabledDep = newPackage("enabled_dep")
    let disabledDep = newPackage("disabled_dep")
    let rootRelease = root.addRelease(
      "#head", @[(toolkit.url, requirement("*"))])
    rootRelease.reqsByFeatures[toolkit.url] = ["enabled"].toHashSet()
    let toolkitRelease = toolkit.addRelease("1.0.0")
    toolkitRelease.features["enabled"] = @[(enabledDep.url, requirement("*"))]
    toolkitRelease.features["disabled"] = @[(disabledDep.url, requirement("*"))]
    enabledDep.addRelease("1.0.0")
    disabledDep.addRelease("1.0.0")
    enabledDep.state = LazyDeferred
    disabledDep.state = LazyDeferred

    var graph = DepGraph(root: root)
    for pkg in [root, toolkit, enabledDep, disabledDep]:
      graph.addPackage(pkg)

    var rerun = false
    check not graph.solveBreadthFirst(rerun)
    check rerun
    check enabledDep.state == DoLoad
    check enabledDep.versions.len == 0
    check disabledDep.state == LazyDeferred
    check disabledDep.versions.len == 1

    enabledDep.addRelease("1.0.0")
    enabledDep.state = Processed
    rerun = false
    check graph.solveBreadthFirst(rerun)
    check not rerun
    check enabledDep.active
    check disabledDep.state == LazyDeferred

  test "an unsatisfied winning requirement fails resolution":
    let root = newPackage("root", isRoot = true)
    let dep = newPackage("dep")
    root.addRelease("#head", @[(dep.url, requirement(">= 2.0.0"))])
    dep.addRelease("1.0.0")

    var graph = DepGraph(root: root)
    for pkg in [root, dep]:
      graph.addPackage(pkg)

    check not graph.resolveBreadthFirst()
    check not dep.active
    check atlasErrors() == 1

  test "BFS is an available resolver mode":
    check parseEnum[ResolutionAlgorithm]("Bfs") == Bfs
