import std/[os, paths, unittest]
import basic/[context, packageinfos]
import atlas
import pkgsearch

template withDir(dir: string; body: untyped) =
  let old = os.getCurrentDir()
  try:
    os.setCurrentDir(dir)
    body
  finally:
    os.setCurrentDir(old)

suite "search":
  withDir "tests":
    if fileExists("atlas.config"):
      removeFile("atlas.config")
    if dirExists("deps"):
      removeDir("deps")
    test "runs without project":
      setContext AtlasContext()
      atlasRun(@["search", "balls"])
      check project() == Path("")
      check not fileExists("atlas.config")
      check not dirExists("deps")

    test "skips aliases":
      let pkgs = @[
        PackageInfo(kind: pkAlias, name: "jwt", alias: "jwtpkg"),
        PackageInfo(kind: pkPackage, name: "jwtpkg", url: "https://example.com/jwtpkg",
          license: "", downloadMethod: "git", description: "jwt package",
          tags: @["jwt"])
      ]
      let candidates = determineCandidates(pkgs, @["jwt"])
      check candidates[0].len == 0
      check candidates[1].len == 1
