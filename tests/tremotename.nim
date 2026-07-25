import std/[strutils, unittest]

import basic/gitops

suite "remoteNameFromGitUrl":
  test "empty input returns empty":
    check remoteNameFromGitUrl("") == ""

  test "github url produces dotted remote name":
    check remoteNameFromGitUrl("https://github.com/user/repo") ==
      "repo.user.github.com"

  test "gitlab url produces dotted remote name":
    check remoteNameFromGitUrl("https://gitlab.com/user/repo") ==
      "repo.user.gitlab.com"

  test "trailing .git is stripped":
    check remoteNameFromGitUrl("https://github.com/user/repo.git") ==
      "repo.user.github.com"

  test "ssh git@ url is parsed":
    check remoteNameFromGitUrl("git@github.com:user/repo.git") ==
      "repo.user.github.com"

  test "sourcehut url with tilde user strips the tilde":
    let name = remoteNameFromGitUrl("https://git.sr.ht/~bptato/chame")
    check name == "chame.bptato.git.sr.ht"
    check not name.contains("~")

  test "sourcehut url tilde user is general":
    let name = remoteNameFromGitUrl("https://git.sr.ht/~user/repo")
    check name == "repo.user.git.sr.ht"
    check not name.contains("~")

  test "generated remote name only uses git-safe characters":
    # Git refnames forbid: control chars, space, ~ ^ : ? * [ \
    # and may not begin/end with a dot or contain "..".
    const forbidden = {'~', '^', ':', '?', '*', '[', '\\', ' '}
    for url in [
      "https://github.com/user/repo",
      "https://gitlab.com/user/repo",
      "https://git.sr.ht/~bptato/chame",
      "https://git.sr.ht/~user/repo",
      "git@git.sr.ht:~bptato/chame"
    ]:
      let name = remoteNameFromGitUrl(url)
      checkpoint "url: " & url & " -> " & name
      check name.len > 0
      for c in forbidden:
        check not name.contains(c)
      check not name.startsWith(".")
      check not name.endsWith(".")
      check ".." notin name
