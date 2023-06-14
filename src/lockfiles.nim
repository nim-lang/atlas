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

  LockFile* = object # serialized as JSON so an object for extensibility
    items*: OrderedTable[string, LockFileEntry]

proc readLockFile(filename: string): LockFile =
  let jsonAsStr = readFile(filename)
  let jsonTree = parseJson(jsonAsStr)
  result = to(jsonTree, LockFile)

proc write(lock: LockFile; lockFilePath: string) =
  writeFile lockFilePath, toJson(lock).pretty

proc genLockEntry(c: var AtlasContext; lf: var LockFile; dir: string) =
  let url = getRemoteUrl()
  let commit = getCurrentCommit()
  when defined(windows):
    let dir = dir.replace('\\', '/')
  let name = dir.splitPath.tail
  lf.items[name] = LockFileEntry(dir: dir, url: $url, commit: commit)

proc genLockEntriesForDir(c: var AtlasContext; lf: var LockFile; dir: string) =
  for k, f in walkDir(dir):
    if k == pcDir and dirExists(f / ".git"):
      withDir c, f:
        genLockEntry c, lf, f

proc pinWorkspace*(c: var AtlasContext; lockFilePath: string) =
  var lf = LockFile(items: initOrderedTable[string, LockFileEntry]())
  genLockEntriesForDir(c, lf, c.workspace)
  if c.workspace != c.depsDir and c.depsDir.len > 0:
    genLockEntriesForDir c, lf, c.depsDir
  write lf, lockFilePath

proc pinProject*(c: var AtlasContext; lockFilePath: string) =
  var lf = LockFile(items: initOrderedTable[string, LockFileEntry]())

  let start = c.currentDir.splitPath.tail
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
    for i in countdown(g.nodes.len-1, 0):
      if g.nodes[i].active:
        let w = g.nodes[i]
        let destDir = toDestDir(w.name)
        let dir = selectDir(c.workspace / destDir, c.depsDir / destDir)
        tryWithDir dir:
          genLockEntry c, lf, dir
    write lf, lockFilePath


proc replay*(c: var AtlasContext; lockFilePath: string) =
  let lockFile = readLockFile(lockFilePath)
  let base = splitPath(lockFilePath).head
  withDir c, base:
    for _, v in pairs(lockFile.items):
      if not dirExists(v.dir):
        let err = osutils.cloneUrl(getUrl v.url, v.dir, false)
        if err.len > 0:
          error c, toName(lockFilePath), "could not clone: " & v.url
          continue
      withDir c, v.dir:
        let url = $getRemoteUrl()
        if v.url != url:
          error c, toName(v.dir), "remote URL has been compromised: got: " &
              url & " but wanted: " & v.url
        checkoutGitCommit(c, toName(v.dir), v.commit)
