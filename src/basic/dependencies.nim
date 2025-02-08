
import std / [sets, tables, os, strutils, streams, json, jsonutils, algorithm]

import context, gitops, runners, reporters, nimbleparser, pkgurls, cloner, versions

type
  DependencyVersion* = object  # Represents a specific version of a project.
    version*: Version
    commit*: string
    req*: int # index into graph.reqs so that it can be shared between versions
    v: VarId

  Dependency* = object
    pkg*: PkgUrl
    versions*: seq[DependencyVersion]
    #v: VarId
    active*: bool
    isRoot*: bool
    isTopLevel*: bool
    status: CloneStatus
    activeVersion*: int
    ondisk*: string

  DepGraph* = object
    nodes: seq[Dependency]
    reqs: seq[Requirements]
    packageToDependency: Table[PkgUrl, int]
    ondisk: OrderedTable[string, string] # URL -> dirname mapping
    reqsByDeps: Table[Requirements, int]

const
  EmptyReqs = 0
  UnknownReqs = 1

proc defaultReqs(): seq[Requirements] =
  @[Requirements(deps: @[], v: NoVar), Requirements(status: HasUnknownNimbleFile, v: NoVar)]

proc toJson*(d: DepGraph): JsonNode =
  result = newJObject()
  result["nodes"] = toJson(d.nodes)
  result["reqs"] = toJson(d.reqs)

proc findNimbleFile(g: DepGraph; idx: int): (string, int) =
  var nimbleFile = g.nodes[idx].pkg.projectName & ".nimble"
  var found = 0
  if fileExists(nimbleFile):
    inc found
  else:
    for file in walkFiles("*.nimble"):
      nimbleFile = file
      inc found
  result = (ensureMove nimbleFile, found)

proc enrichVersionsViaExplicitHash*(versions: var seq[DependencyVersion]; x: VersionInterval) =
  let commit = extractSpecificCommit(x)
  if commit.len > 0:
    for v in versions:
      if v.commit == commit: return
    versions.add DependencyVersion(version: Version"",
      commit: commit, req: EmptyReqs, v: NoVar)
