# Package
version = "0.14.11"
author = "Araq"
description = "Atlas is a simple package cloner tool. It manages an isolated project."
license = "MIT"
srcDir = "src"
skipDirs = @["doc"]
binDir = "bin"
bin = @["atlas", "atlasrun"]
namedBin = {"atlasrun": "atlas-run"}.toTable

# Dependencies

requires "nim >= 2.0.0"
requires "sat"

task docs, "build Atlas's docs":
  exec "nim rst2html --putenv:atlasversion=$1 doc/atlas.md" % version
