import std/[os, strutils]

import wsGenerated
import wsIntegration

runWsGenerated()
runWsIntegration()

proc exec(cmd: string) =
  if execShellCmd(cmd) != 0:
    quit "FAILURE: " & cmd

template withDir(dir: string; body: untyped) =
  let old = getCurrentDir()
  try:
    setCurrentDir(dir)
    # echo "WITHDIR: ", dir, " at: ", getCurrentDir()
    body
  finally:
    setCurrentDir(old)

let nimble = readFile("atlas.nimble")
var ver = ""
for line in nimble.split("\n"):
  if line.startsWith("version ="):
    ver = line.replace("\"", "").split("=")[1].strip()
doAssert ver != "" and " " notin ver and ver.len() < 10, "need to provide atlas version"

withDir "test-repos":
  let zipfile = "test-repos-$1.zip" % [ver]
  if fileExists(zipfile):
    removeFile(zipfile)
  exec "zip -r $1 ws_generated/ ws_integrated/" % [file]
