import std/[os, paths, strutils, unittest]

import basic/[context, reporters]
import atlas

template withDir(dir: Path; body: untyped) =
  let old = os.getCurrentDir()
  try:
    os.setCurrentDir($dir)
    body
  finally:
    os.setCurrentDir(old)

suite "install":
  test "runs when nimble file has no requirements":
    let dir = getTempDir().Path / Path"atlas_install_no_requirements"
    if dirExists($dir):
      removeDir($dir)
    createDir($dir)

    try:
      withDir dir:
        writeFile("emptydeps.nimble", """
version "0.1.0"
""")

        setAtlasVerbosity(Error)
        setContext AtlasContext()
        atlasRun(@["install"])

        check atlasErrors() == 0
        check fileExists("nim.cfg")
        let cfg = readFile("nim.cfg")
        check "--noNimblePath" in cfg
        check "--path:" notin cfg
    finally:
      if dirExists($dir):
        removeDir($dir)
