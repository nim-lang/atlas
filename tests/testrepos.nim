
import std / os

proc exec*(cmd: string) =
  if execShellCmd(cmd) != 0:
    quit "FAILURE RUNNING: " & cmd

template withDir*(dir: string; body: untyped) =
  let old = getCurrentDir()
  try:
    setCurrentDir(dir)
    # echo "WITHDIR: ", dir, " at: ", getCurrentDir()
    body
  finally:
    setCurrentDir(old)

proc buildGraph* =
  createDir "source"
  withDir "source":

    exec "git clone http://localhost:4242/buildGraph/proj_a"
    exec "git clone http://localhost:4242/buildGraph/proj_b"
    exec "git clone http://localhost:4242/buildGraph/proj_c"
    exec "git clone http://localhost:4242/buildGraph/proj_d"

proc buildGraphNoGitTags* =
  createDir "source"
  withDir "source":

    exec "git clone http://localhost:4242/buildGraphNoGitTags/proj_a"
    exec "git clone http://localhost:4242/buildGraphNoGitTags/proj_b"
    exec "git clone http://localhost:4242/buildGraphNoGitTags/proj_c"
    exec "git clone http://localhost:4242/buildGraphNoGitTags/proj_d"

when isMainModule:
  buildGraph()
