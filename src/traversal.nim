#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Helpers for the graph traversal.

import std / [strutils, os, osproc]
import context, osutils, gitops, nameresolver

proc createGraph*(c: var AtlasContext; start: string, url: PackageUrl): DepGraph =
  result = DepGraph(nodes: @[DepNode(name: toName(start),
                                     url: url,
                                     algo: c.defaultAlgo)])
  #result.byName.mgetOrPut(toName(start), @[]).add 0
  result.byName[result.nodes[0].name] = 0

proc addUnique*[T](s: var seq[T]; elem: sink T) =
  if not s.contains(elem): s.add elem

when false:
  proc addUniqueDep*(c: var AtlasContext; g: var DepGraph; parent: int;
                    url: PackageUrl; query: VersionQuery) =
    let commit = versionKey(query)
    let key = url / commit
    if g.processed.hasKey($key):
      g.nodes[g.processed[$key]].parents.addUnique parent
    else:
      let name = url.toName
      let self = g.nodes.len
      g.byName.mgetOrPut(name, @[]).add self
      g.processed[$key] = self
      g.nodes.add Dependency(name: name, url: url, commit: commit,
                             self: self,
                             query: query,
                             parents: @[parent],
                             algo: c.defaultAlgo)

  proc rememberNimVersion(g: var DepGraph; q: VersionQuery) =
    let v = extractGeQuery(q)
    if v != Version"" and v > g.bestNimVersion: g.bestNimVersion = v

  proc collectDeps*(c: var AtlasContext; g: var DepGraph; parent: int;
                  dep: Dependency; nimbleFile: string): CfgPath =
    # If there is a .nimble file, return the dependency path & srcDir
    # else return "".
    assert nimbleFile != ""
    let nimbleInfo = extractRequiresInfo(c, nimbleFile)
    if dep.self >= 0 and dep.self < g.nodes.len:
      g.nodes[dep.self].hasInstallHooks = nimbleInfo.hasInstallHooks
    for r in nimbleInfo.requires:
      var i = 0
      while i < r.len and r[i] notin {'#', '<', '=', '>'} + Whitespace: inc i
      let pkgName = r.substr(0, i-1)
      var err = pkgName.len == 0
      let pkgUrl = c.resolveUrl(pkgName)
      let query = parseVersionInterval(r, i, err)
      if err:
        error c, toName(nimbleFile), "invalid 'requires' syntax: " & r
      else:
        if cmpIgnoreCase(pkgName, "nim") != 0:
          c.addUniqueDep g, parent, pkgUrl, query
        else:
          rememberNimVersion g, query
    result = CfgPath(toDestDir(dep.name) / nimbleInfo.srcDir)

  proc collectNewDeps*(c: var AtlasContext; g: var DepGraph; parent: int;
                      dep: Dependency): CfgPath =
    let nimbleFile = findNimbleFile(c, dep)
    if nimbleFile != "":
      result = collectDeps(c, g, parent, dep, nimbleFile)
    else:
      result = CfgPath toDestDir(dep.name)

proc extractRequiresInfo*(c: var AtlasContext; nimbleFile: string): NimbleFileInfo =
  result = extractRequiresInfo(nimbleFile)
  when ProduceTest:
    echo "nimble ", nimbleFile, " info ", result

proc parseNimbleFile(c: var AtlasContext; nimbleFile: string; commit: Commit): DepSubnode =
  result = DepSubnode(commit: commit)
  let nimbleInfo = extractRequiresInfo(c, nimbleFile)
  result.hasInstallHooks = nimbleInfo.hasInstallHooks
  for r in nimbleInfo.requires:
    var i = 0
    while i < r.len and r[i] notin {'#', '<', '=', '>'} + Whitespace: inc i
    let pkgName = r.substr(0, i-1)
    var err = pkgName.len == 0
    let query = parseVersionInterval(r, i, err)
    if err:
      result.errors.add "invalid 'requires' syntax: " & r
    else:
      if cmpIgnoreCase(pkgName, "nim") != 0:
        result.deps.add SingleDep(nameOrUrl: pkgName, query: query)
      else:
        result.nimVersion = query
  result.srcDir = nimbleInfo.srcDir

proc nimbleFileVersions(c: var AtlasContext; nimbleFile: string): seq[Commit] =
  result = @[]
  let (outp, exitCode) = silentExec("git log --format=%H", [nimbleFile])
  if exitCode == 0:
    for commit in splitLines(outp):
      let (tag, exitCode) = silentExec("git describe --tags ", [commit])
      if exitCode == 0:
        let v = parseVersion(tag, 0)
        if v != Version(""):
          if result.len > 0 and result[^1].v.string == v.string:
            # Ensure we use the earlier commit for when the tags look like
            # 1.3.0, 1.2.2-6-g0af2c85, 1.2.2
            # The Karax project uses tags like these, don't ask me why.
            result[^1].h = commit
          else:
            result.add Commit(h: commit, v: v)
  else:
    error c, projectFromCurrentDir(), outp

proc allDeps*(c: var AtlasContext; nimbleFile: string): seq[DepSubnode] =
  let cv = nimbleFileVersions(c, nimbleFile)
  result = @[]
  try:
    for commit in items cv:
      let (err, exitCode) = osproc.execCmdEx("git checkout " & commit.h & " -- " & quoteShell(nimbleFile))
      if exitCode == 0:
        result.add parseNimbleFile(c, nimbleFile, commit)
      else:
        error c, projectFromCurrentDir(), err
  finally:
    discard osproc.execCmdEx("git checkout HEAD " & quoteShell(nimbleFile))

when false:
  proc expandGraph(c: var AtlasContext; g: var DepGraph; currentNode: int; deps: seq[DepSubnode]) =
    for dep in deps:
      for d in dep.deps:
        let url = resolveUrl(c, d.nameOrUrl)
        if $url == "":
          error c, toName(d.nameOrUrl), "cannot resolve package name"
        else:
          addUniqueDep(c, g, currentNode, url, d.query)
