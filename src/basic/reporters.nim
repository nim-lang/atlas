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
    Notice =  "[Notice] ",
    Info =    "[Info]   ",
    Debug =   "[Debug]  "
    Trace =   "[Trace]  "

  Reporter* = object of RootObj
    verbosity*: MsgKind
    noColors*: bool
    assertOnError*: bool
    errorsColor* = fgRed
    warnings*: int
    errors*: int
    messages: seq[(MsgKind, string, seq[string])] # delayed output
    recentErrors: seq[(string, seq[string])]

  AtlasFatalError* = object of CatchableError

  AtlasRunStatus* = enum
    arsNeutral, arsRunning, arsSuccess, arsFailed

var atlasReporter* = Reporter(verbosity: Notice)

proc setAtlasVerbosity*(verbosity: MsgKind) =
  atlasReporter.verbosity = verbosity

proc setAtlasNoColors*(nc: bool) =
  atlasReporter.noColors = nc

proc setAtlasAssertOnError*(err: bool) =
  atlasReporter.assertOnError = err

proc atlasErrors*(): int =
  atlasReporter.errors

proc resetAtlasReporter*() =
  atlasReporter.warnings = 0
  atlasReporter.errors = 0
  atlasReporter.messages.setLen 0
  atlasReporter.recentErrors.setLen 0

proc setAtlasErrorsColor*(color: ForegroundColor) =
  atlasReporter.errorsColor = color

proc atlasMessageStyle*(c: Reporter; k: MsgKind): tuple[
    color: ForegroundColor,
    style: Style
] =
  case k
  of Ignore:
    (fgWhite, styleDim)
  of Trace:
    (fgWhite, styleDim)
  of Debug:
    (fgBlue, styleBright)
  of Info:
    (fgGreen, styleBright)
  of Notice:
    (fgMagenta, styleBright)
  of Warning:
    (fgYellow, styleBright)
  of Error:
    (c.errorsColor, styleBright)

proc atlasRunStatusColor(status: AtlasRunStatus): ForegroundColor =
  case status
  of arsNeutral:
    atlasReporter.atlasMessageStyle(Trace).color
  of arsRunning:
    fgCyan
  of arsSuccess:
    atlasReporter.atlasMessageStyle(Info).color
  of arsFailed:
    atlasReporter.atlasMessageStyle(Error).color

proc atlasRunStatusStyle(status: AtlasRunStatus): Style =
  case status
  of arsRunning:
    styleBright
  of arsNeutral:
    atlasReporter.atlasMessageStyle(Trace).style
  of arsSuccess:
    atlasReporter.atlasMessageStyle(Info).style
  of arsFailed:
    atlasReporter.atlasMessageStyle(Error).style

proc writeAtlasRunPrefix*() =
  if atlasReporter.noColors:
    stdout.write "atlas-run: "
  else:
    let (color, style) = atlasReporter.atlasMessageStyle(Notice)
    stdout.styledWrite(color, style, "atlas-run:", resetStyle, " ")

proc writeAtlasRunLine*(message: string) =
  writeAtlasRunPrefix()
  stdout.writeLine message

proc writeAtlasRunStatusLine*(beforeStatus, statusText: string;
                              status: AtlasRunStatus) =
  writeAtlasRunPrefix()
  stdout.write beforeStatus
  if atlasReporter.noColors:
    stdout.writeLine statusText
  else:
    stdout.styledWriteLine(
      status.atlasRunStatusColor(),
      status.atlasRunStatusStyle(),
      statusText,
      resetStyle
    )

proc writeMessageRaw(c: var Reporter; category: string; p: string, args: seq[string]) =
  var msg = category
  if p.len > 0: msg.add "(" & p & ") "
  for arg in args:
    msg.add arg
    msg.add " "
  stdout.writeLine msg

proc writeMessage(c: var Reporter; k: MsgKind; p: string, args: seq[string]) =
  if k == Ignore: return
  if k > c.verbosity: return
  # if k == Trace and c.verbosity < 1: return
  # elif k == Debug and c.verbosity < 2: return

  if c.noColors:
    writeMessageRaw(c, $k, p, args)
  else:
    let (color, style) = c.atlasMessageStyle(k)
    
    stdout.styledWrite(color, style, $k, resetStyle, fgCyan, "(", p, ")", resetStyle)
    let colors = [fgWhite, fgMagenta]
    for idx, arg in args:
      stdout.styledWrite(colors[idx mod 2], " ", arg)
    stdout.styledWriteLine(resetStyle, "")

proc message(c: var Reporter; k: MsgKind; p: string, args: openArray[string]) =
  ## collects messages or prints them out immediately
  # c.messages.add (k, p, arg)
  if c.assertOnError:
    raise newException(AssertionDefect, p & ": " & $args)
  if k == Warning:
    inc c.warnings
  elif k == Error:
    inc c.errors
    c.recentErrors.add (p, @args)
    if c.recentErrors.len > 5:
      c.recentErrors.delete(0)
  writeMessage c, k, p, @args

proc writePendingMessages*(c: var Reporter) =
  for i in 0..<c.messages.len:
    let (k, p, arg) = c.messages[i]
    writeMessage c, k, p, arg
  c.messages.setLen 0

proc atlasWritePendingMessages*() =
  atlasReporter.writePendingMessages()

proc atlasWriteErrorSummary*() =
  if atlasReporter.errors == 0:
    return
  let count = atlasReporter.errors
  var heading = "error summary: " & $count &
    (if count == 1: " error reported" else: " errors reported")
  if count > atlasReporter.recentErrors.len:
    heading.add "; showing the last " & $atlasReporter.recentErrors.len
  # Replaying output must not record another error or alter the exit status.
  writeMessage(atlasReporter, Error, "atlas", @[heading])
  for (source, args) in atlasReporter.recentErrors:
    writeMessage(atlasReporter, Error, source, args)

proc writeSuccess(c: var Reporter; p: string; args: seq[string]) =
  ## A command result is always visible, even at error-only verbosity.
  if c.noColors:
    writeMessageRaw(c, "[Success] ", p, args)
  else:
    stdout.styledWrite(fgGreen, styleBright, "[Success] ", resetStyle,
                       fgCyan, "(", p, ")", resetStyle)
    for arg in args:
      stdout.styledWrite(fgWhite, " ", arg)
    stdout.styledWriteLine(resetStyle, "")

proc atlasWriteResultFooter*(succeeded: bool) =
  if succeeded:
    writeSuccess(atlasReporter, "atlas", @["completed successfully"])
  else:
    # Do not record the footer as another error.
    writeMessage(atlasReporter, Error, "atlas", @["failed"])

proc atlasWriteResultFooter*() =
  atlasWriteResultFooter(atlasReporter.errors == 0)

proc doInfoNow*(c: var Reporter; p: string, args: seq[string]) =
  writeMessage c, Info, p, @args

proc doFatal*(c: var Reporter, msg: string, prefix = "fatal", code: int) =
  when defined(debug):
    writeStackTrace()
  writeMessage(c, Error, prefix, @[msg])
  atlasWriteResultFooter(false)
  quit code

when not compiles($(Path("test"))):
  template `$`*(x: Path): string =
    string(x)

when not compiles(len(Path("test"))):
  template len*(x: Path): int =
    x.string.len()

proc toReporterName(s: string): string = s
proc toReporterName(p: Path): string = $p.splitPath().tail

proc message*[T](k: MsgKind; p: T, args: varargs[string]) =
  mixin toReporterName
  message(atlasReporter, k, toReporterName(p), @args)

proc warn*[T](p: T, args: varargs[string]) =
  mixin toReporterName
  message(atlasReporter, Warning, toReporterName(p), @args)

proc error*[T](p: T, args: varargs[string]) =
  mixin toReporterName
  message(atlasReporter, Error, toReporterName(p), @args)

proc notice*[T](p: T, args: varargs[string]) =
  mixin toReporterName
  message(atlasReporter, Notice, toReporterName(p), @args)

proc info*[T](p: T, args: varargs[string]) =
  mixin toReporterName
  message(atlasReporter, Info, toReporterName(p), @args)

proc trace*[T](p: T, args: varargs[string]) =
  mixin toReporterName
  message(atlasReporter, Trace, toReporterName(p), @args)

proc debug*[T](p: T, args: varargs[string]) =
  mixin toReporterName
  message(atlasReporter, Debug, toReporterName(p), @args)

template fatal*(msg: string | Path, prefix = "fatal", code = 1) =
  mixin toReporterName
  when defined(atlasUnitTests):
    message(atlasReporter, Error, prefix, @[toReporterName(msg)])
    raise newException(AtlasFatalError, prefix & ": " & toReporterName(msg))
  else:
    doFatal(atlasReporter, toReporterName(msg), prefix, code)

proc infoNow*[T](p: T, args: varargs[string]) =
  mixin toReporterName
  doInfoNow(atlasReporter, toReporterName(p), @args)
