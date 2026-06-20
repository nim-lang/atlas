#
#           Atlas Package Cloner
#        (c) Copyright 2026 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std/[
  algorithm, atomics, deques, locks, monotimes, os, osproc, paths, random,
  streams, strutils, terminal, times
]

when defined(posix):
  from std/posix import Pid, SIGKILL, SIGTERM, killpg, setpgid

import basic/reporters

type
  AtlasTestOptions* = object
    projectDir*: Path
    nimExe*: string
    nimcacheDir*: Path
    jobs*: int
    selectors*: seq[string]
    shuffle*: bool
    showProgress*: bool
    showOutput*: bool

  AtlasTestResult* = object
    label*: string
    path*: Path
    commandLine*: string
    exitCode*: int
    output*: string

  TestStage = enum
    tsQueued, tsCompiling, tsRunning, tsDone, tsFailed

  TestJob = object
    label: string
    path: Path
    nimcache: Path
    executable: Path
    compileCommand: string
    compileArgs: seq[string]
    runCommand: string
    runArgs: seq[string]
    workingDir: string
    commandLine: string

  IndexedTestJob = object
    index: int
    job: TestJob

  TestProgressEventKind = enum
    tpStarted, tpUpdated, tpFinished

  TestProgressEvent = object
    kind: TestProgressEventKind
    jobIndex: int
    label: string
    stage: TestStage
    output: string
    exitCode: int

  TestProgressEventQueue = object
    lock: Lock
    items: Deque[TestProgressEvent]

  TestWorkerArgs = object
    jobs: seq[IndexedTestJob]
    events: ptr TestProgressEventQueue
    registry: ptr TestProcessRegistry
    startLock: ptr Lock

  ActiveTestProcess = object
    process: Process
    pgid: int

  TestProcessRegistry = object
    lock: Lock
    processes: seq[ActiveTestProcess]

  TestJobState = object
    label: string
    stage: TestStage
    running: bool
    finished: bool
    failed: bool
    lastActivityAt: MonoTime

const
  DefaultAtlasTestJobs* = 0
  TestProgressBarWidth = 24
  TestProgressRenderIntervalMs = 250
  TestProgressIdleRenderIntervalMs = 250
  TestProgressPollSleepMs = 25
  TestProgressQuietMs = 1500
  TestProgressSpinnerFrames = "|/-\\"

var testRunCancelled: Atomic[bool]

proc initAtlasTestOptions*(projectDir = Path"";
                           nimExe = "nim";
                           nimcacheDir = Path"";
                           jobs = DefaultAtlasTestJobs;
                           selectors: seq[string] = @[];
                           shuffle = true;
                           showProgress = true;
                           showOutput = true): AtlasTestOptions =
  AtlasTestOptions(
    projectDir: projectDir,
    nimExe: nimExe,
    nimcacheDir: nimcacheDir,
    jobs: jobs,
    selectors: selectors,
    shuffle: shuffle,
    showProgress: showProgress,
    showOutput: showOutput
  )

proc pushEvent(events: ptr TestProgressEventQueue; event: sink TestProgressEvent) =
  acquire(events.lock)
  try:
    events.items.addLast event
  finally:
    release(events.lock)

proc drainEvents(events: ptr TestProgressEventQueue): seq[TestProgressEvent] =
  acquire(events.lock)
  try:
    while events.items.len > 0:
      result.add events.items.popFirst()
  finally:
    release(events.lock)

proc requestTestCancellation() {.noconv.} =
  testRunCancelled.store(true)

proc cancellationRequested(): bool =
  testRunCancelled.load()

proc installCancellationHook() =
  testRunCancelled.store(false)
  setControlCHook(requestTestCancellation)

proc uninstallCancellationHook() =
  when declared(unsetControlCHook):
    unsetControlCHook()

proc processGroupFor(process: Process): int =
  when defined(posix):
    let pid = processID(process)
    if setpgid(Pid(pid), Pid(pid)) == 0:
      result = pid
  else:
    result = 0

proc registerProcess(registry: ptr TestProcessRegistry; process: Process; pgid: int) =
  acquire(registry.lock)
  try:
    registry.processes.add ActiveTestProcess(process: process, pgid: pgid)
  finally:
    release(registry.lock)

proc unregisterProcess(registry: ptr TestProcessRegistry; process: Process) =
  acquire(registry.lock)
  try:
    let pid = processID(process)
    var i = 0
    while i < registry.processes.len:
      if processID(registry.processes[i].process) == pid:
        registry.processes.delete(i)
      else:
        inc i
  finally:
    release(registry.lock)

proc registeredProcesses(registry: ptr TestProcessRegistry): seq[ActiveTestProcess] =
  acquire(registry.lock)
  try:
    result = registry.processes
  finally:
    release(registry.lock)

proc signalProcess(entry: ActiveTestProcess; force: bool) =
  try:
    when defined(posix):
      if entry.pgid > 0:
        let signal =
          if force:
            SIGKILL
          else:
            SIGTERM
        discard killpg(Pid(entry.pgid), signal)
      elif force:
        entry.process.kill()
      else:
        entry.process.terminate()
    else:
      if force:
        entry.process.kill()
      else:
        entry.process.terminate()
  except OSError:
    discard

proc killRegisteredProcesses(registry: ptr TestProcessRegistry) =
  let processes = registeredProcesses(registry)
  for process in processes:
    signalProcess(process, force = false)
  sleep 100
  for process in processes:
    signalProcess(process, force = true)

proc normalizePathText(s: string): string =
  s.replace("\\", "/")

proc effectiveProjectDir(projectDir: Path): Path =
  if ($projectDir).len > 0:
    projectDir.expandTilde().absolutePath()
  else:
    Path(os.getCurrentDir()).absolutePath()

proc testLabel(projectDir, path: Path): string =
  normalizePathText($path.relativePath(projectDir, '/'))

proc matchesSelector(projectDir, path: Path; selector: string): bool =
  let
    normalized = selector.normalizePathText()
    rel = testLabel(projectDir, path)
    filename = normalizePathText($path.extractFilename())
    name = normalizePathText($path.splitFile().name)
    selectedPath = Path(selector).expandTilde().absolutePath()

  result =
    normalized == rel or
    normalized == filename or
    normalized == name or
    selectedPath == path

proc addUnique(paths: var seq[Path]; path: Path) =
  var found = false
  for existing in paths:
    if existing == path:
      found = true
  if not found:
    paths.add path

proc discoverAllTestFiles(projectDir: Path): seq[Path] =
  let testsDir = projectDir / Path"tests"
  for path in walkFiles($(testsDir / Path"t*.nim")):
    result.add Path(path).absolutePath()
  result.sort(proc(a, b: Path): int = cmp($a, $b))

proc discoverTestFiles*(projectDir: Path;
                        selectors: openArray[string] = []): seq[Path] =
  let
    projectDir = effectiveProjectDir(projectDir)
    allFiles = discoverAllTestFiles(projectDir)

  if selectors.len == 0:
    result = allFiles
  else:
    for selector in selectors:
      var matched = false
      for path in allFiles:
        if matchesSelector(projectDir, path, selector):
          result.addUnique path
          matched = true
      if not matched:
        raise newException(ValueError, "test selector did not match: " & selector)

  if result.len == 0:
    raise newException(ValueError, "no tests found matching tests/t*.nim")

proc quoteCommand(command: string; args: openArray[string]): string =
  result = quoteShell(command)
  for arg in args:
    result.add " "
    result.add quoteShell(arg)

proc effectiveNimcacheRoot(projectDir, nimcacheDir: Path): Path =
  if ($nimcacheDir).len > 0:
    let expanded = nimcacheDir.expandTilde()
    if expanded.isAbsolute:
      result = expanded.absolutePath()
    else:
      result = projectDir / expanded
  else:
    result = projectDir / Path".nimcache" / Path"atlas-run"

proc testNimcacheDir(projectDir, nimcacheRoot, path: Path): Path =
  let relativeTest = path.relativePath(projectDir, '/').changeFileExt("")
  nimcacheRoot / relativeTest

proc testExecutablePath(nimcache, path: Path): Path =
  nimcache / Path(($path.splitFile().name).addFileExt(ExeExt))

proc makeTestJob(projectDir, nimcacheRoot, path: Path; nimExe: string): TestJob =
  let
    label = testLabel(projectDir, path)
    nimcache = testNimcacheDir(projectDir, nimcacheRoot, path)
    executable = testExecutablePath(nimcache, path)
    compileArgs = @[
      "c",
      "--colors:on",
      "-d:nimUnittestColor:on",
      "--nimcache:" & $nimcache,
      "--out:" & $executable,
      label
    ]
  createDir($nimcache)
  TestJob(
    label: label,
    path: path,
    nimcache: nimcache,
    executable: executable,
    compileCommand: nimExe,
    compileArgs: compileArgs,
    runCommand: $executable,
    runArgs: @[],
    workingDir: $projectDir,
    commandLine: quoteCommand(nimExe, compileArgs) & " && " & quoteShell($executable)
  )

proc shuffleJobs(jobs: var seq[TestJob]) =
  if jobs.len > 1:
    randomize()
    shuffle(jobs)

proc splitJobs(jobs: seq[TestJob]; workerCount: int): seq[seq[IndexedTestJob]] =
  result = newSeq[seq[IndexedTestJob]](workerCount)
  for idx, job in jobs:
    result[idx mod workerCount].add IndexedTestJob(index: idx, job: job)

proc spinnerFrame(): char =
  let tick = int(epochTime() * 10)
  TestProgressSpinnerFrames[tick mod TestProgressSpinnerFrames.len]

proc stageName(stage: TestStage): string =
  case stage
  of tsQueued:
    "queued"
  of tsCompiling:
    "compiling"
  of tsRunning:
    "running"
  of tsDone:
    "done"
  of tsFailed:
    "failed"

proc stagePercent(stage: TestStage): int =
  case stage
  of tsQueued:
    0
  of tsCompiling:
    35
  of tsRunning:
    70
  of tsDone, tsFailed:
    100

proc formatIdleDuration(elapsedMs: int64): string =
  let seconds = elapsedMs div 1000
  let tenths = (elapsedMs mod 1000) div 100
  $seconds & "." & $tenths & "s"

proc renderTestProgressBlock(states: seq[TestJobState];
                             now: MonoTime;
                             includeFinished = false): seq[string] =
  for state in states:
    if state.running or state.failed or (includeFinished and state.finished):
      let
        percent = stagePercent(state.stage)
        filled = min(TestProgressBarWidth, (percent * TestProgressBarWidth) div 100)
      var bar = "["
      if filled > 0:
        if filled > 1:
          bar.add repeat('=', filled - 1)
        if filled < TestProgressBarWidth:
          bar.add ">"
        else:
          bar.add "="
      if filled < TestProgressBarWidth:
        bar.add repeat(' ', TestProgressBarWidth - filled)
      bar.add "]"

      var phase = state.stage.stageName()
      if state.running:
        let idleMs = inMilliseconds(now - state.lastActivityAt)
        if idleMs >= TestProgressQuietMs:
          phase = state.stage.stageName() & " " & formatIdleDuration(idleMs)
        phase.add " "
        phase.add spinnerFrame()

      result.add "  " & state.label.alignLeft(24) & " " & bar & " " & phase

proc clearInteractiveBlock(lastLines: var int) =
  if lastLines > 0:
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
      let
        isDone = " done" in line
        isFailed = " failed" in line
        color =
          if isFailed:
            fgRed
          elif isDone:
            fgGreen
          else:
            fgCyan
      let barStart = line.find('[')
      let barEnd = line.find(']')
      if barStart >= 0 and barEnd > barStart:
        stdout.write line[0..<barStart]
        stdout.styledWrite(color, styleBright, line[barStart..barEnd], resetStyle)
        stdout.write line[barEnd + 1 .. ^1]
      else:
        stdout.write line
    if idx < lines.high:
      stdout.write "\n"
  stdout.flushFile()
  lastLines = lines.len

proc renderInteractiveNow(states: seq[TestJobState];
                          now: MonoTime;
                          lastLines: var int;
                          lastRenderedBlock: var string;
                          includeFinished = false): bool =
  let
    lines = renderTestProgressBlock(states, now, includeFinished)
    renderedBlock = lines.join("\n")
  if renderedBlock != lastRenderedBlock:
    writeInteractiveBlock(lines, lastLines)
    lastRenderedBlock = renderedBlock
    result = true

proc interactiveProgressEnabled(showProgress: bool): bool =
  showProgress and
    atlasReporter.verbosity >= Notice and
    isatty(stdout) and
    getEnv("TERM") != "dumb"

proc outputChunks(buffer: var string; piece: string): seq[string] =
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

proc flushOutputBuffer(buffer: var string): seq[string] =
  let line = buffer.strip()
  if line.len > 0:
    result.add line
  buffer.setLen(0)

proc lineStage(line: string; current: TestStage): TestStage =
  if "[Exec]" in line or "[Suite]" in line or "[OK]" in line or "[FAILED]" in line:
    tsRunning
  elif current == tsQueued:
    tsCompiling
  else:
    current

proc readTestOutput(p: Process;
                    jobIndex: int;
                    label: string;
                    events: ptr TestProgressEventQueue;
                    initialStage: TestStage): tuple[output: string,
                                                    stage: TestStage] =
  result.stage = initialStage
  var buffer = ""
  var chunk = newString(4096)
  while true:
    let readLen = p.outputStream.readData(addr chunk[0], chunk.len)
    if readLen <= 0:
      break
    let piece = chunk[0..<readLen]
    result.output.add piece
    for line in outputChunks(buffer, piece):
      let nextStage = lineStage(line, result.stage)
      if nextStage != result.stage:
        result.stage = nextStage
        events.pushEvent TestProgressEvent(
          kind: tpUpdated,
          jobIndex: jobIndex,
          label: label,
          stage: nextStage
        )

  for line in flushOutputBuffer(buffer):
    let nextStage = lineStage(line, result.stage)
    if nextStage != result.stage:
      result.stage = nextStage
      events.pushEvent TestProgressEvent(
        kind: tpUpdated,
        jobIndex: jobIndex,
        label: label,
        stage: nextStage
      )

proc runTestProcess(job: TestJob;
                    indexedJob: IndexedTestJob;
                    command: string;
                    args: openArray[string];
                    stage: TestStage;
                    workerArgs: TestWorkerArgs): tuple[output: string,
                                                       exitCode: int] =
  var process: Process
  var registered = false
  try:
    workerArgs.events.pushEvent TestProgressEvent(
      kind: tpUpdated,
      jobIndex: indexedJob.index,
      label: job.label,
      stage: stage
    )
    acquire(workerArgs.startLock[])
    try:
      process = startProcess(
        command,
        workingDir = job.workingDir,
        args = args,
        options = {poUsePath, poStdErrToStdOut}
      )
      let pgid = process.processGroupFor()
      workerArgs.registry.registerProcess(process, pgid)
      registered = true
    finally:
      release(workerArgs.startLock[])

    let readResult = readTestOutput(
      process,
      indexedJob.index,
      job.label,
      workerArgs.events,
      stage
    )
    result.output = readResult.output
    result.exitCode = waitForExit(process)
  finally:
    if process != nil:
      if registered:
        workerArgs.registry.unregisterProcess(process)
      acquire(workerArgs.startLock[])
      try:
        close(process)
      finally:
        release(workerArgs.startLock[])

proc testWorker(args: TestWorkerArgs) {.thread.} =
  for indexedJob in args.jobs:
    let job = indexedJob.job
    args.events.pushEvent TestProgressEvent(
      kind: tpStarted,
      jobIndex: indexedJob.index,
      label: job.label,
      stage: tsCompiling
    )

    try:
      var output = ""
      var exitCode = 130
      if not cancellationRequested():
        let compileResult = runTestProcess(
          job,
          indexedJob,
          job.compileCommand,
          job.compileArgs,
          tsCompiling,
          args
        )
        output.add compileResult.output
        exitCode = compileResult.exitCode

      if exitCode == 0 and not cancellationRequested():
        let runResult = runTestProcess(
          job,
          indexedJob,
          job.runCommand,
          job.runArgs,
          tsRunning,
          args
        )
        output.add runResult.output
        exitCode = runResult.exitCode

      args.events.pushEvent TestProgressEvent(
        kind: tpFinished,
        jobIndex: indexedJob.index,
        label: job.label,
        stage: if exitCode == 0: tsDone else: tsFailed,
        output: output,
        exitCode: exitCode
      )
    except CatchableError as exc:
      args.events.pushEvent TestProgressEvent(
        kind: tpFinished,
        jobIndex: indexedJob.index,
        label: job.label,
        stage: tsFailed,
        output: $exc.name & ": " & exc.msg & "\n",
        exitCode: 1
      )

proc effectiveJobs(requested, testCount: int): int =
  if requested > 0:
    max(1, min(requested, testCount))
  else:
    max(1, min(countProcessors(), testCount))

proc writeResultChunk(result: AtlasTestResult) =
  let status =
    if result.exitCode == 0:
      "passed"
    else:
      "failed"
  stdout.writeLine "[atlas:test] " & result.label & " " & status
  stdout.writeLine "[atlas:test] command: " & result.commandLine
  if result.output.len > 0:
    stdout.write result.output
    if not result.output.endsWith("\n"):
      stdout.write "\n"
  stdout.flushFile()

proc runTestJobs(jobs: seq[TestJob];
                 workerCount: int;
                 showProgress, showOutput: bool): tuple[
                   results: seq[AtlasTestResult],
                   cancelled: bool
                 ] =
  result.results = newSeq[AtlasTestResult](jobs.len)
  if jobs.len == 0:
    return

  var states = newSeq[TestJobState](jobs.len)
  let startedAt = getMonoTime()
  for idx, job in jobs:
    states[idx].label = job.label
    states[idx].stage = tsQueued
    states[idx].lastActivityAt = startedAt
    result.results[idx].label = job.label
    result.results[idx].path = job.path
    result.results[idx].commandLine = job.commandLine

  let renderInteractive = interactiveProgressEnabled(showProgress)
  var eventQueue: TestProgressEventQueue
  initLock(eventQueue.lock)
  var registry: TestProcessRegistry
  initLock(registry.lock)
  var startLock: Lock
  initLock(startLock)

  var workerSlices = splitJobs(jobs, workerCount)
  var threads = newSeq[Thread[TestWorkerArgs]](workerCount)
  for idx in 0..<workerCount:
    createThread(
      threads[idx],
      testWorker,
      TestWorkerArgs(
        jobs: workerSlices[idx],
        events: addr eventQueue,
        registry: addr registry,
        startLock: addr startLock
      )
    )

  var finished = 0
  var lastRender = getMonoTime()
  var lastLines = 0
  var lastRenderedBlock = ""
  var cancellationHandled = false

  installCancellationHook()
  while finished < jobs.len:
    var changed = false
    let now = getMonoTime()
    if cancellationRequested() and not cancellationHandled:
      result.cancelled = true
      cancellationHandled = true
      if renderInteractive:
        clearInteractiveBlock(lastLines)
        lastRenderedBlock = ""
      stdout.writeLine "atlas-run: interrupted; killing running tests"
      stdout.flushFile()
      killRegisteredProcesses(addr registry)

    for ev in drainEvents(addr eventQueue):
      case ev.kind
      of tpStarted:
        states[ev.jobIndex].running = true
        states[ev.jobIndex].stage = ev.stage
        states[ev.jobIndex].lastActivityAt = now
      of tpUpdated:
        states[ev.jobIndex].running = true
        states[ev.jobIndex].stage = ev.stage
        states[ev.jobIndex].lastActivityAt = now
      of tpFinished:
        states[ev.jobIndex].running = false
        states[ev.jobIndex].finished = true
        states[ev.jobIndex].failed = ev.exitCode != 0
        states[ev.jobIndex].stage = ev.stage
        states[ev.jobIndex].lastActivityAt = now
        result.results[ev.jobIndex].exitCode = ev.exitCode
        result.results[ev.jobIndex].output = ev.output
        inc finished
        if showOutput and not result.cancelled:
          if renderInteractive:
            clearInteractiveBlock(lastLines)
            lastRenderedBlock = ""
          writeResultChunk(result.results[ev.jobIndex])
          if renderInteractive:
            if renderInteractiveNow(states, now, lastLines, lastRenderedBlock):
              lastRender = now
      changed = true

    if renderInteractive and changed and
        inMilliseconds(now - lastRender) >= TestProgressRenderIntervalMs:
      if renderInteractiveNow(states, now, lastLines, lastRenderedBlock):
        lastRender = now
    elif renderInteractive and not changed and
        inMilliseconds(now - lastRender) >= TestProgressIdleRenderIntervalMs:
      discard renderInteractiveNow(states, now, lastLines, lastRenderedBlock)
      lastRender = now

    if finished < jobs.len:
      sleep TestProgressPollSleepMs

  for thread in mitems(threads):
    joinThread(thread)

  if renderInteractive:
    discard renderInteractiveNow(
      states,
      getMonoTime(),
      lastLines,
      lastRenderedBlock,
      includeFinished = true
    )
    stdout.write "\n"
    stdout.flushFile()

  if result.cancelled:
    killRegisteredProcesses(addr registry)
  uninstallCancellationHook()
  deinitLock(eventQueue.lock)
  deinitLock(registry.lock)
  deinitLock(startLock)

proc runAtlasTests*(options: AtlasTestOptions): int =
  let
    projectDir = effectiveProjectDir(options.projectDir)
    nimcacheRoot = effectiveNimcacheRoot(projectDir, options.nimcacheDir)
    testFiles = discoverTestFiles(projectDir, options.selectors)
    workerCount = effectiveJobs(options.jobs, testFiles.len)
  var jobs: seq[TestJob]
  for path in testFiles:
    jobs.add makeTestJob(projectDir, nimcacheRoot, path, options.nimExe)
  if options.shuffle:
    shuffleJobs(jobs)

  let runResult = runTestJobs(jobs, workerCount, options.showProgress, options.showOutput)
  if runResult.cancelled:
    echo "atlas-run: test run interrupted"
    return 130

  var failures = 0
  for testResult in runResult.results:
    if testResult.exitCode != 0:
      inc failures

  if failures == 0:
    echo "atlas-run: ", runResult.results.len, " tests passed"
    result = 0
  else:
    echo "atlas-run: ", failures, " of ", runResult.results.len, " tests failed"
    result = 1
