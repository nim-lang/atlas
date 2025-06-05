
when defined(nimAtlasBootstrap):
  import ../../dist/sat/src/sat/satvars
else:
  import sat/satvars

proc `$`*(v: VarId): string =
  "v" & $v.int

export satvars