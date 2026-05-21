import std/[dirs, os, osproc, paths, unittest]
import basic/gitprogresspool

proc runGit(args: string; cwd: Path) =
  let cmd = "git -C " & quoteShell($cwd) & " " & args
  check execShellCmd(cmd) == 0

proc createLocalRepo(root: Path; name: string): Path =
  result = root / Path(name & "-src")
  createDir(result)
  runGit("init", result)
  runGit("config user.email atlas@example.invalid", result)
  runGit("config user.name Atlas", result)
  writeFile($(result / Path(name & ".nimble")), "version = \"0.1.0\"\n")
  writeFile($(result / Path"README.md"), "# " & name & "\n")
  runGit("add .", result)
  runGit("commit -m init", result)

suite "git progress pool":
  test "parse git progress lines":
    var snapshot = GitProgressSnapshot(percent: -1)
    check parseGitProgressLine("Receiving objects:  42% (124/295), 1.23 MiB", snapshot)
    check snapshot.phase == "receiving objects"
    check snapshot.percent == 42

    check parseGitProgressLine("remote: Counting objects: 100% (5/5), done.", snapshot)
    check snapshot.phase == "counting objects"
    check snapshot.percent == 100

    check not parseGitProgressLine("Cloning into 'pkg'...", snapshot)

  test "run progress jobs clones local repos":
    when defined(posix):
      let root = (getTempDir() / "atlas-gitprogresspool-test").Path.absolutePath()
      if dirExists(root):
        removeDir(root)
      createDir(root)
      defer:
        if dirExists(root):
          removeDir(root)

      let alphaSrc = createLocalRepo(root, "alpha")
      let betaSrc = createLocalRepo(root, "beta")
      let jobs = @[
        GitProgressJob(
          label: "alpha",
          command: "git",
          args: @[
            "clone",
            "--progress",
            $alphaSrc,
            $(root / Path"alpha")
          ]
        ),
        GitProgressJob(
          label: "beta",
          command: "git",
          args: @[
            "clone",
            "--progress",
            $betaSrc,
            $(root / Path"beta")
          ]
        )
      ]

      let results = runGitProgressJobs(
        jobs,
        title = "test:clone",
        workerCount = DefaultGitProgressWorkers,
        showProgress = true
      )

      check results.len == 2
      check results[0].label == "alpha"
      check results[0].exitCode == 0
      check dirExists(root / Path"alpha")
      check fileExists($(root / Path"alpha" / Path"alpha.nimble"))
      check results[0].progress.percent == 100

      check results[1].label == "beta"
      check results[1].exitCode == 0
      check dirExists(root / Path"beta")
      check fileExists($(root / Path"beta" / Path"beta.nimble"))
      check results[1].progress.percent == 100
    else:
      skip()
