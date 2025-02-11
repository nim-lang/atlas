
import std / [os, strutils, strformat]

proc exec*(cmd: string) =
  if execShellCmd(cmd) != 0:
    quit "FAILURE: " & cmd

template withDir*(dir: string; body: untyped) =
  let old = getCurrentDir()
  try:
    setCurrentDir(dir)
    # echo "WITHDIR: ", dir, " at: ", getCurrentDir()
    body
  finally:
    setCurrentDir(old)

proc getRepoUrls(): seq[string]

proc setupWsIntegration() =
  for repo in getRepoUrls():
    let org = repo.split("/")[^2]
    let name = repo.split("/")[^1]
    echo "REPO: ", "org: ", org, " name: ", name, " url: ", "`" & repo & "`"
    createDir(org)
    withDir(org):
      if not dirExists(name & ".git"):
        exec &"git clone --mirror {repo}"

        withDir(name & ".git"):
          moveFile "hooks"/"post-update.sample", "hooks"/"post-update"
          setFilePermissions("hooks"/"post-update", getFilePermissions("hooks"/"post-update") + {fpUserExec})
          exec "git update-server-info"

when isMainModule:
  withDir("test-repos"):
    # removeDir("ws_integration")
    createDir "ws_integration"
    withDir("ws_integration"):
      setupWsIntegration()

    var repos: seq[tuple[org: string, name: string]]
    template findRepo(item) =
      echo "FIND REPO: ", item
      if item.kind == pcDir and dirExists(item.path / ".git"):
        echo "GIT REPO: ", item
        let paths = item.path.split(DirSep)
        let repo = (org: paths[1], name: paths[2])
        echo "GIT REPO: ", repo
        repos.add(repo)

    # for org in walkDir("ws_integration"):
    #   echo "ORG: ", org
    #   for item in walkDir(org.path):
    #     findRepo(item)

    # echo "============= Setup bare gits ============="
    # for repo in repos:
    #   echo "git repo: ", repo
    # removeDir("ws_integration")
    # createDir("ws_integration")
    # withDir("ws_integration"):
    #   for repo in repos:
    #     createDir(repo.org)
    #   for repo in repos:
    #     echo "REPO: ", repo
    #     withDir(repo.org):
    #       let orig = ".." / ".." / "ws_integration" / repo.org / repo.name
    #       echo "CLONING: ", " cwd: ", getCurrentDir()
    #       exec &"git clone --mirror {orig}"
    #       withDir(repo.name & ".git"):
    #         moveFile "hooks"/"post-update.sample", "hooks"/"post-update"
    #         setFilePermissions("hooks"/"post-update", getFilePermissions("hooks"/"post-update") + {fpUserExec})
    #         exec "git update-server-info"



# test-repos/setups  0.36s user 0.31s system 28% cpu 2.361 total

proc getRepoUrls(): seq[string] =
  let repos = dedent"""
  https://github.com/timotheecour/asynctools
  https://github.com/disruptek/bump
  https://github.com/nim-lang/checksums
  https://github.com/disruptek/cligen
  https://github.com/disruptek/criterion
  https://github.com/disruptek/cutelog
  https://github.com/euantorano/dotenv.nim
  https://github.com/treeform/flatty
  https://github.com/disruptek/frosty
  https://github.com/nim-lang/fusion
  https://github.com/disruptek/grok
  https://github.com/zedeus/httpbeast
  https://github.com/dom96/jester
  https://github.com/treeform/jsony
  https://github.com/karaxnim/karax
  https://github.com/PhilippMDoerner/lowdb
  https://github.com/jangko/msgpack4nim
  https://github.com/disruptek/muffins
  https://github.com/fowlmouth/nake
  https://github.com/xzfc/ndb.nim
  https://github.com/status-im/nim-bearssl
  https://github.com/juancarlospaco/nim-bytes2human
  https://github.com/status-im/nim-chronicles
  https://github.com/status-im/nim-chronos
  https://github.com/status-im/nim-confutils
  https://github.com/status-im/nim-faststreams
  https://github.com/nitely/nim-graphemes
  https://github.com/status-im/nim-http-utils
  https://github.com/status-im/nim-json-serialization
  https://github.com/soasme/nim-markdown
  https://github.com/soasme/nim-mustache
  https://github.com/status-im/nim-ranges
  https://github.com/nitely/nim-regex
  https://github.com/arnetheduck/nim-results
  https://github.com/nitely/nim-segmentation
  https://github.com/status-im/nim-serialization
  https://github.com/status-im/nim-snappy
  https://github.com/status-im/nim-stew
  https://github.com/FedericoCeratto/nim-syslog
  https://github.com/status-im/nim-testutils
  https://github.com/status-im/nim-toml-serialization
  https://github.com/nitely/nim-unicodedb
  https://github.com/nitely/nim-unicodeplus
  https://github.com/status-im/nim-unittest2
  https://github.com/nim-lang/nimble
  https://github.com/cheatfate/nimcrypto
  https://github.com/pietroppeter/nimib
  https://github.com/pietroppeter/nimibook
  https://github.com/GULPF/nimquery
  https://github.com/zedeus/nitter
  https://github.com/moigagoo/norm
  https://github.com/zevv/npeg
  https://github.com/CORDEA/oauth
  https://github.com/nim-lang/packages
  https://github.com/Araq/packedjson
  https://github.com/NimParsers/parsetoml
  https://github.com/nimpylib/pylib
  https://github.com/OpenSystemsLab/q.nim
  https://github.com/zedeus/redis
  https://github.com/zedeus/redpool
  https://github.com/dom96/sass
  https://github.com/nim-lang/sat
  https://github.com/onionhammer/sha1
  https://github.com/narimiran/sorta
  https://github.com/guzba/supersnappy
  https://github.com/OpenSystemsLab/tempfile.nim
  https://github.com/disruptek/testes
  https://github.com/disruptek/testutils
  https://github.com/disruptek/ups
  https://github.com/treeform/ws
  https://github.com/guzba/zippy
  """
  repos.strip(chars={'\n'}).splitLines()