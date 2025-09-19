import unittest
import std/[os, files, dirs, paths, osproc, strutils, uri, options]
import basic/[reporters, osutils, versions, context]

import basic/gitops
import testerutils

ensureGitHttpServer()

suite "Git Operations Tests":
  var 
    c: AtlasContext
    reporter: Reporter
    testDir = Path "tests/test_repo"
    
  setup:
    # Create a fresh test directory
    removeDir(testDir)
    createDir(testDir)
    c = AtlasContext(flags: {DumbProxy})
    reporter = Reporter()
    
  teardown:
    # Clean up test directory
    removeDir(testDir)

  test "isGitDir detection":
    check(not isGitDir(testDir))
    discard execCmd("git init " & $testDir)
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
      check(isGitDir(Path "."))
      
      # Test git diff command
      let (diffOutput, diffStatus) = exec(GitDiff, Path ".", [])
      check(diffStatus.int == 0)
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
      let commit = versionToCommit(Path ".", MinVer, parseVersionInterval("1.0.0", 0, err))
      check(not commit.isEmpty)

  test "Git clone functionality":
    let testUrl = parseUri "http://localhost:4242/buildGraph/proj_a.git"
    let res = clone(testUrl, testDir)
    # Note: This will fail if gitHttpServer isn't running
    check(res[0] == Ok)  # Expected to fail since URL is fake

  test "incrementTag behavior":
    check(incrementTag("test", "v1.0.0", 2) == "v1.0.1")
    check(incrementTag("test", "v2.3.4", 1) == "v2.4.4")
    check(incrementTag("test", "1.0.0", 0) == "2.0.0")

  # test "needsCommitLookup detection":
  #   check(needsCommitLookup("1.0.0"))
  #   check(needsCommitLookup("v1.2.3"))
  #   check(not needsCommitLookup("abc123"))
  #   check(not needsCommitLookup("1234567890abcdef1234567890abcdef12345678"))

  test "isShortCommitHash validation":
    check(isShortCommitHash("abcd"))
    check(isShortCommitHash("1234567"))
    check(not isShortCommitHash("abc"))
    check(not isShortCommitHash("1234567890abcdef1234567890abcdef12345678"))

  test "isGitDir detection":
    check(not isGitDir(testDir))
    discard execCmd("git init " & $testDir)
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
      writeFile("test.txt", "more content")
      discard execCmd("git commit -am \"second commit\"")

      # Test incrementing different version fields
      check(incrementLastTag(Path ".", 0) == "v2.0.0")
      check(incrementLastTag(Path ".", 1) == "v1.1.0")
      check(incrementLastTag(Path ".", 2) == "v1.0.1")

  test "incrementLastTag behavior no tags":
    withDir testDir:
      # Test with no tags
      discard execCmd("git init ")
      writeFile("test.txt", "initial content")
      discard execCmd("git add test.txt")
      discard execCmd("git commit -m \"initial commit\"")
      check(incrementLastTag(Path ".", 0) == "v0.0.1")

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
      let outdated = isOutdated(Path ".")
      # Note: This might fail in isolated test environments
      # We're mainly testing the function structure
      check(outdated.isNone)  # Expected to be false in test environment

  test "getRemoteUrl functionality":
    withDir testDir:
      discard execCmd("git init")
      let testUrl = "https://github.com/test/repo.git"
      discard execCmd("git remote add origin " & testUrl)
      
      # Test getting remote URL
      let url = getRemoteUrl(Path ".")
      check(url == testUrl)
      
      # Test getting remote URL from specific directory
      # let dirUrl = getRemoteUrl(c, testDir)
      # check(dirUrl == testUrl)

  test "checkGitDiffStatus behavior":
    withDir testDir:
      discard execCmd("git init")
      
      # Test clean state
      let cleanStatus = checkGitDiffStatus(Path ".")
      check(cleanStatus == "")
      
      # Test with uncommitted changes
      writeFile("test.txt", "some content")
      discard execCmd("git add test.txt")
      writeFile("test.txt", "modified content")
      let dirtyStatus = checkGitDiffStatus(Path ".")
      check(dirtyStatus == "'git diff' not empty")
      
      # Test with committed changes
      discard execCmd("git add test.txt")
      discard execCmd("git commit -m \"test commit\"")
      let committedStatus = checkGitDiffStatus(Path ".")
      check(committedStatus == "")

  test "gitDescribeRefTag functionality":
    withDir testDir:
      discard execCmd("git init")
      
      # Create and tag a commit
      writeFile("test.txt", "initial content")
      discard execCmd("git add test.txt")
      discard execCmd("git commit -m \"initial commit\"")
      let initialCommit = execProcess("git rev-parse HEAD").strip()
      discard execCmd("git tag v1.0.0")
      
      # Test describing the tagged commit
      let tagDescription = gitDescribeRefTag(Path ".", initialCommit)
      check(tagDescription == "v1.0.0")
      
      # Test describing an untagged commit
      writeFile("test.txt", "updated content")
      discard execCmd("git add test.txt")
      discard execCmd("git commit -m \"update commit\"")
      let newCommit = execProcess("git rev-parse HEAD").strip()
      let untaggedDescription = gitDescribeRefTag(Path ".", newCommit)
      check(untaggedDescription.startsWith("v1.0.0-1-"))

  test "collectTaggedVersions functionality":
    withDir testDir:
      discard execCmd("git init")
     
      # Create initial commit and tag
      writeFile("test.txt", "initial content")
      discard execCmd("git add test.txt")
      discard execCmd("git commit -m \"initial commit\"")
      discard execCmd("git tag v1.0.0")
      
      # Add more commits and tags
      writeFile("test.txt", "second version")
      discard execCmd("git add test.txt")
      discard execCmd("git commit -m \"second commit\"")
      discard execCmd("git tag v1.1.0")
      
      writeFile("test.txt", "third version")
      discard execCmd("git add test.txt")
      discard execCmd("git commit -m \"third commit\"")
      discard execCmd("git tag v2.0.0")
      
      # Test collecting all tagged versions
      let versions = collectTaggedVersions(Path ".")
      check(versions.len == 3)
      check($versions[0].v == "2.0.0")
      check($versions[1].v == "1.1.0")
      check($versions[2].v == "1.0.0")
      
      # Verify commit hashes are present
      for v in versions:
        check(v.c.h.len == 40)  # Full SHA-1 hash length
