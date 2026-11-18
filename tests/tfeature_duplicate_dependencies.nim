import std / [paths, sets, unittest, uri]

import basic/[context, deptypes, nimblecontext, nimbleparser, pkgurls, versions]
import confighandler, depgraphs

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

  test "root dev and patch features are enabled automatically":
    setContext(AtlasContext())

    var nc = createNimbleContext()
    nc.put("shared_dependency", toPkgUriRaw(parseUri("file:///shared_dependency")))
    let sharedDependency = nc.createUrl("shared_dependency")
    let rootUrl = nc.createUrlFromPath(Path"tests/test_data")

    let rootRelease = nc.parseNimbleFile(
      Path"tests/test_data/automatic_features.nimble")
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
    doAssert dependency.active, "automatic feature dependencies must be selected"
    doAssert root.activeFeatures.toHashSet == ["dev", "patch"].toHashSet

  for scenario in [
      (name: "bare CLI feature", requested: "dev", withinFeature: false, explicit: false),
      (name: "requirement inside dev", requested: "", withinFeature: true, explicit: false),
      (name: "scoped CLI feature", requested: "features.dependency.dev",
        withinFeature: true, explicit: false),
      (name: "explicit dependency feature", requested: "", withinFeature: false, explicit: true)]:
    test "same-name dev features with " & scenario.name:
      setContext(AtlasContext())
      if scenario.requested.len > 0:
        context().features.incl scenario.requested

      var nc = createUnfilledNimbleContext()
      let rootUrl = toPkgUriRaw(parseUri("https://example.com/root"))
      let depUrl = toPkgUriRaw(parseUri("https://example.com/dependency"))
      let dep = nc.initPackage(depUrl, Processed)
      let depRelease = NimbleRelease(name: "dependency", version: Version"1.0.0", status: Normal)
      depRelease.features["dev"] = @[]
      dep.versions[toVersionTag("1.0.0@-").toPkgVer] = depRelease

      var invalid = false
      let query = (depUrl, parseVersionInterval(">= 1.0.0", 0, invalid))
      require not invalid
      let rootRelease = NimbleRelease(version: Version"#head", status: Normal)
      rootRelease.features["dev"] = @[]
      if scenario.withinFeature:
        rootRelease.features["dev"].add query
      else:
        rootRelease.requirements.add query
      if scenario.explicit:
        rootRelease.reqsByFeatures[depUrl] = ["dev"].toHashSet

      let root = nc.initPackage(rootUrl, Processed)
      root.isRoot = true
      root.versions[toVersionTag("*@head").toPkgVer] = rootRelease
      var graph = DepGraph(root: root)
      graph.pkgs[rootUrl] = root
      graph.pkgs[depUrl] = dep

      graph.solve(graph.toFormular(SemVer))

      check root.activeFeatures == @["dev"]
      check dep.active
      check ("dev" in dep.activeFeatures) ==
        (scenario.explicit or scenario.requested == "features.dependency.dev")

  test "required dependency features need not be declared":
    setContext(AtlasContext())
    context().flags.incl NoExec

    var nc = createNimbleContext()
    nc.put("shared_dependency", toPkgUriRaw(parseUri("file:///shared_dependency")))
    let sharedDependency = nc.createUrl("shared_dependency")
    let rootUrl = nc.createUrlFromPath(Path"tests/test_data")

    let rootRelease = nc.parseNimbleFile(
      Path"tests/test_data/undeclared_dependency_feature.nimble")
    rootRelease.version = Version"#head"

    let root = nc.initPackage(rootUrl, Processed)
    root.isRoot = true
    root.versions[toVersionTag("*@head").toPkgVer] = rootRelease

    let dependency = nc.initPackage(sharedDependency, Processed)
    dependency.versions[toVersionTag("1.0.0@-").toPkgVer] = NimbleRelease(
      name: "declared_dependency",
      version: Version"1.0.0",
      status: Normal)

    var graph = DepGraph(root: root)
    graph.pkgs[rootUrl] = root
    graph.pkgs[sharedDependency] = dependency

    graph.solve(graph.toFormular(SemVer))

    doAssert root.active
    doAssert dependency.active
    doAssert dependency.activeFeatures == @["future"]
    let (_, features) = graph.activateGraph()
    doAssert "features.declared_dependency.future" in features

  test "feature defines use the package name instead of the URL slug":
    setContext(AtlasContext())
    context().flags.incl NoExec

    var nc = createUnfilledNimbleContext()
    let markdownUrl = toPkgUriRaw(parseUri("https://example.com/nim-markdown"))
    discard nc.put("markdown", markdownUrl)
    let markdownRelease = nc.parseNimbleFile(Path"tests/test_data/markdown.nimble")
    let markdownVersion = toVersionTag("1.0.0@-").toPkgVer

    let markdown = nc.initPackage(markdownUrl, Processed)
    markdown.versions[markdownVersion] = markdownRelease
    markdown.activeVersion = markdownVersion
    markdown.activeFeatures = @["regex"]
    markdown.active = true
    markdown.ondisk = Path"tests/test_data"

    var graph = DepGraph()
    graph.pkgs[markdownUrl] = markdown

    let (_, features) = graph.activateGraph()
    let cache = graph.toActivationCache()
    doAssert cache.packages[0].name == "markdown"
    doAssert "features.markdown.regex" in features
    doAssert "features.nim-markdown.regex" notin features
