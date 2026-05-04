#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Utilities for getting dependency packages onto disk.
##
## Dependency graph traversal decides when a package needs loading; this module
## handles the clone/copy step and finalizes the on-disk package directory name.

import std/[os, paths, dirs, strutils]
import context, deptypes, pkgurls, reporters, nimblecontext, gitops

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

proc nameFromNimbleFile(pkg: Package; checkoutDir: Path): string =
  let searchDir =
    if pkg.subdir.len > 0: checkoutDir / pkg.subdir
    else: checkoutDir
  let nimbleFiles = findNimbleFile(searchDir, "")
  if nimbleFiles.len == 1:
    let (_, name, _) = nimbleFiles[0].splitFile()
    result = $name

proc tmpCheckoutDir(pkg: Package): Path =
  depsDir() / Path(".tmp") / Path(pkg.url.projectName() & "-" & $hash(pkg.url))

proc matchesPackageUrl(path: Path; pkg: Package): bool =
  dirExists(path) and gitops.getCanonicalUrl(path) == $pkg.url.cloneUri()

proc disambiguatedDirectoryPath(pkg: Package): Path =
  let baseName =
    if pkg.url.fullName().len > 0: pkg.url.fullName()
    else: pkg.url.projectName()

  var attempt = 0
  while true:
    let suffix =
      case attempt
      of 0: ""
      of 1: "-" & $hash(pkg.url)
      else: "-" & $hash(pkg.url) & "-" & $attempt
    result = (depsDir() / Path(baseName & suffix)).absolutePath()
    if not dirExists(result) or matchesPackageUrl(result, pkg):
      return
    inc attempt

proc warnPackageNameMismatch(pkg: Package; nimbleName: string) =
  if nimbleName.len > 0 and pkg.isOfficial and
      cmpIgnoreCase(pkg.name, nimbleName) != 0:
    warn pkg.projectName, "packages.json package name differs from nimble file name:",
         "packages.json:", pkg.name, "nimble:", nimbleName

proc finalizeClonedPackagePath(pkg: var Package; checkoutDir: Path) =
  let nimbleName = nameFromNimbleFile(pkg, checkoutDir)
  if nimbleName.len > 0:
    if pkg.isOfficial:
      warnPackageNameMismatch(pkg, nimbleName)
    else:
      pkg.name = nimbleName

  var finalDir = pkg.url.toDirectoryPath(pkg.projectName())
  if checkoutDir != finalDir:
    if dirExists(finalDir):
      if matchesPackageUrl(finalDir, pkg):
        removeDir($checkoutDir)
      else:
        finalDir = disambiguatedDirectoryPath(pkg)
        warn pkg.projectName, "package directory name collides with different repository:",
             "preferred:", $pkg.url.toDirectoryPath(pkg.projectName()),
             "using:", $finalDir
        if dirExists(finalDir):
          removeDir($checkoutDir)
        else:
          moveDir($checkoutDir, $finalDir)
    else:
      moveDir($checkoutDir, $finalDir)
    pkg.ondisk = finalDir

proc shouldCloneToTemp(pkg: Package): bool =
  not pkg.isOfficial and
    not pkg.url.isFileProtocol and
    pkg.url.cloneUri().scheme notin ["link", "atlas"]

proc resolveExistingPackageDir*(pkg: var Package): bool =
  ## Returns true when `pkg.ondisk` already contains the correct checkout.
  ##
  ## Non-official packages can derive their install directory from the nimble
  ## filename after cloning. If another unofficial package with the same nimble
  ## filename already owns that directory, look for this package's deterministic
  ## disambiguated directory instead of reusing the wrong checkout.
  if not dirExists(pkg.ondisk):
    return false
  if not pkg.shouldCloneToTemp():
    return true
  if matchesPackageUrl(pkg.ondisk, pkg):
    return true

  let alternateDir = disambiguatedDirectoryPath(pkg)
  if dirExists(alternateDir) and matchesPackageUrl(alternateDir, pkg):
    pkg.ondisk = alternateDir
    return true

  false

proc checkoutDir(pkg: Package): Path =
  if pkg.shouldCloneToTemp():
    let tmpDir = tmpCheckoutDir(pkg)
    if dirExists(tmpDir):
      removeDir($tmpDir)
    createDir($tmpDir.parentDir())
    tmpDir
  else:
    pkg.ondisk

proc clonePackage*(
    pkg: var Package;
    officialUrl: PkgUrl;
    isFork: bool;
) =
  ## Clones or copies `pkg` into its final on-disk location.
  ##
  ## Packages without a registry name are checked out to a temporary directory
  ## first so the `.nimble` filename can provide the package/install name.
  ## This is useful since if others fork the same unofficial package
  ## we could end up with different packages.
  let checkoutDir = pkg.checkoutDir()
  let (status, msg) =
    if pkg.url.isFileProtocol:
      pkg.isLocalOnly = true
      copyFromDisk(pkg, checkoutDir)
    else:
      gitops.clone(pkg.url.cloneUri(), checkoutDir)

  if status != Ok:
    pkg.state = Error
    pkg.errors.add $status & ": " & msg
    return

  if checkoutDir != pkg.ondisk:
    pkg.finalizeClonedPackagePath(checkoutDir)
  else:
    warnPackageNameMismatch(pkg, nameFromNimbleFile(pkg, pkg.ondisk))

  if not pkg.isLocalOnly:
    var repo = gitops.loadRepoMetadata(pkg.ondisk, expectedCanonicalUrl = $pkg.url.cloneUri())
    if isFork:
      discard gitops.ensureRemoteForUrl(pkg.ondisk, officialUrl.cloneUri())
    discard gitops.fetchRemoteTags(repo)
  pkg.state = Found
