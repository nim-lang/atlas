#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import context, sat, gitops, osutils, nameresolver, runners

iterator matchingCommits(c: var AtlasContext; g: DepGraph; w: DepNode; q: VersionQuery): Commit =
  var q = q
  if w.algo == SemVer: q = toSemVer(q)
  let commit = extractSpecificCommit(q)
  if commit.len > 0:
    var v = Version("#" & commit)
    for j in countup(0, w.versions.len-1):
      if q.matches(w.versions[j]):
        v = w.versions[j].v
        break
    yield Commit(h: commit, v: v)
  elif w.algo == MinVer:
    for j in countup(0, w.versions.len-1):
      if q.matches(w.versions[j]):
        yield w.versions[j]
  else:
    for j in countdown(w.versions.len-1, 0):
      if q.matches(w.versions[j]):
        yield w.versions[j]

proc toString(x: (string, string, Version)): string =
  "(" & x[0] & ", " & $x[2] & ")"

proc findDeps(n: DepNode; commit: Commit): int =
  for j in 0 ..< n.subs.len:
    if n.subs[j].commit.v == commit.v or n.subs[j].commit.h == commit.h:
      return j
  return -1

proc toGraph(c: var AtlasContext; g: DepGraph; b: var sat.Builder) =
  var urlToIndex = initTable[string, int]()
  for i in 0 ..< g.nodes.len:
    for j in 0 ..< g.nodes[i].versions.len:
      let thisNode = i * g.nodes.len + j
      let key = $g.nodes[i].url & "/" & g.nodes[i].versions[j].h
      urlToIndex[key] = thisNode + 1

    urlToIndex[$g.nodes[i].url] = i+1

  for i in 0 ..< g.nodes.len:
    for j in 0 ..< g.nodes[i].versions.len:
      let thisNode = i * g.nodes.len + j
      let jj = findDeps(g.nodes[i], g.nodes[i].versions[j])
      if jj >= 0:
        for d in 0 ..< g.nodes[i].subs[jj].deps.len:
          let dep {.cursor.} = g.nodes[i].subs[j].deps[d]
          let url = resolveUrl(c, dep.nameOrUrl)

          if $url == "":
            discard "no error, instead avoid this dependency"
            #error c, toName(dep.nameOrUrl), "cannot resolve package name"
          else:
            let bpos = rememberPos(b)
            # A -> (exactly one of: A1, A2, A3)
            b.openOpr(OrForm)
            b.openOpr(NotForm)
            b.add newVar(VarId thisNode)
            b.closeOpr
            b.openOpr(ExactlyOneOfForm)
            var counter = 0
            let depIdx = urlToIndex.getOrDefault($url)
            assert depIdx > 0
            for mx in matchingCommits(c, g, g.nodes[depIdx-1], dep.query):
              let key = $url & "/" & mx.h
              let val = urlToIndex.getOrDefault(key)
              if val > 0:
                b.add newVar(VarId(val - 1))
                inc counter
            b.closeOpr # ExactlyOneOfForm
            b.closeOpr # OrForm
            if counter == 0:
              b.rewind bpos

proc toFormular(c: var AtlasContext; g: var DepGraph): Formular =
  var b = sat.Builder()
  b.openOpr(AndForm)
  toGraph(c, g, b)
  b.closeOpr
  result = toForm(b)

proc resolve*(c: var AtlasContext; g: var DepGraph) =
  let f = toFormular(c, g)

  var varCounter = 0
  for i in 0 ..< g.nodes.len:
    inc varCounter, g.nodes[i].versions.len

  var s = newSeq[BindingKind](varCounter)
  when false:
    let L = g.nodes.len
    var nodes = newSeq[string]()
    for i in 0..<L: nodes.add g.nodes[i].name.string
    echo f$(proc (buf: var string; i: int) =
      if i < L:
        buf.add nodes[i]
      else:
        buf.add $mapping[i - L])
  if satisfiable(f, s):
    for i in 0 ..< g.nodes.len:
      for j in 0 ..< g.nodes[i].versions.len:
        let thisNode = i * g.nodes.len + j
        if s[thisNode] == setToTrue:
          g.nodes[i].selected = j
          withDir c, g.nodes[i].dir:
            checkoutGitCommit(c, toName(g.nodes[i].dir), g.nodes[i].versions[j].h)
    if NoExec notin c.flags:
      runBuildSteps(c, g)
      #echo f
    if ListVersions in c.flags:
      echo "selected:"
      let L = g.nodes.len
      var nodes = newSeq[string]()
      for i in 0..<L: nodes.add g.nodes[i].name.string
      echo f$(proc (buf: var string; i: int) =
        if i < L:
          buf.add nodes[i]
        else:
          buf.add $mapping[i - L])
      for i in g.nodes.len..<s.len:
        if s[i] == setToTrue:
          echo "[x] ", toString mapping[i - g.nodes.len]
        else:
          echo "[ ] ", toString mapping[i - g.nodes.len]
      echo "end of selection"
  else:
    error c, toName(c.workspace), "version conflict; for more information use --showGraph"
    var usedVersions = initCountTable[string]()
    for i in g.nodes.len..<s.len:
      if s[i] == setToTrue:
        usedVersions.inc mapping[i - g.nodes.len][0]
    for i in g.nodes.len..<s.len:
      if s[i] == setToTrue:
        let counter = usedVersions.getOrDefault(mapping[i - g.nodes.len][0])
        if counter > 0:
          error c, toName(mapping[i - g.nodes.len][0]), $mapping[i - g.nodes.len][2] & " required"
