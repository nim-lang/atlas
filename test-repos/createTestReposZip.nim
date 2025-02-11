import std/[os, strutils]

import wsGenerated
import wsIntegration
import downloadTestRepos

runWsGenerated()
runWsIntegration()

let nimble = readFile("atlas.nimble")
var ver = ""
for line in nimble.split("\n"):
  if line.startsWith("version ="):
    ver = line.replace("\"", "").split("=")[1].strip()
doAssert ver != "" and " " notin ver and ver.len() < 10, "need to provide atlas version"

withDir "test-repos":
  let zipfile = "test-repos-$1.zip" % [ver]
  exec "zip -ru $1 ws_generated/ ws_integration/" % [zipfile]
