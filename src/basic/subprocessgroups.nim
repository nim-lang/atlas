#
#           Atlas Package Cloner
#        (c) Copyright 2026 The Atlas contributors
#

## Optional POSIX subprocess group management for packager-owned child
## processes so Ctrl-C can terminate children explicitly.

import std/[locks, osproc, strtabs]

when not defined(windows):
  import std/posix

var managedSubprocessGroupsEnabled* = false

when not defined(windows):
  var
    subprocessGroupLock: Lock
    subprocessGroupLockInitialized = false
    managedProcessGroups: seq[Pid]

  proc ensureSubprocessGroupLock() =
    if not subprocessGroupLockInitialized:
      initLock(subprocessGroupLock)
      subprocessGroupLockInitialized = true

  proc rememberManagedProcessGroup(pgid: Pid) =
    if pgid <= 0:
      return
    ensureSubprocessGroupLock()
    acquire(subprocessGroupLock)
    try:
      if pgid notin managedProcessGroups:
        managedProcessGroups.add pgid
    finally:
      release(subprocessGroupLock)

  proc forgetManagedProcessGroup(pgid: Pid) =
    if pgid <= 0 or not subprocessGroupLockInitialized:
      return
    acquire(subprocessGroupLock)
    try:
      var next: seq[Pid]
      for existing in managedProcessGroups:
        if existing != pgid:
          next.add existing
      managedProcessGroups = next
    finally:
      release(subprocessGroupLock)

  proc configureManagedProcessGroup(p: Process) =
    if not managedSubprocessGroupsEnabled or p.isNil:
      return
    let pid = Pid(processID(p))
    if pid <= 0:
      return
    discard setpgid(pid, pid)
    rememberManagedProcessGroup(pid)

proc enableManagedSubprocessGroups*() =
  managedSubprocessGroupsEnabled = true

proc startManagedProcess*(
    command: string;
    workingDir = "";
    args: openArray[string] = [];
    env: StringTableRef = nil;
    options: set[ProcessOption] = {poStdErrToStdOut}
): owned(Process) =
  result = startProcess(command, workingDir, args, env, options)
  when not defined(windows):
    configureManagedProcessGroup(result)

proc waitForManagedExit*(p: Process; timeout = -1): int =
  waitForExit(p, timeout)

proc closeManagedProcess*(p: Process) =
  if p.isNil:
    return
  when not defined(windows):
    if managedSubprocessGroupsEnabled:
      forgetManagedProcessGroup(Pid(processID(p)))
  close(p)

proc terminateManagedSubprocessGroups*() =
  when not defined(windows):
    if not subprocessGroupLockInitialized:
      return
    var pgids: seq[Pid]
    acquire(subprocessGroupLock)
    try:
      pgids = managedProcessGroups
      managedProcessGroups.setLen(0)
    finally:
      release(subprocessGroupLock)

    for pgid in pgids:
      if pgid > 0:
        discard kill(Pid(-pgid), SIGKILL)
