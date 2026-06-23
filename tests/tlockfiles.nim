## Unit tests for the lockfile machinery (`lockfiles.nim`).
##
## These exercise `listChanged` against real (local, offline) git repos so
## that two regressions stay fixed:
##   1. `convertNimbleLock` must map a nimble package to `deps/<package-name>`
##      (the lockfile key), not `deps/<url-repo-name>`.
##   2. `listChanged` must inspect each dep's git state via the dir path alone,
##      without an extra `withDir` wrapper that double-applies the path and
##      makes every repo read back as an empty url / "-" commit.

import std/[os, osproc, paths, json]
import unittest

import basic/[reporters, context, lockfiletypes, gitops, versions]
import lockfiles

proc git(dir, args: string) =
  let (outp, code) = execCmdEx("git -C " & quoteShell(dir) & " " & args)
  doAssert code == 0, "git " & args & " failed in " & dir & ":\n" & outp

proc freshDir(name: string): string =
  result = os.getCurrentDir() / "tests" / name
  if dirExists(result): removeDir(result)
  createDir(result)

proc setupDep(name, url: string): tuple[url, commit: string] =
  ## Creates `deps/<name>` as a one-commit git repo with `origin` set to `url`.
  ## Returns the canonical url and full commit hash as the lockfile-comparison
  ## helpers see them (read from cwd, i.e. the project root).
  let depDir = "deps" / name
  createDir(depDir)
  git(depDir, "init -q")
  git(depDir, "config user.email test@example.com")
  git(depDir, "config user.name test-user")
  git(depDir, "remote add origin " & quoteShell(url))
  writeFile(depDir / "f.txt", "hello")
  git(depDir, "add .")
  git(depDir, "commit -q -m initial")

  let gotUrl = getCanonicalUrl(Path depDir)
  let gotCommit = currentGitCommit(Path depDir)
  doAssert gotCommit.isFull, "expected a full commit hash, got: " & $gotCommit
  result = (gotUrl, gotCommit.h)

template withCwd(dir: string; body: untyped) =
  let saved = os.getCurrentDir()
  setCurrentDir(dir)
  try:
    body
  finally:
    setCurrentDir(saved)

suite "Lockfile listChanged":
  setup:
    # project()=="." while cwd is the fixture root, deps live under "deps".
    setContext AtlasContext(projectDir: Path".", depsDir: Path"deps")

  test "atlas.lock: matching deps produce no warnings":
    let root = freshDir("ws_lockfiles_clean")
    defer: removeDir(root)

    withCwd root:
      let exp = setupDep("foo", "https://example.com/foo")

      var lf = LockFile(items: initOrderedTable[string, LockFileEntry]())
      lf.items["foo"] = LockFileEntry(
        dir: Path("deps" / "foo"), url: exp.url, commit: exp.commit)
      # hostOS left empty so the nim/gcc/clang version comparison is skipped.
      write(lf, "atlas.lock")

      resetAtlasReporter()
      listChanged(Path"atlas.lock")
      check atlasReporter.warnings == 0

  test "atlas.lock: a drifted commit is detected":
    let root = freshDir("ws_lockfiles_drift")
    defer: removeDir(root)

    withCwd root:
      let exp = setupDep("foo", "https://example.com/foo")

      var lf = LockFile(items: initOrderedTable[string, LockFileEntry]())
      lf.items["foo"] = LockFileEntry(
        dir: Path("deps" / "foo"), url: exp.url, commit: exp.commit)
      write(lf, "atlas.lock")

      # move HEAD forward so the on-disk commit no longer matches the lock
      git("deps" / "foo", "commit -q --allow-empty -m second")

      resetAtlasReporter()
      listChanged(Path"atlas.lock")
      check atlasReporter.warnings >= 1

  test "nimble.lock: conversion locates deps by package name":
    let root = freshDir("ws_lockfiles_nimble")
    defer: removeDir(root)

    withCwd root:
      # nimble package name "unittest2" but the repo is "nim-unittest2";
      # the dep dir must be found as deps/unittest2 (the lockfile key).
      let url = "https://github.com/status-im/nim-unittest2"
      let exp = setupDep("unittest2", url)

      let nl = %*{
        "version": 2,
        "packages": {
          "unittest2": {
            "version": "0.2.4",
            "vcsRevision": exp.commit,
            "url": exp.url,
            "downloadMethod": "git",
            "dependencies": [],
            "checksums": {"sha1": "0000000000000000000000000000000000000000"}
          }
        },
        "tasks": {}
      }
      writeFile("nimble.lock", pretty(nl))

      resetAtlasReporter()
      listChanged(NimbleLockFileName)
      check atlasReporter.warnings == 0
