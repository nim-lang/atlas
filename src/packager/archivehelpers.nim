#
#           Atlas Package Cloner
#        (c) Copyright 2026 The Atlas contributors
#

## Helpers for selecting and building package archives using Nimble-like rules.

import std/[json, os, osproc, paths, sequtils, sets, strutils, times]

import ../basic/[deptypes, gitops, nimblechecksums, packageinfos, pkgurls, versions]

type
  ArchiveCompression* = enum
    acGzip
    acXz

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

proc isSimpleLibraryPackage(release: NimbleRelease): bool =
  not release.isNil and
    $release.srcDir != "" and
    not release.hasInstallHooks and
    release.installDirs.len == 0 and
    release.installFiles.len == 0 and
    release.installExt.len == 0 and
    release.bin.len == 0 and
    release.namedBin.len == 0 and
    not release.hasBin

proc selectPrimaryNimbleFile(
    trackedRelFiles: openArray[string];
    candidateNames: openArray[string]
): string =
  var nimbleFiles: seq[string]
  for relFile in trackedRelFiles:
    let normalized = normalizeArchivePath(relFile)
    if normalized.splitFile().ext == ".nimble":
      nimbleFiles.add normalized

  for candidateName in candidateNames:
    if candidateName.len == 0:
      continue
    let candidateFile = normalizeArchivePath(candidateName) & ".nimble"
    for nimbleFile in nimbleFiles:
      if cmpIgnoreCase(nimbleFile, candidateFile) == 0:
        return nimbleFile

  if nimbleFiles.len == 1:
    return nimbleFiles[0]
  ""

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
  var packageRelFiles: seq[string]
  var realDirFiles: seq[string]
  for file in trackedFiles:
    let packageRelFile = archivePathRelativeTo(file, normalizeArchivePath($packageSubdir))
    if packageRelFile.len > 0:
      packageRelFiles.add packageRelFile
    let relFile = archivePathRelativeTo(file, realDirPrefix)
    if relFile.len > 0 or normalizeArchivePath(file) == realDirPrefix:
      realDirFiles.add relFile

  if isSimpleLibraryPackage(release):
    let primaryNimbleFile = selectPrimaryNimbleFile(
      packageRelFiles,
      [release.name, info.name, pkg.name, pkg.projectName]
    )
    for file in trackedFiles:
      let relFile = archivePathRelativeTo(file, realDirPrefix)
      if relFile.len > 0:
        result.add file
      elif primaryNimbleFile.len > 0 and
          cmpIgnoreCase(archivePathRelativeTo(file, normalizeArchivePath($packageSubdir)), primaryNimbleFile) == 0:
        result.add file
    return

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

proc sanitizeArchiveComponent*(value: string): string =
  result = value
  for c in mitems(result):
    if c notin {'a'..'z', 'A'..'Z', '0'..'9', '.', '_', '-'}:
      c = '-'
  while result.contains("--"):
    result = result.replace("--", "-")
  result = result.strip(chars = {'-', '.'})

proc archiveCompressionExtension*(compression: ArchiveCompression): string =
  case compression
  of acGzip: ".tar.gz"
  of acXz: ".tar.xz"

proc compressionTempPath*(tarPath: Path; compression: ArchiveCompression): Path =
  case compression
  of acGzip: tarPath.parentDir() / Path(tarPath.splitPath().tail.string & ".gz")
  of acXz: tarPath.parentDir() / Path(tarPath.splitPath().tail.string & ".xz")

proc archiveCompressionName*(compression: ArchiveCompression): string =
  case compression
  of acGzip: "gzip"
  of acXz: "xz"

proc archiveCompressionNames*(compressions: openArray[ArchiveCompression]): seq[string] =
  for compression in compressions:
    result.add archiveCompressionName(compression)

proc archiveBaseName*(pkg: Package; info: PackageInfo; release: NimbleRelease): string =
  result = info.name
  if not release.isNil and release.name.len > 0:
    result = release.name
  elif pkg.name.len > 0:
    result = pkg.name
  elif pkg.projectName.len > 0:
    result = pkg.projectName
  result = sanitizeArchiveComponent(result)
  if result.len == 0:
    result = "package"

proc archiveReleaseLabel*(ver: PackageVersion; release: NimbleRelease; isHead: bool): string =
  if isHead:
    result = "head"
  elif not release.isNil and release.version.string.len > 0 and release.version.string != "#head":
    result = release.version.string
  elif ver.vtag.version.string.len > 0 and ver.vtag.version.string != "#head":
    result = ver.vtag.version.string
  elif ver.vtag.commit.h.len > 0:
    result = ver.vtag.commit.short()
  else:
    result = "head"
  result = sanitizeArchiveComponent(result)
  if result.len == 0:
    result = "head"

proc archiveCommitLabel*(ver: PackageVersion): string =
  result = sanitizeArchiveComponent(ver.vtag.commit.short())
  if result.len == 0:
    result = "unknown"

proc octalField(value: string): int =
  for c in value:
    if c in {'0'..'7'}:
      result = result * 8 + ord(c) - ord('0')

proc tarEntryName(header: string): string =
  result = header[0 ..< 100].strip(chars = {'\0'})
  let prefix = header[345 ..< 500].strip(chars = {'\0'})
  if prefix.len > 0:
    result = prefix & "/" & result

proc archiveContentHash*(tarPath: Path; archivePrefix: string): string =
  let tar = readFile($tarPath)
  var offset = 0
  var entries: seq[(string, string)] = @[]
  while offset + 512 <= tar.len:
    let header = tar[offset ..< offset + 512]
    if header.allIt(it == '\0'):
      break

    var name = tarEntryName(header)
    if name.startsWith(archivePrefix):
      name = name[archivePrefix.len .. ^1]
    let size = octalField(header[124 ..< 136])
    let kind = header[156]
    let dataOffset = offset + 512
    case kind
    of '\0', '0':
      entries.add((name, tar[dataOffset ..< dataOffset + size]))
    of '2':
      entries.add((name, header[157 ..< 257].strip(chars = {'\0'})))
    else:
      discard

    offset = dataOffset + ((size + 511) div 512) * 512
  result = nimbleChecksumForEntries(entries)

proc runArchiveCommand*(command: string): int =
  var process = startProcess(command, options = {poParentStreams, poUsePath, poEvalCommand})
  result = waitForExit(process)
  close(process)

proc runArchiveCommand*(command: string; args: openArray[string]): int =
  var process = startProcess(command, args = args, options = {poParentStreams, poUsePath})
  result = waitForExit(process)
  close(process)

proc writeTrackedReleaseTar*(
    pkg: Package;
    ver: PackageVersion;
    tarPath: Path;
    archiveStem: string;
    archiveFiles: openArray[string]
) =
  let prefix = archiveStem & "/"
  var args = @[
    "-C", $pkg.ondisk,
    "archive",
    "--format=tar",
    "--prefix=" & prefix,
    "-o", $tarPath,
    ver.vtag.commit.h
  ]
  for file in archiveFiles:
    args.add file

  if fileExists($tarPath):
    removeFile($tarPath)
  let exitCode = runArchiveCommand("git " & args.mapIt(quoteShell(it)).join(" "))
  if exitCode != 0 or not fileExists($tarPath):
    if fileExists($tarPath):
      removeFile($tarPath)
    raise newException(IOError, "failed to archive release to " & $tarPath)

proc writeTrackedReleaseArchive*(
    pkg: Package;
    ver: PackageVersion;
    archiveDir: Path;
    archiveStem: string;
    archiveFiles: openArray[string];
    compression: ArchiveCompression;
    siblingTempPath: proc (dest: Path): Path
): string =
  if ver.isNil or ver.vtag.commit.h.len == 0:
    raise newException(ValueError, "release is missing a commit for archiving")
  if archiveFiles.len == 0:
    raise newException(IOError, "release archive has no tracked files to package")

  createDir($archiveDir)
  let archivePath = archiveDir / Path(archiveStem & archiveCompressionExtension(compression))
  let tmpArchivePath = siblingTempPath(archivePath)

  let tarPath = siblingTempPath(archiveDir / Path(archiveStem & ".tar"))
  if fileExists($tmpArchivePath):
    removeFile($tmpArchivePath)
  writeTrackedReleaseTar(pkg, ver, tarPath, archiveStem, archiveFiles)
  let compressor =
    case compression
    of acGzip: "gzip"
    of acXz: "xz"
  let compressedTarPath = compressionTempPath(tarPath, compression)
  if fileExists($compressedTarPath):
    removeFile($compressedTarPath)
  let compressExitCode = runArchiveCommand(compressor, ["-9", "-f", $tarPath])
  if fileExists($tarPath):
    removeFile($tarPath)
  if compressExitCode == 0 and fileExists($compressedTarPath):
    moveFile($compressedTarPath, $tmpArchivePath)
  if compressExitCode != 0 or not fileExists($tmpArchivePath):
    if fileExists($tarPath):
      removeFile($tarPath)
    if fileExists($compressedTarPath):
      removeFile($compressedTarPath)
    if fileExists($tmpArchivePath):
      removeFile($tmpArchivePath)
    raise newException(IOError, "failed to compress release archive " & $archivePath)
  moveFile($tmpArchivePath, $archivePath)
  result = $archivePath.splitPath().tail

proc loadExistingDigestEntries*(digestPath: Path): JsonNode =
  if not fileExists($digestPath):
    return newJArray()
  try:
    let digest = parseFile($digestPath)
    if "tarballs" in digest and digest["tarballs"].kind == JArray:
      return digest["tarballs"]
  except CatchableError:
    discard
  newJArray()

proc matchingDigestEntry*(
    entries: JsonNode;
    versionLabel: string;
    gitSha: string;
    compression: string
): JsonNode =
  if entries.kind != JArray:
    return nil
  for entry in entries:
    if entry.kind != JObject:
      continue
    if entry{"version"}.getStr() == versionLabel and
        entry{"gitSha"}.getStr() == gitSha and
        entry{"compression"}.getStr() == compression:
      return entry
  nil

proc initArchiveEntry*(
    versionLabel: string;
    gitSha: string;
    gitShortSha: string;
    contentSha: string;
    contentShortSha: string;
    compression: string;
    archiveFile: string;
    archiveSize: BiggestInt;
    packageSubdir: Path;
    release: NimbleRelease
): JsonNode =
  result = newJObject()
  result["version"] = %versionLabel
  result["createdAt"] = %now().utc().format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  result["gitSha"] = %gitSha
  result["gitShortSha"] = %gitShortSha
  result["contentSha"] = %contentSha
  result["contentShortSha"] = %contentShortSha
  result["archiveRoot"] = %"package"
  result["compression"] = %compression
  result["file"] = %archiveFile
  result["size"] = %archiveSize
  if $packageSubdir != "":
    result["packageSubdir"] = %($packageSubdir)
  if not release.isNil and release.name.len > 0:
    result["name"] = %release.name
  if not release.isNil and $release.srcDir != "":
    result["srcDir"] = %($release.srcDir)
