#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std / [strutils, os, sha1, algorithm]
import gitops, reporters

proc updateSecureHash(checksum: var Sha1State; c: var Reporter; name, path: string) =
  if not path.fileExists(): return
  checksum.update(name)

  if symlinkExists(path):
    # checksum file path (?)
    try:
      let path = expandSymlink(path)
      checksum.update(path)
    except OSError:
      error c, name, "cannot follow symbolic link " & path
  else:
    # checksum file contents
    var file: File
    try:
      file = path.open(fmRead)
      const bufferSize = 8192
      var buffer = newString(bufferSize)
      while true:
        let bytesRead = readChars(file, buffer)
        if bytesRead == 0: break
        checksum.update(buffer.toOpenArray(0, bytesRead - 1))
    except IOError:
      error c, name, "error opening file " & path
    finally:
      file.close()

proc nimbleChecksum*(c: var Reporter; name, path: string): string =
  ## calculate a nimble style checksum from a `path`.
  ##
  ## Useful for exporting a Nimble sync file.
  ##
  withDir path:
    var files = c.listFiles()
    if files.len == 0:
      error c, path, "couldn't list files"
    else:
      sort(files)
      var checksum = newSha1State()
      for file in files:
        checksum.updateSecureHash(c, name, file)
      result = toLowerAscii($SecureHash(checksum.finalize()))
