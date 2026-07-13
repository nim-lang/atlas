#
#           Atlas Package Cloner
#        (c) Copyright 2026 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std/[
  algorithm, atomics, cmdline, deques, locks, monotimes, os, osproc, paths,
  random, streams, strutils, terminal, times
]

when defined(posix):
  from std/posix import Pid, SIGKILL, SIGTERM, killpg, setpgid

import basic/reporters

type
  AtlasTestOptions* = object
    projectDir*: Path
    nimExe*: string
    nimcacheDir*: Path
    compilerArgs*: seq[string]
    jobs*: int
    selectors*: seq[string]
    skipSelectors*: seq[string]
    compileOnly*: bool
    shuffle*: bool
    showProgress*: bool
    showOutput*: bool
    onlyErrors*: bool
    showCompilerOutput*: bool

  AtlasTestResult* = object
    label*: string
    path*: Path
    commandLine*: string
    exitCode*: int
    compileExitCode*: int
    compileOutput*: string
    runOutput*: string
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
    exitCode: int
    compileExitCode: int
    compileOutput: string
    runOutput: string

  TestProgressEventQueue = object
    lock: Lock
    items: Deque[TestProgressEvent]

  TestWorkerArgs = object
    jobs: seq[IndexedTestJob]
    compileOnly: bool
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
  TestProgressLeftPadding = 2

var testRunCancelled: Atomic[bool]

proc initAtlasTestOptions*(projectDir = Path"";
                           nimExe = "nim";
                           nimcacheDir = Path"";
                           compilerArgs: seq[string] = @[];
                           jobs = DefaultAtlasTestJobs;
                           selectors: seq[string] = @[];
                           skipSelectors: seq[string] = @[];
                           compileOnly = false;
                           shuffle = true;
                           showProgress = true;
                           showOutput = true;
                           onlyErrors = false;
                           showCompilerOutput = false): AtlasTestOptions =
  AtlasTestOptions(
    projectDir: projectDir,
    nimExe: nimExe,
    nimcacheDir: nimcacheDir,
    compilerArgs: compilerArgs,
    jobs: jobs,
    selectors: selectors,
    skipSelectors: skipSelectors,
    compileOnly: compileOnly,
    shuffle: shuffle,
    showProgress: showProgress,
    showOutput: showOutput,
    onlyErrors: onlyErrors,
    showCompilerOutput: showCompilerOutput
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

proc addUniquePath(paths: var seq[Path]; path: Path) =
  var found = false
  for existing in paths:
    if existing == path:
      found = true
  if not found:
    paths.add path

proc hasPathSeparator(selector: string): bool =
  selector.find('/') >= 0 or selector.find('\\') >= 0

proc hasGlobWildcard(selector: string): bool =
  selector.find('*') >= 0 or selector.find('?') >= 0 or selector.find('[') >= 0

proc isNimSource(path: Path): bool =
  normalizePathText($path).endsWith(".nim")

proc selectorProjectPath(projectDir: Path; selector: string): Path =
  let selectedPath = Path(selector).expandTilde()
  if selectedPath.isAbsolute:
    result = selectedPath.absolutePath()
  else:
    result = (projectDir / selectedPath).absolutePath()

proc selectorProjectPattern(projectDir: Path; selector: string): string =
  let selectedPath = Path(selector).expandTilde()
  if selectedPath.isAbsolute:
    result = $selectedPath
  else:
    result = $(projectDir / selectedPath)

proc matchesTestSelector(path: Path; selector: string): bool =
  let
    name = normalizePathText($path.splitFile().name)
    selectorName = normalizePathText($Path(selector).splitFile().name)
    testName =
      if selectorName.startsWith("t"):
        selectorName
      else:
        "t" & selectorName

  if selector.endsWith(".nim"):
    result = name == testName
  else:
    result = name.startsWith(testName)

proc discoverDirectSelectorFiles(projectDir: Path; selector: string): seq[Path] =
  if selector.hasGlobWildcard():
    for match in walkPattern(selectorProjectPattern(projectDir, selector)):
      let path = Path(match).absolutePath()
      if fileExists($path) and path.isNimSource():
        result.addUniquePath path
  else:
    let path = selectorProjectPath(projectDir, selector)
    if fileExists($path) and path.isNimSource():
      result.addUniquePath path

  result.sort(proc(a, b: Path): int = cmp($a, $b))

proc matchesSelector(path: Path; selector: string): bool =
  if not selector.hasPathSeparator():
    result = matchesTestSelector(path, selector)

proc matchesDirectSelector(projectDir, path: Path; selector: string): bool =
  if selector.hasGlobWildcard():
    for match in walkPattern(selectorProjectPattern(projectDir, selector)):
      let matchPath = Path(match).absolutePath()
      if matchPath == path:
        return true
  else:
    result = selectorProjectPath(projectDir, selector) == path

proc matchesSkipSelector(projectDir, path: Path; selector: string): bool =
  if selector.hasPathSeparator():
    result = matchesDirectSelector(projectDir, path, selector)
  else:
    result = matchesSelector(path, selector)

proc discoverAllTestFiles(projectDir: Path): seq[Path] =
  let testsDir = projectDir / Path"tests"
  for path in walkFiles($(testsDir / Path"t*.nim")):
    result.add Path(path).absolutePath()
  result.sort(proc(a, b: Path): int = cmp($a, $b))

proc discoverTestFiles*(projectDir: Path;
                        selectors: openArray[string] = [];
                        skipSelectors: openArray[string] = []): seq[Path] =
  let
    projectDir = effectiveProjectDir(projectDir)
    allFiles = discoverAllTestFiles(projectDir)

  if selectors.len == 0:
    result = allFiles
  else:
    for selector in selectors:
      var matched = false
      if selector.hasPathSeparator():
        for path in discoverDirectSelectorFiles(projectDir, selector):
          result.addUniquePath path
          matched = true
      else:
        for path in allFiles:
          if matchesSelector(path, selector):
            result.addUniquePath path
            matched = true
      if not matched:
        raise newException(ValueError, "test selector did not match: " & selector)

  if result.len == 0:
    raise newException(ValueError, "no tests found matching tests/t*.nim")

  if skipSelectors.len > 0:
    var filtered: seq[Path]
    for path in result:
      var skip = false
      for selector in skipSelectors:
        if matchesSkipSelector(projectDir, path, selector):
          skip = true
      if not skip:
        filtered.add path
    result = filtered

  if result.len == 0:
    raise newException(ValueError, "all selected tests were skipped")

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
  let relativeText = normalizePathText($relativeTest)
  if relativeText == ".." or relativeText.startsWith("../") or
      relativeText.startsWith("/"):
    var safeName = normalizePathText($path.absolutePath().changeFileExt(""))
    safeName = safeName.replace(":", "_").replace("/", "_")
    result = nimcacheRoot / Path"external" / Path safeName
  else:
    result = nimcacheRoot / relativeTest

proc testExecutablePath(nimcache, path: Path): Path =
  nimcache / Path(($path.splitFile().name).addFileExt(ExeExt))

proc nimFlagsArgs(): seq[string] =
  let flags = getEnv("NIMFLAGS").strip()
  if flags.len > 0:
    result = parseCmdLine(flags)

proc makeTestJob(projectDir, nimcacheRoot, path: Path;
                 nimExe: string;
                 userCompilerArgs: openArray[string];
                 compileOnly: bool): TestJob =
  let
    label = testLabel(projectDir, path)
    nimcache = testNimcacheDir(projectDir, nimcacheRoot, path)
    executable = testExecutablePath(nimcache, path)
  var compileArgs = @["c"]
  compileArgs.add nimFlagsArgs()
  compileArgs.add userCompilerArgs
  compileArgs.add @[
    "--colors:on",
    "-d:nimUnittestColor:on",
    "--nimcache:" & $nimcache,
    "--out:" & $executable,
    label
  ]
  let
    compileCommandLine = quoteCommand(nimExe, compileArgs)
    commandLine =
      if compileOnly:
        compileCommandLine
      else:
        compileCommandLine & " && " & quoteShell($executable)
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
    commandLine: commandLine
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
    "success"
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

proc terminalColumns(): int =
  try:
    result = terminalWidth()
  except CatchableError:
    result = 80
  if result <= 0:
    result = 80

proc clipText(text: string; width: int): string =
  if width <= 0:
    result = ""
  elif text.len <= width:
    result = text
  elif width <= 2:
    result = text[0 ..< width]
  else:
    result = text[0 ..< width - 2] & ".."

proc progressBar(stage: TestStage): string =
  let
    percent = stagePercent(stage)
    filled = min(TestProgressBarWidth, (percent * TestProgressBarWidth) div 100)
  result = "["
  if filled > 0:
    if filled > 1:
      result.add repeat('=', filled - 1)
    if filled < TestProgressBarWidth:
      result.add ">"
    else:
      result.add "="
  if filled < TestProgressBarWidth:
    result.add repeat(' ', TestProgressBarWidth - filled)
  result.add "]"

proc progressPhase(state: TestJobState; now: MonoTime): string =
  result = state.stage.stageName()
  if state.running:
    let idleMs = inMilliseconds(now - state.lastActivityAt)
    if idleMs >= TestProgressQuietMs:
      result = state.stage.stageName() & " " & formatIdleDuration(idleMs)
    result.add " "
    result.add spinnerFrame()

proc renderTestProgressBlock(states: seq[TestJobState];
                             now: MonoTime;
                             includeFinished = false): seq[string] =
  var rows: seq[tuple[label, bar, phase: string]]
  var phaseWidth = 0
  for state in states:
    if state.running or state.failed or (includeFinished and state.finished):
      let phase = progressPhase(state, now)
      phaseWidth = max(phaseWidth, phase.len)
      rows.add (state.label, progressBar(state.stage), phase)

  let
    columns = max(1, terminalColumns() - 1)
    statusWidth = TestProgressBarWidth + 2 + 1 + phaseWidth
    labelWidth = max(
      0,
      columns - TestProgressLeftPadding - 1 - statusWidth
    )
    padding = repeat(' ', TestProgressLeftPadding)

  for row in rows:
    let status = row.bar & " " & row.phase.alignLeft(phaseWidth)
    if labelWidth > 0:
      result.add padding & row.label.clipText(labelWidth).alignLeft(labelWidth) &
        " " & status
    else:
      result.add padding & status

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
        isSuccess = " success" in line
        isFailed = " failed" in line
        color =
          if isFailed:
            fgRed
          elif isSuccess:
            fgGreen
          else:
            fgCyan
      let barStart = line.rfind('[')
      let barEnd =
        if barStart >= 0:
          line.find(']', barStart)
        else:
          -1
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

    var compileOutput = ""
    var runOutput = ""
    var compileExitCode = 130
    var exitCode = 130
    var currentStage = tsCompiling
    try:
      if not cancellationRequested():
        currentStage = tsCompiling
        let compileResult = runTestProcess(
          job,
          indexedJob,
          job.compileCommand,
          job.compileArgs,
          tsCompiling,
          args
        )
        compileOutput = compileResult.output
        compileExitCode = compileResult.exitCode
        exitCode = compileExitCode

      if exitCode == 0 and not args.compileOnly and not cancellationRequested():
        currentStage = tsRunning
        let runResult = runTestProcess(
          job,
          indexedJob,
          job.runCommand,
          job.runArgs,
          tsRunning,
          args
        )
        runOutput = runResult.output
        exitCode = runResult.exitCode

      args.events.pushEvent TestProgressEvent(
        kind: tpFinished,
        jobIndex: indexedJob.index,
        label: job.label,
        stage: if exitCode == 0: tsDone else: tsFailed,
        exitCode: exitCode,
        compileExitCode: compileExitCode,
        compileOutput: compileOutput,
        runOutput: runOutput
      )
    except CatchableError as exc:
      if currentStage == tsCompiling:
        compileOutput.add $exc.name & ": " & exc.msg & "\n"
        compileExitCode = 1
      else:
        runOutput.add $exc.name & ": " & exc.msg & "\n"
      args.events.pushEvent TestProgressEvent(
        kind: tpFinished,
        jobIndex: indexedJob.index,
        label: job.label,
        stage: tsFailed,
        exitCode: 1,
        compileExitCode: compileExitCode,
        compileOutput: compileOutput,
        runOutput: runOutput
      )

proc effectiveJobs(requested, testCount: int): int =
  if requested > 0:
    max(1, min(requested, testCount))
  else:
    let defaultJobs = max(1, countProcessors() div 2)
    max(1, min(defaultJobs, testCount))

proc writeOutputText(output: string) =
  if output.len > 0:
    stdout.write output
    if not output.endsWith("\n"):
      stdout.write "\n"

proc writeResultChunk(result: AtlasTestResult; showCompilerOutput: bool) =
  let
    status =
      if result.exitCode == 0:
        arsSuccess
      else:
        arsFailed
    statusText =
      if result.exitCode == 0:
        "success"
      else:
        "failed"
  writeAtlasRunStatusLine(result.label & " ", statusText, status)
  writeAtlasRunLine("command: " & result.commandLine)
  if showCompilerOutput or result.compileExitCode != 0:
    writeOutputText(result.compileOutput)
  writeOutputText(result.runOutput)
  stdout.flushFile()

proc writeResultSummary(result: AtlasTestResult) =
  let
    status =
      if result.exitCode == 0:
        arsSuccess
      else:
        arsFailed
    statusText =
      if result.exitCode == 0:
        "success"
      else:
        "failed"
  writeAtlasRunStatusLine(result.label & " ", statusText, status)
  stdout.flushFile()

proc writeStartedSummary(label: string; stage: TestStage) =
  let action =
    if stage == tsCompiling:
      "compiling"
    else:
      "running"
  writeAtlasRunStatusLine(label & " ", action, arsRunning)
  stdout.flushFile()

proc runTestJobs(jobs: seq[TestJob];
                 workerCount: int;
                 showProgress, showOutput: bool;
                 onlyErrors, showCompilerOutput: bool;
                 compileOnly: bool): tuple[
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
        compileOnly: compileOnly,
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
      writeAtlasRunStatusLine("interrupted; killing tests ", "running", arsRunning)
      stdout.flushFile()
      killRegisteredProcesses(addr registry)

    for ev in drainEvents(addr eventQueue):
      case ev.kind
      of tpStarted:
        states[ev.jobIndex].running = true
        states[ev.jobIndex].stage = ev.stage
        states[ev.jobIndex].lastActivityAt = now
        if showOutput and not renderInteractive and not result.cancelled:
          writeStartedSummary(ev.label, ev.stage)
      of tpUpdated:
        let previousStage = states[ev.jobIndex].stage
        states[ev.jobIndex].running = true
        states[ev.jobIndex].stage = ev.stage
        states[ev.jobIndex].lastActivityAt = now
        if showOutput and not renderInteractive and not result.cancelled and
            previousStage != ev.stage:
          writeStartedSummary(ev.label, ev.stage)
      of tpFinished:
        states[ev.jobIndex].running = false
        states[ev.jobIndex].finished = true
        states[ev.jobIndex].failed = ev.exitCode != 0
        states[ev.jobIndex].stage = ev.stage
        states[ev.jobIndex].lastActivityAt = now
        result.results[ev.jobIndex].exitCode = ev.exitCode
        result.results[ev.jobIndex].compileExitCode = ev.compileExitCode
        result.results[ev.jobIndex].compileOutput = ev.compileOutput
        result.results[ev.jobIndex].runOutput = ev.runOutput
        result.results[ev.jobIndex].output = ev.compileOutput & ev.runOutput
        inc finished
        let shouldWriteOutput = showOutput and not result.cancelled and
          (not onlyErrors or ev.exitCode != 0)
        if shouldWriteOutput:
          if renderInteractive:
            clearInteractiveBlock(lastLines)
            lastRenderedBlock = ""
          writeResultChunk(result.results[ev.jobIndex], showCompilerOutput)
          if renderInteractive:
            if renderInteractiveNow(states, now, lastLines, lastRenderedBlock):
              lastRender = now
        elif showOutput and onlyErrors and not renderInteractive and
            not result.cancelled and ev.exitCode == 0:
          writeResultSummary(result.results[ev.jobIndex])
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
    testFiles = discoverTestFiles(projectDir, options.selectors,
      options.skipSelectors)
    workerCount = effectiveJobs(options.jobs, testFiles.len)
  var jobs: seq[TestJob]
  for path in testFiles:
    jobs.add makeTestJob(
      projectDir,
      nimcacheRoot,
      path,
      options.nimExe,
      options.compilerArgs,
      options.compileOnly
    )
  if options.shuffle:
    shuffleJobs(jobs)

  let runResult = runTestJobs(
    jobs,
    workerCount,
    options.showProgress,
    options.showOutput,
    options.onlyErrors,
    options.showCompilerOutput,
    options.compileOnly
  )
  if runResult.cancelled:
    writeAtlasRunStatusLine("test run ", "interrupted", arsFailed)
    return 130

  var failures = 0
  for testResult in runResult.results:
    if testResult.exitCode != 0:
      inc failures
  let
    total = runResult.results.len
    passed = total - failures

  if failures == 0:
    let statusText =
      if options.compileOnly:
        "compiled"
      else:
        "passed"
    writeAtlasRunStatusLine($passed & "/" & $total & " ", statusText, arsSuccess)
    result = 0
  else:
    let successText =
      if options.compileOnly:
        " compiled, "
      else:
        " passed, "
    writeAtlasRunStatusLine(
      $passed & "/" & $total & successText & $failures & "/" & $total & " ",
      "failed",
      arsFailed
    )
    result = 1
