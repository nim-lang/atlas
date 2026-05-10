version = "1.0.0"

requires "nim >= 1.0.0"

when NimMajor == 2 or (NimMajor >= 1 and NimMinor >= 9):
  requires "db_connector >= 0.1.0"

when (NimMajor, NimMinor) >= (2, 0):
  requires "tuple_ge >= 1.0.0"

when NimMajor < 0:
  requires "impossible >= 1.0.0"
