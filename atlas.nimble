# Package
version = "0.8.0"
author = "Araq"
description = "Atlas is a simple package cloner tool. It manages an isolated workspace."
license = "MIT"
srcDir = "src"
skipDirs = @["doc"]
bin = @["atlas"]

# Dependencies

requires "nim >= 2.0.0"
requires "sat"

task docs, "build Atlas's docs":
  exec "nim rst2html --putenv:atlasversion=$1 doc/atlas.md" % version
