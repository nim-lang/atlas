#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Configuration handling.

import std / [strutils, os, streams, json]
import versions, context, reporters, compiledpatterns, parse_requires

proc parseOverridesFile(c: var AtlasContext; filename: string) =
  const Separator = " -> "
  let path = c.workspace / filename
  var f: File
  if open(f, path):
    info c, "overrides", "loading file: " & path
    c.flags.incl UsesOverrides
    try:
      var lineCount = 1
      for line in lines(path):
        let splitPos = line.find(Separator)
        if splitPos >= 0 and line[0] != '#':
          let key = line.substr(0, splitPos-1)
          let val = line.substr(splitPos+len(Separator))
          if key.len == 0 or val.len == 0:
            error c, path, "key/value must not be empty"
          let err = c.overrides.addPattern(key, val)
          if err.len > 0:
            error c, path, "(" & $lineCount & "): " & err
        else:
          discard "ignore the line"
        inc lineCount
    finally:
      close f
  else:
    error c, path, "cannot open: " & path

proc readPluginsDir(c: var AtlasContext; dir: string) =
  for k, f in walkDir(c.workspace / dir):
    if k == pcFile and f.endsWith(".nims"):
      extractPluginInfo f, c.plugins

type
  JsonConfig = object
    deps: string
    overrides: string
    plugins: string
    resolver: string
    graph: JsonNode

proc writeDefaultConfigFile*(c: var AtlasContext) =
  let config = JsonConfig(resolver: $SemVer, graph: newJNull())
  let configFile = c.workspace / AtlasWorkspace
  writeFile(configFile, pretty %*config)

proc readConfig*(c: var AtlasContext) =
  let configFile = c.workspace / AtlasWorkspace
  var f = newFileStream(configFile, fmRead)
  if f == nil:
    error c, configFile, "cannot open: " & configFile
    return

  let j = parseJson(f, configFile)
  try:
    let m = j.to(JsonConfig)
    if m.deps.len > 0:
      c.depsDir = m.deps
      c.origDepsDir = m.deps
      #absoluteDepsDir(c.workspace, m.deps)
    if m.overrides.len > 0:
      c.overridesFile = m.overrides
      parseOverridesFile(c, m.overrides)
    if m.resolver.len > 0:
      try:
        c.defaultAlgo = parseEnum[ResolutionAlgorithm](m.resolver)
      except ValueError:
        warn c, configFile, "ignored unknown resolver: " & m.resolver
    if m.plugins.len > 0:
      c.pluginsFile = m.plugins
      readPluginsDir(c, m.plugins)
  finally:
    close f

proc writeConfig*(c: AtlasContext; graph: JsonNode) =
  let config = JsonConfig(deps: c.origDepsDir, overrides: c.overridesFile,
    plugins: c.pluginsFile, resolver: $c.defaultAlgo,
    graph: graph)
  let configFile = c.workspace / AtlasWorkspace
  writeFile(configFile, pretty %*config)
