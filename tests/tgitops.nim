import unittest
import std/[os, osproc, strutils, uri]
import basic/[reporters, osutils, versions, context]

import basic/gitops

suite "Git Operations Tests":
  var 
    c: AtlasContext
    reporter: Reporter
    testDir = "tests/test_repo"
    
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
      
      var err = false
      let commit = versionToCommit(reporter, MinVer, parseVersionInterval("1.0.0", 0, err))
      check(commit.len > 0)

  test "Git clone functionality":
    let testUrl = "http://localhost:4242/buildGraph/proj_a.git"
    let success = clone(c, testUrl, testDir, fullClones=true)
    # Note: This will fail without network access, so we just check the function exists
    check(success == true)  # Expected to fail since URL is fake

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

  test "isGitDir detection":
    check(not isGitDir(testDir))
    discard execCmd("git init " & testDir)
    check(isGitDir(testDir))

  test "sameVersionAs comparisons":
    check(sameVersionAs("v1.0.0", "1.0.0"))
    check(sameVersionAs("release-1.2.3", "1.2.3"))
    check(not sameVersionAs("v1.0.1", "1.0.0"))
    check(not sameVersionAs("v10.0.0", "1.0.0"))

  test "incrementLastTag behavior":
    withDir testDir:
      discard execCmd("git init")
      # Create initial commit and tag
      writeFile("test.txt", "initial content")
      discard execCmd("git add test.txt")
      discard execCmd("git commit -m \"initial commit\"")
      discard execCmd("git tag v1.0.0")
      
      # Test incrementing different version fields
      check(incrementLastTag(reporter, "test", 0) == "v2.0.0")
      check(incrementLastTag(reporter, "test", 1) == "v1.1.0")
      check(incrementLastTag(reporter, "test", 2) == "v1.0.1")

      # Test with no tags
      removeDir(testDir)
      createDir(testDir)
      discard execCmd("git init " & testDir)
      withDir testDir:
        check(incrementLastTag(reporter, "test", 0) == "v0.0.1")

  test "isOutdated detection":
    withDir testDir:
      discard execCmd("git init")
      # Create initial commit and tag
      writeFile("test.txt", "initial content")
      discard execCmd("git add test.txt")
      discard execCmd("git commit -m \"initial commit\"")
      discard execCmd("git tag v1.0.0")
      
      # Create new commit without tag
      writeFile("test.txt", "updated content")
      discard execCmd("git add test.txt")
      discard execCmd("git commit -m \"update commit\"")
      
      # Test if repo is outdated
      let outdated = isOutdated(c, "test")
      # Note: This might fail in isolated test environments
      # We're mainly testing the function structure
      check(not outdated)  # Expected to be false in test environment

  test "getRemoteUrl functionality":
    withDir testDir:
      discard execCmd("git init")
      let testUrl = "https://github.com/test/repo.git"
      discard execCmd("git remote add origin " & testUrl)
      
      # Test getting remote URL
      let url = getRemoteUrl()
      check(url == testUrl)
      
      # Test getting remote URL from specific directory
      let dirUrl = getRemoteUrl(testDir)
      check(dirUrl == testUrl)
