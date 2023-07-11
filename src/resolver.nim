#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import context, sat, gitops, osutils, nameresolver, runners, bitabs

iterator matchingCommits(c: var AtlasContext; g: DepGraph; w: DepNode; q: VersionQuery): Commit =
  var q = q
  if w.algo == SemVer: q = toSemVer(q)
  let commit = extractSpecificCommit(q)
  if commit.len > 0:
    var v = Version("#" & commit)
    var h = commit
    for j in countup(0, w.versions.len-1):
      if q.matches(w.versions[j]):
        v = w.versions[j].v
        h = w.versions[j].h
        break
    yield Commit(h: h, v: v)
  elif w.algo == MinVer:
    for j in countup(0, w.versions.len-1):
      if q.matches(w.versions[j]):
        yield w.versions[j]
  else:
    for j in countdown(w.versions.len-1, 0):
      if q.matches(w.versions[j]):
        yield w.versions[j]

proc toString(name: PackageName; v: Version): string =
  "(" & $name & ", " & $v & ")"

proc findDeps(n: DepNode; commit: Commit): int =
  for j in 0 ..< n.subs.len:
    if (commit.v != Version"" and n.subs[j].commit.v == commit.v) or
       (commit.h != "" and n.subs[j].commit.h == commit.h):
      return j
  return if n.subs.len > 0: 0 else: -1

proc toKey(c: Commit): string =
  if c.h.len > 0: c.h else: c.v.string

proc toReadableKey(c: Commit): string =
  if c.v.string.len > 0: c.v.string else: c.h

type
  Mapping = BiTable[(int, int)] # package url, version index

proc toGraph(c: var AtlasContext; g: DepGraph; b: var sat.Builder;
             m: var Mapping) =
  for i in 0 ..< g.nodes.len:
    discard m.getOrIncl (i, -1, -1)
    #for j in 0 ..< g.nodes[i].versions.len:
    #  discard m.getOrIncl (i, j)

  for i in 0 ..< g.nodes.len:
    for j in 0 ..< g.nodes[i].versions.len:
      let jj = findDeps(g.nodes[i], g.nodes[i].versions[j])
      if jj >= 0:
        #echo $g.nodes[i].url & "/" & $g.nodes[i].versions[j].v, " ", g.nodes[i].subs[jj].deps.len
        for d in 0 ..< g.nodes[i].subs[jj].deps.len:
          let dep {.cursor.} = g.nodes[i].subs[jj].deps[d]
          #echo dep.nameOrUrl, " ", dep.query
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
            let depIdx = g.urlToIdx[url]
            for mx in matchingCommits(c, g, g.nodes[depIdx], dep.query):
              let val = m.getKeyId((depIdx, mx, jj))
              if val != LitId(0):
                b.add newVar(VarId(val.int - 1))
              else:
                let val = m.getOrIncl((depIdx, g.nodes[depIdx].versions.len, jj))
                b.add newVar(VarId(m.int - 1))
                g.nodes[depIdx].versions.add mx
              inc counter
            b.closeOpr # ExactlyOneOfForm
            b.closeOpr # OrForm
            if counter == 0:
              b.rewind bpos
      inc thisNode

proc toFormular(c: var AtlasContext; g: var DepGraph; m: var Mapping): Formular =
  var b = sat.Builder()
  b.openOpr(AndForm)
  b.add newVar(VarId 0) # root node must be true.
  toGraph(c, g, b, m)
  b.closeOpr
  result = toForm(b)

proc checkoutGitCommitMaybe(c: var AtlasContext; n: DepNode) =
  if n.versions[n.vindex].h != "":
    withDir c, n.dir:
      checkoutGitCommit(c, n.name, n.versions[n.vindex].h)

proc resolve*(c: var AtlasContext; g: var DepGraph) =
  var m = default(Mapping)
  let f = toFormular(c, g, m)

  var s = newSeq[BindingKind](m.len)
  when true: # defined(showForm):
    var nodeNames = newSeq[string]()
    for x in items(m):
      var entry = $g.nodes[x[0]].name
      if x[1] >= 0:
        entry.add '@'
        entry.add toReadableKey(g.nodes[x[0]].versions[x[1]])
      nodeNames.add entry
    echo f$(proc (buf: var string; i: int) =
      buf.add nodeNames[i])

  if satisfiable(f, s):
    for i in 0 ..< s.len:
      if s[i] == setToTrue:
        let (nodeIdx, vindex, sindex) = m[LitId(i+1)]
        g.nodes[nodeIdx].vindex = vindex
        g.nodes[nodeIdx].sindex = sindex
        if i != 0:
          checkoutGitCommitMaybe(c, g.nodes[nodeIdx])

    if NoExec notin c.flags:
      runBuildSteps(c, g)
      #echo f
    if ListVersions in c.flags:
      echo "selected:"
      var thisNode = 0
      for i in 0 ..< g.nodes.len:
        for j in 0 ..< g.nodes[i].versions.len:
          let nodeRepr = toString(g.nodes[i].name, g.nodes[i].versions[j].v)
          if thisNode != 0:
            if s[thisNode] == setToTrue:
              echo "[x] ", nodeRepr
            else:
              echo "[ ] ", nodeRepr
          inc thisNode
      for i in 0 ..< additionalVars.len:
        let nodeRepr = "(" & $g.nodes[additionalVars[i][0]].name & ", " & additionalVars[i][1].h & ")"
        if s[i + lastNode] == setToTrue:
          echo "[x] ", nodeRepr
        else:
          echo "[ ] ", nodeRepr
      echo "end of selection"
  else:
    error c, toName(c.workspace), "version conflict; for more information use --showGraph"
    var usedVersions = initCountTable[string]()
    var thisNode = 0
    for i in 0 ..< g.nodes.len:
      for j in 0 ..< g.nodes[i].versions.len:
        if s[thisNode] == setToTrue:
          usedVersions.inc $g.nodes[i].name
        inc thisNode

    thisNode = 0
    for i in 0 ..< g.nodes.len:
      let counter = usedVersions.getOrDefault($g.nodes[i].name)
      for j in 0 ..< g.nodes[i].versions.len:
        if counter > 1:
          if s[thisNode] == setToTrue:
            error c, g.nodes[i].name, $g.nodes[i].versions[j] & " required"
        inc thisNode
