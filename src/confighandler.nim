#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Configuration handling.

import std / [strutils, os, streams, json, tables, jsonutils]
import basic/[versions, context, reporters, compiledpatterns, parse_requires]

proc readPluginsDir(dir: Path) =
  for k, f in walkDir($(workspace() / dir)):
    if k == pcFile and f.endsWith(".nims"):
      extractPluginInfo f, context().plugins

type
  JsonConfig = object
    deps: string
    nameOverrides: Table[string, string]
    urlOverrides: Table[string, string]
    plugins: string
    resolver: string
    graph: JsonNode

proc writeDefaultConfigFile*() =
  let config = JsonConfig(
    deps: $context().depsDir,
    nameOverrides: initTable[string, string](),
    urlOverrides: initTable[string, string](),
    resolver: $SemVer,
    graph: newJNull()
  )
  let configFile = getWorkspaceConfig()
  writeFile($configFile, pretty %*config)

proc readConfig*() =
  let configFile = getWorkspaceConfig()
  var f = newFileStream($configFile, fmRead)
  if f == nil:
    warn "atlas:config", "could not read workspace config:", $configFile
    return

  let j = parseJson(f, $configFile)
  try:
    let m = j.jsonTo(JsonConfig, Joptions(allowExtraKeys: true, allowMissingKeys: true))
    if m.deps.len > 0:
      context().depsDir = m.deps.Path
    
    # Handle package name overrides
    for key, val in m.nameOverrides:
      let err = context().nameOverrides.addPattern(key, val)
      if err.len > 0:
        error configFile, "invalid name override pattern: " & err

    # Handle URL overrides  
    for key, val in m.urlOverrides:
      let err = context().urlOverrides.addPattern(key, val)
      if err.len > 0:
        error configFile, "invalid URL override pattern: " & err

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
  let config = JsonConfig(
    deps: $context().depsDir,
    nameOverrides: context().nameOverrides.toTable(),
    urlOverrides: context().urlOverrides.toTable(),
    plugins: $context().pluginsFile,
    resolver: $context().defaultAlgo,
    graph: graph
  )
  let configFile = getWorkspaceConfig()
  writeFile($configFile, pretty %*config)
