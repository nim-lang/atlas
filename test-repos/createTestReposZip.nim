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
    ver = line.replace("\"", "").split("=")[1]

withDir "test-repos":
  doAssert ver != "" and "." in ver, "need to provide atlas version"
  exec "zip -r test-repos.zip ws_generated/ ws_integrated/"
