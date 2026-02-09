
import sat/[sat, satvars]

proc `$`*(v: VarId): string =
  "v" & $v.int

export sat, satvars
