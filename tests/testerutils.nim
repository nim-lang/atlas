
import std / os
from std/private/gitutils import diffFiles
export diffFiles
import githttpserver

let atlasExe* = absolutePath("bin" / "atlas".addFileExt(ExeExt))

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

template sameDirContents*(expected, given: string) =
  # result = true
  for _, e in walkDir(expected):
    let g = given / splitPath(e).tail
    if fileExists(g):
      let edata  = readFile(e)
      let gdata = readFile(g)
      check gdata == edata
      if gdata != edata:
        echo "FAILURE: files differ: ", e.absolutePath, " to: ", g.absolutePath
        echo diffFiles(e, g).output
      else:
        echo "SUCCESS: files match: ", e.absolutePath
    else:
      echo "FAILURE: file does not exist: ", g
      check fileExists(g)
      # result = false

proc ensureGitHttpServer*() =
  try:
    if checkHttpReadme():
      return
  except CatchableError:
    echo "Starting Tester git http server"
    runGitHttpServerThread([
      "atlas-tests/ws_integration",
      "atlas-tests/ws_generated"
    ])
    for count in 1..10:
      os.sleep(1000)
      if checkHttpReadme():
        return

    quit "Error accessing git-http server.\n" &
        "Check that tests/githttpserver server is running on port 4242.\n" &
        "To start it run in another terminal:\n" &
        "  nim c -r tests/githttpserver test-repos/generated"
