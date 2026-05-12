#
#           Atlas Package Cloner
#        (c) Copyright 2026 The Atlas contributors
#

## Helpers for selecting package archive contents using Nimble-like rules.

import std/[os, paths, sets, strutils]

import ../basic/[deptypes, gitops, packageinfos, pkgurls, versions]

proc packageRootSubdir*(pkg: Package): Path =
  let packageSubdir =
    if $pkg.subdir != "": pkg.subdir
    else: pkg.url.subdir()
  result = packageSubdir

proc archiveTrackedFiles(pkg: Package; commit: CommitHash; subdir: Path): seq[string] =
  let subdirPrefix =
    if $subdir != "": $subdir & "/"
    else: ""

  for file in listFiles(pkg.ondisk, commit):
    if file.len == 0:
      continue
    if subdirPrefix.len == 0 or file == $subdir or file.startsWith(subdirPrefix):
      result.add file

proc normalizeArchivePath(path: string): string =
  result = path.replace('\\', '/')
  while result.startsWith("./"):
    result = result[2 .. ^1]
  if result == ".":
    result = ""

proc archivePathRelativeTo(path: string; basePrefix: string): string =
  let normalizedPath = normalizeArchivePath(path)
  let normalizedBase = normalizeArchivePath(basePrefix)
  if normalizedBase.len == 0:
    return normalizedPath
  if normalizedPath == normalizedBase:
    return ""
  if normalizedPath.startsWith(normalizedBase & "/"):
    return normalizedPath[normalizedBase.len + 1 .. ^1]
  ""

proc pathParts(path: string): seq[string] =
  for part in normalizeArchivePath(path).split('/'):
    if part.len > 0 and part != ".":
      result.add part

proc containsPath(parts: openArray[string]; needle: string): bool =
  for part in parts:
    if cmpIgnoreCase(part, needle) == 0:
      return true
  false

proc containsAnyPath(parts: openArray[string]; needles: openArray[string]): bool =
  for needle in needles:
    if containsPath(parts, needle):
      return true
  false

proc isInstallDirMatch(relPath: string; installDir: string): bool =
  let normalizedPath = normalizeArchivePath(relPath)
  let normalizedDir = normalizeArchivePath(installDir)
  normalizedDir.len > 0 and (
    normalizedPath == normalizedDir or
    normalizedPath.startsWith(normalizedDir & "/")
  )

proc hasWhitelistInstructions(release: NimbleRelease): bool =
  not release.isNil and (
    release.installDirs.len > 0 or
    release.installFiles.len > 0 or
    release.installExt.len > 0
  )

proc fileExtNoDot(path: string): string =
  let fileExt = normalizeArchivePath(path).splitFile().ext
  if fileExt.len > 0:
    fileExt[1 .. ^1]
  else:
    ""

proc inferredInstallDirPaths(
    release: NimbleRelease;
    packageName: string;
    trackedRelFiles: openArray[string]
): seq[string] =
  if release.isNil or $release.srcDir != "":
    return
  let packageDir = normalizeArchivePath(packageName)
  let packageMain = packageDir & ".nim"
  var hasPackageDir = false
  for relFile in trackedRelFiles:
    let normalized = normalizeArchivePath(relFile)
    if packageDir.len > 0 and normalized.startsWith(packageDir & "/"):
      hasPackageDir = true
    discard cmpIgnoreCase(normalized, packageMain)
  if hasPackageDir:
    result.add packageDir

proc effectiveInstallDirs(
    release: NimbleRelease;
    packageName: string;
    trackedRelFiles: openArray[string]
): seq[string] =
  if not release.isNil:
    result = release.installDirs
  for inferred in inferredInstallDirPaths(release, packageName, trackedRelFiles):
    if inferred notin result:
      result.add inferred

proc effectiveInstallFiles(
    release: NimbleRelease;
    packageName: string;
    trackedRelFiles: openArray[string]
): seq[string] =
  if not release.isNil:
    result = release.installFiles
  if release.isNil or $release.srcDir != "":
    return
  let packageMain = normalizeArchivePath(packageName) & ".nim"
  for relFile in trackedRelFiles:
    if cmpIgnoreCase(normalizeArchivePath(relFile), packageMain) == 0 and packageMain notin result:
      result.add packageMain

proc shouldSkipArchiveDir(relDir: string; release: NimbleRelease; installDirs: openArray[string]): bool =
  let parts = pathParts(relDir)
  if parts.len == 0:
    return false
  let dirName = parts[^1]
  if not release.isNil:
    for ignoreDir in release.skipDirs:
      if isInstallDirMatch(relDir, ignoreDir):
        return true
  if dirName.len > 0 and dirName[0] == '.':
    return true
  if containsAnyPath(parts, ["nimcache", "test", "tests", "example", "examples"]):
    for installDir in installDirs:
      if isInstallDirMatch(relDir, installDir):
        return false
    return true
  false

proc shouldSkipArchiveFile(relFile: string; release: NimbleRelease): bool =
  let normalized = normalizeArchivePath(relFile)
  let parts = pathParts(normalized)
  if parts.len == 0:
    return false
  let fileName = parts[^1]
  if fileName.len > 0 and fileName[0] == '.':
    return true
  if not release.isNil:
    for ignoreFile in release.skipFiles:
      if cmpIgnoreCase(normalized, normalizeArchivePath(ignoreFile)) == 0:
        return true
    for ignoreExt in release.skipExt:
      if cmpIgnoreCase(fileExtNoDot(normalized), ignoreExt) == 0:
        return true
  false

proc collectArchiveFiles*(
    pkg: Package;
    ver: PackageVersion;
    info: PackageInfo;
    release: NimbleRelease;
    packageSubdir: Path
): seq[string] =
  let realDir =
    if not release.isNil and $release.srcDir != "":
      packageSubdir / release.srcDir
    else:
      packageSubdir
  let realDirPrefix = normalizeArchivePath($realDir)
  let trackedFiles = archiveTrackedFiles(pkg, ver.vtag.commit, packageSubdir)
  var realDirFiles: seq[string]
  for file in trackedFiles:
    let relFile = archivePathRelativeTo(file, realDirPrefix)
    if relFile.len > 0 or normalizeArchivePath(file) == realDirPrefix:
      realDirFiles.add relFile

  let installDirs = effectiveInstallDirs(release, info.name, realDirFiles)
  let installFiles = effectiveInstallFiles(release, info.name, realDirFiles)
  let whitelistMode = hasWhitelistInstructions(release) or installDirs.len > 0 or installFiles.len > 0
  var included = initHashSet[string]()

  for file in trackedFiles:
    let relFile = archivePathRelativeTo(file, realDirPrefix)
    if relFile.len == 0:
      continue
    let normalizedRel = normalizeArchivePath(relFile)
    let relParts = pathParts(normalizedRel)
    if relParts.len > 1:
      let relDir = relParts[0 .. ^2].join("/")
      if shouldSkipArchiveDir(relDir, release, installDirs):
        continue
    if shouldSkipArchiveFile(normalizedRel, release):
      continue

    var shouldInclude = false
    if whitelistMode:
      for installFile in installFiles:
        if cmpIgnoreCase(normalizedRel, normalizeArchivePath(installFile)) == 0:
          shouldInclude = true
          break
      if not shouldInclude:
        for installDir in installDirs:
          if isInstallDirMatch(normalizedRel, installDir):
            shouldInclude = true
            break
      if not shouldInclude and not release.isNil:
        for installExt in release.installExt:
          if cmpIgnoreCase(fileExtNoDot(normalizedRel), installExt) == 0:
            shouldInclude = true
            break
    else:
      shouldInclude = true

    if shouldInclude and not included.containsOrIncl(file):
      result.add file
