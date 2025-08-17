import std/[unittest, os]
suite "A":
  test "a":
    writeFile("ran_a.txt", "ok")
    check true
