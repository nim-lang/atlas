#
#           Atlas Package Cloner
#        (c) Copyright 2026 The Atlas contributors
#

## Helpers for scanning package-registry entries without building a full
## dependency graph.

import std/[strutils]

import basic/[deptypes, nimblecontext, packageinfos, pkgurls]
import dependencies

export packageinfos, deptypes, dependencies

type
  RegistryPackageReleaseInfo* = object
    packageInfo*: PackageInfo
    package*: Package
    releaseInfo*: PackageReleaseInfo

proc registryPackageUrl*(info: PackageInfo): PkgUrl =
  ## Build the canonical Atlas URL for a packages.json package entry.
  if info.kind != pkPackage:
    raise newException(ValueError, "registry package entry is an alias: " & info.name)

  result = createUrlSkipPatterns(info.url, skipDirTest = true)
  result = result.withSubdir(info.subdir)

proc initRegistryPackage*(nc: var NimbleContext; info: PackageInfo): Package =
  ## Convert a packages.json package entry into an Atlas Package.
  let url = nc.putPackageInfo(info)
  result = nc.initPackage(url)

proc loadRegistryPackageReleaseInfo*(
    nc: var NimbleContext;
    info: PackageInfo;
    mode = AllReleases;
    explicitVersions: seq[VersionTag] = @[];
    onClone = DoClone
): RegistryPackageReleaseInfo =
  ## Load release metadata for one package-registry entry.
  ##
  ## This ensures the package is present on disk, then delegates release
  ## discovery and package release cache handling to releaseinfo.nim.
  if info.kind != pkPackage:
    raise newException(ValueError, "registry package entry is an alias: " & info.name)

  var pkg = nc.initRegistryPackage(info)
  nc.loadDependency(pkg, onClone)
  if pkg.state == Error:
    let msg =
      if pkg.errors.len > 0: pkg.errors.join("; ")
      else: "unknown package load error"
    raise newException(ValueError, "cannot load registry package " & info.name & ": " & msg)

  result.packageInfo = info
  result.releaseInfo = nc.loadPackageReleaseInfo(pkg, mode, explicitVersions)
  result.package = pkg
