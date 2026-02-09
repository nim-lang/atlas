import std/[os, paths, strutils, tables]
import basic/[context, nimblecontext, deptypesjson, versions, pkgurls, reporters]
import depgraphs
import sat/[satvars]

proc findRootVar(form: Form): VarId =
  for vid, info in form.mapping.pairs:
    if info.feature.len == 0 and info.pkg.isRoot:
      return vid
  return NoVar

proc findVersionVar(form: Form; pname: string; commitPrefix: string): VarId =
  for vid, info in form.mapping.pairs:
    if info.feature.len > 0:
      continue
    if info.pkg.url.projectName == pname:
      let c = info.version.vtag.c.h
      if c.startsWith(commitPrefix):
        return vid
  return NoVar

let picks = [
  ("nitter.zedeus.github.com", "92cd6abc"),
  ("jester.dom96.github.com", "baca3f"),
  ("karax.karaxnim.github.com", "5cf360c"),
  ("sass.dom96.github.com", "7dfdd03"),
  ("nimcrypto.cheatfate.github.com", "a079df9"),
  ("nim-markdown.soasme.github.com", "158efe3"),
  ("packedjson.Araq.github.com", "9e6fbb6"),
  ("supersnappy.guzba.github.com", "6c94198"),
  ("redpool.zedeus.github.com", "8b7c1db"),
  ("redis.zedeus.github.com", "d0a0e6f"),
  ("zippy.guzba.github.com", "ca5989a"),
  ("flatty.treeform.github.com", "e668085"),
  ("jsony.treeform.github.com", "1de1f08"),
  ("oauth.CORDEA.github.com", "b8c163b")
]

let testsDir = currentSourcePath().parentDir().Path
let projectDir = testsDir / Path"ws_integration"
let graphFile = testsDir / Path"test_data" / Path"sat_bug_graph_input.json"

if not fileExists(graphFile.string):
  quit "missing graph fixture: " & graphFile.string

var ctx = context()
ctx.projectDir = projectDir
setContext(ctx)
setAtlasVerbosity(Error)

var nc: NimbleContext
var graph = nc.loadJson(graphFile.string)
let form = graph.toFormular(SemVer)
let maxVar = maxVariable(form.formula)

var assignment = createSolution(maxVar)
let rootVar = findRootVar(form)
doAssert rootVar != NoVar, "missing root SAT variable"
assignment.setVar(rootVar, SetToTrue)

for (pkgName, commitPrefix) in picks:
  let vid = findVersionVar(form, pkgName, commitPrefix)
  doAssert vid != NoVar, "missing SAT variable for " & pkgName
  assignment.setVar(vid, SetToTrue)

let manualEval = eval(form.formula, assignment)
echo "manual_eval=", manualEval

var fastSol = createSolution(maxVar)
let fastSat = satisfiable(form.formula, fastSol)
echo "fast_sat=", fastSat

doAssert manualEval, "expected manual assignment to satisfy formula"
doAssert not fastSat, "expected fast SAT false-UNSAT for this bug sample"
