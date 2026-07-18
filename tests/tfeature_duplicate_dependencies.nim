import std / [paths, sets, unittest, uri]

import basic/[context, deptypes, nimblecontext, nimbleparser, pkgurls, versions]
import depgraphs

suite "duplicate feature dependencies":
  test "two enabled features can share one dependency":
    setContext(AtlasContext())
    context().features.incl "first"
    context().features.incl "second"

    var nc = createNimbleContext()
    nc.put("shared_dependency", toPkgUriRaw(parseUri("file:///shared_dependency")))
    let sharedDependency = nc.createUrl("shared_dependency")
    let rootUrl = nc.createUrlFromPath(Path"tests/test_data")

    let rootRelease = nc.parseNimbleFile(
      Path"tests/test_data/duplicate_feature_dependencies.nimble")
    rootRelease.version = Version"#head"

    let root = nc.initPackage(rootUrl, Processed)
    root.isRoot = true
    root.versions[toVersionTag("*@head").toPkgVer] = rootRelease

    let dependency = nc.initPackage(sharedDependency, Processed)
    dependency.versions[toVersionTag("1.0.0@head").toPkgVer] =
      NimbleRelease(version: Version"1.0.0", status: Normal)

    var graph = DepGraph(root: root)
    graph.pkgs[rootUrl] = root
    graph.pkgs[sharedDependency] = dependency

    graph.solve(graph.toFormular(SemVer))

    doAssert root.active
    doAssert dependency.active, "the shared feature dependency must be selected"
    doAssert root.activeFeatures.len == 2
