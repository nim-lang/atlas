#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std/[os, paths, dirs]
import context, deptypes, pkgurls, reporters

proc copyFromDisk*(pkg: Package, dest: Path): (CloneStatus, string) =
  let source = pkg.url.toOriginalPath()
  info pkg, "copyFromDisk cloning:", $dest, "from:", $source
  if dirExists(source) and not dirExists(dest):
    trace pkg, "copyFromDisk cloning:", $dest, "from:", $source
    os.copyDir($source, $dest)
    result = (Ok, "")
  else:
    error pkg, "copyFromDisk not found:", $source
    result = (NotFound, $dest)
