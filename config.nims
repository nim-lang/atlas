
task unitTests, "Runs unit tests":
  exec "nim c -r tests/tests.nim"

task tester, "Runs integration tests":
  exec "nim c -r tests/tester.nim"

task test, "Runs all tests":
  unitTestsTask()
  testerTask()
