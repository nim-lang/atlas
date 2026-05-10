#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

{.push warning[Deprecated]: off.}
import std / [strutils, os, sha1, algorithm]
{.pop.}
import reporters
import osutils
import gitops

proc updateSecureHash(checksum: var Sha1State; fileName, path: string) =
  if not path.fileExists():
    # VCS manifests can include empty directories or vanished entries. Skip
    # them to match Nimble's checksum behavior.
    return
  checksum.update(fileName)

  if symlinkExists(path):
    # Hash the symlink target path rather than file contents.
    try:
      let path = expandSymlink(path)
      checksum.update(path)
    except OSError:
      warn fileName, "cannot follow symbolic link " & path
      return
  else:
    # Hash regular file contents.
    var file: File
    try:
      file = path.open(fmRead)
    except IOError:
      warn fileName, "error opening file " & path
      return
    const bufferSize = 8192
    var buffer = newString(bufferSize)
    try:
      while true:
        let bytesRead = readChars(file, buffer)
        if bytesRead == 0:
          break
        checksum.update(buffer.toOpenArray(0, bytesRead - 1))
    finally:
      file.close()

proc getPackageFileListWithoutVcs(dir: Path): seq[string] =
  for file in walkDirRec($dir, yieldFilter = {pcFile, pcLinkToFile}, relative = true):
    when defined(windows):
      result.add file.replace('\\', '/')
    else:
      result.add file

proc getPackageFileList(dir: Path): seq[string] =
  let (outp, status) = exec(GitLsFiles, dir, [], Debug)
  if status == RES_OK:
    result = outp.strip().splitLines()
  else:
    result = dir.getPackageFileListWithoutVcs()

proc nimbleChecksum*(name: string, path: Path): string =
  ## calculate a nimble style checksum from a `path`.
  ##
  ## Useful for exporting a Nimble sync file.
  ##
  var files = getPackageFileList(path)
  sort(files)
  var checksum = newSha1State()
  for file in files:
    checksum.updateSecureHash(file, $path / file)
  result = toLowerAscii($SecureHash(checksum.finalize()))
