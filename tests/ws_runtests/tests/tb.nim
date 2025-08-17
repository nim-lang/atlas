import std/[unittest, os]
suite "B":
  test "b":
    writeFile("ran_b.txt", "ok")
    check true
