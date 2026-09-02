# Research: xctest host stalls before running any test (2026-09-01)

Recorded because it cost several hours across one session and was twice misdiagnosed — once
as a suite defect, once as resource pressure. It is neither.

## Signature

`script/check.sh` reaches `stage=verify`, `xcodebuild test-without-building` starts, `xctest`
starts, and then nothing happens. The identifying facts, all reproducible from a `sample`:

- `cpuSeconds` in the heartbeat is **flat across consecutive minutes** (19, 19, 19).
- The log contains **zero `Test case` lines** — no test ever reported.
- `sample <xctest pid>` shows **zero `(in OtosKit)` / `(in OtosTests)` frames**.
- **Zero threads blocked** on `semaphore_wait`, `psynch_cvwait`, or `_dispatch_sema`.
- The main thread is parked in XCTest's own driver:
  `_XCTestMain → -[XCTestDriver _runTests] → XCTAsyncEnumerateWithWaiter →
  -[XCTWaiter _performWait:manager:completionHandler:] → mach_msg2_trap`.

The host is idle, not deadlocked, and it is not running our code.

## What it is not

- **Not a suite defect.** No Otos frame appears in any thread. Nothing of ours is executing,
  so nothing of ours can be looping or deadlocking.
- **Not resource pressure.** Observed with 37% system memory free and 20 GB disk free.
- **Not tree-specific.** The same tree, unchanged, completed on other attempts — 862 tests
  green on one run and stalled on the next.

## Cause: a wedged `testmanagerd`

`/usr/libexec/testmanagerd` is the system daemon that hands tests to `xctest`. When a test
run is killed with `SIGKILL`, the daemon can survive **orphaned** (`PPID 1`) in a state where
it accepts a new `xctest` connection and then never delivers any test to run. That produces
the signature above exactly: the host connects, waits, and nothing of ours ever executes.

Confirmed on the fourth occurrence — `ps` showed `49136 1 13:24 /usr/libexec/testmanagerd`,
orphaned and older than the run it was serving. Killing it (launchd respawns it on demand)
cleared the stall.

It is not in the project's process tree, so "kill the tree, never the parent alone" does not
cover it. `check.sh`, `xcodebuild`, and `xctest` can all be dead while the daemon that wedged
them is still running and poisoning every subsequent run.

## Frequency

Four occurrences in one session. The first three read as intermittent — they interleaved with
successful runs — because the daemon only wedges after a `SIGKILL`, and a run that completes
normally leaves it healthy. Once wedged it is **persistent**, not intermittent: every
subsequent run stalls until the daemon is cleared.

## What to do

1. **Confirm the signature before acting** — flat `cpuSeconds`, no `Test case` lines, no Otos
   frames in a `sample`. Without all three it is a different problem and this note does not
   apply.
2. **Check for an orphaned `testmanagerd` first** — `ps -eo pid,ppid,etime,comm | grep
   testmanagerd`. A `PPID 1` daemon older than the current run is the cause; kill it and
   re-run. This is the fix, and nothing else in the list matters if it is present.
3. **Then kill the tree and re-run.** Kill `check.sh`, `xcodebuild`, and `xctest` — killing
   the parent alone orphans children that then compete with the retry for the same
   `build/DerivedData`, which is its own cause of stalls.
4. **Do not add a kill-timeout to shared tooling.** A wall-clock limit destroys legitimately
   slow runs and hides the failure instead of surfacing it. `check.sh`'s existing detector
   already watches CPU consumed rather than wall time, which is the right discriminator.

## Cost of misdiagnosis

The first occurrence was recorded as "the suite hangs, defect undiagnosed" and blocked an
increment overnight. The second was attributed to OneDrive thrashing a nearly-full disk. The
third was called intermittent and retried blindly. All three readings were wrong.

The sample rules out our code in one command; `ps` for an orphaned `testmanagerd` names the
cause in a second. Neither was run until the fourth occurrence. The lesson is not "take a
sample" but **check what the failing thing depends on** — `xctest` waiting on a daemon is not
visible in `xctest`'s own stack, only in the process table.

There is also a self-inflicted loop here worth naming: each `SIGKILL` used to clear a stall
could wedge the daemon that causes the next one.
