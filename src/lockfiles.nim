#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Lockfile implementation.

import std / [strutils, tables, os, json, jsonutils]
import context, gitops, osutils, traversal

type
  LockFileEntry* = object
    dir*: string
    url*: string
    commit*: string

  LockedNimbleFile* = object
    filename*, content*: string

  LockFile* = object # serialized as JSON
    items*: OrderedTable[string, LockFileEntry]
    nimcfg*: string
    nimbleFile*: LockedNimbleFile

proc readLockFile(filename: string): LockFile =
  let jsonAsStr = readFile(filename)
  let jsonTree = parseJson(jsonAsStr)
  result = to(jsonTree, LockFile)

proc write(lock: LockFile; lockFilePath: string) =
  writeFile lockFilePath, toJson(lock).pretty

proc genLockEntry(c: var AtlasContext; lf: var LockFile; dir: string) =
  let url = getRemoteUrl()
  let commit = getCurrentCommit()
  let name = dir.lastPathComponent
  lf.items[name] = LockFileEntry(dir: dir, url: $url, commit: commit)

proc genLockEntriesForDir(c: var AtlasContext; lf: var LockFile; dir: string) =
  for k, f in walkDir(dir):
    if k == pcDir and dirExists(f / ".git"):
      withDir c, f:
        genLockEntry c, lf, f.relativePath(dir, '/')

const
  NimCfg = "nim.cfg"

proc pinWorkspace*(c: var AtlasContext; lockFilePath: string) =
  var lf = LockFile(items: initOrderedTable[string, LockFileEntry]())
  genLockEntriesForDir(c, lf, c.workspace)
  if c.workspace != c.depsDir and c.depsDir.len > 0:
    genLockEntriesForDir c, lf, c.depsDir

  let nimcfgPath = c.workspace / NimCfg
  if fileExists(nimcfgPath):
    lf.nimcfg = readFile(nimcfgPath)

  let nimblePath = c.workspace / c.workspace.lastPathComponent & ".nimble"
  if fileExists nimblePath:
    lf.nimbleFile = LockedNimbleFile(
      filename: c.workspace.lastPathComponent & ".nimble",
      content: readFile(nimblePath))

  write lf, lockFilePath

proc pinProject*(c: var AtlasContext; lockFilePath: string) =
  var lf = LockFile(items: initOrderedTable[string, LockFileEntry]())

  let start = c.currentDir.lastPathComponent
  let url = getRemoteUrl()
  var g = createGraph(c, start, url)

  var i = 0
  while i < g.nodes.len:
    let w = g.nodes[i]
    let destDir = toDestDir(w.name)

    let dir = selectDir(c.workspace / destDir, c.depsDir / destDir)
    if not dirExists(dir):
      error c, w.name, "dependency does not exist"
    else:
      # assume this is the selected version, it might get overwritten later:
      selectNode c, g, w
      discard collectNewDeps(c, g, i, w)
    inc i

  if c.errors == 0:
    # topo-sort:
    for i in countdown(g.nodes.len-1, 1):
      if g.nodes[i].active:
        let w = g.nodes[i]
        let destDir = toDestDir(w.name)
        let dir = selectDir(c.workspace / destDir, c.depsDir / destDir)
        tryWithDir dir:
          genLockEntry c, lf, dir.relativePath(c.currentDir, '/')

    let nimcfgPath = c.currentDir / NimCfg
    if fileExists(nimcfgPath):
      lf.nimcfg = readFile(nimcfgPath)

    let nimblePath = c.currentDir / c.currentDir.lastPathComponent & ".nimble"
    if fileExists nimblePath:
      lf.nimbleFile = LockedNimbleFile(
        filename: c.currentDir.lastPathComponent & ".nimble",
        content: readFile(nimblePath))

    write lf, lockFilePath

proc replay*(c: var AtlasContext; lockFilePath: string) =
  let lockFile = readLockFile(lockFilePath)
  let base = splitPath(lockFilePath).head
  if lockFile.nimcfg.len > 0:
    writeFile(base / NimCfg, lockFile.nimcfg)
  if lockFile.nimbleFile.filename.len > 0:
    writeFile(base / lockFile.nimbleFile.filename, lockFile.nimbleFile.content)
  for _, v in pairs(lockFile.items):
    let dir = base / v.dir
    if not dirExists(dir):
      let err = osutils.cloneUrl(getUrl v.url, dir, false)
      if err.len > 0:
        error c, toName(lockFilePath), "could not clone: " & v.url
        continue
    withDir c, dir:
      let url = $getRemoteUrl()
      if v.url != url:
        error c, toName(v.dir), "remote URL has been compromised: got: " &
            url & " but wanted: " & v.url
      checkoutGitCommit(c, toName(dir), v.commit)
