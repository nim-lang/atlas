import std/[os, osproc, paths, strutils, terminal, times, unittest]

import basic/[compiledpatterns, context, deptypes, nimblecontext, packageinfos, pkgurls, reporters, versions]
import dependencies
import depgraphs

proc sh(cmd: string) =
  if execShellCmd(cmd) != 0:
    quit "FAILURE RUNNING: " & cmd

proc initGitRepo(dir: Path) =
  sh("git -C " & quoteShell($dir) & " init -b master")
  sh("git -C " & quoteShell($dir) & " config user.name test-user")
  sh("git -C " & quoteShell($dir) & " config user.email test@example.com")
  sh("git -C " & quoteShell($dir) & " config commit.gpgsign false")

proc commitAll(dir: Path; msg: string) =
  sh("git -C " & quoteShell($dir) & " add .")
  sh("git -C " & quoteShell($dir) & " commit -m " & quoteShell(msg))

proc writePackage(dir: Path; name, version: string; requires: openArray[string] = []) =
  createDir($dir)
  var lines = @["version = \"" & version & "\""]
  for dep in requires:
    lines.add("requires \"" & dep & "\"")
  writeFile($(dir / Path(name & ".nimble")), lines.join("\n") & "\n")
  writeFile($(dir / Path(name & ".nim")), "discard\n")

proc registryInfo(name: string; repo: Path; subdir: string): PackageInfo =
  PackageInfo(
    kind: pkPackage,
    name: name,
    url: "file://" & $repo,
    downloadMethod: "git",
    description: name & " from monorepo",
    license: "MIT",
    tags: @["test"],
    subdir: subdir
  )

suite "monorepo registry packages":
  setup:
    setAtlasVerbosity(Warning)
    setAtlasErrorsColor(fgMagenta)
    context().nameOverrides = Patterns()
    context().urlOverrides = Patterns()
    context().depsDir = Path"deps"
    context().defaultAlgo = SemVer
    context().flags = {KeepWorkspace, ListVersionsOff}

  test "two registry packages from one repo keep subdir identity through SAT":
    let oldCtx = context()
    let ws = Path(getTempDir()) / Path("atlas_monorepo_" & $int(epochTime()))
    defer:
      setContext(oldCtx)
      if dirExists($ws):
        removeDir($ws)

    let mono = ws / Path"mono"
    let app = ws / Path"app"
    createDir($mono)
    initGitRepo(mono)
    writePackage(mono / Path"libs/proven", "proven", "1.0.0")
    writePackage(mono / Path"libs/proven_auth", "proven_auth", "2.0.0", ["proven >= 1.0.0"])
    commitAll(mono, "add monorepo packages")

    createDir($app)
    initGitRepo(app)
    writePackage(app, "app", "0.1.0", ["proven >= 1.0.0", "proven_auth >= 2.0.0"])
    commitAll(app, "add root package")

    project(app)
    var nc = createUnfilledNimbleContext()
    discard nc.putPackageInfo(registryInfo("proven", mono, "libs/proven"))
    discard nc.putPackageInfo(registryInfo("proven_auth", mono, "libs/proven_auth"))

    let provenUrl = nc.createUrl("proven")
    let authUrl = nc.createUrl("proven_auth")
    check provenUrl != authUrl
    check provenUrl.cloneUri() == authUrl.cloneUri()
    check provenUrl.projectName() == "proven"
    check authUrl.projectName() == "proven_auth"
    check authUrl.subdir() == Path"libs/proven_auth"

    var graph = app.expandGraph(nc, CurrentCommit, onClone=DoClone)
    graph = loadJson(nc, toJsonGraph(graph))
    check provenUrl in graph.pkgs
    check authUrl in graph.pkgs

    let form = graph.toFormular(SemVer)
    solve(graph, form)

    check graph.root.active
    check provenUrl in graph.pkgs
    check authUrl in graph.pkgs
    check graph.pkgs[provenUrl].active
    check graph.pkgs[authUrl].active
    check graph.pkgs[provenUrl].subdir == Path"libs/proven"
    check graph.pkgs[authUrl].subdir == Path"libs/proven_auth"
    check graph.pkgs[provenUrl].activeNimbleRelease().version == Version"1.0.0"
    check graph.pkgs[authUrl].activeNimbleRelease().version == Version"2.0.0"
    check graph.validateDependencyGraph()
