#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std / [terminal, paths]
export paths

type
  MsgKind* = enum
    Ignore = ""
    Error =   "[Error]  "
    Warning = "[Warn]   ",
    Info =    "[Info]   ",
    Debug =   "[Debug]  "
    Trace =   "[Trace]  "

  Reporter* = object of RootObj
    verbosity*: MsgKind
    noColors*: bool
    assertOnError*: bool
    warnings*: int
    errors*: int
    messages: seq[(MsgKind, string, seq[string])] # delayed output

var atlasReporter* = Reporter(verbosity: Info)

proc setAtlasVerbosity*(verbosity: MsgKind) =
  atlasReporter.verbosity = verbosity

proc setAtlasNoColors*(nc: bool) =
  atlasReporter.noColors = nc

proc setAtlasAssertOnError*(err: bool) =
  atlasReporter.assertOnError = err

proc atlasErrors*(): int =
  atlasReporter.errors

proc writeMessageRaw(c: var Reporter; category: string; p: string, args: seq[string]) =
  var msg = category
  if p.len > 0: msg.add "(" & p & ") "
  for arg in args: msg.add arg
  stdout.writeLine msg

proc writeMessage(c: var Reporter; k: MsgKind; p: string, args: seq[string]) =
  if k == Ignore: return
  if k > c.verbosity: return
  # if k == Trace and c.verbosity < 1: return
  # elif k == Debug and c.verbosity < 2: return

  if c.noColors:
    writeMessageRaw(c, $k, p, args)
  else:
    let (color, style) =
      case k
      of Ignore: (fgWhite, styleDim)
      of Trace: (fgWhite, styleDim)
      of Debug: (fgBlue, styleBright)
      of Info: (fgGreen, styleBright)
      of Warning: (fgYellow, styleBright)
      of Error: (fgRed, styleBright)
    
    stdout.styledWrite(color, style, $k, resetStyle, fgCyan, "(", p, ")", resetStyle)
    let colors = [fgWhite, fgMagenta]
    for idx, arg in args:
      stdout.styledWrite(colors[idx mod 2], " ", arg)
    stdout.styledWriteLine(resetStyle, "")

proc message(c: var Reporter; k: MsgKind; p: string, args: varargs[string]) =
  ## collects messages or prints them out immediately
  # c.messages.add (k, p, arg)
  writeMessage c, k, p, @args


proc warn*(c: var Reporter; p: string, args: varargs[string]) =
  c.message(Warning, p, @args)
  # writeMessage c, Warning, p, arg
  inc c.warnings

proc error*(c: var Reporter; p: string, args: varargs[string]) =
  if c.assertOnError:
    raise newException(AssertionDefect, p & ": " & $args)
  c.message(Error, p, @args)
  inc c.errors

proc info*(c: var Reporter; p: string, args: varargs[string]) =
  c.message(Info, p, @args)

proc trace*(c: var Reporter; p: string, args: varargs[string]) =
  c.message(Trace, p, @args)

proc debug*(c: var Reporter; p: string, args: varargs[string]) =
  c.message(Debug, p, @args)

proc writePendingMessages*(c: var Reporter) =
  for i in 0..<c.messages.len:
    let (k, p, arg) = c.messages[i]
    writeMessage c, k, p, arg
  c.messages.setLen 0

proc atlasWritePendingMessages*() =
  atlasReporter.writePendingMessages()

proc infoNow*(c: var Reporter; p: string, args: varargs[string]) =
  writeMessage c, Info, p, @args

proc fatal*(c: var Reporter, msg: string, prefix = "fatal", code = 1) =
  when defined(debug):
    writeStackTrace()
  writeMessage(c, Error, prefix, @[msg])
  quit 1

when not compiles($(Path("test"))):
  template `$`*(x: Path): string =
    string(x)

when not compiles(len(Path("test"))):
  template len*(x: Path): int =
    x.string.len()

proc warn*(c: var Reporter; p: Path, arg: string) =
  warn(c, $p.splitFile().name, arg)

proc error*(c: var Reporter; p: Path, arg: string) =
  error(c, $p.splitFile().name, arg)

proc info*(c: var Reporter; p: Path, arg: string) =
  info(c, $p.splitFile().name, arg)

proc trace*(c: var Reporter; p: Path, arg: string) =
  trace(c, $p.splitFile().name, arg)

proc debug*(c: var Reporter; p: Path, arg: string) =
  debug(c, $p.splitFile().name, arg)

proc toProj(s: string): string = s
proc toProj(p: Path): string = $p.splitFile().name

proc message*(k: MsgKind; p: Path | string, args: varargs[string]) =
  message(atlasReporter, k, toProj(p), @args)

proc warn*(p: Path | string, args: varargs[string]) =
  warn(atlasReporter, toProj(p), @args)

proc error*(p: Path | string, args: varargs[string]) =
  error(atlasReporter, toProj(p), @args)

proc info*(p: Path | string, args: varargs[string]) =
  info(atlasReporter, toProj(p), @args)

proc trace*(p: Path | string, args: varargs[string]) =
  trace(atlasReporter, toProj(p), @args)

proc debug*(p: Path | string, args: varargs[string]) =
  debug(atlasReporter, toProj(p), @args)

proc fatal*(msg: string | Path, prefix = "fatal", code = 1) =
  fatal(atlasReporter, msg, prefix, code)

proc infoNow*(p: Path | string, args: varargs[string]) =
  infoNow(atlasReporter, toProj(p), @args)
