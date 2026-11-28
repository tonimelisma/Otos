---
name: long-checks
description: Supervise a full script/check.sh run on a Mac (or read CI's) — heartbeats, hang and deadlock reports, swift-inspect and sample, parallel runs, killing a run. Use whenever check.sh builds and tests.
---

# Supervising a check that builds

Where Xcode is installed, run `script/check.sh` with `run_in_background: true`, and never
`verify.sh`, `test.sh` or `build.sh` directly: `check.sh` orders the gates and supervises
them. A hung process never completes and never reports, so a wait on completion alone is
unbounded (one waited 9 h 40 m). A long check is watched, not awaited.

- **Arm a `Monitor`** that emits the log's newest heartbeat every 60 seconds. Stop it in
  the same action that reads the result. The log's path is `check.sh`'s first line
  (`op=check.log path=…`). An unstopped watcher keeps running for hours.
- **The heartbeat** reads
  `op=check.heartbeat elapsed=MM:SS stage=<stage> tests=<count> cpuSeconds=<n>`.
  - `tests=` climbing is healthy.
  - `tests=` unchanged for three heartbeats is hung, and `check.sh` then reports the host
    as `op=check.hang` lines.
  - No heartbeat at all means the script died: read the tail.
- **Deadlock detection.** `check.sh` watches the CPU its own process tree consumes. When
  that stays under 5 CPU-s per minute for 420 s (`op=check.stall`), it reports, kills its
  own children and fails (`check: DEADLOCKED`). It never kills on a quiet log.
- **A run at three times its measured duration** (`op=check.duration`) is hung, not slow.
  Diagnose it rather than waiting it out.

## Reading a hang

Each tool shows half the picture:
- `xcrun swift-inspect dump-concurrency <xctest pid>` prints every task object still
  allocated, each with the async backtrace of its last suspension. It does not mark a task
  that has finished. Only tasks under Swift Testing's runner are tests in flight
  (`inFlight`); the rest are `mayBeFinished`
  (docs/research/2026-11-16-finished-tasks-in-concurrency-dumps.md).
- A test blocked synchronously (a lock, a semaphore, a `sync` call) is a *running* task.
  The dump gives only its thread (`onThread`); `sample` gives that thread's stack and the
  main thread's (`threadStack`). A test parked at an `await` owns no thread, so `sample`
  cannot show it.

Never paper over a hang with a kill-timeout. A suite that hangs has a defect; fix the
defect.

## Parallel runs

Several sessions in several worktrees run `check.sh` at once, often while Otos runs; that
is normal.
- Each worktree builds into its own `build/DerivedData` and kills only its own
  descendants. Tests run in a standalone `xctest` host, never inside Otos.app.
- Runs sharing one checkout take turns on its build folder
  (`op=<run>.wait reason=buildFolderBusy`).
- A check whose tree changed mid-run fails with `op=check.tree phase=changed`.
- Builds share one compilation cache, with source paths mapped to `/^worktree` (ADR 0044).
- Kill the **tree**, never the parent alone, and confirm with
  `ps -eo pid,etime,command` that nothing survives. `etime` is `[[DD-]hh:]mm:ss`, so
  `09:40:13` is nine hours.
- Verification evidence comes only from a run that measured the final tree.
