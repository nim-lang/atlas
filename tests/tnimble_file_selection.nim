import std/[assertions, dirs, osproc, paths, tempfiles, uri]

import basic/[dependencycache, deptypes, gitops, pkgurls]

proc runGit(repo: Path; args: string) =
  let command = "git -C " & quoteShell($repo) & " " & args
  doAssert execCmd(command) == 0, command

block package_root_nimble_file_precedes_nested_examples:
  let repo = Path(createTempDir("atlas-nimble-selection-", ""))
  defer:
    removeDir(repo)

  createDir(repo / Path"examples/client")
  createDir(repo / Path"examples/server")
  writeFile($(repo / Path"synthetic.nimble"), "version = \"1.0.0\"\n")
  writeFile($(repo / Path"examples/client/demo.nimble"), "version = \"1.0.0\"\n")
  writeFile($(repo / Path"examples/server/demo.nimble"), "version = \"1.0.0\"\n")

  runGit(repo, "init")
  runGit(repo, "config user.name atlas-test")
  runGit(repo, "config user.email atlas-test@example.invalid")
  runGit(repo, "add .")
  runGit(repo, "commit -m fixture")

  let pkg = Package(
    url: toPkgUriRaw(parseUri("https://example.invalid/example/nim-synthetic")),
    ondisk: repo
  )
  let sources = findGitNimbleFiles(pkg, currentGitCommit(repo))

  doAssert sources.len == 1
  doAssert sources[0].path == Path"synthetic.nimble"
