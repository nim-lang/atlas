#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import reporters

import std / [strutils, os, osproc]

const
  BuilderScriptTemplate* = """

const matchedPattern = $1

template builder(pattern: string; body: untyped) =
  when pattern == matchedPattern:
    body

include $2
"""
  InstallHookTemplate* = """

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

  skipDirs*, skipFiles*, skipExt*, installDirs*, installFiles*,
    installExt*, bin*: seq[string] = @[] ## Nimble metadata.
  requiresData*: seq[string] = @[] ## The package's dependencies.

  foreignDeps*: seq[string] = @[] ## The foreign dependencies. Only
                                  ## exported for 'distros.nim'.

proc requires*(deps: varargs[string]) =
  for d in deps: requiresData.add(d)

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

proc runNimScript*(c: var Reporter; scriptContent: string; name: string) =
  var buildNims = "atlas_build_0.nims"
  var i = 1
  while fileExists(buildNims):
    if i >= 20:
      error c, name, "could not create new: atlas_build_0.nims"
      return
    buildNims = "atlas_build_" & $i & ".nims"
    inc i

  writeFile buildNims, scriptContent

  let cmdLine = "nim e --hints:off " & quoteShell(buildNims)
  if os.execShellCmd(cmdLine) != 0:
    error c, name, "Nimscript failed: " & cmdLine
  else:
    removeFile buildNims

proc runNimScriptInstallHook*(c: var Reporter; nimbleFile, name: string) =
  infoNow c, name, "running install hooks"
  runNimScript c, InstallHookTemplate % [nimbleFile.escape], name

proc runNimScriptBuilder*(c: var Reporter; p: (string, string); name: string) =
  infoNow c, name, "running nimble build scripts"
  runNimScript c, BuilderScriptTemplate % [p[0].escape, p[1].escape], name
