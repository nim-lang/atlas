import std / [os, strutils, sequtils]
from std/private/gitutils import diffFiles
import basic/versions
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

template expectedVersionWithGitTags*() =
    # These will change if atlas-tests is regnerated!
    # To update run and use commits not adding a proj_x.nim file
    #    curl http://localhost:4242/buildGraph/ws_generated-logs.txt
    let projAnimbles {.inject.} = dedent"""
    1aeb8db7c1955af43d458ccbbf65358b0a1a4fab 1.1.0
    e4c0ff66740bf604fc050b783c4ee61af05be36b
    43cdb67b93331a45dd82628c4cc7f3876dc2af91 1.0.0
    """.parseTaggedVersions(false)
    let projAtags {.inject.} = projAnimbles.filterIt(it.v.string != "")

    let projBnimbles {.inject.} = dedent"""
    ecb875d651b205412c880bf6eadbdd9f2a8fc6a3 1.1.0
    185ab2a8ecfca2944e51b38ea66339181e676072
    c0c5fe710e7c274642f8e95a9d7c155ede95d57e 1.0.0
    """.parseTaggedVersions(false)
    let projBtags {.inject.} = projBnimbles.filterIt(it.v.string != "")

    let projCnimbles {.inject.} = dedent"""
    41135038965b204de40ac7b90ef1fcae2acdbf08 1.2.0
    76b20c1e28280f35c9a0122776d0d8b2b7c53d46
    """.parseTaggedVersions(false)
    let projCtags {.inject.} = projCnimbles.filterIt(it.v.string != "")

    let projDnimbles {.inject.} = dedent"""
    a376d2152e86998cfb450e354e83697ccc9fc91f 2.0.0
    7c64075acb954fffd2318cee66113ac2ddad39cf 1.0.0
    """.parseTaggedVersions(false)
    let projDtags {.inject.} = projDnimbles.filterIt(it.v.string != "")

template expectedVersionWithNoGitTags*() =
    # These will change if atlas-tests is regnerated!
    # To update run and use commits not adding a proj_x.nim file
    #    curl http://localhost:4242/buildGraphNoGitTags/ws_generated-logs.txt
    let projAnimbles {.inject.} = dedent"""
    2a475375e473d9dc3163da8c8e67b21da27bcfbe 1.1.0
    af49e004c3de040598c3c174f73cc168255d9272
    26b7db63c1432791812d32dd7b748e90c9bf1b5c 1.0.0
    """.parseTaggedVersions(false)
    let projAtags {.inject.} = projAnimbles.filterIt(it.v.string != "")

    let projBnimbles {.inject.} = dedent"""
    ef7bcc3ec9c5921506390795642281aa69bc0267 1.1.0
    fc92c20321d2c645821601bd0a97169cb8d8f3d4
    4839843c715b1cb48e4a8d8b1ff1a3f2253f63e2 1.0.0
    """.parseTaggedVersions(false)
    let projBtags {.inject.} = projBnimbles.filterIt(it.v.string != "")

    let projCnimbles {.inject.} = dedent"""
    d4722de3342de848cf80afad309b0e1bc918a020 1.2.0
    cfb20bf3770d4f527010637856f8d0f7b62f6f98 1.0.0
    """.parseTaggedVersions(false)
    let projCtags {.inject.} = projCnimbles.filterIt(it.v.string != "")

    let projDnimbles {.inject.} = dedent"""
    cd972f754f7ed0cbc89038375157cfc69e8504dd 2.0.0
    cf22977a771494b0a6923142121121ed451c9bca 1.0.0
    """.parseTaggedVersions(false)
    let projDtags {.inject.} = projDnimbles.filterIt(it.v.string != "")

template expectedVersionWithNoGitTagsMaxVer*() =
    # These will change if atlas-tests is regnerated!
    # To update run and use commits not adding a proj_x.nim file
    #    curl http://localhost:4242/buildGraphNoGitTags/ws_generated-logs.txt
    # this variant uses the last commit where a given nimble version was found
    let projAnimbles {.inject.} = dedent"""
    2a475375e473d9dc3163da8c8e67b21da27bcfbe 1.1.0
    af49e004c3de040598c3c174f73cc168255d9272 1.0.0
    """.parseTaggedVersions(false)
    let projAtags {.inject.} = projAnimbles.filterIt(it.v.string != "")

    let projBnimbles {.inject.} = dedent"""
    ef7bcc3ec9c5921506390795642281aa69bc0267 1.1.0
    fc92c20321d2c645821601bd0a97169cb8d8f3d4 1.0.0
    """.parseTaggedVersions(false)
    let projBtags {.inject.} = projBnimbles.filterIt(it.v.string != "")

    let projCnimbles {.inject.} = dedent"""
    d4722de3342de848cf80afad309b0e1bc918a020 1.2.0
    cfb20bf3770d4f527010637856f8d0f7b62f6f98 1.0.0
    """.parseTaggedVersions(false)
    let projCtags {.inject.} = projCnimbles.filterIt(it.v.string != "")

    let projDnimbles {.inject.} = dedent"""
    cd972f754f7ed0cbc89038375157cfc69e8504dd 2.0.0
    cf22977a771494b0a6923142121121ed451c9bca 1.0.0
    """.parseTaggedVersions(false)
    let projDtags {.inject.} = projDnimbles.filterIt(it.v.string != "")

template findCommit*(proj: string, version: string): VersionTag =
  block:
    var res: VersionTag
    case proj:
      of "proj_a":
        for idx, vt in projAnimbles:
          if $vt.v == version:
            res = vt
            if idx == 0: res.isTip = true 
      of "proj_b":
        for idx, vt in projBnimbles:
          if $vt.v == version:
            res = vt
            if idx == 0: res.isTip = true 
      of "proj_c":
        for idx, vt in projCnimbles:
          if $vt.v == version:
            res = vt
            if idx == 0: res.isTip = true 
      of "proj_d":
        for idx, vt in projDnimbles:
          if $vt.v == version:
            res = vt
            if idx == 0: res.isTip = true 
      else:
        discard
    res


when isMainModule:
  expectedVersionWithGitTags()
  echo findCommit("proj_a", "1.1.0")
  echo findCommit("proj_a", "1.0.0")
  assert findCommit("proj_a", "1.1.0").isTip
  assert not findCommit("proj_a", "1.0.0").isTip