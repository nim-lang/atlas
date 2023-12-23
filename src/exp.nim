#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std / [sets, os, strutils]

import context, sat, nameresolver, configutils

type
  Dependencies* = ref object
    deps*: seq[(Package, VersionInterval)]
    hasInstallHooks*: bool
    srcDir: string
    nimVersion: Version
    v: VarId

  ProjectStatus* = enum
    Normal, HasBrokenNimbleFile, HasUnknownNimbleFile, HasBrokenDep

  ProjectVersion* = object  # Represents a specific version of a project.
    version*: Version
    dependencies*: Dependencies
    status*: ProjectStatus

  Project* = object
    pkg*: Package
    versions*: seq[ProjectVersion]
    v: VarId

  Graph* = object
    projects: seq[Project]
    idgen: int32
    startProjectsLen: int

proc createGraph*(startSet: openArray[Package]): Graph =
  result = Graph(projects: @[], idgen: 0'i32, startProjectsLen: startSet.len)
  for s in startSet:
    result.projects.add Project(pkg: s, versions: @[], v: VarId(result.idgen))
    inc result.idgen

iterator allReleases(c: var AtlasContext): Version =
  yield Version"#head" # dummy implementation for now

proc parseNimbleFile(c: var AtlasContext; proj: var Project; nimble: PackageNimble) =
  # XXX Fix code duplication. Copied from `traversal.nim`:
  let nimbleInfo = parseNimble(c, nimble)

  proj.versions[^1].dependencies.hasInstallHooks = nimbleInfo.hasInstallHooks
  proj.versions[^1].dependencies.srcDir = nimbleInfo.srcDir

  for r in nimbleInfo.requires:
    var i = 0
    while i < r.len and r[i] notin {'#', '<', '=', '>'} + Whitespace: inc i
    let name = r.substr(0, i-1)
    let pkg = c.resolvePackage(name)

    var err = pkg.name.string.len == 0
    if len($pkg.url) == 0 or not pkg.exists:
      #error c, pkg, "invalid pkgUrl in nimble file: " & name
      proj.versions[^1].status = HasBrokenDep

    let query = parseVersionInterval(r, i, err) # update err

    if err:
      if proj.versions[^1].status != HasBrokenDep:
        proj.versions[^1].status = HasBrokenNimbleFile
      #error c, pkg, "invalid 'requires' syntax in nimble file: " & r
    else:
      if cmpIgnoreCase(pkg.name.string, "nim") == 0:
        let v = extractGeQuery(query)
        if v != Version"":
          proj.versions[^1].dependencies.nimVersion = v
      else:
        proj.versions[^1].dependencies.deps.add (pkg, query)

proc traverseProject(c: var AtlasContext; g: var Graph; idx: int;
                     processed: var HashSet[PackageRepo]) =
  var lastNimbleContents = "<invalid content>"

  for release in allReleases(c):
    var nimbleFile = g.projects[idx].pkg.name.string & ".nimble"
    var found = 0
    if fileExists(nimbleFile):
      inc found
    else:
      for file in walkFiles("*.nimble"):
        nimbleFile = file
        inc found
    var pv = ProjectVersion(
      version: release,
      dependencies: Dependencies(deps: @[], v: NoVar),
      status: Normal)
    if found != 1:
      pv.status = HasUnknownNimbleFile
    else:
      let nimbleContents = readFile(nimbleFile)
      if lastNimbleContents == nimbleContents:
        pv.dependencies = g.projects[idx].versions[^1].dependencies
        pv.status = g.projects[idx].versions[^1].status
      else:
        parseNimbleFile(c, g.projects[idx], PackageNimble(nimbleFile))
        lastNimbleContents = ensureMove nimbleContents

      if pv.status == Normal:
        for dep, _ in items(pv.dependencies.deps):
          if not dep.exists:
            pv.status = HasBrokenDep
          elif not processed.containsOrIncl(dep.repo):
            g.projects.add Project(pkg: dep, versions: @[])

    g.projects[idx].versions.add ensureMove pv

proc expand*(c: var AtlasContext; g: var Graph) =
  ## Expand the graph by adding all dependencies.
  var processed = initHashSet[PackageRepo]()
  var i = 0
  while i < g.projects.len:
    let w {.cursor.} = g.projects[i]

    if not processed.containsOrIncl(w.pkg.repo):
      if not dirExists(w.pkg.path.string):
        withDir c, (if i < g.startProjectsLen: c.workspace else: c.depsDir):
          info(c, w.pkg, "cloning: " & $(w.pkg.url))
          let (status, err) = cloneUrl(c, w.pkg.url, w.pkg.path.string, false)
          #g.nodes[i].status = status

      withDir c, w.pkg:
        traverseProject(c, g, i, processed)
    inc i

proc toFormular*(g: Graph): Formular =
  # Key idea: use a SAT variable for every `Dependencies` object, which are
  # shared.
  var idgen = g.idgen


