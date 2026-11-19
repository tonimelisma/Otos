# ADR 0043: Performance is measured once a week, in one run with one verdict

- Status: Accepted
- Last updated: 2026-11-18

## Context

Otos has two performance instruments. The **tour** (ADR 0015) runs the installed app over
the owner's library and reports what a session felt, against the targets in
`docs/scorecard-targets.json`. The **benchmarks** count the instructions owner code retires
on a generated catalog, per commit. Until 2026-11-18 they ran as two processes. The
benchmarks ran daily, and a flagged case became the next work unless the owner accepted it.
Every performance PR toured the owner's library before and after. Nothing scheduled a tour.

The owner asked why the same outcome was looked for twice, and asked for one short process
run rarely (2026-11-18). The record (`docs/research/2026-11-18-performance-process.md`):

- The tours found every felt win of the performance program (a view from 48.8 s to 51 ms,
  launch from 4.0 s to 1.1 s). The benchmarks found none of them.
- The benchmarks' flags were not felt. Each one took a bisection, a research note and a fix.
  The last was a SQL comment holding `§` and an order walk, measured in a `-Onone` build.
- Chromium, Firefox and rustc all triage a lab counter's alert: they do not block on it, and
  most alerts are not work. They set priorities from user-felt numbers. A one-owner project
  has no sheriff, so making every alert someone's next work is the toil this repo had.

Two measured facts shape the counts (2026-11-01, a duplicates build on a copy of the
owner's catalog):

- **Wall time is not a stable measure on this machine.** The same build's phases varied
  2–5× between runs while another worktree's `xcodebuild` ran. Parallel checks are normal
  here.
- **Instructions retired are stable.** On the same runs, each phase's count varied by about
  1%.

## Decision

### One weekly run

- **One entry point, `script/perf.sh`.** `status` prints one line, `op=perf.status
  verdict=due|running|pass|fail|error`, which `script/check.sh` prints on every run. `run`
  does the run. `self-test` holds the status and verdict rules against stubbed inputs, in
  check's fast gates.
- **Once a week.** A run is due when the last one finished seven or more days ago and
  `origin/main` has moved since. A run that could not measure (`error`) is due again the next
  day. Rejected: daily, since the counts' flags were not felt and a felt regression a week old
  is still cheap to find; before every install, which in practice is daily.
- **The session starts it.** The session whose check prints `verdict=due` starts
  `script/perf.sh run` in the background and keeps working. The run re-executes from the
  primary checkout, which outlives the session's worktree. It holds a kernel lock
  (`otos_hold_lock`) on a file in the clone's git directory, so a second start reports
  `phase=skipped` and `status` reads `verdict=running`. The lock dies with the run.
  Rejected: a launchd agent, which is persistent configuration on the owner's Mac and owns a
  run nobody watches; GitHub Actions, which has no runner with this repo's Xcode beta.
- **What it measures, in order.**
  1. **The tour** of the installed app on the owner's library, read-only: a launch tour
     with a 120 s idle (`script/scorecard.sh --tour --idle 120`). The owner set two
     minutes on 2026-11-18; stall lines are still judged as a rate per 10 minutes. The tour never runs beside a running
     installed app. The run quits that app through the helper `script/install.sh` uses
     (`otos_quit_installed_app`, `script/lib/installed-app.sh`): never while an import or
     reorganization is in flight (then `phase=pending`, and it stays due), with a
     normal Quit, never a kill. It reopens the app in the background when the tour ends,
     however the run ends. The scorecard is saved under the primary checkout's
     `build/scorecards/`.
  2. **The counts** of `origin/main`'s head against the last run's head
     (`refs/bench/baseline`), through `script/bench.sh compare <baseline> <head>`, which
     measures either side that has no records.
- **One verdict.** The verdict is `fail` when any scorecard row is `FAIL`: a target missed
  on the owner's library, a tour step that reached its deadline, or memory pressure Otos
  caused. Otherwise it is `pass`. The line names the missed targets (`felt=`) and the flagged
  cases (`cpu=`). A tour that judged nothing, or a comparison that failed or was refused, is
  `error`, and it moves no baseline.
- **What a failure means.** A `fail` is fixed next. The fix starts with one tour that
  reproduces the miss. A miss that does not reproduce is noted in the DoD and left to the next
  weekly run, because the weekly tour runs beside whatever else the machine is doing. A
  target changes only with the owner's decision, in `docs/scorecard-targets.json`.
- **Instruction rises decide nothing.** They are listed in the verdict, and the baseline
  moves to each run's head. The owner decides whether a rise is work. The counts remain the
  per-commit trail for finding the commit behind a felt miss (`bench.sh history`,
  `bench.sh compare`). Rejected: a flag that is the next work until accepted, which the owner
  chose before; its flags were not felt, and it turned every alert into a bisection.
- **Per PR, nothing.** One `script/check.sh` is a PR's verification. A performance PR adds a
  deterministic twin test for its win (rows visited per row returned, stall lines in
  `StallReproductionTests`, a hosted footprint) and says it is measured in the next weekly run.
  No session runs a tour or a comparison for a PR unless it is reproducing a `fail` or the
  owner asks for it. Rejected: a before-and-after owner tour on every performance PR, which
  cost about ten minutes of a quiet machine each, often several times a PR.

### The counts

- **The cases live in the test target.** `OtosTests/BenchmarkTests.swift` holds them and
  `OtosTests/BenchmarkSupport.swift` the harness, with the same `@testable` access as any
  test, so a case measures the real owner code.
- **A case counts Otos's own code.** Work that is Apple's (Core Image's crop, Core ML's
  predictions, Vision's text reading) has no case: no Otos change moves its count, and its
  noise is the framework's (up to 45% between processes for the crop). Those suites test
  their results. A new hot path of Otos's own gets a case when it is worked on.
- **They are opt-in.** The suite is enabled only when `OTOS_BENCHMARK=1`, which
  `script/bench.sh` passes through the scheme. `script/check.sh` never measures them, but
  every check runs each scenario that holds a store, a projection or the grid once, small and
  unmeasured (`BenchmarkScenarioTests`, `BenchmarkRun.checked`). What a scenario expects
  beyond its numbers then fails the change that breaks it, not the next weekly run, which
  records nothing for a failed case.
- **Fixtures are generated from a fixed seed, never the owner's library.**
  `BenchmarkLibrary` builds about 15,000 stills shaped like the owner's catalog of
  2026-11-01, so every commit measures the same catalog. Each case checks that it did its
  work, so a broken fixture fails instead of measuring nothing. No case asserts a budget.
- **A measurement is several test processes, each with one hash seed.** Each side builds
  once in a detached checkout of its commit and runs the suite in `OTOS_BENCH_PROCESSES`
  fresh processes (default 3), each with `SWIFT_DETERMINISTIC_HASHING=1`. Each case gets one
  warm-up run and five measured runs.
  - For each run the harness records the instructions the test process retired
    (`proc_pid_rusage`, `ri_instructions`) and the wall time. A process's result keeps the
    median instructions, their spread, and the median and minimum milliseconds.
  - Counting is process-wide, because a case's work hops between actors and into the
    frameworks' threads, and the suite is serialized. A case that asks what the main thread
    alone spends (the `….mainThread` grid cases) counts that thread's own instructions
    (`thread_selfcounts`).
  - Several processes, because a count differs from one process to the next by more than its
    samples vary inside one: the allocator (xzone malloc) and the frameworks' worker threads
    settle differently in each process, and neither can be held still on a release macOS.
  - One hash seed, because random seeding alone made some cases differ by 4–5% between
    processes; with one seed, under 2% (`docs/research/2026-11-11-benchmark-process-variance.md`).
- **Results are recorded per commit, as git notes** (`refs/notes/benchmarks`), one JSON
  object per case and process, with the machine model, macOS, Xcode, configuration and
  harness number. Notes attach data to the exact commit measured, are shared by every
  worktree of the clone, and survive branch removal. An append is built on a ref of its own
  and moves the shared ref only if it is unchanged, so a parallel append is never lost.
  `compare` sets only records of one harness and machine against each other.
- **When a case is flagged.** Its median over head's processes rose by more than 2% and by
  more than the case's noise, the widest range its processes spanned on one commit over the
  newest 10 measured commits. The rise is also beyond every process's range: head's lowest
  sample still exceeds base's highest. A smaller or noisier rise is reported as
  `within noise`.

## Rejected alternatives

- **Keep only the tour.** A felt miss would have no per-commit trail, and bisecting by tour
  costs about ten minutes a step on a quiet machine.
- **Keep only the counts.** They missed every felt win of the program. They measure a
  `-Onone` build on a generated catalog, so the owner's waits, cold reads and memory pressure
  never reach them.
- **XCTest `measure` with Xcode baselines.** One number per machine, pass/fail, no history per
  commit, and XCTest beside a Swift Testing suite.
- **ordo-one/package-benchmark.** It runs over a Swift package's code; Otos's owner code is
  reached through an Xcode test target. Adopting it means restructuring the build or a
  third-party dependency.
- **Wall-time budgets in `check.sh`.** A budget measured under parallel load either fails on
  load or is so loose it catches nothing (ADR 0033).
- **A results file committed to the tree.** Every run would be a commit and conflict across
  worktrees.

## Consequences

- A week costs one run in the background of one session: a tour of about eleven minutes with
  the installed app quit for that time, and for each side without records a build and three
  test processes (about five minutes). A PR costs no measurement.
- A felt regression is found within a week, as a range of commits. An instruction rise is
  shown once in the weekly line and always in `bench.sh history`. A rise the owner does not
  take up stays, and drift below the per-run noise is not flagged run to run.
- Acts are timed only in a sandbox library (ADR 0015), so the weekly run does not judge
  `act.resultMs`. Their CPU paths have cases (`grid.choiceReconfigure…`, `grid.hideApply…`),
  and the sandbox tour measures them when the owner asks or an act is being fixed.
- The counts build at `-Onone`, which the installed app does not run (ADR 0030).
- Numbers compare only on one machine and configuration. Notes stay in the local clone
  unless pushed (`git push origin refs/notes/benchmarks`).
