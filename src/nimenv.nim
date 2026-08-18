#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Implementation of the "Nim virtual environment" (`atlas env`) feature.
import std/[files, dirs, strscans, os, strutils, uri, json, options,
            httpclient, tempfiles, osproc, streams]
import basic/[context, osutils, versions, gitops, httpclientutils, sha256]

const NimReleasesUrl* = "https://nim-lang.org/releases.json"

type
  NimEnvMode* {.pure.} = enum
    Auto, Binary, Source

  NimBinaryRelease* = object
    url*, digest*: string

when defined(windows):
  const
    BatchFile = """
@echo off
if not defined _OLD_NIM_PATH set "_OLD_NIM_PATH=%PATH%"
if not defined _OLD_NIM_PROMPT set "_OLD_NIM_PROMPT=%PROMPT%"
set "PATH=$1;%PATH%"
set "PROMPT=(nim $2) %PROMPT%"
doskey deactivate=if defined _OLD_NIM_PATH (set "PATH=%%_OLD_NIM_PATH%%" ^& set "PROMPT=%%_OLD_NIM_PROMPT%%" ^& set "_OLD_NIM_PATH=" ^& set "_OLD_NIM_PROMPT=") else (echo Not in an activated Nim environment)
"""
    PowerShellFile = """
# Save original PATH and prompt if not already in a nim env
if (-not $$env:_OLD_NIM_PATH) {
    $$env:_OLD_NIM_PATH = $$env:PATH
    $$global:_OLD_NIM_PROMPT = (Get-Item Function:\prompt).ScriptBlock
}

$$env:PATH = "$1;$$env:PATH"

function global:prompt {
    "(nim $2) " + (& $$global:_OLD_NIM_PROMPT)
}

function global:deactivate {
    if ($$env:_OLD_NIM_PATH) {
        $$env:PATH = $$env:_OLD_NIM_PATH
        Remove-Item Env:\_OLD_NIM_PATH
        Set-Item Function:\prompt $$global:_OLD_NIM_PROMPT
        Remove-Variable -Name _OLD_NIM_PROMPT -Scope Global
        Remove-Item Function:\deactivate
    } else {
        Write-Host "Not in an activated Nim environment"
    }
}
"""
else:
  const
    ShellFile* = """
# Save original PATH and PS1 if not already in a nim env
if [ -z "$${_OLD_NIM_PATH+x}" ]; then
    export _OLD_NIM_PATH="$$PATH"
    export _OLD_NIM_PS1="$${PS1:-}"
fi

export PATH=$1:$$PATH
export PS1="(nim $2) $${PS1:-}"

deactivate() {
    if [ -n "$${_OLD_NIM_PATH+x}" ]; then
        export PATH="$$_OLD_NIM_PATH"
        export PS1="$$_OLD_NIM_PS1"
        unset _OLD_NIM_PATH
        unset _OLD_NIM_PS1
        unset -f deactivate
    else
        echo "Not in an activated Nim environment"
    fi
}
"""

const
  ActivationFile* = when defined(windows): Path "activate.bat" else: Path "activate.sh"
  NimBuildScript* = when defined(windows): "build_all.bat" else: "build_all.sh"

template withDir*(dir: string; body: untyped) =
  let old = paths.getCurrentDir()
  try:
    setCurrentDir(dir)
    # echo "WITHDIR: ", dir, " at: ", getCurrentDir()
    body
  finally:
    setCurrentDir(old)

proc infoAboutActivation(nimDest: Path, nimVersion: string) =
  when defined(windows):
    info nimDest, "RUN (cmd)\nnim-" & nimVersion & "\\activate.bat\nRUN (PowerShell)\n. nim-" & nimVersion & "\\activate.ps1"
  else:
    info nimDest, "RUN\nsource nim-" & nimVersion & "/activate.sh"

proc releasePlatform*(osName, cpuName: string): string =
  let osPart =
    case osName.normalize()
    of "linux": "linux"
    of "macosx", "macos", "darwin": "macosx"
    of "windows", "win32": "windows"
    else: ""
  let cpuPart =
    case cpuName.normalize()
    of "amd64", "x8664", "x64": "x64"
    of "i386", "i686", "x86", "x32": "x32"
    of "arm64", "aarch64": "arm64"
    of "arm", "armv7", "armv7l": "armv7l"
    else: ""

  if osPart == "linux" and cpuPart in ["x64", "x32", "arm64", "armv7l"]:
    result = osPart & "_" & cpuPart
  elif osPart == "macosx" and cpuPart in ["x64", "arm64"]:
    result = osPart & "_" & cpuPart
  elif osPart == "windows" and cpuPart in ["x64", "x32"]:
    result = osPart & "_" & cpuPart

proc hostReleasePlatform*(): string =
  releasePlatform(hostOS, hostCPU)

proc jsonString(node: JsonNode; key: string): string =
  if node.kind == JObject and node.hasKey(key) and node[key].kind == JString:
    result = node[key].getStr()

proc findBinaryRelease*(manifest, nimVersion, platform: string): Option[NimBinaryRelease] =
  let root = parseJson(manifest)
  if root.kind != JObject:
    raise newException(ValueError, "Nim release index is not a JSON object")
  if not root.hasKey(nimVersion):
    return

  let release = root[nimVersion]
  if release.kind != JObject:
    raise newException(ValueError, "Nim release entry is not a JSON object")
  if not release.hasKey(platform):
    return

  let artifact = release[platform]
  var url = artifact.jsonString("nimlang_url")
  if url.len == 0:
    url = artifact.jsonString("github_url")
  if url.len == 0:
    raise newException(ValueError, "Nim binary release has no download URL")
  result = some(NimBinaryRelease(url: url, digest: artifact.jsonString("digest")))

proc digestMatches*(path, expected: string): bool =
  let parts = expected.split(':', maxsplit = 1)
  if parts.len != 2 or parts[0].cmpIgnoreCase("sha256") != 0:
    raise newException(ValueError, "unsupported release digest: " & expected)
  result = sha256File(path).cmpIgnoreCase(parts[1]) == 0

proc runCommand(command: string; args: openArray[string]): tuple[output: string, exitCode: int] =
  let process = startProcess(command, args = args,
                             options = {poUsePath, poStdErrToStdOut})
  try:
    result.output = process.outputStream.readAll()
    result.exitCode = process.waitForExit()
  finally:
    process.close()

proc writeActivation(nimDest: Path; nimVersion: string) =
  let nimDir = depsDir() / nimDest
  let pathEntry = nimDir / Path"bin"
  when defined(windows):
    let winPath = replace($pathEntry, '/', '\\')
    writeFile $(nimDir / Path"activate.bat"), BatchFile % [winPath, nimVersion]
    writeFile $(nimDir / Path"activate.ps1"), PowerShellFile % [winPath, nimVersion]
  else:
    writeFile $(nimDir / Path"activate.sh"), ShellFile % [$pathEntry, nimVersion]

proc removeBundledAtlas(nimDir: Path) =
  let binDir = nimDir / Path"bin"
  if cmpPaths(getAppDir(), $binDir) != 0:
    let bundledAtlas = binDir / Path("atlas".addFileExt(ExeExt))
    if fileExists($bundledAtlas):
      removeFile($bundledAtlas)

proc removeBootstrapSources(nimDir: Path) =
  for kind, path in walkDir($nimDir):
    if kind == pcDir and path.lastPathComponent().startsWith("csources"):
      let cCode = Path(path) / Path"c_code"
      if dirExists($cCode):
        removeDir($cCode)

proc setupNimFromSource(nimVersion: string; nimDest: Path; keepCsources: bool): bool =
  let url = "https://github.com/nim-lang/nim"
  withDir $depsDir():
    let (status, msg) = gitops.clone(url.parseUri(), nimDest)
    if status != Ok:
      error nimDest, "failed to clone: " & url & " (" & $status & "): " & msg
      return false
    discard gitops.fetchRemoteTags(nimDest)

  let nimDir = depsDir() / nimDest
  if nimVersion != "devel":
    let query = createQueryEq(Version(nimVersion))
    let commit = versionToCommit(nimDir, algo = SemVer, query = query)
    if commit.isEmpty():
      error nimDest, "cannot resolve version to a commit"
      return false
    if not checkoutGitCommit(nimDir, commit):
      error nimDest, "cannot check out version " & nimVersion
      return false

  info nimDest, "building Nim from source with " & NimBuildScript
  let command = when defined(windows): "cmd" else: "sh"
  let args = when defined(windows): @["/c", NimBuildScript] else: @[NimBuildScript]
  var buildResult: tuple[output: string, exitCode: int]
  try:
    withDir $nimDir:
      buildResult = runCommand(command, args)
  except OSError as e:
    error nimDest, "cannot run " & NimBuildScript & ": " & e.msg
    return false
  let (output, exitCode) = buildResult
  if exitCode != 0:
    error nimDest, "failed: " & NimBuildScript & "\n" & output
    return false

  removeBundledAtlas(nimDir)
  if not keepCsources:
    removeBootstrapSources(nimDir)
  result = true

proc extractBinaryArchive(archive, destination: string): tuple[output: string, exitCode: int] =
  when defined(windows):
    if findExe("tar").len > 0:
      try:
        result = runCommand("tar", ["-xf", archive, "-C", destination])
        if result.exitCode == 0:
          return
      except OSError as e:
        result = (e.msg, 1)

    let tarOutput = result.output
    try:
      result = runCommand("powershell", ["-NoProfile", "-NonInteractive", "-Command",
        "Expand-Archive", "-LiteralPath", archive, "-DestinationPath", destination, "-Force"])
      if result.exitCode != 0 and tarOutput.len > 0:
        result.output = tarOutput & "\n" & result.output
    except OSError as e:
      result = (tarOutput & "\n" & e.msg, 1)
  else:
    try:
      result = runCommand("tar", ["-xJf", archive, "-C", destination])
    except OSError as e:
      result = (e.msg, 1)

proc setupNimFromBinary(nimVersion: string; nimDest: Path;
                        release: NimBinaryRelease): bool =
  let tempDir = createTempDir(".atlas-nim-", "", $depsDir())
  defer:
    if dirExists(tempDir):
      removeDir(tempDir)

  let archiveExt = when defined(windows): ".zip" else: ".tar.xz"
  let archive = tempDir / ("nim-" & nimVersion & archiveExt)
  let extractDir = tempDir / "extract"
  createDir(extractDir)

  info nimDest, "downloading " & release.url
  let client = newAtlasHttpClient(acceptGzip = false)
  try:
    client.downloadFile(release.url, archive)
  except CatchableError as e:
    error nimDest, "cannot download binary release: " & e.msg
    return false
  finally:
    client.close()

  if release.digest.len > 0:
    try:
      if not digestMatches(archive, release.digest):
        error nimDest, "binary release checksum does not match " & release.digest
        return false
    except CatchableError as e:
      error nimDest, "cannot verify binary release: " & e.msg
      return false
  else:
    warn nimDest, "binary release has no checksum in " & NimReleasesUrl

  let (output, exitCode) = extractBinaryArchive(archive, extractDir)
  if exitCode != 0:
    error nimDest, "cannot extract binary release\n" & output
    return false

  let extracted = Path(extractDir) / nimDest
  let nimExe = extracted / Path"bin" / Path("nim".addFileExt(ExeExt))
  if not dirExists($extracted) or not fileExists($nimExe):
    error nimDest, "binary release has an unexpected directory layout"
    return false

  moveDir($extracted, $(depsDir() / nimDest))
  removeBundledAtlas(depsDir() / nimDest)
  result = true

proc fetchBinaryRelease(nimVersion: string): Option[NimBinaryRelease] =
  let platform = hostReleasePlatform()
  if platform.len == 0:
    return

  let client = newAtlasHttpClient(acceptGzip = false)
  try:
    result = findBinaryRelease(client.getContent(NimReleasesUrl), nimVersion, platform)
  finally:
    client.close()

proc addNimEnvToGitHubPath*(nimVersion: string): bool =
  let nimDest = Path("nim-" & nimVersion)
  let binDir = (depsDir() / nimDest / Path"bin").absolutePath()
  if not dirExists($binDir):
    error nimDest, "cannot add missing Nim bin directory to GITHUB_PATH"
    return false

  let githubPath = getEnv("GITHUB_PATH")
  if githubPath.len == 0:
    error nimDest, "GITHUB_PATH environment variable is not set"
    return false
  if '\n' in $binDir or '\r' in $binDir:
    error nimDest, "cannot add a path containing a newline to GITHUB_PATH"
    return false

  try:
    var file = open(githubPath, fmAppend)
    defer:
      file.close()
    file.write($binDir & "\n")
  except CatchableError as e:
    error nimDest, "cannot append to GITHUB_PATH: " & e.msg
    return false

  info nimDest, "added " & $binDir & " to GITHUB_PATH"
  result = true

proc setupNimEnv*(nimVersion: string; keepCsources: bool;
                  mode = NimEnvMode.Auto): bool {.discardable.} =
  let nimDest = Path("nim-" & nimVersion)
  if dirExists(depsDir() / nimDest):
    if not fileExists(depsDir() / nimDest / ActivationFile):
      info nimDest, "already exists; remove or rename and try again"
    else:
      infoAboutActivation nimDest, nimVersion
      result = true
    return

  if nimVersion != "devel":
    var major, minor, patch: int
    if not scanf(nimVersion, "$i.$i.$i", major, minor, patch):
      error "nim", "cannot parse version requirement"
      return

  var installed = false
  if mode != NimEnvMode.Source and nimVersion != "devel":
    let release =
      try:
        fetchBinaryRelease(nimVersion)
      except CatchableError as e:
        error nimDest, "cannot read " & NimReleasesUrl & ": " & e.msg
        return
    if release.isSome():
      installed = setupNimFromBinary(nimVersion, nimDest, release.get())
      if not installed:
        return
    elif mode == NimEnvMode.Binary:
      let platform = hostReleasePlatform()
      let detail = if platform.len > 0: " for " & platform else: " for this platform"
      error nimDest, "no binary release is available" & detail
      return

  if mode == NimEnvMode.Binary and nimVersion == "devel":
    error nimDest, "binary releases are not available for devel"
    return

  if not installed:
    installed = setupNimFromSource(nimVersion, nimDest, keepCsources)

  if installed:
    writeActivation(nimDest, nimVersion)
    infoAboutActivation nimDest, nimVersion
  result = installed
