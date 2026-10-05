# 2026-10-04 — check.sh heartbeat was blind for the whole test phase

## Symptom

A `script/check.sh` run in worktree `test-waits` hung in its test phase. Its test log
(`logs/test-20261005T043220Z-p39558-test.log`) held 931 finished tests and `xctest` had
been running ~2.5 min, yet every heartbeat read `stage=building tests=n/a`. The
`tests=` counter, which the hang procedure in `AGENTS.md` relies on, never appeared.
The stall report's `sample` showed only `XCTWaiter` frames, and its "last test to
report" section printed nothing.

## Cause

The heartbeat found its test log with
`find "$ROOT_DIR/logs" -name '*test*.log' -newermt "@$STARTED_AT"`. macOS's
`/usr/bin/find` rejects that date:

    $ /usr/bin/find "$d" -name '*test*.log' -newermt "@1791172253"
    find: Can't parse date/time: @1791172253        (exit 1)

The error went to `2>/dev/null`, so the result was always empty, which meant
`stage=building`.

The expression *seemed* to work by hand only because the agent shell's `find` is not
`/usr/bin/find`. Claude Code's zsh snapshot defines `find` as a shell function that
execs the bundled `bfs`, which accepts the GNU `@epoch` form. `check.sh` runs
under bash without that snapshot and gets BSD find. Verify a script's command in the
script's shell (`bash -c 'type find'`), not the agent's.

## Reproduction

A scratch Swift Testing test that awaits a never-resumed `withCheckedContinuation`
(parks with no CPU), run under `OTOS_CHECK_HEARTBEAT_SECONDS=20
OTOS_CHECK_STALL_SECONDS=150`:

- **Before:** at 21:56:46 the test log held 959 finished tests, while the 21:56:49
  heartbeat read `stage=building tests=n/a`. The stall fired with `stage=building`,
  the `sample` excerpt was all `XCTWaiter`/libdispatch, and no test was named.
- **After:** heartbeats read `stage=testing tests=0`, then `tests=958` unchanged for
  eight heartbeats. The stall fired with `stage=testing tests=958`, and the report
  printed the parked test:

      --- parked tests in xctest 32856 (OtosTests frames, innermost first; full dump: …) ---
      Task 6939:
        withCheckedContinuationNonisolatedNonsending<A>(function:_:) in OtosTests
        ScratchHangReproTests.parkedWait() in OtosTests
        ScratchHangReproTests.parksForever() in OtosTests

  No `xcodebuild`/`xctest` survived the kill.

## What names a parked test

`sample` shows OS threads. A parked Swift-concurrency test owns none: it is a suspended
task, so its frames never appear. `xcrun swift-inspect dump-concurrency <pid>` prints
every task's async backtrace. In the repro it took ~2 s; the 2026-10-04 incident took
~40 s on a busy host. The stuck task read:

    Task 6983:
      withCheckedContinuationNonisolatedNonsending<A>(function:_:) in OtosTests
      ScratchHangReproTests.parkedWait() in OtosTests
      ScratchHangReproTests.parksForever() in OtosTests

The surrounding frames (`$s…` macro entry points, thunks, partial applies) restate the
test function, and the frames below them are the `Testing` runner.

"Last test to report" does not name the hung test. Under parallel execution it is
whichever unrelated test finished last.

## Conclusions applied

- `check.sh` reads the test-log path from `test.sh`'s own `Capturing test output to …`
  line in the captured verify output, with no filesystem or date inference.
- `tests=` counts `passed on` and `failed on`. Counting only passes froze the
  counter at the first failure.
- `xctest` is a child of `xcodebuild` (observed: `xctest` PPID = the `xcodebuild` PID).
  CPU liveness, the stall report and cleanup now walk `check.sh`'s own process
  tree, where they used a machine-wide `pgrep`/`pkill` that adopted, and on exit
  killed, another worktree's run.
- On a stall, the report keeps the `sample` excerpt (it shows synchronous deadlocks)
  and adds the OtosTests frames of a `swift-inspect` dump per test host, saving the
  full dump under `logs/`. The inspector is bounded (`OTOS_CHECK_INSPECT_SECONDS`,
  default 180). That bound limits only the diagnostic on a host already measured as
  parked, never test work.
