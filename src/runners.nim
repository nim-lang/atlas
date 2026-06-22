#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import basic/context
import nimble/nimscriptexec

import std/[os, paths, strutils]

const
  BuilderScriptTemplate* = """

const matchedPattern = $1

template builder(pattern: string; body: untyped) =
  when pattern == matchedPattern:
    body

include $2
"""
  InstallHookTemplate* = """

import std/tables

var
  packageName* = ""    ## Set this to the package name. It
                       ## is usually not required to do that, nims' filename is
                       ## the default.
  version*: string     ## The package's version.
  author*: string      ## The package's author.
  description*: string ## The package's description.
  license*: string     ## The package's license.
  srcDir*: string      ## The package's source directory.
  binDir*: string      ## The package's binary directory.
  backend*: string     ## The package's backend.
  hasBin*: bool        ## Whether the package has binaries.

  skipDirs*, skipFiles*, skipExt*, installDirs*, installFiles*,
    installExt*, bin*: seq[string] = @[] ## Nimble metadata.
  namedBin*: Table[string, string] ## Named package binaries.
  requiresData*: seq[string] = @[] ## The package's dependencies.

  foreignDeps*: seq[string] = @[] ## The foreign dependencies. Only
                                  ## exported for 'distros.nim'.

proc requires*(deps: varargs[string]) =
  for d in deps: requiresData.add(d)

template feature*(names: varargs[string]; body: untyped) =
  discard

template after(name, body: untyped) =
  when astToStr(name) == "install":
    body

template before(name, body: untyped) =
  when astToStr(name) == "install":
    body

proc getPkgDir*(): string = getCurrentDir()
proc thisDir*(): string = getCurrentDir()

include $1

"""

proc runNimScript*(scriptContent: string; name: string) =
  let options = initNimScriptRunOptions(
    "atlas_build_" & $getCurrentProcessId(),
    cleanup = CleanupOnSuccess,
    candidateLimit = 20
  )
  try:
    let res = runTempNimScript(scriptContent, options)
    if res.exitCode != 0:
      error name, "Nimscript failed: " & res.commandLine
  except IOError, OSError:
    error name, getCurrentExceptionMsg()

proc runNimScriptInstallHook*(nimbleFile: Path, name: string) =
  notice name, "running install hooks"
  runNimScript InstallHookTemplate % [escape($(nimbleFile))], name

proc runNimScriptBuilder*(p: (string, string); name: string) =
  notice name, "running nimble build scripts"
  runNimScript BuilderScriptTemplate % [p[0].escape, p[1].escape], name
