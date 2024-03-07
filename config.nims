
task build, "Build local atlas":
  exec "nim c -d:debug -o:./atlas src/atlas.nim"

task unitTests, "Runs unit tests":
  exec "nim c -d:debug -r tests/unittests.nim"

task tester, "Runs integration tests":
  exec "nim c -d:debug -r tests/tester.nim"

task buildRelease, "Build release":
  exec "nimble install -y sat"
  when defined(macosx):
    let x86Args = "\"-target x86_64-apple-macos11 -arch x86_64 -DARCH=x86_64\""
    exec "nim c -d:release --passC:" & x86args & " --passL:" & x86args & " -o:./atlas_x86_64 src/atlas.nim"
    let armArgs = "\"-target arm64-apple-macos11 -arch arm64 -DARCH=arm64\""
    exec "nim c -d:release --passC:" & armArgs & " --passL:" & armArgs & " -o:./atlas_arm64 src/atlas.nim"
    exec "lipo -create -output atlas atlas_x86_64 atlas_arm64"
    rmFile("atlas_x86_64")
    rmFile("atlas_arm64")
  else:
    let os = getEnv("OS")
    let arch = getEnv("ARCH")
    if os != "" and arch != "":
      if os == "windows":
        exec "nim c -d:release -d:mingw -o:./atlas src/atlas.nim"
      else:
        exec "nim c -d:release --cpu:" & arch & " --os:" & os & " -o:./atlas src/atlas.nim"
    else:
      exec "nim c -d:release -o:./atlas src/atlas.nim"

task test, "Runs all tests":
  # unitTestsTask() # tester runs both
  testerTask()

--path:"$nim"