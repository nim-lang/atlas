import std/[os, paths, unittest]

import basic/context
import atlas

proc runWithOptions(options: seq[string]): AtlasContext =
  let oldDir = os.getCurrentDir()
  let oldContext = context()
  let dir = getTempDir().Path / Path"atlas_parallel_options_test"
  if dirExists($dir):
    removeDir($dir)
  createDir($dir)

  try:
    setCurrentDir($dir)
    writeFile("atlas.config", "{}\n")
    writeFile("options.nimble", "version = \"0.1.0\"\n")
    setContext AtlasContext()
    atlasRun(options & @["--noexec", "install"])
    result = context()
  finally:
    setContext(oldContext)
    setCurrentDir(oldDir)
    if dirExists($dir):
      removeDir($dir)

suite "parallel clone options":
  test "parallel cloning is enabled by default":
    block:
      let ctx = runWithOptions(@[])
      doAssert ParallelClones in ctx.flags
      doAssert ctx.parallelCloneWorkers == 4

  test "no-thread disables parallel cloning":
    block:
      doAssert ParallelClones notin runWithOptions(@["--no-thread"]).flags
      doAssert ParallelClones notin runWithOptions(@["-T"]).flags

  test "legacy -t remains accepted":
    block:
      doAssert ParallelClones in runWithOptions(@["-t"]).flags

  test "parallel options are applied in command-line order":
    block:
      doAssert ParallelClones in runWithOptions(@["--no-thread", "-t"]).flags
      doAssert ParallelClones notin runWithOptions(@["-t", "--no-thread"]).flags
