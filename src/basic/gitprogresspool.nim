#
#           Atlas Package Cloner
#        (c) Copyright 2026 Atlas Contributors
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Run bounded git command pools with live progress parsing.
##
## This module is intended for network-heavy git operations such as clone/fetch
## batches. Each worker thread owns its subprocess, parses `git --progress`
## output, and sends progress updates back to the main thread for rendering.

import std/[deques, locks, monotimes, os, osproc, streams, strutils, terminal, times]
import context, reporters

type
  GitProgressWorkerCount* = range[1..high(int)]

  GitProgressSnapshot* = object
    phase*: string
    percent*: int
    speed*: string

  GitProgressJob* = object
    label*: string
    command*: string
    args*: seq[string]
    workingDir*: string

  GitProgressResult* = object
    label*: string
    exitCode*: int
    output*: string
    progress*: GitProgressSnapshot

  GitProgressEventKind = enum
    gpStarted, gpUpdated, gpFinished

  GitProgressEvent = object
    kind: GitProgressEventKind
    jobIndex: int
    label: string
    output: string
    exitCode: int
    progress: GitProgressSnapshot

  IndexedGitProgressJob = object
    index: int
    job: GitProgressJob

  GitProgressWorkerArgs = object
    jobs: seq[IndexedGitProgressJob]
    events: ptr GitProgressEventQueue
    startLock: ptr Lock

  GitProgressJobState = object
    label: string
    running: bool
    finished: bool
    failed: bool
    progress: GitProgressSnapshot
    lastActivityAt: MonoTime

  GitProgressEventQueue = object
    lock: Lock
    items: Deque[GitProgressEvent]

const DefaultGitProgressWorkers* = 3
const GitProgressBarWidth = 24
const GitProgressRenderIntervalMs = 250
const GitProgressIdleRenderIntervalMs = 250
const GitProgressPollSleepMs = 25
const GitProgressQuietMs = 1500
const GitProgressSpinnerFrames = "|/-\\"

proc pushEvent(events: ptr GitProgressEventQueue; event: sink GitProgressEvent) =
  acquire(events.lock)
  try:
    events.items.addLast event
  finally:
    release(events.lock)

proc drainEvents(events: ptr GitProgressEventQueue): seq[GitProgressEvent] =
  acquire(events.lock)
  try:
    while events.items.len > 0:
      result.add events.items.popFirst()
  finally:
    release(events.lock)

proc parsePercent(s: string): int =
  var digits = ""
  for c in s:
    if c in {'0'..'9'}:
      digits.add c
    elif digits.len > 0:
      break
  if digits.len == 0:
    return -1
  try:
    result = parseInt(digits)
  except ValueError:
    result = -1

proc normalizePhase(line: string): string =
  let colon = line.find(':')
  let phase =
    if colon >= 0: line[0..<colon].strip()
    else: line.strip()
  phase.toLowerAscii()

proc extractGitProgressSpeed(line: string): string =
  let pipePos = line.find('|')
  if pipePos < 0 or pipePos + 1 >= line.len:
    return ""
  let tail = line[pipePos + 1 .. ^1].strip()
  let commaPos = tail.find(',')
  if commaPos >= 0:
    return tail[0..<commaPos].strip()
  tail

proc parseGitProgressLine*(
    line: string;
    snapshot: var GitProgressSnapshot
): bool =
  let normalized = line.strip()
  if normalized.len == 0:
    return false

  var lineForParse = normalized
  if lineForParse.startsWith("remote:"):
    lineForParse = lineForParse.substr("remote:".len).strip()

  let percentPos = lineForParse.find('%')
  if percentPos < 0:
    return false

  let start =
    block:
      var i = percentPos - 1
      while i >= 0 and lineForParse[i] in {'0'..'9', ' '}:
        dec i
      i + 1
  let parsedPercent = parsePercent(lineForParse[start ..< percentPos])
  if parsedPercent < 0:
    return false

  snapshot.phase = normalizePhase(lineForParse)
  snapshot.percent = parsedPercent
  snapshot.speed = extractGitProgressSpeed(lineForParse)
  true

proc progressOutputChunks(buffer: var string; piece: string): seq[string] =
  buffer.add piece
  var current = ""
  for ch in buffer:
    if ch in {'\r', '\n'}:
      let line = current.strip()
      if line.len > 0:
        result.add line
      current.setLen(0)
    else:
      current.add ch
  buffer = current

proc flushProgressOutputBuffer(buffer: var string): seq[string] =
  let line = buffer.strip()
  if line.len > 0:
    result.add line
  buffer.setLen(0)

proc splitJobs(
    jobs: seq[GitProgressJob];
    workerCount: int
): seq[seq[IndexedGitProgressJob]] =
  result = newSeq[seq[IndexedGitProgressJob]](workerCount)
  for idx, job in jobs:
    result[idx mod workerCount].add IndexedGitProgressJob(index: idx, job: job)

proc spinnerFrame(): char =
  let tick = int(epochTime() * 10)
  GitProgressSpinnerFrames[tick mod GitProgressSpinnerFrames.len]

proc formatIdleDuration(elapsedMs: int64): string =
  let seconds = elapsedMs div 1000
  let tenths = (elapsedMs mod 1000) div 100
  $seconds & "." & $tenths & "s"

proc renderProgressBlock(
    title: string;
    states: seq[GitProgressJobState];
    now: MonoTime;
    includeFinished = false
): seq[string] =
  for state in states:
    if not state.running and not state.finished:
      continue
    if state.finished and not state.failed and not includeFinished:
      continue
    let status =
      if state.finished:
        if state.failed: "failed"
        else: "done"
      elif state.running:
        "running"
      else:
        "queued"
    let pct =
      if state.progress.percent >= 0:
        $state.progress.percent & "%"
      else:
        "--"
    let idleMs =
      if state.running:
        inMilliseconds(now - state.lastActivityAt)
      else:
        0
    var phase =
      if state.progress.phase.len > 0:
        if state.progress.speed.len > 0:
          state.progress.phase & " " & state.progress.speed
        else:
          state.progress.phase
      else:
        status
    if state.running:
      let spin = $spinnerFrame()
      if idleMs >= GitProgressQuietMs:
        phase = "idle " & formatIdleDuration(idleMs) & " " & spin
      else:
        phase.add " " & spin
    let filled =
      if state.progress.percent >= 0:
        min(GitProgressBarWidth, (state.progress.percent * GitProgressBarWidth) div 100)
      else:
        0
    var bar = "["
    if filled > 0:
      if filled > 1:
        bar.add repeat('=', filled - 1)
      if filled < GitProgressBarWidth:
        bar.add ">"
      else:
        bar.add "="
    if filled < GitProgressBarWidth:
      bar.add repeat(' ', GitProgressBarWidth - filled)
    bar.add "]"
    result.add "  " & state.label.alignLeft(14) & " " & bar & " " & pct.align(4) & " " & phase

proc clearInteractiveBlock(lastLines: var int) =
  if lastLines <= 0:
    return
  let lineCount = lastLines
  for idx in 0..<lineCount:
    stdout.write "\r\27[2K"
    if idx < lineCount - 1:
      stdout.write "\27[1A"
  stdout.write "\r\27[2K\r"
  stdout.flushFile()
  lastLines = 0

proc writeInteractiveBlock(lines: seq[string]; lastLines: var int) =
  clearInteractiveBlock(lastLines)
  for idx, line in lines:
    if atlasReporter.noColors:
      stdout.write line
    else:
      let isDone = " done" in line
      let isFailed = " failed" in line
      let color =
        if isFailed:
          fgRed
        elif isDone:
          fgGreen
        else:
          fgCyan

      let barStart = line.find('[')
      let barEnd = line.find(']')
      let percentPos =
        if barEnd >= 0:
          line.find('%', barEnd)
        else:
          -1
      let phaseStart =
        if percentPos >= 0 and percentPos + 2 < line.len:
          percentPos + 2
        else:
          -1

      if barStart >= 0 and barEnd > barStart and percentPos >= 0:
        let prefix = line[0..<barStart]
        let pkgEnd = prefix.rfind(' ')
        if pkgEnd >= 0:
          stdout.write prefix[0..pkgEnd]
          stdout.styledWrite(fgMagenta, styleBright, prefix[pkgEnd + 1 .. ^1], resetStyle)
        else:
          stdout.write prefix

        stdout.styledWrite(color, styleBright, line[barStart..barEnd], resetStyle)
        stdout.write " "
        let percentSpace = line.rfind(' ', percentPos)
        let percentStart =
          if percentSpace >= 0: percentSpace + 1
          else: -1
        if percentStart >= 0 and percentStart <= percentPos and percentStart > barEnd:
          stdout.styledWrite(fgGreen, styleBright, line[percentStart..percentPos], resetStyle)
        elif percentPos >= 0:
          stdout.write line[barEnd + 1 .. percentPos]
        if phaseStart >= 0:
          stdout.write " "
          let msgColor =
            if isFailed:
              fgRed
            elif isDone:
              fgWhite
            else:
              fgMagenta
          stdout.styledWrite(msgColor, line[phaseStart..^1], resetStyle)
      else:
        stdout.write line
    if idx < lines.high:
      stdout.write "\n"
  stdout.flushFile()
  lastLines = lines.len

proc interactiveProgressEnabled(showProgress: bool): bool =
  showProgress and
    atlasReporter.verbosity >= Notice and
    isatty(stdout) and
    getEnv("TERM") != "dumb"

proc readGitProgressOutput(
    p: Process;
    jobIndex: int;
    label: string;
    events: ptr GitProgressEventQueue
): tuple[output: string, progress: GitProgressSnapshot] =
  var buffer = ""
  var chunk = newString(4096)
  while true:
    let readLen = p.outputStream.readData(addr chunk[0], chunk.len)
    if readLen <= 0:
      break
    let piece = chunk[0..<readLen]
    result.output.add piece
    for line in progressOutputChunks(buffer, piece):
      var snapshot = result.progress
      if parseGitProgressLine(line, snapshot):
        if snapshot.phase != result.progress.phase or
            snapshot.percent != result.progress.percent:
          result.progress = snapshot
          events.pushEvent GitProgressEvent(
            kind: gpUpdated,
            jobIndex: jobIndex,
            label: label,
            progress: snapshot
          )

  for line in flushProgressOutputBuffer(buffer):
    var snapshot = result.progress
    if parseGitProgressLine(line, snapshot):
      if snapshot.phase != result.progress.phase or
          snapshot.percent != result.progress.percent:
        result.progress = snapshot
        events.pushEvent GitProgressEvent(
          kind: gpUpdated,
          jobIndex: jobIndex,
          label: label,
          progress: snapshot
        )

proc gitProgressWorker(args: GitProgressWorkerArgs) {.thread.} =
  for indexedJob in args.jobs:
    let job = indexedJob.job
    args.events.pushEvent GitProgressEvent(
      kind: gpStarted,
      jobIndex: indexedJob.index,
      label: job.label
    )

    var process: Process
    try:
      acquire(args.startLock[])
      try:
        process = startProcess(
          job.command,
          workingDir = job.workingDir,
          args = job.args,
          options = {poUsePath, poStdErrToStdOut}
        )
      finally:
        release(args.startLock[])

      let readResult = readGitProgressOutput(process, indexedJob.index, job.label, args.events)
      let exitCode = waitForExit(process)
      args.events.pushEvent GitProgressEvent(
        kind: gpFinished,
        jobIndex: indexedJob.index,
        label: job.label,
        output: readResult.output,
        exitCode: exitCode,
        progress: readResult.progress
      )
    except CatchableError as exc:
      args.events.pushEvent GitProgressEvent(
        kind: gpFinished,
        jobIndex: indexedJob.index,
        label: job.label,
        output: $exc.name & ": " & exc.msg,
        exitCode: 1,
        progress: GitProgressSnapshot(phase: "failed", percent: -1)
      )
    finally:
      if process != nil:
        acquire(args.startLock[])
        try:
          close(process)
        finally:
          release(args.startLock[])

proc runGitProgressJobs*(
    jobs: openArray[GitProgressJob];
    title = "atlas:git";
    workerCount = DefaultGitProgressWorkers;
    showProgress = true
): seq[GitProgressResult] =
  let jobsSeq = @jobs
  result = newSeq[GitProgressResult](jobsSeq.len)
  if jobsSeq.len == 0:
    return

  var states = newSeq[GitProgressJobState](jobsSeq.len)
  let startedAt = getMonoTime()
  for idx, job in jobsSeq:
    states[idx].label = job.label
    states[idx].lastActivityAt = startedAt
    result[idx].label = job.label
    result[idx].progress.percent = -1

  let effectiveWorkers = max(1, min(workerCount, jobsSeq.len))
  let renderInteractive = interactiveProgressEnabled(showProgress)
  var eventQueue: GitProgressEventQueue
  initLock(eventQueue.lock)
  var startLock: Lock
  initLock(startLock)

  var workerSlices = splitJobs(jobsSeq, effectiveWorkers)
  var threads = newSeq[Thread[GitProgressWorkerArgs]](effectiveWorkers)
  for idx in 0..<effectiveWorkers:
    createThread(
      threads[idx],
      gitProgressWorker,
      GitProgressWorkerArgs(
        jobs: workerSlices[idx],
        events: addr eventQueue,
        startLock: addr startLock
      )
    )

  var finished = 0
  var lastRender = getMonoTime()
  var lastLines = 0
  var lastRenderedBlock = ""

  while finished < jobsSeq.len:
    var changed = false
    let now = getMonoTime()
    for ev in drainEvents(addr eventQueue):
      case ev.kind
      of gpStarted:
        states[ev.jobIndex].running = true
        states[ev.jobIndex].lastActivityAt = now
      of gpUpdated:
        states[ev.jobIndex].running = true
        states[ev.jobIndex].progress = ev.progress
        states[ev.jobIndex].lastActivityAt = now
      of gpFinished:
        states[ev.jobIndex].running = false
        states[ev.jobIndex].finished = true
        states[ev.jobIndex].failed = ev.exitCode != 0
        states[ev.jobIndex].lastActivityAt = now
        if ev.exitCode == 0:
          states[ev.jobIndex].progress = ev.progress
          states[ev.jobIndex].progress.percent = 100
          if states[ev.jobIndex].progress.phase.len == 0:
            states[ev.jobIndex].progress.phase = "done"
          result[ev.jobIndex].progress = states[ev.jobIndex].progress
        else:
          states[ev.jobIndex].progress = ev.progress
          result[ev.jobIndex].progress = ev.progress
        result[ev.jobIndex].exitCode = ev.exitCode
        result[ev.jobIndex].output = ev.output
        inc finished
      changed = true

    if renderInteractive and changed and
        inMilliseconds(now - lastRender) >= GitProgressRenderIntervalMs:
      let lines = renderProgressBlock(title, states, now)
      let renderedBlock = lines.join("\n")
      if renderedBlock != lastRenderedBlock:
        writeInteractiveBlock(lines, lastLines)
        lastRenderedBlock = renderedBlock
        lastRender = now
    elif renderInteractive and not changed and
        inMilliseconds(now - lastRender) >= GitProgressIdleRenderIntervalMs:
      let lines = renderProgressBlock(title, states, now)
      let renderedBlock = lines.join("\n")
      if renderedBlock != lastRenderedBlock:
        writeInteractiveBlock(lines, lastLines)
        lastRenderedBlock = renderedBlock
      lastRender = now

    if finished < jobsSeq.len:
      sleep GitProgressPollSleepMs

  for thread in mitems(threads):
    joinThread(thread)

  if renderInteractive:
    let lines = renderProgressBlock(title, states, getMonoTime(), includeFinished = true)
    let renderedBlock = lines.join("\n")
    if renderedBlock != lastRenderedBlock:
      writeInteractiveBlock(lines, lastLines)
    stdout.write "\n"
    stdout.flushFile()

  deinitLock(eventQueue.lock)
  deinitLock(startLock)
