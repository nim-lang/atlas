#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std / [strutils, os, sha1, algorithm]
import context, nameresolver, gitops

proc updateSecureHash(checksum: var Sha1State; c: var AtlasContext; pkg: Package; name: string) =
  let path = pkg.path.string / name
  if not path.fileExists(): return
  checksum.update(name)

  if symlinkExists(path):
    # checksum file path (?)
    try:
      let path = expandSymlink(path)
      checksum.update(path)
    except OSError:
      error c, pkg, "cannot follow symbolic link " & path
  else:
    # checksum file contents
    var file: File
    try:
      file = path.open(fmRead)
      const bufferSize = 8192
      var buffer = newString(bufferSize)
      while true:
        var bytesRead = readChars(file, buffer)
        if bytesRead == 0: break
        checksum.update(buffer.toOpenArray(0, bytesRead - 1))
    except IOError:
      error c, pkg, "error opening file " & path
    finally:
      file.close()

proc nimbleChecksum*(c: var AtlasContext, pkg: Package, cfg: CfgPath): string =
  ## calculate a nimble style checksum from a `CfgPath`.
  ##
  ## Useful for exporting a Nimble sync file.
  ##
  let res = c.listFiles(pkg)
  if res.len == 0:
    error c, pkg, "couldn't list files"
  else:
    var files = res.sorted()
    var checksum = newSha1State()
    for file in files:
      checksum.updateSecureHash(c, pkg, file)
    result = toLowerAscii($SecureHash(checksum.finalize()))
