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

when isMainModule:
  withDir "test-repos":
    let host = "https://github.com"
    let repo = "elcritch/atlas"
    let release = "releases/download/test-repos-v0.8.0"
    let file = "test-repos-0.8.0.zip"
    let url = "$1/$2/$3/$4" % [host, repo, release, file]
    exec("curl -L -o $2 $1" % [url, file])
    exec("unzip -o $1" % [file])
