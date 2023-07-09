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
                                     algo: c.defaultAlgo,
                                     sindex: -1, vindex: -1,
                                     versions: @[HeadCommit])])
  #result.byName.mgetOrPut(toName(start), @[]).add 0
  #result.byName[result.nodes[0].name] = 0
  result.urlToIdx[url] = 0

proc addUnique*[T](s: var seq[T]; elem: sink T) =
  if not s.contains(elem): s.add elem

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
  result = @[parseNimbleFile(c, nimbleFile, HeadCommit)]
  try:
    for commit in items cv:
      let (err, exitCode) = osproc.execCmdEx("git checkout " & commit.h & " -- " & quoteShell(nimbleFile))
      if exitCode == 0:
        result.add parseNimbleFile(c, nimbleFile, commit)
      else:
        error c, projectFromCurrentDir(), err
  finally:
    discard osproc.execCmdEx("git checkout HEAD " & quoteShell(nimbleFile))

proc addDeps(c: var AtlasContext; g: var DepGraph; deps: seq[DepSubnode]) =
  for dep in deps:
    for d in dep.deps:
      let url = resolveUrl(c, d.nameOrUrl)
      if $url == "":
        error c, toName(d.nameOrUrl), "cannot resolve package name"
      else:
        if not g.urlToIdx.contains(url):
          g.urlToIdx[url] = g.nodes.len
          g.nodes.add DepNode(name: toName(url), url: url, dir: "", subs: deps,
                              sindex: -1, vindex: -1, algo: c.defaultAlgo, status: Ok)

proc expandGraph*(c: var AtlasContext; g: var DepGraph; i: int) =
  let nimbleFile = findNimbleFile(c, g.nodes[i])
  if nimbleFile.len > 0:
    g.nodes[i].subs = allDeps(c, nimbleFile)
  g.nodes[i].versions = collectTaggedVersions(c)
  if i == 0 and g.nodes[i].versions.len == 0:
    g.nodes[i].versions.add HeadCommit
  addDeps c, g, g.nodes[i].subs
