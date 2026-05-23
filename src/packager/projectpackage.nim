#
#           Atlas Package Cloner
#        (c) Copyright 2026 The Atlas contributors
#

## Package the current local project into a release tarball and releases.json.

import std/[algorithm, json, monotimes, os, parseopt, paths, strutils, tempfiles, times]

import ../basic/[context, dependencycache, deptypes, gitops, nimblecontext, packageinfos,
                 pkgurls, reporters, versions]
import ../releaseinfo
import ./archivehelpers
import ./cacheharvest

type
  ProjectReleaseMode* = enum
    prmLatestRelease
    prmHead

  ProjectPackageCliOptions* = object
    projectDir*: Path
    outputDir*: Path
    compressions*: seq[ArchiveCompression]
    createTarballs*: bool
    releaseMode*: ProjectReleaseMode

proc usage*(versionString: string): string =
  "atlas-package - Atlas Local Project Packager Version " & versionString & """

  (c) 2026 Atlas Contributors
Usage:
  atlas-package [options] [project-dir]

Options:
  --help, -h            show this help
  --version, -v         show the version
  --project=path, -p    package the given local project
  --output=path         write releases.json and archives to the given directory
                        default: project directory
  --head                package the current git commit as a #head release
                        default packages the latest tagged/versioned release
  --compression=type    archive compression(s): gzip, xz, or comma-separated list
                        default: xz
  --no-tarballs         refresh releases.json without creating tarballs
"""

proc writeHelp*(versionString: string; code = 2) =
  stdout.write(usage(versionString))
  stdout.flushFile()
  quit(code)

proc writeVersion*(versionString: string) =
  stdout.write("version: " & versionString & "\n")
  stdout.flushFile()
  quit(0)

proc parseArchiveCompression(value: string): ArchiveCompression =
  case value.normalize()
  of "xz":
    acXz
  of "gzip", "gz":
    acGzip
  else:
    raise newException(ValueError, "unknown compression: " & value)

proc parseArchiveCompressions(value: string): seq[ArchiveCompression] =
  for rawName in value.split(','):
    let name = rawName.strip()
    if name.len == 0:
      continue
    let compression = parseArchiveCompression(name)
    if compression notin result:
      result.add compression

  if result.len == 0:
    raise newException(ValueError, "missing compression")

proc addArchiveCompressions(dest: var seq[ArchiveCompression]; value: string) =
  for compression in parseArchiveCompressions(value):
    if compression notin dest:
      dest.add compression

proc parseAtlasPackageOptions*(
    params: seq[string];
    versionString: string;
    positional: var seq[string]
): ProjectPackageCliOptions =
  result.compressions = @[acXz]
  result.createTarballs = true
  var compressionWasSet = false
  for kind, key, val in getopt(params):
    case kind
    of cmdLongOption, cmdShortOption:
      case normalize(key)
      of "help", "h":
        writeHelp(versionString, 0)
      of "version", "v":
        writeVersion(versionString)
      of "project", "p":
        if val.len == 0:
          writeHelp(versionString)
        result.projectDir = Path(val)
      of "output", "o":
        if val.len == 0:
          writeHelp(versionString)
        result.outputDir = Path(val)
      of "head":
        result.releaseMode = prmHead
      of "compression":
        if val.len == 0:
          writeHelp(versionString)
        try:
          if not compressionWasSet:
            result.compressions.setLen(0)
            compressionWasSet = true
          result.compressions.addArchiveCompressions(val)
        except ValueError:
          writeHelp(versionString)
      of "no-tarballs", "notarballs":
        result.createTarballs = false
      else:
        writeHelp(versionString)
    of cmdArgument:
      positional.add key
    of cmdEnd:
      assert false, "cannot happen"

proc siblingTempPath(dest: Path): Path =
  let destDir = dest.parentDir()
  destDir / Path(".tmp." & dest.splitPath().tail.string)

proc findProjectNimbleFile(projectDir: Path): Path =
  let nimbleFiles = findNimbleFile(projectDir)
  if nimbleFiles.len == 0:
    raise newException(IOError, "no Nimble file found in: " & $projectDir)
  if nimbleFiles.len > 1:
    raise newException(IOError, "ambiguous Nimble files found in: " & $projectDir)
  nimbleFiles[0]

proc localArchiveBaseName*(packageName: string): string =
  let sanitized = sanitizeArchiveComponent(packageName)
  if sanitized.len > 0:
    sanitized & "-release"
  else:
    "package-release"

proc projectPkgUrl(nc: var NimbleContext; projectDir: Path): PkgUrl =
  let canonicalUrl = getCanonicalUrl(projectDir)
  if canonicalUrl.len > 0:
    return nc.createUrl(canonicalUrl)
  project(projectDir)
  nc.createUrlFromPath(projectDir)

proc initProjectPackage(
    nc: var NimbleContext;
    projectDir: Path;
    nimbleFile: Path
): Package =
  let url = nc.projectPkgUrl(projectDir)
  result = nc.initPackage(url, Found)
  result.ondisk = projectDir
  result.nimbleFile = nimbleFile
  result.name = nimbleFile.splitFile().name.string
  result.isLocalOnly = url.url.scheme in ["atlas", "file", "link"]

proc loadProjectRelease(
    nc: var NimbleContext;
    pkg: Package
): (PackageVersion, NimbleRelease, CommitHash) =
  let repo = loadRepoMetadata(
    pkg.ondisk,
    expectedCanonicalUrl = if pkg.isLocalOnly: "" else: $pkg.url.cloneUri(),
    errorReportLevel = Warning,
    isLocalOnly = pkg.isLocalOnly
  )
  if repo.currentCommit.isEmpty():
    raise newException(IOError, "could not determine current git commit for: " & $pkg.ondisk)

  let releaseCommit = initCommitHash(repo.currentCommit, FromNimbleFile)
  let parsedRelease = nc.processNimbleRelease(
    pkg,
    VersionTag(v: Version"", c: releaseCommit)
  )
  if parsedRelease.isNil:
    raise newException(IOError, "could not parse Nimble release metadata for: " & $pkg.ondisk)

  let releaseVersion =
    if parsedRelease.version.string.len > 0 and parsedRelease.version.string != "#head":
      parsedRelease.version
    else:
      Version"#head"
  let commitOrigin =
    if releaseVersion == Version"#head":
      FromHead
    else:
      FromNimbleFile
  pkg.originHead =
    if repo.originTip.commit().isEmpty():
      repo.currentCommit
    else:
      repo.originTip.commit()
  if pkg.originHead.isEmpty():
    pkg.originHead = repo.currentCommit

  (
    VersionTag(v: releaseVersion, c: initCommitHash(repo.currentCommit, commitOrigin)).toPkgVer(),
    parsedRelease,
    repo.currentCommit
  )

proc headProjectRelease(
    nc: var NimbleContext;
    pkg: Package
): (PackageVersion, NimbleRelease, CommitHash) =
  var (ver, release, currentCommit) = nc.loadProjectRelease(pkg)
  ver.vtag = VersionTag(v: Version"#head", c: initCommitHash(currentCommit, FromHead))
  release.version = Version"#head"
  (ver, release, currentCommit)

proc isPackagedReleaseCandidate*(ver: PackageVersion): bool =
  not ver.isNil and
    ver.vtag.version.string.len > 0 and
    ver.vtag.version.string[0] != '#'

proc selectLatestPackagedRelease*(
    releases: openArray[(PackageVersion, NimbleRelease)]
): int =
  var sorted = @releases
  sorted.sort(sortVersionsDesc)

  for candidate in sorted:
    if candidate[0].isPackagedReleaseCandidate():
      for i, release in releases:
        if release[0] == candidate[0]:
          return i

  if releases.len > 0:
    for i, release in releases:
      if not release[0].isNil and release[0].vtag.version != Version"#head":
        return i
    return 0

  -1

proc selectedProjectRelease(
    nc: var NimbleContext;
    pkg: var Package;
    releaseMode: ProjectReleaseMode
): (PackageVersion, NimbleRelease, CommitHash) =
  case releaseMode
  of prmHead:
    nc.headProjectRelease(pkg)
  of prmLatestRelease:
    let releaseInfo = nc.loadPackageReleaseInfo(pkg, AllReleases, @[])
    let selectedIdx = selectLatestPackagedRelease(releaseInfo.releases)
    if selectedIdx >= 0:
      let selected = releaseInfo.releases[selectedIdx]
      return (selected[0], selected[1], releaseInfo.currentCommit)

    warn "atlas:package", "no tagged or versioned release found; packaging current head"
    nc.headProjectRelease(pkg)

proc removeUnreferencedArchives(archiveDir: Path; referencedFiles: seq[string]) =
  if not dirExists($archiveDir):
    return

  for kind, path in walkDir($archiveDir):
    if kind != pcFile:
      continue
    let filename = $path.Path.splitPath().tail
    if path.Path.splitFile().ext in [".gz", ".xz", ".tar"] and filename notin referencedFiles:
      removeFile(path)

proc collectProjectTarballs(
    pkg: Package;
    info: PackageInfo;
    ver: PackageVersion;
    release: NimbleRelease;
    archiveDir: Path;
    compressions: openArray[ArchiveCompression]
): JsonNode =
  result = newJObject()
  let label = archiveReleaseLabel(ver, release, ver.vtag.version == Version"#head")
  let rootSubdir = packageRootSubdir(pkg)
  let rootArchiveFiles = collectArchiveFiles(pkg, ver, info, release, rootSubdir)
  let baseName = localArchiveBaseName(info.name)
  let commitSuffix = archiveCommitLabel(ver)
  let hashStem = baseName & "-" & label & "-" & commitSuffix
  let hashTarPath = siblingTempPath(archiveDir / Path(hashStem & ".hash.tar"))
  createDir($archiveDir)

  var contentHash = ""
  try:
    writeTrackedReleaseTar(pkg, ver, hashTarPath, hashStem, rootArchiveFiles)
    contentHash = archiveContentHash(hashTarPath, hashStem & "/")
  finally:
    if fileExists($hashTarPath):
      removeFile($hashTarPath)

  let contentHashSuffix = sanitizeArchiveComponent(contentHash[0 .. 7])
  let archiveStem = baseName & "-" & label & "-" & commitSuffix & "-" & contentHashSuffix
  var referencedFiles: seq[string]
  result[label] = newJArray()

  for compression in compressions:
    let archiveFile = writeTrackedReleaseArchive(
      pkg, ver, archiveDir, archiveStem, rootArchiveFiles, compression, siblingTempPath
    )
    referencedFiles.add archiveFile
    result[label].add initArchiveEntry(label, contentHash, archiveFile, rootSubdir, release)

  removeUnreferencedArchives(archiveDir, referencedFiles)

proc packageProject*(
    projectDir: Path;
    outputDir: Path;
    compressions: seq[ArchiveCompression];
    createTarballs: bool;
    releaseMode: ProjectReleaseMode
) =
  let absProjectDir = projectDir.absolutePath()
  let absOutputDir =
    if outputDir.len > 0:
      outputDir.absolutePath()
    else:
      absProjectDir
  let nimbleFile = findProjectNimbleFile(absProjectDir)
  let tempCacheDir = createTempDir("atlas-package", "cache-").Path

  var ctx = AtlasContext()
  ctx.cacheDir = tempCacheDir
  setContext(ctx)
  project(absProjectDir)
  createDir($absOutputDir)
  defer:
    if dirExists($tempCacheDir):
      removeDir($tempCacheDir)

  var nc = createNimbleContext()
  var pkg = nc.initProjectPackage(absProjectDir, nimbleFile)
  let (ver, release, currentCommit) = nc.selectedProjectRelease(pkg, releaseMode)
  let info = PackageInfo(kind: pkPackage, name: pkg.name, subdir: $pkg.subdir)

  let versions = @[(ver, release)]
  savePackageReleaseCache(pkg, currentCommit, versions)
  let releaseMetadata = parseFile($packageReleaseCachePath(pkg))
  let tarballs =
    if createTarballs:
      collectProjectTarballs(
        pkg,
        info,
        ver,
        release,
        absOutputDir / Path"releases",
        compressions
      )
    else:
      newJNull()

  mergePackageReleaseMetadata(absOutputDir, info, releaseMetadata, tarballs)

proc runAtlasPackageOnce*(
    opts: ProjectPackageCliOptions;
    args: seq[string]
): bool =
  let startedAt = getMonoTime()
  let projectDir =
    if opts.projectDir.len > 0:
      opts.projectDir
    elif args.len >= 1:
      Path(args[0])
    else:
      os.getCurrentDir().Path
  let outputDir =
    if opts.outputDir.len > 0:
      opts.outputDir
    else:
      projectDir

  notice "atlas:package", "project:", $projectDir.absolutePath()
  notice "atlas:package", "output:", $outputDir.absolutePath()
  notice "atlas:package", "compressions:", archiveCompressionNames(opts.compressions).join(",")
  notice "atlas:package", "create tarballs:", $opts.createTarballs
  notice "atlas:package", "release mode:", $opts.releaseMode

  try:
    packageProject(projectDir, outputDir, opts.compressions, opts.createTarballs, opts.releaseMode)
  except CatchableError as e:
    error "atlas:package", e.msg
    return false

  let elapsed = getMonoTime() - startedAt
  notice "atlas:package", "elapsed:", $initDuration(milliseconds = int(elapsed.inMilliseconds))
  true

proc main*(versionString = "unknown") =
  setAtlasVerbosity(Notice)
  var args: seq[string]
  let opts = parseAtlasPackageOptions(commandLineParams(), versionString, args)
  if args.len > 1:
    writeHelp(versionString)
  if not runAtlasPackageOnce(opts, args):
    quit(1)

when isMainModule:
  main()
