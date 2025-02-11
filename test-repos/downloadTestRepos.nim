import std/[os, strutils]

proc exec*(cmd: string) =
  if execShellCmd(cmd) != 0:
    quit "FAILURE: " & cmd

template withDir*(dir: string; body: untyped) =
  let old = getCurrentDir()
  try:
    setCurrentDir(dir)
    echo "WITHDIR: ", dir, " at: ", getCurrentDir()
    body
  finally:
    setCurrentDir(old)

let reposUrl = "https://github.com/elcritch/atlas/releases/download/test-repos-v0.8.0/test-repos-0.8.0.zip"

exec("curl $1" % [reposUrl])
