import std/[os, osproc, streams, strutils, unittest]

import basic/reporters

const RepoRoot = currentSourcePath().parentDir().parentDir()

proc run(command: string; workingDir = ""): tuple[output: string, exitCode: int] =
  execCmdEx(command, workingDir = workingDir,
            options = {poStdErrToStdOut, poUsePath})

proc runProgram(program: string; args: seq[string]; workingDir: string):
    tuple[output: string, exitCode: int] =
  let process = startProcess(program, workingDir = workingDir, args = args,
                             options = {poStdErrToStdOut})
  result.output = process.outputStream.readAll()
  result.exitCode = process.waitForExit()
  process.close()

proc initPackage(dir, name, version: string; requires: openArray[string] = []) =
  createDir(dir)
  var lines = @["version = \"" & version & "\""]
  for requirement in requires:
    lines.add("requires \"" & requirement & "\"")
  writeFile(dir / (name & ".nimble"), lines.join("\n") & "\n")
  writeFile(dir / (name & ".nim"), "discard\n")
  let commands = [
    "git init -b master",
    "git config user.name test-user",
    "git config user.email test@example.com",
    "git add .",
    "git commit -m release-" & version,
    "git tag v" & version
  ]
  for command in commands:
    let res = run(command, dir)
    doAssert res.exitCode == 0, command & "\n" & res.output

proc buildAtlas(outputPath: string) =
  let command = "nim c -d:debug -o:" & outputPath.quoteShell() & " " &
    (RepoRoot / "src/atlas.nim").quoteShell()
  let res = run(command, RepoRoot)
  doAssert res.exitCode == 0, res.output

proc writeConfig(dir: string) =
  createDir(dir / "deps")
  createDir(dir / "deps/.cache")
  writeFile(dir / "deps/.cache/packages.json", "[]\n")
  writeFile(dir / "atlas.config", """
{
  "deps": "deps",
  "nameOverrides": {"$+": "file://./buildGraph/$#"},
  "urlOverrides": {},
  "plugins": "",
  "resolver": "SemVer",
  "graph": null
}
""")

proc createFailureWorkspace(dir: string) =
  createDir(dir)
  createDir(dir / "buildGraph")
  initPackage(dir / "buildGraph/shared", "shared", "1.0.0")
  initPackage(dir / "buildGraph/consumer_a", "consumer_a", "1.0.0",
              ["shared == 1.0.0"])
  initPackage(dir / "buildGraph/consumer_b", "consumer_b", "1.0.0",
              ["shared == 2.0.0"])
  writeFile(dir / "failure.nimble", """
version = "0.1.0"
requires "consumer_a"
requires "consumer_b"
""")
  writeConfig(dir)
  writeFile(dir / "nim.cfg", "sentinel configuration\n")

proc createSuccessWorkspace(dir: string) =
  createDir(dir)
  writeFile(dir / "success.nimble", "version = \"0.1.0\"\n")
  writeConfig(dir)

if paramCount() > 0 and paramStr(1) == "reporter-child":
  resetAtlasReporter()
  setAtlasNoColors(true)
  setAtlasVerbosity(Error)
  for index in 1 .. 7:
    error "source" & $index, "failure " & $index
  atlasWriteErrorSummary()
  stdout.writeLine "count=" & $atlasErrors()
  resetAtlasReporter()
  atlasWriteErrorSummary()
  stdout.writeLine "reset-count=" & $atlasErrors()
  quit 0

suite "CLI failure summary":
  test "failed install preserves config and prints a final failure footer":
    let base = getTempDir() / "atlas_failure_summary"
    if dirExists(base):
      removeDir(base)
    createDir(base)
    defer:
      removeDir(base)

    let atlasBin = base / "atlas"
    buildAtlas(atlasBin)

    let failureDir = base / "failure"
    createFailureWorkspace(failureDir)
    let failed = runProgram(atlasBin,
      @["--colors:off", "--verbosity:normal", "install"], failureDir)

    check failed.exitCode != 0
    check readFile(failureDir / "nim.cfg") == "sentinel configuration\n"
    check "error summary:" in failed.output
    check "dependency conflict:" in failed.output
    let failureSummary = failed.output.find("error summary:")
    check failureSummary >= 0
    check "dependency conflict:" in failed.output[failureSummary .. ^1]
    check failed.output.strip().splitLines()[^1].contains("(atlas) failed")
    check "Activating project deps" notin failed.output
    check "Running build steps" notin failed.output
    check "Wrote nim.cfg!" notin failed.output

    let successDir = base / "success"
    createSuccessWorkspace(successDir)
    let succeeded = runProgram(atlasBin,
      @["--colors:off", "--verbosity:error", "install"], successDir)
    check succeeded.exitCode == 0
    check "error summary:" notin succeeded.output
    let successLine = succeeded.output.strip().splitLines()[^1]
    check "[Success]" in successLine
    check "(atlas) completed successfully" in successLine

  test "reporter summary retains five errors without changing the count":
    let child = runProgram(getAppFilename(), @["reporter-child"], os.getCurrentDir())
    check child.exitCode == 0
    check "error summary: 7 errors reported; showing the last 5" in child.output
    let summary = child.output.find("error summary:")
    check summary >= 0
    let footer = child.output[summary .. ^1]
    check "failure 1" notin footer
    check "failure 2" notin footer
    for index in 3 .. 7:
      check "failure " & $index in footer
    check "count=7" in footer
    check footer.strip().endsWith("reset-count=0")
