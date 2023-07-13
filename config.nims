
task build, "Build local atlas":
  exec "nim c -o:./atlas src/atlas.nim"

task unitTests, "Runs unit tests":
  exec "nim c -d:debug -r tests/unittests.nim"

task tester, "Runs integration tests":
  exec "nim c -d:debug -r tests/tester.nim"

task test, "Runs all tests":
  # unitTestsTask() # tester runs both
  testerTask()

task release, "Build local atlas":

  when defined(windows):
    exec "nim c --passL:-static -o:./atlas src/atlas.nim"
    let os = "windows"
  elif defined(macosx):
    exec "nim c -o:./atlas src/atlas.nim"
    let os = "macos"
  elif defined(linux):
    exec "nim c --passL:-static -o:./atlas src/atlas.nim"
    let os = "linux"
  else:
    quit 1, "unknown os"

  when defined x86:
    let arch = "x86"
  elif defined amd64:
    let arch = "amd64"
  elif defined arm:
    let arch = "arm"
  elif defined arm64:
    let arch = "arm64"
  else:
    quit 1, "unknown arch"

  let name = "atlas_" & os & "_" & arch & ".tar.gz"
  exec "tar -cjf " & name & " atlas"
