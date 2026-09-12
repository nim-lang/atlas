import std/[os, osproc, sets, strutils, terminal, unittest]

import basic/[compiledpatterns, context, deptypes, nimblecontext, reporters,
              versions]
import dependencies
import depgraphs
import integration_test_utils

const Workspace = "tests/ws_history_feasibility"
var oldSiwinCommit = ""
var newSiwinCommit = ""
var cycleEscapeCommit = ""

proc initGitRepo() =
  exec("git init -b master")
  exec("git config user.name test-user")
  exec("git config user.email test@example.com")

proc writePackage(name, version: string;
                  requires: openArray[string] = []) =
  var lines = @["version = \"" & version & "\""]
  for dependency in requires:
    lines.add("requires \"" & dependency & "\"")
  writeFile(name & ".nimble", lines.join("\n") & "\n")
  writeFile(name & ".nim", "discard\n")

proc commitRelease(name, version: string;
                   requires: openArray[string] = []) =
  writePackage(name, version, requires)
  exec("git add .")
  exec("git commit -m release-" & version)
  exec("git tag v" & version)

proc gitHead(): string =
  execProcess("git rev-parse HEAD").strip()

proc createFixture() =
  removeDir(Workspace)
  createDir(Workspace / "buildGraph")

  withDir Workspace / "buildGraph":
    createDir("unicodedb")
    withDir "unicodedb":
      initGitRepo()
      commitRelease("unicodedb", "0.3.0")
      commitRelease("unicodedb", "0.14.1")

    createDir("poison")
    withDir "poison":
      initGitRepo()
      commitRelease("poison", "1.0.0")
      commitRelease("poison", "2.0.0")

    createDir("segmentation")
    withDir "segmentation":
      initGitRepo()
      commitRelease("segmentation", "0.1.0", ["poison <= 1.0.0"])

    createDir("graphemes")
    withDir "graphemes":
      initGitRepo()
      commitRelease("graphemes", "0.12.0")

    createDir("unicodeplus")
    withDir "unicodeplus":
      initGitRepo()
      commitRelease("unicodeplus", "0.1.0", [
        "unicodedb >= 0.2.0 & <= 0.3.0"
      ])
      commitRelease("unicodeplus", "0.14.0", [
        "unicodedb >= 0.8.0",
        "segmentation >= 0.1.0",
        "graphemes >= 0.12.0"
      ])

    createDir("regex")
    withDir "regex":
      initGitRepo()
      commitRelease("regex", "0.1.0", [
        "unicodedb >= 0.2.0 & <= 0.3.0",
        "unicodeplus >= 0.1.0 & <= 0.2.0"
      ])
      commitRelease("regex", "0.26.3", ["unicodedb >= 0.13.2"])

    createDir("first")
    withDir "first":
      initGitRepo()
      commitRelease("first", "1.0.0", ["second == 2.0.0"])
      commitRelease("first", "2.0.0", ["second == 1.0.0"])

    createDir("second")
    withDir "second":
      initGitRepo()
      commitRelease("second", "1.0.0", ["third == 2.0.0"])
      commitRelease("second", "2.0.0", ["third == 1.0.0"])

    createDir("third")
    withDir "third":
      initGitRepo()
      commitRelease("third", "1.0.0", ["first == 2.0.0"])
      commitRelease("third", "2.0.0", ["first == 1.0.0"])

    createDir("cyclea")
    withDir "cyclea":
      initGitRepo()
      commitRelease("cyclea", "1.0.0", ["cycleb == 2.0.0"])
      commitRelease("cyclea", "2.0.0", ["cycleb == 1.0.0"])
      exec("git switch -c escape")
      writePackage("cyclea", "1.5.0", ["cycleb == 1.0.0"])
      exec("git add .")
      exec("git commit -m untagged-escape")
      cycleEscapeCommit = gitHead()
      exec("git switch master")

    createDir("cycleb")
    withDir "cycleb":
      initGitRepo()
      commitRelease("cycleb", "1.0.0", ["cyclec == 2.0.0"])
      commitRelease("cycleb", "2.0.0", ["cyclec == 1.0.0"])

    createDir("cyclec")
    withDir "cyclec":
      initGitRepo()
      commitRelease("cyclec", "1.0.0", ["cyclea == 2.0.0"])
      commitRelease("cyclec", "2.0.0", ["cyclea >= 1.0.0 & < 2.0.0"])

    createDir("revealer")
    withDir "revealer":
      initGitRepo()
      commitRelease("revealer", "1.0.0", [
        "cyclea#" & cycleEscapeCommit[0..7]
      ])

    createDir("gateway")
    withDir "gateway":
      initGitRepo()
      commitRelease("gateway", "1.0.0", ["revealer"])

    createDir("siwin")
    withDir "siwin":
      initGitRepo()
      commitRelease("siwin", "1.0.0")
      oldSiwinCommit = gitHead()
      commitRelease("siwin", "2.0.0")
      newSiwinCommit = gitHead()
      exec("git branch next " & newSiwinCommit)

    createDir("figdraw")
    withDir "figdraw":
      initGitRepo()
      writeFile("figdraw.nimble", [
        "version = \"0.37.4\"",
        "feature \"render\":",
        "  requires \"siwin#head\"",
        ""
      ].join("\n"))
      writeFile("figdraw.nim", "discard\n")
      exec("git add .")
      exec("git commit -m release-0.37.4")
      exec("git tag v0.37.4")

    createDir("harddraw")
    withDir "harddraw":
      initGitRepo()
      writeFile("harddraw.nimble", [
        "version = \"1.0.0\"",
        "feature \"render\":",
        "  requires \"siwin#" & newSiwinCommit[0..7] & "\"",
        ""
      ].join("\n"))
      writeFile("harddraw.nim", "discard\n")
      exec("git add .")
      exec("git commit -m release-1.0.0")
      exec("git tag v1.0.0")

    createDir("olddraw")
    withDir "olddraw":
      initGitRepo()
      writeFile("olddraw.nimble", [
        "version = \"1.0.0\"",
        "feature \"render\":",
        "  requires \"siwin#" & oldSiwinCommit[0..7] & "\"",
        ""
      ].join("\n"))
      writeFile("olddraw.nim", "discard\n")
      exec("git add .")
      exec("git commit -m release-1.0.0")
      exec("git tag v1.0.0")

    createDir("semverdraw")
    withDir "semverdraw":
      initGitRepo()
      commitRelease("semverdraw", "1.0.0", ["siwin >= 2.0.0"])

    createDir("branchdraw")
    withDir "branchdraw":
      initGitRepo()
      commitRelease("branchdraw", "1.0.0", ["siwin#next"])

  writeFile(Workspace / "ws_history_feasibility.nimble", [
    "version = \"0.1.0\"",
    "requires \"unicodedb >= 0.14.0\"",
    "requires \"poison >= 2.0.0\"",
    "feature \"kosmo\":",
    "  requires \"regex >= 0.26.3\"",
    ""
  ].join("\n"))

proc configureFixture(eager: bool; algo = SemVer) =
  setContext(AtlasContext())
  context().nameOverrides = Patterns()
  context().urlOverrides = Patterns()
  context().depsDir = Path "deps"
  context().defaultAlgo = algo
  context().flags = {KeepWorkspace, ListVersions}
  if eager:
    context().flags.incl NoLazyDeps
  context().features.incl "kosmo"
  discard context().nameOverrides.addPattern("$+", "file://./buildGraph/$#")
  setAtlasVerbosity(Error)
  setAtlasErrorsColor(fgMagenta)
  project(paths.getCurrentDir())

proc solveFixture(eager, cold: bool): DepGraph =
  withDir Workspace:
    if cold:
      removeDir("deps")

    configureFixture(eager)

    var nc = createNimbleContext()
    result = loadWorkspace(project(), nc, AllReleases, DoClone, doSolve = true)

    doAssert result.root.active, "the valid modern dependency selection must be satisfiable"
    for (name, expectedVersion) in [
      ("regex", "0.26.3"),
      ("unicodedb", "0.14.1"),
      ("poison", "2.0.0")
    ]:
      let url = nc.createUrl(name)
      doAssert url in result.pkgs, name & " must be represented in the graph"
      let pkg = result.pkgs[url]
      doAssert pkg.active, name & " must be selected"
      doAssert $pkg.activeNimbleRelease.version == expectedVersion,
        name & " selected unexpected version " & $pkg.activeNimbleRelease.version

    let unicodeplusUrl = nc.createUrl("unicodeplus")
    doAssert unicodeplusUrl in result.pkgs,
      "the old regex release should register unicodeplus metadata"
    doAssert not result.pkgs[unicodeplusUrl].active,
      "unicodeplus belongs only to the excluded old regex release"
    if not eager:
      doAssert result.pkgs[unicodeplusUrl].state == LazyDeferred,
        "unicodeplus should stay deferred when the selected regex does not require it"

    for name in ["segmentation", "graphemes"]:
      let url = nc.createUrl(name)
      if eager:
        doAssert url in result.pkgs,
          name & " metadata should be represented by eager historical traversal"
        doAssert not result.pkgs[url].active,
          name & " belongs only to an excluded historical dependency chain"
      else:
        doAssert url notin result.pkgs,
          name & " must not be reached through an unselected unicodeplus release"

proc checkUnsatDoesNotExpandExcludedHistory() =
  withDir Workspace:
    removeDir("deps")
    writeFile("ws_history_feasibility.nimble", [
      "version = \"0.1.0\"",
      "requires \"unicodedb >= 0.14.0\"",
      "requires \"poison >= 2.0.0\"",
      "requires \"regex >= 0.26.3\"",
      "requires \"first\"",
      "requires \"second\"",
      "requires \"third\"",
      ""
    ].join("\n"))
    configureFixture(eager = false)

    var nc = createNimbleContext()
    let errorsBefore = atlasErrors()
    let graph = loadWorkspace(project(), nc, AllReleases, DoClone, doSolve = true)
    doAssert atlasErrors() > errorsBefore,
      "the deliberately inconsistent alternative cycle should be UNSAT"
    doAssert not graph.root.active

    let unicodeplusUrl = nc.createUrl("unicodeplus")
    doAssert unicodeplusUrl in graph.pkgs
    doAssert graph.pkgs[unicodeplusUrl].state == LazyDeferred,
      "UNSAT retry must not load a dependency owned only by excluded regex releases"
    for name in ["segmentation", "graphemes"]:
      doAssert nc.createUrl(name) notin graph.pkgs,
        "UNSAT retry must not splice " & name & " from excluded unicodeplus releases"

proc checkUnsatPreservesSecondHopConstraint() =
  withDir Workspace:
    removeDir("deps")
    writeFile("ws_history_feasibility.nimble", [
      "version = \"0.1.0\"",
      "requires \"regex == 0.1.0\"",
      "requires \"unicodedb == 0.3.0\"",
      "requires \"poison >= 2.0.0\"",
      "requires \"first\"",
      "requires \"second\"",
      "requires \"third\"",
      ""
    ].join("\n"))
    configureFixture(eager = false)

    var nc = createNimbleContext()
    let errorsBefore = atlasErrors()
    let graph = loadWorkspace(project(), nc, AllReleases, DoClone, doSolve = true)
    doAssert atlasErrors() > errorsBefore
    doAssert not graph.root.active

    let unicodeplus = graph.pkgs[nc.createUrl("unicodeplus")]
    doAssert unicodeplus.state == Processed,
      "the eligible old regex release should load its deferred dependency"
    for name in ["segmentation", "graphemes"]:
      let url = nc.createUrl(name)
      doAssert url in graph.pkgs,
        name & " should be represented after unicodeplus metadata is loaded"
      doAssert graph.pkgs[url].state == LazyDeferred,
        name & " belongs only to unicodeplus releases excluded by <= 0.2.0"

proc checkAlternativeReleaseBacktracking() =
  withDir Workspace:
    removeDir("deps")
    writeFile("ws_history_feasibility.nimble", [
      "version = \"0.1.0\"",
      "requires \"regex\"",
      "requires \"unicodedb >= 0.14.0\"",
      "requires \"poison >= 2.0.0\"",
      ""
    ].join("\n"))
    configureFixture(eager = true, algo = MinVer)

    var nc = createNimbleContext()
    let graph = loadWorkspace(project(), nc, AllReleases, DoClone, doSolve = true)
    doAssert graph.root.active,
      "minimum-version search must backtrack from the incompatible old regex"
    let regex = graph.pkgs[nc.createUrl("regex")]
    doAssert regex.active
    doAssert regex.activeNimbleRelease.version == Version"0.26.3"
    doAssert not graph.pkgs[nc.createUrl("unicodeplus")].active,
      "requirements from mutually exclusive regex releases must not be intersected"

proc checkDeferredMetadataCanRevealCandidate() =
  withDir Workspace:
    removeDir("deps")
    writeFile("ws_history_feasibility.nimble", [
      "version = \"0.1.0\"",
      "requires \"cyclea\"",
      "requires \"cycleb\"",
      "requires \"cyclec\"",
      "requires \"gateway\"",
      ""
    ].join("\n"))
    configureFixture(eager = false)

    var nc = createNimbleContext()
    let errorsBefore = atlasErrors()
    let graph = loadWorkspace(project(), nc, AllReleases, DoClone, doSolve = true)
    doAssert atlasErrors() == errorsBefore
    doAssert graph.root.active,
      "a mandatory deferred child may reveal a needed off-branch candidate"
    let cyclea = graph.pkgs[nc.createUrl("cyclea")]
    doAssert cyclea.active
    doAssert cyclea.activeVersion.commit.h == cycleEscapeCommit

proc checkRootPinOverridesTransitiveHead() =
  withDir Workspace:
    removeDir("deps")
    writeFile("ws_history_feasibility.nimble", [
      "version = \"0.1.0\"",
      "requires \"siwin#" & oldSiwinCommit[0..7] & "\"",
      "requires \"figdraw[render]\"",
      ""
    ].join("\n"))
    configureFixture(eager = true)

    var nc = createNimbleContext()
    let errorsBefore = atlasErrors()
    let graph = loadWorkspace(project(), nc, AllReleases, DoClone, doSolve = true)
    doAssert atlasErrors() == errorsBefore
    doAssert graph.root.active
    let siwin = graph.pkgs[nc.createUrl("siwin")]
    doAssert siwin.active
    doAssert siwin.activeVersion.commit.h == oldSiwinCommit,
      "the direct root commit pin must override a transitive #head request"

proc checkTransitiveCommitRemainsStrict() =
  withDir Workspace:
    removeDir("deps")
    writeFile("ws_history_feasibility.nimble", [
      "version = \"0.1.0\"",
      "requires \"siwin#" & oldSiwinCommit[0..7] & "\"",
      "requires \"harddraw[render]\"",
      ""
    ].join("\n"))
    configureFixture(eager = true)

    var nc = createNimbleContext()
    let errorsBefore = atlasErrors()
    let graph = loadWorkspace(project(), nc, AllReleases, DoClone, doSolve = true)
    doAssert atlasErrors() > errorsBefore
    doAssert not graph.root.active,
      "a different explicit transitive hash must still conflict with the root pin"

proc checkDisabledRootFeaturePinDoesNotOverrideHead() =
  withDir Workspace:
    removeDir("deps")
    writeFile("ws_history_feasibility.nimble", [
      "version = \"0.1.0\"",
      "requires \"figdraw[render]\"",
      "feature \"legacy\":",
      "  requires \"siwin#" & oldSiwinCommit[0..7] & "\"",
      ""
    ].join("\n"))
    configureFixture(eager = true)

    var nc = createNimbleContext()
    let errorsBefore = atlasErrors()
    let graph = loadWorkspace(project(), nc, AllReleases, DoClone, doSolve = true)
    doAssert atlasErrors() == errorsBefore
    doAssert graph.root.active
    let siwin = graph.pkgs[nc.createUrl("siwin")]
    doAssert siwin.active
    doAssert siwin.activeVersion.commit.h == newSiwinCommit,
      "a commit pin in a disabled root feature must not override #head"

proc checkEnabledRootFeaturePinOverridesHead() =
  withDir Workspace:
    removeDir("deps")
    writeFile("ws_history_feasibility.nimble", [
      "version = \"0.1.0\"",
      "requires \"figdraw[render]\"",
      "feature \"legacy\":",
      "  requires \"siwin#" & oldSiwinCommit[0..7] & "\"",
      ""
    ].join("\n"))
    configureFixture(eager = true)
    context().features.incl "legacy"

    var nc = createNimbleContext()
    let errorsBefore = atlasErrors()
    let graph = loadWorkspace(project(), nc, AllReleases, DoClone, doSolve = true)
    doAssert atlasErrors() == errorsBefore
    doAssert graph.root.active
    doAssert graph.pkgs[nc.createUrl("siwin")].activeVersion.commit.h == oldSiwinCommit

proc checkDirectRootHeadRemainsStrict() =
  withDir Workspace:
    removeDir("deps")
    writeFile("ws_history_feasibility.nimble", [
      "version = \"0.1.0\"",
      "requires \"siwin#head\"",
      "requires \"olddraw[render]\"",
      ""
    ].join("\n"))
    configureFixture(eager = true)

    var nc = createNimbleContext()
    let errorsBefore = atlasErrors()
    let graph = loadWorkspace(project(), nc, AllReleases, DoClone, doSolve = true)
    doAssert atlasErrors() > errorsBefore
    doAssert not graph.root.active,
      "a direct root #head must conflict with a different transitive commit"

proc checkTransitiveSemverRemainsBinding() =
  withDir Workspace:
    removeDir("deps")
    writeFile("ws_history_feasibility.nimble", [
      "version = \"0.1.0\"",
      "requires \"siwin#" & oldSiwinCommit[0..7] & "\"",
      "requires \"semverdraw\"",
      ""
    ].join("\n"))
    configureFixture(eager = true)

    var nc = createNimbleContext()
    let errorsBefore = atlasErrors()
    let graph = loadWorkspace(project(), nc, AllReleases, DoClone, doSolve = true)
    doAssert atlasErrors() > errorsBefore
    doAssert not graph.root.active,
      "a semver constraint must not be discarded by a direct root commit pin"

proc checkTransitiveBranchRemainsStrict() =
  withDir Workspace:
    removeDir("deps")
    writeFile("ws_history_feasibility.nimble", [
      "version = \"0.1.0\"",
      "requires \"siwin#" & oldSiwinCommit[0..7] & "\"",
      "requires \"branchdraw\"",
      ""
    ].join("\n"))
    configureFixture(eager = true)

    var nc = createNimbleContext()
    let errorsBefore = atlasErrors()
    let graph = loadWorkspace(project(), nc, AllReleases, DoClone, doSolve = true)
    doAssert atlasErrors() > errorsBefore
    doAssert not graph.root.active,
      "a named branch must not be discarded by a direct root commit pin"

suite "dependency history feasibility":
  test "excluded releases cannot activate a cross-version historical chain":
    createFixture()
    defer:
      removeDir(Workspace)

    discard solveFixture(eager = false, cold = true)
    discard solveFixture(eager = false, cold = false)
    discard solveFixture(eager = true, cold = true)
    discard solveFixture(eager = true, cold = false)

  test "independent UNSAT does not expand excluded historical dependencies":
    createFixture()
    defer:
      removeDir(Workspace)

    checkUnsatDoesNotExpandExcludedHistory()

  test "UNSAT traversal preserves constraints across a second hop":
    createFixture()
    defer:
      removeDir(Workspace)

    checkUnsatPreservesSecondHopConstraint()

  test "mutually exclusive parent releases remain alternatives":
    createFixture()
    defer:
      removeDir(Workspace)

    checkAlternativeReleaseBacktracking()

  test "mandatory deferred metadata may reveal a satisfiable candidate":
    createFixture()
    defer:
      removeDir(Workspace)

    checkDeferredMetadataCanRevealCandidate()

  test "root commit pin overrides transitive head feature dependency":
    createFixture()
    defer:
      removeDir(Workspace)

    checkRootPinOverridesTransitiveHead()

  test "different transitive commit remains a conflict":
    createFixture()
    defer:
      removeDir(Workspace)

    checkTransitiveCommitRemainsStrict()

  test "disabled root feature pin does not override transitive head":
    createFixture()
    defer:
      removeDir(Workspace)

    checkDisabledRootFeaturePinDoesNotOverrideHead()

  test "enabled root feature pin overrides transitive head":
    createFixture()
    defer:
      removeDir(Workspace)

    checkEnabledRootFeaturePinOverridesHead()

  test "direct root head remains strict":
    createFixture()
    defer:
      removeDir(Workspace)

    checkDirectRootHeadRemainsStrict()

  test "transitive semver requirement remains binding":
    createFixture()
    defer:
      removeDir(Workspace)

    checkTransitiveSemverRemainsBinding()

  test "transitive named branch remains strict":
    createFixture()
    defer:
      removeDir(Workspace)

    checkTransitiveBranchRemainsStrict()
