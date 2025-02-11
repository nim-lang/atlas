import std/os

import wsGenerated
import wsIntegration

runWsGenerated()
runWsIntegration()

proc exec(cmd: string) =
  if execShellCmd(cmd) != 0:
    quit "FAILURE: " & cmd

exec "ls -lh"
