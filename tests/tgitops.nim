import unittest
import std/[os, osproc, strutils, uri]
import basic/[reporters, osutils, versions, context]

suite "Git Operations Tests":
  var 
    c: AtlasContext
    reporter: Reporter
    testDir = "test_repo"
    
  setup:
    # Create a fresh test directory
    removeDir(testDir)
    createDir(testDir)
    c = AtlasContext(dumbProxy: false)
    reporter = Reporter()
    
  teardown:
    # Clean up test directory
    removeDir(testDir)

  test "isGitDir detection":
    check(not isGitDir(testDir))
    discard execCmd("git init " & testDir)
    check(isGitDir(testDir))

  test "sameVersionAs comparisons":
    check(sameVersionAs("v1.0.0", "1.0.0"))
    check(sameVersionAs("release-1.2.3", "1.2.3"))
    check(not sameVersionAs("v1.0.1", "1.0.0"))
    check(not sameVersionAs("v10.0.0", "1.0.0"))

  test "extractVersion from strings":
    check(extractVersion("v1.0.0") == "1.0.0")
    check(extractVersion("release-2.3.4") == "2.3.4")
    check(extractVersion("prefix_5.0.1_suffix") == "5.0.1_suffix")

  test "Git command execution":
    # Initialize test repo
    withDir testDir:
      discard execCmd("git init")
      check(isGitDir("."))
      
      # Test git diff command
      let (diffOutput, diffStatus) = exec(reporter, GitDiff, [])
      check(diffStatus == 0)
      check(diffOutput.len == 0)

  test "Version to commit resolution":
    withDir testDir:
      discard execCmd("git init")
      # Create and tag a test commit
      writeFile("test.txt", "test content")
      discard execCmd("git add test.txt")
      discard execCmd("git commit -m \"test commit\"")
      discard execCmd("git tag v1.0.0")
      
      let commit = versionToCommit(reporter, MinVer, parseVersionInterval("1.0.0"))
      check(commit.len > 0)

  test "Git clone functionality":
    let testUrl = "https://github.com/test/repo.git"
    let success = clone(c, testUrl, testDir)
    # Note: This will fail without network access, so we just check the function exists
    check(success == false)  # Expected to fail since URL is fake

  test "incrementTag behavior":
    check(incrementTag(reporter, "test", "v1.0.0", 2) == "v1.0.1")
    check(incrementTag(reporter, "test", "v2.3.4", 1) == "v2.4.4")
    check(incrementTag(reporter, "test", "1.0.0", 0) == "2.0.0")

  test "needsCommitLookup detection":
    check(needsCommitLookup("1.0.0"))
    check(needsCommitLookup("v1.2.3"))
    check(not needsCommitLookup("abc123"))
    check(not needsCommitLookup("1234567890abcdef1234567890abcdef12345678"))

  test "isShortCommitHash validation":
    check(isShortCommitHash("abcd"))
    check(isShortCommitHash("1234567"))
    check(not isShortCommitHash("abc"))
    check(not isShortCommitHash("1234567890abcdef1234567890abcdef12345678"))

when isMainModule:
  main()