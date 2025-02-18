#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Configuration handling.

import std / [strutils, os, streams, json]
import basic/[versions, context, reporters, compiledpatterns, parserequires]

proc parseOverridesFile(filename: Path) =
  const Separator = " -> "
  let path = context().workspace / filename
  var f: File
  if open(f, $path):
    info "overrides", "loading file: " & $path
    context().flags.incl UsesOverrides
    try:
      var lineCount = 1
      for line in lines($path):
        let splitPos = line.find(Separator)
        if splitPos >= 0 and line[0] != '#':
          let key = line.substr(0, splitPos-1)
          let val = line.substr(splitPos+len(Separator))
          if key.len == 0 or val.len == 0:
            error path, "key/value must not be empty"
          let err = context().overrides.addPattern(key, val)
          if err.len > 0:
            error path, "(" & $lineCount & "): " & err
        else:
          discard "ignore the line"
        inc lineCount
    finally:
      close f
  else:
    error path, "cannot open: " & $path

proc readPluginsDir(dir: Path) =
  for k, f in walkDir($(context().workspace / dir)):
    if k == pcFile and f.endsWith(".nims"):
      extractPluginInfo f, context().plugins

type
  JsonConfig = object
    deps: string
    overrides: string
    plugins: string
    resolver: string
    graph: JsonNode

proc writeDefaultConfigFile*() =
  let config = JsonConfig(deps: $context().origDepsDir, resolver: $SemVer, graph: newJNull())
  let configFile = context().workspace / AtlasWorkspace
  writeFile($configFile, pretty %*config)

proc readConfig*() =
  let configFile = context().workspace / AtlasWorkspace
  var f = newFileStream($configFile, fmRead)
  if f == nil:
    error configFile, "cannot open: " & $configFile
    return

  let j = parseJson(f, $configFile)
  try:
    let m = j.to(JsonConfig)
    if m.deps.len > 0:
      context().origDepsDir = m.deps.Path
    if m.overrides.len > 0:
      context().overridesFile = m.overrides.Path
      parseOverridesFile(m.overrides.Path)
    if m.resolver.len > 0:
      try:
        context().defaultAlgo = parseEnum[ResolutionAlgorithm](m.resolver)
      except ValueError:
        warn configFile, "ignored unknown resolver: " & m.resolver
    if m.plugins.len > 0:
      context().pluginsFile = m.plugins.Path
      readPluginsDir(m.plugins.Path)
  finally:
    close f

proc writeConfig*(graph: JsonNode) =
  let config = JsonConfig(deps: $context().origDepsDir, overrides: $context().overridesFile,
    plugins: $context().pluginsFile, resolver: $context().defaultAlgo,
    graph: graph)
  let configFile = context().workspace / AtlasWorkspace
  writeFile($configFile, pretty %*config)
