
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
    exec "nim c --passL:-static -o:./atlas.exe src/atlas.nim"
  elif defined(macosx):
    exec "nim c -o:./atlas src/atlas.nim"
  elif defined(linux):
    exec "nim c --passL:-static -o:./atlas src/atlas.nim"
  else:
    quit 1, "unknown os"
