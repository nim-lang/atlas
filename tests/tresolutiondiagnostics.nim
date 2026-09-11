import std/[sets, strutils, tables, unittest]
import basic/[context, deptypes, nimblecontext, pkgurls, reporters, versions]
import depgraphs

proc query(text: string): VersionInterval =
  var err = false
  result = parseVersionInterval(text, 0, err)
  doAssert not err

proc pkg(name: string; root = false): Package =
  var nc = createUnfilledNimbleContext()
  Package(url: nc.createUrl("https://example.com/" & name), isRoot: root, state: Processed)

proc release(p: Package; version, commit: string;
             requirements: openArray[(Package, string)] = []): NimbleRelease =
  result = NimbleRelease(version: Version(version), status: Normal)
  for (dep, requirement) in requirements:
    result.requirements.add (dep.url, query(requirement))
  p.versions[VersionTag(v: Version(version),
    c: initCommitHash(commit, FromNone)).toPkgVer()] = result

proc graph(root: Package; dependencies: varargs[Package]): DepGraph =
  result = DepGraph(root: root)
  result.pkgs[root.url] = root
  for dep in dependencies:
    result.pkgs[dep.url] = dep

suite "dependency conflict diagnostics":
  setup:
    let oldContext = context()
    setContext(AtlasContext())
    let root = pkg("app", root = true)
    let siwin = pkg("siwin")
    let ui = pkg("ui")
    discard siwin.release("1.0.0", "abcdef123456")
    discard siwin.release("2.0.0", "fedcba654321")
  teardown:
    setContext(oldContext)

  test "an existing root pin is valid":
    discard root.release("0.1.0", "root", [(siwin, "#abcdef")])
    let g = graph(root, siwin)
    check g.findDependencyConflict().len == 0

  test "a missing root pin identifies its source and loaded versions":
    discard root.release("0.1.0", "root", [(siwin, "#badbad")])
    let g = graph(root, siwin)
    let explanation = g.findDependencyConflict().join("\n")
    check "(root) requires siwin #badbad" in explanation
    check "loaded releases:" in explanation
    check "abcdef" in explanation

  test "two incompatible root constraints identify both requirements":
    discard root.release("0.1.0", "root", [(siwin, "#abcdef"), (siwin, ">= 2.0.0")])
    let g = graph(root, siwin)
    let explanation = g.findDependencyConflict().join("\n")
    check "no compatible release of siwin" in explanation
    check "requires siwin #abcdef" in explanation
    check "requires siwin >= 2.0.0" in explanation

  test "all required consumer releases conflict with the root pin":
    discard root.release("0.1.0", "root", [(siwin, "#abcdef"), (ui, ">= 1.0.0")])
    discard ui.release("1.0.0", "ui1", [(siwin, "#fedcba")])
    discard ui.release("2.0.0", "ui2", [(siwin, ">= 2.0.0")])
    let g = graph(root, siwin, ui)
    let explanation = g.findDependencyConflict().join("\n")
    check "no compatible release of ui" in explanation
    check "(root) requires siwin #abcdef" in explanation
    check "ui 1.0.0@- requires siwin #fedcba" in explanation
    check "ui 2.0.0@- requires siwin >= 2.0.0" in explanation
    check ui.versions.len == 2 # Diagnostics must not alter the solver's choices.

  test "a historical incompatible pin does not poison a valid alternative":
    discard root.release("0.1.0", "root", [(siwin, "#abcdef"), (ui, "*")])
    discard ui.release("1.0.0", "ui1", [(siwin, "#fedcba")])
    discard ui.release("2.0.0", "ui2", [(siwin, "#abcdef")])
    var g = graph(root, siwin, ui)
    check g.findDependencyConflict().len == 0
    g.solve(g.toFormular(SemVer))
    check root.active
    check ui.activeVersion.version == Version"2.0.0"

  test "unreachable broken packages are not conflicts":
    discard root.release("0.1.0", "root", [(siwin, "#abcdef")])
    discard ui.release("1.0.0", "ui1", [(siwin, "#badbad")])
    let g = graph(root, siwin, ui)
    check g.findDependencyConflict().len == 0

  test "lazy dependencies remain unknown until loaded":
    discard root.release("0.1.0", "root", [(ui, "#badbad")])
    ui.state = LazyDeferred
    let g = graph(root, ui)
    check g.findDependencyConflict().len == 0

  test "only enabled features contribute mandatory requirements":
    let rel = root.release("0.1.0", "root", [(siwin, "#abcdef")])
    rel.features["other"] = @[(siwin.url, query("#fedcba"))]
    let g = graph(root, siwin)
    check g.findDependencyConflict().len == 0
    context().features.incl "other"
    let explanation = g.findDependencyConflict().join("\n")
    check "feature other requires siwin #fedcba" in explanation
    check "(root) requires siwin #abcdef" in explanation

  test "mandatory cycles terminate without false conflicts":
    discard root.release("0.1.0", "root", [(ui, "*")])
    discard ui.release("1.0.0", "ui1", [(root, "*")])
    let g = graph(root, ui)
    check g.findDependencyConflict().len == 0

  test "root alternatives do not all become mandatory":
    discard root.release("0.1.0", "root1", [(siwin, "#abcdef")])
    discard root.release("0.2.0", "root2", [(siwin, "#fedcba")])
    let g = graph(root, siwin)
    check g.findDependencyConflict().len == 0

  test "a proven conflict returns before consulting the supplied SAT formula":
    discard root.release("0.1.0", "root", [(siwin, "#badbad")])
    var g = graph(root, siwin)
    let errorsBefore = atlasErrors()
    var rerun = false
    # No SAT formula is supplied: the preflight must diagnose the conflict first.
    g.solve(Form(), rerun)
    check atlasErrors() == errorsBefore + 1
    check not root.active
    check not rerun

  test "interdependent alternatives still use SAT":
    let third = pkg("third")
    siwin.versions.clear()
    discard root.release("0.1.0", "root", [(siwin, "*"), (ui, "*"), (third, "*")])
    discard siwin.release("1.0.0", "a1", [(ui, "2.0.0")])
    discard siwin.release("2.0.0", "a2", [(ui, "1.0.0")])
    discard ui.release("1.0.0", "b1", [(third, "2.0.0")])
    discard ui.release("2.0.0", "b2", [(third, "1.0.0")])
    discard third.release("1.0.0", "c1", [(siwin, "2.0.0")])
    discard third.release("2.0.0", "c2", [(siwin, "1.0.0")])
    var g = graph(root, siwin, ui, third)
    check g.findDependencyConflict().len == 0
    let errorsBefore = atlasErrors()
    g.solve(g.toFormular(SemVer))
    check not root.active
    check atlasErrors() > errorsBefore

  test "preflight rejection agrees with SAT across constraint combinations":
    for pattern in 0..<64:
      let app = pkg("app", root = true)
      let first = pkg("first")
      let second = pkg("second")
      let firstQuery = if (pattern and 1) == 0: "*" else: "1.0.0"
      let secondQuery = if (pattern and 2) == 0: "*" else: "2.0.0"
      discard app.release("0.1.0", "root", [(first, firstQuery), (second, secondQuery)])
      for i in 0..1:
        let version = $(i + 1) & ".0.0"
        let firstDep = if (pattern and (4 shl i)) == 0: "1.0.0" else: "2.0.0"
        let secondDep = if (pattern and (16 shl i)) == 0: "1.0.0" else: "2.0.0"
        discard first.release(version, "first", [(second, firstDep)])
        discard second.release(version, "second", [(first, secondDep)])
      var g = graph(app, first, second)
      if g.findDependencyConflict().len > 0:
        let form = g.toFormular(SemVer)
        var solution = createSolution(form.formula)
        check not satisfiable(form.formula, solution)
