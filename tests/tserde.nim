import std/[unittest, json, jsonutils, sets, tables, os, times, paths, sequtils]
import basic/[context, sattypes, pkgurls, deptypes, nimblecontext, dependencycache, remotecache]
import basic/[deptypesjson, versions]
import confighandler
import releaseinfo

proc p(s: string): VersionInterval =
  var err = false
  result = parseVersionInterval(s, 0, err)
  # assert not err

suite "json serde":
  setup:
    var nc = createUnfilledNimbleContext()
    nc.put("foobar", toPkgUriRaw(parseUri "https://github.com/nimble-test/foobar.git"))
    nc.put("proj_a", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_a"))

  test "pkg url":
    let upkg = nc.createUrl("foobar")
    let jn = toJson(upkg)
    var upkg2: PkgUrl
    upkg2.fromJson(jn)
    check upkg == upkg2
    echo "upkg2: ", $(upkg2)

    let url2 = nc.createUrl("https://github.com/nimble-test/foobar")
    check url2.projectName() == "foobar"


  test "pkg url, version interval":
    let upkg = nc.createUrl("foobar")
    let jn = toJson((upkg, p"1.0.0"))
    var upkg2: (PkgUrl, VersionInterval)
    upkg2.fromJson(jn)
    check upkg2[0] == upkg

  test "json serde ordered table":
    var table: OrderedTable[PkgUrl, Package]
    let url = nc.createUrl("foobar")
    var pkg = Package(url: url)
    table[url] = pkg
    let jn = toJson(table)
    var table2: OrderedTable[PkgUrl, Package]
    table2.fromJson(jn)
    # note this will fail because the url doesn't use nimble context
    # check table == table2

  test "json dep graph":
    var graph = DepGraph()
    let url = nc.createUrl("foobar")
    var pkg = Package(url: url)
    graph.root = pkg
    graph.pkgs[url] = pkg
    let url2 = nc.createUrl("proj_a")
    var pkg2 = Package(url: url2)
    graph.pkgs[url2] = pkg2

    let jn = toJsonGraph(graph)
    var graph2 = loadJson(nc, jn)

    echo "root: ", graph.root.repr
    echo "root2: ", graph2.root.repr

    echo "root2.url: ", $(graph2.root.url), " project name: ", graph2.root.url.projectName()

    check graph.root.hash() == graph2.root.hash()

    check graph.pkgs[url].hash() == graph2.pkgs[url].hash()
    check graph.pkgs[url2].hash() == graph2.pkgs[url2].hash()

  test "json serde nimble release":
    let release = NimbleRelease(version: Version"1.0.0", requirements: @[(nc.createUrl("foobar"), p"1.0.0")])
    let jnRelease = toJsonHook(release)
    echo "jnRelease: ", pretty(jnRelease)
    check "name" notin jnRelease
    check "author" notin jnRelease
    check "description" notin jnRelease
    check "license" notin jnRelease
    check "srcDir" notin jnRelease
    check "binDir" notin jnRelease
    check "skipDirs" notin jnRelease
    check "skipFiles" notin jnRelease
    check "skipExt" notin jnRelease
    check "installDirs" notin jnRelease
    check "installFiles" notin jnRelease
    check "installExt" notin jnRelease
    check "bin" notin jnRelease
    check "namedBin" notin jnRelease
    check "backend" notin jnRelease
    check "hasBin" notin jnRelease
    check "err" notin jnRelease
    check "reqs" notin jnRelease
    check "features" notin jnRelease
    check "featureVars" notin jnRelease
    check "reqsByFeatures" notin jnRelease
    var versions: OrderedTable[PackageVersion, NimbleRelease]
    versions[VersionTag(v: Version"1.0.0").toPkgVer] = release
    let jnVersions = toJsonHook(versions, ToJsonOptions(enumMode: joptEnumString))
    check "name" notin jnVersions[0][1]
    check "author" notin jnVersions[0][1]
    check "description" notin jnVersions[0][1]
    check "license" notin jnVersions[0][1]
    check "srcDir" notin jnVersions[0][1]
    check "binDir" notin jnVersions[0][1]
    check "skipDirs" notin jnVersions[0][1]
    check "skipFiles" notin jnVersions[0][1]
    check "skipExt" notin jnVersions[0][1]
    check "installDirs" notin jnVersions[0][1]
    check "installFiles" notin jnVersions[0][1]
    check "installExt" notin jnVersions[0][1]
    check "bin" notin jnVersions[0][1]
    check "namedBin" notin jnVersions[0][1]
    check "backend" notin jnVersions[0][1]
    check "hasBin" notin jnVersions[0][1]
    check "err" notin jnVersions[0][1]
    check "reqs" notin jnVersions[0][1]
    check "features" notin jnVersions[0][1]
    check "featureVars" notin jnVersions[0][1]
    check "reqsByFeatures" notin jnVersions[0][1]
    var release2: NimbleRelease
    fromJsonHook(release2, jnRelease)
    check release == release2

  test "package release cache writes version and names":
    let oldCtx = context()
    let ws = Path(getTempDir()) / Path("atlas_release_cache_" & $int(epochTime()))
    defer:
      setContext(oldCtx)
      if dirExists($ws):
        removeDir($ws)

    setContext(AtlasContext(projectDir: ws, depsDir: Path"deps"))
    let url = nc.createUrl("foobar")
    let current = initCommitHash("24870f48c40da2146ce12ff1e675e6e7b9748355", FromNone)
    let pkg = Package(url: url, originHead: current)
    let release = NimbleRelease(version: Version"1.0.0", requirements: @[], status: Normal)
    savePackageReleaseCache(
      pkg,
      current,
      @[(VersionTag(v: Version"1.0.0", c: current).toPkgVer, release)]
    )
    let cache = parseFile($packageReleaseCachePath(pkg))
    check cache["cv"].getInt() == PackageReleaseCacheVersion
    check "cacheVersion" notin cache
    check cache["name"].getStr() == "foobar"
    check cache["fqn"].getStr() == "foobar.nimble-test.github.com"
    check "url" notin cache
    check cache["current"].getStr() == "24870f48c40da2146ce12ff1e675e6e7b9748355"
    check "shortName" notin cache
    check "nim" notin cache
    check "includeTagsAndNimbleCommits" notin cache
    check "nimbleCommitsMax" notin cache
    check "name" notin cache["releases"][0]
    check "version" notin cache["releases"][0]
    check "status" notin cache["releases"][0]
    check cache["releases"][0].pairs().toSeq()[0][0] == "v"

    setContext(AtlasContext(
      projectDir: ws,
      depsDir: Path"deps",
      flags: {IncludeTagsAndNimbleCommits, NimbleCommitsMax}
    ))
    savePackageReleaseCache(
      pkg,
      current,
      @[(VersionTag(v: Version"1.0.0", c: current).toPkgVer, release)]
    )
    let cacheWithFlags = parseFile($packageReleaseCachePath(pkg))
    check cacheWithFlags["includeTagsAndNimbleCommits"].getBool()
    check cacheWithFlags["nimbleCommitsMax"].getBool()

  test "package release cache uses url identity and subdir":
    let oldCtx = context()
    let ws = Path(getTempDir()) / Path("atlas_registry_release_cache_" & $int(epochTime()))
    defer:
      setContext(oldCtx)
      if dirExists($ws):
        removeDir($ws)

    setContext(AtlasContext(projectDir: ws, depsDir: Path"deps"))
    let repoUrl = toPkgUriRaw(parseUri "https://github.com/nimble-test/monorepo")
    let rootUrl = repoUrl
    let subdirUrl = repoUrl.withSubdir("bindings/nim")
    let current = initCommitHash("24870f48c40da2146ce12ff1e675e6e7b9748355", FromNone)
    let pkgRoot = Package(url: rootUrl, originHead: current)
    let pkgSubdir = Package(
      url: subdirUrl,
      originHead: current,
      subdir: subdirUrl.subdir()
    )
    let release = NimbleRelease(version: Version"1.0.0", requirements: @[], status: Normal)
    let version = VersionTag(v: Version"1.0.0", c: current).toPkgVer

    check rootUrl.cloneUri() == subdirUrl.cloneUri()
    check rootUrl.projectName() == "monorepo"
    check subdirUrl.projectName() == "nim"
    check subdirUrl.shortName() == "monorepo"
    savePackageReleaseCache(pkgRoot, current, @[(version, release)])
    savePackageReleaseCache(pkgSubdir, current, @[(version, release)])

    let rootPath = packageReleaseCachePath(pkgRoot)
    let subdirPath = packageReleaseCachePath(pkgSubdir)
    check rootPath != subdirPath
    check fileExists($rootPath)
    check fileExists($subdirPath)

    let cache = parseFile($subdirPath)
    check "shortName" notin cache
    check "url" notin cache
    check cache["subdir"].getStr() == "bindings/nim"
    check "registryName" notin cache
    check "registrySubdir" notin cache

    var entries: seq[PackageReleaseCacheEntry]
    check loadPackageReleaseCache(pkgSubdir, current, entries)
    check entries.len == 1
    entries.setLen(0)
    check not loadPackageReleaseCache(
      Package(url: repoUrl.withSubdir("bindings/other"), originHead: current),
      current,
      entries
    )

  test "forge package release info loads cache without current checkout":
    let oldCtx = context()
    let ws = Path(getTempDir()) / Path("atlas_forge_release_cache_" & $int(epochTime()))
    defer:
      setContext(oldCtx)
      if dirExists($ws):
        removeDir($ws)

    setContext(AtlasContext(projectDir: ws, depsDir: Path"deps"))
    let url = nc.createUrl("foobar")
    let head = initCommitHash("24870f48c40da2146ce12ff1e675e6e7b9748355", FromHead)
    var pkg = Package(
      url: url,
      originHead: head,
      name: "foobar",
      isForgePackage: true
    )
    let release = NimbleRelease(version: Version"1.0.0", requirements: @[], status: Normal)
    savePackageReleaseCache(
      pkg,
      head,
      @[(VersionTag(v: Version"1.0.0", c: head).toPkgVer, release)]
    )

    var nc2 = createUnfilledNimbleContext()
    let info = nc2.loadPackageReleaseInfo(pkg, AllReleases, @[])
    check info.loadedFromCache
    check not info.repoError
    check info.currentCommit.isEmpty()
    check info.releases.len == 1

  test "package release cache rejects old cache version":
    let oldCtx = context()
    let ws = Path(getTempDir()) / Path("atlas_stale_release_cache_" & $int(epochTime()))
    defer:
      setContext(oldCtx)
      if dirExists($ws):
        removeDir($ws)

    setContext(AtlasContext(projectDir: ws, depsDir: Path"deps"))
    let url = nc.createUrl("foobar")
    let current = initCommitHash("24870f48c40da2146ce12ff1e675e6e7b9748355", FromNone)
    let pkg = Package(url: url, originHead: current)
    let release = NimbleRelease(version: Version"1.0.0", requirements: @[], status: Normal)
    let version = VersionTag(v: Version"1.0.0", c: current).toPkgVer

    savePackageReleaseCache(pkg, current, @[(version, release)])
    let cachePath = packageReleaseCachePath(pkg)
    var staleCache = parseFile($cachePath)
    staleCache["cv"] = %1
    writeFile($cachePath, pretty(staleCache))

    var entries: seq[PackageReleaseCacheEntry]
    check not loadPackageReleaseCache(pkg, current, entries)
    check entries.len == 0

    savePackageReleaseCache(pkg, current, @[(version, release)])
    let regeneratedCache = parseFile($cachePath)
    check regeneratedCache["cv"].getInt() == PackageReleaseCacheVersion

  test "package release cache loads compact unversioned tag entries":
    let oldCtx = context()
    let ws = Path(getTempDir()) / Path("atlas_unversioned_release_cache_" & $int(epochTime()))
    defer:
      setContext(oldCtx)
      if dirExists($ws):
        removeDir($ws)

    setContext(AtlasContext(projectDir: ws, depsDir: Path"deps"))
    let url = nc.createUrl("foobar")
    let current = initCommitHash("24870f48c40da2146ce12ff1e675e6e7b9748355", FromNone)
    let unversioned = initCommitHash("cbbd23c289ac624e2137752f893697d7dd784b17", FromNone)
    let pkg = Package(url: url, originHead: current)
    createDir($cachesDirectory())
    writeFile($packageReleaseCachePath(pkg), pretty(%*{
      "cv": PackageReleaseCacheVersion,
      "name": "foobar",
      "head": current.h,
      "current": current.h,
      "releases": [
        {
          "v": "~@cbbd23c289ac624e2137752f893697d7dd784b17",
          "r": []
        }
      ]
    }))

    var entries: seq[PackageReleaseCacheEntry]
    check loadPackageReleaseCache(pkg, current, entries)
    check entries.len == 1
    if entries.len == 1:
      check entries[0].vtag.version == Version""
      check entries[0].vtag.commit == unversioned

  test "shared release cache copies into project cache":
    let oldCtx = context()
    let ws = Path(getTempDir()) / Path("atlas_shared_release_cache_" & $int(epochTime()))
    let mirror = ws / Path"mirror"
    defer:
      setContext(oldCtx)
      if dirExists($ws):
        removeDir($ws)

    setContext(AtlasContext(projectDir: ws, depsDir: Path"deps"))
    let url = nc.createUrl("foobar")
    let pkg = Package(url: url, name: "foobar", isOfficial: true)
    let sourcePath = sharedPackageReleasePath("foobar", mirror)
    let headPath = sharedPackageReleaseHeadPath("foobar", mirror)
    createDir($sourcePath.parentDir())
    writeFile($sourcePath, pretty(%*{
      "cv": PackageReleaseCacheVersion,
      "name": "foobar",
      "fqn": "foobar.nimble-test.github.com",
      "head": "24870f48c40da2146ce12ff1e675e6e7b9748355",
      "releases": [
        {
          "v": {
            "v": "1.0.0",
            "c": "24870f48c40da2146ce12ff1e675e6e7b9748355"
          }
        }
      ]
    }))
    writeFile($headPath, pretty(%*{
      "v": "#head@ffffffffffffffffffffffffffffffffffffffff",
      "b": "headbin",
      "p": ["foobar-head"]
    }))

    check copySharedReleaseCache(pkg, mirror)
    let cachePath = packageReleaseCachePath(pkg)
    check fileExists($cachePath)
    let cache = parseFile($cachePath)
    check cache["name"].getStr() == "foobar"
    check cache["releases"].len == 2
    check cache["releases"][1]["v"].getStr() == "#head@ffffffffffffffffffffffffffffffffffffffff"
    check cache["releases"][1]["b"].getStr() == "headbin"
    check cache["releases"][1]["p"][0].getStr() == "foobar-head"

  test "json serde nimble release requirements use combined strings":
    let starDep = createUrlSkipPatterns("https://github.com/nimble-test/mummy", skipDirTest = true)
    let jwtDep = createUrlSkipPatterns("https://github.com/nimble-test/jwt", skipDirTest = true)
    let urlDep = createUrlSkipPatterns(
      "https://github.com/yglukhov/bearssl_pkey_decoder",
      skipDirTest = true
    )
    let release = NimbleRelease(
      version: Version"1.0.0",
      status: Normal,
      requirements: @[(starDep, p"*"), (jwtDep, p">= 0.3"), (urlDep, p"#546f8d9b")]
    )

    let jnRelease = toJsonHook(release)
    check "requirements" notin jnRelease
    check "reqs" notin jnRelease
    check jnRelease["r"][0].getStr() == "gh:nimble-test/mummy"
    check jnRelease["r"][1].getStr() == "gh:nimble-test/jwt >= 0.3"
    check jnRelease["r"][2].getStr() == "gh:yglukhov/bearssl_pkey_decoder #546f8d9b"

    var release2: NimbleRelease
    fromJsonHook(release2, jnRelease)
    check release2.requirements == release.requirements

  test "json serde nimble release feature requirements use combined strings":
    let starDep = createUrlSkipPatterns("https://github.com/nimble-test/mummy", skipDirTest = true)
    let jwtDep = createUrlSkipPatterns("https://github.com/nimble-test/jwt", skipDirTest = true)
    let urlDep = createUrlSkipPatterns(
      "https://github.com/yglukhov/bearssl_pkey_decoder",
      skipDirTest = true
    )
    let release = NimbleRelease(
      version: Version"1.0.0",
      status: Normal,
      requirements: @[],
      features: {
        "dev": @[(starDep, p"*"), (jwtDep, p">= 0.3"), (urlDep, p"#546f8d9b")]
      }.toTable()
    )

    let jnRelease = toJsonHook(release)
    check "features" notin jnRelease
    check jnRelease["f"]["dev"][0].getStr() == "gh:nimble-test/mummy"
    check jnRelease["f"]["dev"][1].getStr() == "gh:nimble-test/jwt >= 0.3"
    check jnRelease["f"]["dev"][2].getStr() == "gh:yglukhov/bearssl_pkey_decoder #546f8d9b"

    var release2: NimbleRelease
    fromJsonHook(release2, jnRelease)
    check release2.features == release.features

  test "package release cache lifts stable metadata":
    let oldCtx = context()
    let ws = Path(getTempDir()) / Path("atlas_release_cache_metadata_" & $int(epochTime()))
    defer:
      setContext(oldCtx)
      if dirExists($ws):
        removeDir($ws)

    setContext(AtlasContext(projectDir: ws, depsDir: Path"deps"))
    let url = nc.createUrl("foobar")
    let current = initCommitHash("24870f48c40da2146ce12ff1e675e6e7b9748355", FromNone)
    let pkg = Package(url: url, originHead: current)
    let v1 = VersionTag(v: Version"1.0.0", c: current).toPkgVer
    let v2 = VersionTag(v: Version"2.0.0", c: current).toPkgVer
    let v3 = VersionTag(v: Version"3.0.0", c: current).toPkgVer
    let r1 = NimbleRelease(
      version: Version"1.0.0",
      requirements: @[],
      status: Normal,
      nimVersion: Version"2.0.0",
      author: "Atlas Tester",
      description: "Test package",
      license: "MIT",
      srcDir: Path"src",
      binDir: Path"bin",
      skipDirs: @["tests"],
      skipFiles: @["config.local"],
      skipExt: @["tmp"],
      installDirs: @["assets"],
      installFiles: @["README.md"],
      installExt: @["nim"],
      bin: @["main", "worker"],
      namedBin: {"main": "myfoo"}.toTable,
      backend: "c",
      hasBin: true
    )
    let r2 = NimbleRelease(
      version: Version"2.0.0",
      requirements: @[],
      status: Normal,
      author: "Atlas Tester",
      description: "Test package",
      license: "MIT",
      srcDir: Path"",
      binDir: Path"",
      skipDirs: @["tests"],
      skipFiles: @[],
      skipExt: @["tmp"],
      installDirs: @["assets"],
      installFiles: @["README.md"],
      installExt: @["nim"],
      bin: @[],
      namedBin: initTable[string, string](),
      backend: "",
      hasBin: false
    )
    let r3 = NimbleRelease(
      version: Version"3.0.0",
      requirements: @[],
      status: Normal,
      nimVersion: Version"2.2.0",
      author: "Other Tester",
      description: "Test package",
      license: "MIT",
      srcDir: Path"lib",
      binDir: Path"dist",
      skipDirs: @["docs"],
      skipFiles: @["config.local"],
      skipExt: @["tmp"],
      installDirs: @["assets"],
      installFiles: @[],
      installExt: @["nim"],
      bin: @["tool"],
      namedBin: {"tool": "other"}.toTable,
      backend: "cpp",
      hasBin: true
    )

    savePackageReleaseCache(pkg, current, @[(v1, r1), (v2, r2), (v3, r3)])
    let cache = parseFile($packageReleaseCachePath(pkg))
    check cache["author"].getStr() == "Atlas Tester"
    check cache["description"].getStr() == "Test package"
    check "by" notin cache
    check "desc" notin cache
    check cache["license"].getStr() == "MIT"
    check cache["nim"].getStr() == "2.0.0"
    check cache["srcDir"].getStr() == "src"
    check cache["binDir"].getStr() == "bin"
    check cache["skipDirs"][0].getStr() == "tests"
    check cache["skipFiles"][0].getStr() == "config.local"
    check cache["skipExt"][0].getStr() == "tmp"
    check cache["installDirs"][0].getStr() == "assets"
    check cache["installFiles"][0].getStr() == "README.md"
    check cache["installExt"][0].getStr() == "nim"
    check cache["bin"].len == 2
    check cache["namedBin"]["main"].getStr() == "myfoo"
    check cache["backend"].getStr() == "c"
    check "hasBin" notin cache
    check "author" notin cache["releases"][0]
    check "description" notin cache["releases"][0]
    check "license" notin cache["releases"][0]
    check "name" notin cache["releases"][0]
    check "m" notin cache["releases"][0]
    check "s" notin cache["releases"][0]
    check "b" notin cache["releases"][0]
    check "x" notin cache["releases"][0]
    check "y" notin cache["releases"][0]
    check "z" notin cache["releases"][0]
    check "i" notin cache["releases"][0]
    check "j" notin cache["releases"][0]
    check "k" notin cache["releases"][0]
    check "p" notin cache["releases"][0]
    check "o" notin cache["releases"][0]
    check "e" notin cache["releases"][0]
    check "g" notin cache["releases"][0]
    check "author" notin cache["releases"][1]
    check "m" notin cache["releases"][1]
    check "s" notin cache["releases"][1]
    check cache["releases"][1]["b"].getStr() == ""
    check cache["releases"][1]["y"].len == 0
    check cache["releases"][1]["p"].len == 0
    check cache["releases"][1]["o"].len == 0
    check cache["releases"][1]["e"].getStr() == ""
    check "g" notin cache["releases"][1]
    check cache["releases"][2]["a"].getStr() == "Other Tester"
    check cache["releases"][2]["m"].getStr() == "2.2.0"
    check cache["releases"][2]["s"].getStr() == "lib"
    check cache["releases"][2]["b"].getStr() == "dist"
    check cache["releases"][2]["x"][0].getStr() == "docs"
    check cache["releases"][2]["j"].len == 0
    check cache["releases"][2]["p"][0].getStr() == "tool"
    check cache["releases"][2]["o"]["tool"].getStr() == "other"
    check cache["releases"][2]["e"].getStr() == "cpp"
    check "description" notin cache["releases"][2]
    check "license" notin cache["releases"][2]

    var entries: seq[PackageReleaseCacheEntry]
    check loadPackageReleaseCache(pkg, current, entries)
    check entries.len == 3
    check entries[0].release.author == "Atlas Tester"
    check entries[1].release.author == "Atlas Tester"
    check entries[2].release.author == "Other Tester"
    check entries[0].release.description == "Test package"
    check entries[2].release.description == "Test package"
    check entries[0].release.license == "MIT"
    check entries[2].release.license == "MIT"
    check entries[0].release.nimVersion == Version"2.0.0"
    check entries[1].release.nimVersion == Version"2.0.0"
    check entries[2].release.nimVersion == Version"2.2.0"
    check entries[0].release.srcDir == Path"src"
    check entries[1].release.srcDir == Path"src"
    check entries[2].release.srcDir == Path"lib"
    check entries[0].release.binDir == Path"bin"
    check entries[1].release.binDir == Path""
    check entries[2].release.binDir == Path"dist"
    check entries[0].release.skipDirs == @["tests"]
    check entries[1].release.skipDirs == @["tests"]
    check entries[2].release.skipDirs == @["docs"]
    check entries[0].release.skipFiles == @["config.local"]
    check entries[1].release.skipFiles.len == 0
    check entries[2].release.installFiles.len == 0
    check entries[0].release.installExt == @["nim"]
    check entries[0].release.bin == @["main", "worker"]
    check entries[1].release.bin.len == 0
    check entries[2].release.bin == @["tool"]
    check entries[0].release.namedBin["main"] == "myfoo"
    check entries[1].release.namedBin.len == 0
    check entries[2].release.namedBin["tool"] == "other"
    check entries[0].release.backend == "c"
    check entries[1].release.backend == ""
    check entries[2].release.backend == "cpp"
    check entries[0].release.hasBin
    check not entries[1].release.hasBin
    check entries[2].release.hasBin

  test "activation cache writes bin metadata":
    let url = nc.createUrl("foobar")
    let commit = initCommitHash("24870f48c40da2146ce12ff1e675e6e7b9748355", FromNone)
    let version = VersionTag(v: Version"1.0.0", c: commit).toPkgVer
    let release = NimbleRelease(
      version: Version"1.0.0",
      name: "foobar",
      author: "Atlas Tester",
      description: "Test package",
      license: "MIT",
      srcDir: Path"src",
      skipDirs: @["tests"],
      skipFiles: @["config.local"],
      skipExt: @["tmp"],
      installDirs: @["assets"],
      installFiles: @["README.md"],
      installExt: @["nim"],
      bin: @["main", "worker"],
      namedBin: {"main": "myfoo"}.toTable,
      backend: "c",
      hasBin: true
    )
    var pkg = Package(
      url: url,
      active: true,
      activeVersion: version,
      activeFeatures: @["testing"],
      ondisk: Path"deps/foobar"
    )
    pkg.versions[version] = release
    var graph = DepGraph(root: pkg)
    graph.pkgs[url] = pkg

    let cache = toActivationCache(graph)
    check cache.packages.len == 1
    check cache.packages[0].bin == @["main", "worker"]
    check cache.packages[0].namedBin["main"] == "myfoo"
    check cache.packages[0].name == "foobar"
    check cache.packages[0].author == "Atlas Tester"
    check cache.packages[0].description == "Test package"
    check cache.packages[0].license == "MIT"
    check cache.packages[0].backend == "c"
    check cache.packages[0].hasBin

    let jn = toJson(cache, ToJsonOptions(enumMode: joptEnumString))
    check jn["packages"][0]["name"].getStr() == "foobar"
    check jn["packages"][0]["author"].getStr() == "Atlas Tester"
    check jn["packages"][0]["description"].getStr() == "Test package"
    check jn["packages"][0]["license"].getStr() == "MIT"
    check jn["packages"][0]["bin"].len == 2
    check jn["packages"][0]["namedBin"]["main"].getStr() == "myfoo"
    check jn["packages"][0]["backend"].getStr() == "c"
    check jn["packages"][0]["hasBin"].getBool()

    var cache2: ActivationCache
    cache2.fromJson(jn, Joptions(allowMissingKeys: true, allowExtraKeys: true))
    check cache2.packages.len == 1
    check cache2.packages[0].bin == @["main", "worker"]
    check cache2.packages[0].namedBin["main"] == "myfoo"
    check cache2.packages[0].name == "foobar"
    check cache2.packages[0].author == "Atlas Tester"
    check cache2.packages[0].description == "Test package"
    check cache2.packages[0].license == "MIT"
    check cache2.packages[0].backend == "c"
    check cache2.packages[0].hasBin

  test "json serde nimble release with features":
    let featureUrl = nc.createUrl("proj_a")
    var reqsByFeatures: Table[PkgUrl, HashSet[string]]
    reqsByFeatures[featureUrl] = ["testing"].toHashSet
    let release = NimbleRelease(
      name: "foobar",
      version: Version"1.0.0",
      author: "Atlas Tester",
      description: "Test package",
      license: "MIT",
      nimVersion: Version"2.0.0",
      status: Normal,
      requirements: @[(nc.createUrl("foobar"), p"1.0.0")],
      srcDir: Path"src",
      binDir: Path"bin",
      skipDirs: @["tests"],
      skipFiles: @["config.local"],
      skipExt: @["tmp"],
      installDirs: @["assets"],
      installFiles: @["README.md"],
      installExt: @["nim"],
      bin: @["main", "worker"],
      namedBin: {"main": "myfoo"}.toTable,
      backend: "c",
      hasBin: true,
      err: "broken",
      features: {"testing": @[(featureUrl, p">= 1.0.0")]}.toTable,
      reqsByFeatures: reqsByFeatures,
      featureVars: {"testing": VarId(3)}.toTable
    )
    let jnRelease = toJsonHook(release)
    check jnRelease["n"].getStr() == "foobar"
    check jnRelease["a"].getStr() == "Atlas Tester"
    check jnRelease["d"].getStr() == "Test package"
    check jnRelease["l"].getStr() == "MIT"
    check jnRelease["s"].getStr() == "src"
    check jnRelease["b"].getStr() == "bin"
    check jnRelease["x"][0].getStr() == "tests"
    check jnRelease["y"][0].getStr() == "config.local"
    check jnRelease["z"][0].getStr() == "tmp"
    check jnRelease["i"][0].getStr() == "assets"
    check jnRelease["j"][0].getStr() == "README.md"
    check jnRelease["k"][0].getStr() == "nim"
    check jnRelease["p"].len == 2
    check jnRelease["o"]["main"].getStr() == "myfoo"
    check jnRelease["e"].getStr() == "c"
    check jnRelease["g"].getBool()
    check jnRelease["m"].getStr() == "2.0.0"
    check "nimVersion" notin jnRelease
    check jnRelease["E"].getStr() == "broken"
    check jnRelease.hasKey("f")
    check "features" notin jnRelease
    check jnRelease.hasKey("F")
    check jnRelease.hasKey("q")
    var release2: NimbleRelease
    fromJsonHook(release2, jnRelease)

    check release2.name == release.name
    check release2.version == release.version
    check release2.author == release.author
    check release2.description == release.description
    check release2.license == release.license
    check release2.nimVersion == release.nimVersion
    check release2.requirements == release.requirements
    check release2.srcDir == release.srcDir
    check release2.binDir == release.binDir
    check release2.skipDirs == release.skipDirs
    check release2.skipFiles == release.skipFiles
    check release2.skipExt == release.skipExt
    check release2.installDirs == release.installDirs
    check release2.installFiles == release.installFiles
    check release2.installExt == release.installExt
    check release2.bin == release.bin
    check release2.namedBin == release.namedBin
    check release2.backend == release.backend
    check release2.hasBin == release.hasBin
    check release2.err == release.err
    check release2.features == release.features
    check release2.reqsByFeatures == release.reqsByFeatures
    check release2.featureVars == release.featureVars

  test "json serde version interval":

    let interval = p"1.0.0"
    let jn = toJson(interval)
    var interval2 = VersionInterval()
    interval2.fromJson(jn)
    check interval == interval2

    let query = p">= 1.2 & < 1.4"
    let jn2 = toJson(query)
    var query2 = VersionInterval()
    query2.fromJson(jn2)
    check query == query2

  test "var ids":
    let var1 = VarId(1)
    let jn = toJson(var1)
    var var2 = VarId(0)
    var2.fromJson(jn)
    check var1.int == var2.int

  test "path":
    let path1 = Path("test.nim")
    let jn = toJson(path1)
    var path2: Path
    path2.fromJson(jn)
    check path1 == path2

  test "test version tag and commit hash str":
    let c1 = initCommitHash("24870f48c40da2146ce12ff1e675e6e7b9748355", FromNone)
    let v1 = VersionTag(v: Version"#head", c: c1)

    check $c1 == "24870f48c40da2146ce12ff1e675e6e7b9748355"
    check $v1 == "#head@24870f48"

    let v2 = toVersionTag("#head@24870f48c40da2146ce12ff1e675e6e7b9748355")
    check $v2 == "#head@24870f48"
    check repr(v2) == "#head@24870f48c40da2146ce12ff1e675e6e7b9748355"

    let v3 = toVersionTag("#head@-")
    check v3.v.string == "#head"
    check v3.c.h == ""
    check $v3 == "#head@-"

    let v4 = VersionTag(v: Version"#head", c: initCommitHash("", FromGitTag))
    check v4 == v3

    let jn = toJson(v1)
    var v5 = VersionTag()
    v5.fromJson(jn)
    check v5 == v1
    echo "v5: ", repr(v5)

    let jn2 = toJson(c1)
    var c2 = CommitHash()
    c2.fromJson(jn2)
    check c2 == c1
    echo "c2: ", repr(c2)

    let jn3 = toJson(v3)
    var v6 = VersionTag()
    v6.fromJson(jn3)
    check v6 == v3
    echo "v6: ", repr(v6)

    let jn4 = toJson(v4)
    var v7 = VersionTag()
    v7.fromJson(jn4)
    check v7 == v4
    echo "v7: ", repr(v7)

  test "test empty version tag":
    let v8 = VersionTag()
    echo "v8: ", repr(v8)
    let jn = toJson(v8)

    var v9 = VersionTag()
    v9.fromJson(jn)
    check v9 == v8
    echo "v9: ", repr(v9)
    
  
