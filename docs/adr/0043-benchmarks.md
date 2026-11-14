# ADR 0043: Benchmarks are opt-in, count instructions, are recorded per commit, and run once a day on main

- Status: Accepted
- Last updated: 2026-11-12

## Context

Performance work here is evidence-driven, but the evidence was one-off. Each change was
measured by hand, from installed-app logs or a trace, and nothing kept the numbers. So no
one could see whether a path got slower over a series of commits. The owner asked for a
library of benchmark cases that tracks how long things take, per commit.

Two measured facts shape the design (2026-11-01, a duplicates build on a copy of the
owner's catalog):

- **Wall time is not a stable measure on this machine.** The same build's phases varied
  2–5× from run to run while another worktree's `xcodebuild` ran. Parallel checks are the
  normal case here (see the toolchain section of `AGENTS.md`), not an exception to wait
  out.
- **Instructions retired are stable.** On the same runs, each phase's instruction count
  varied by about 1% (e.g. 1,607 / 1,605 / 1,610 million).

The tooling found:

- Swift Testing, the repo's test framework, has no benchmark or performance API. Its
  maintainers said in 2024 that none was planned
  (https://forums.swift.org/t/benchmark-in-swift-testing/75582).
- XCTest's `measure(metrics:)` reports clock, CPU (including instructions retired) and
  memory metrics. Its baselines are per machine and stored in the scheme's `xcbaselines`.
- ordo-one's `package-benchmark` is the Swift ecosystem's established runner. It is a
  SwiftPM plugin over a package's code.

## Decision

- **The cases live in the test target.** `OtosTests/BenchmarkTests.swift` holds them and
  `OtosTests/BenchmarkSupport.swift` the harness. A case uses the same `@testable` access
  as any test, so a benchmark measures the real owner code, not a copy.
- **They are opt-in.** The suite is enabled only when `OTOS_BENCHMARK=1`, which
  `script/bench.sh run` passes through the scheme, the same way `OTOS_SCALE_TEST` works.
  `script/check.sh` never runs them.
- **A run measures several test processes, each with one hash seed.** `script/bench.sh run`
  builds once and runs the suite in `OTOS_BENCH_PROCESSES` fresh test processes (default
  3), each with `SWIFT_DETERMINISTIC_HASHING=1`. In each process, each case is measured as
  one warm-up run and five measured runs.
  - For each run the harness records the instructions the test process retired
    (`proc_pid_rusage`, `ri_instructions`) and the wall time. A process's result keeps the
    median instructions, their spread, and the median and minimum milliseconds.
  - Instructions are the number to compare across commits; milliseconds are kept as what
    a user waits for.
  - Counting is process-wide because a case's work hops between actors and into Apple's
    frameworks' threads. The suite is serialized so no other test adds to the count.
  - **Why several processes (2026-11-11):** a case's count differs from one process to the
    next by more than its samples vary inside one. A process's allocator (xzone malloc)
    takes different paths in each process, and its switches are locked on a release macOS.
    Core Image's and Vision's worker threads settle into different modes in each process.
    Neither can be held still, so a run measures it.
  - **Why one hash seed (2026-11-11):** each process otherwise seeds `Set` and `Dictionary`
    hashing at random. That alone made the People cases differ by 4–5% between processes;
    with one seed, under 2%. Measured in
    `docs/research/2026-11-11-benchmark-process-variance.md`.
- **Fixtures are generated from a fixed seed, never the owner's library.**
  `BenchmarkLibrary` builds about 15,000 stills shaped like the owner's catalog of
  2026-11-01: one in nine without capture metadata, in screenshot shapes; one in forty
  an identical copy; one in eleven a near-identical version. Every commit therefore
  measures the same catalog.
- **Each case checks that it did its work.** A broken fixture then fails instead of
  measuring nothing. No case asserts a time or instruction budget.
- **Results are recorded per commit, as git notes.** When the tree is clean,
  `script/bench.sh run` appends one JSON object per case to `refs/notes/benchmarks` on
  HEAD. Each object carries the machine model, macOS, Xcode and configuration. Notes
  attach data to the exact commit measured without changing the tree. They are shared by
  every worktree of the clone and survive branch and worktree removal.
- **History is read with `script/bench.sh history [case]`.** It lists the records, newest
  first, with each case's change in instructions from the previous record on the same
  machine.
- **Benchmarks run once a day on `main`, never per PR, and a session runs them
  (2026-11-12).** A per-PR comparison cost two runs a change, the PR head and then `main`
  after the merge, each a build plus three ~70-second test processes: 9–10 minutes of
  every commit, more than the test suite. The owner asked to move it off the commit path.
  - **Due.** `script/check.sh` prints `script/bench.sh status`. It reads `verdict=due`
    when no run has finished today and `origin/main` has moved past the commit the last
    run judged: the **baseline**, the last commit that measured clean
    (`refs/bench/baseline`), or, while a case stays flagged, the flagged head. A flagged
    verdict that is due says so and names its cases (`flagged=`), because only the next
    run can find that a fix landed. The session that sees it starts
    `script/bench.sh daily` in the background and keeps working.
  - **One run, from the primary checkout.** The run holds a kernel lock (`flock`) on a
    file in the clone's git directory, through the same holder process that holds a build
    folder (`otos_hold_lock`, `script/lib/build-folder.sh`), so every other session sees
    `verdict=running` and a second start reports `phase=skipped`. The lock dies with the
    run, so a run killed mid-way or a reboot leaves nothing to reclaim. `status` asks the
    kernel whether the lock is held (`F_GETLK`) without taking it. The pid-in-a-directory
    lock it replaced outlived a `kill -9`, after which `status` read `verdict=running`
    forever and no session started another run; and two starts racing between its `mkdir`
    and the pid write both ran. The run re-executes from the primary checkout and
    measures in a detached checkout under it, because the starting session may remove
    its own worktree before the run ends. It reads `origin/main` as the clone last
    fetched it, since every merge fetches it, so a network that hangs never hangs it.
  - **A clean run moves the baseline; a flagged one does not.** The verdict and the day
    of the last finished run sit beside the lock, shared by every worktree. A regression
    stays flagged across later runs until one measures clean against the same baseline
    (it was fixed) or the owner accepts it (`script/bench.sh accept`). A baseline that
    followed every run would forget a regression the next day.
  - **A run that measured nothing judges nothing.** Both sides are measured with this
    harness first (the baseline too, when it has no record of this harness), a
    measurement that fails or records nothing fails the run with a named phase, and the
    judge refuses a side with no records (exit 4). Such a run moves no baseline and writes
    no last-run day, so the next check reports it due again. Before this, an empty head
    judged `flagged=0`, an unrecorded base made every case "new", and either one became
    the baseline.
  - **`check.sh` never fails on the verdict**, because the fix for a flagged case must
    pass the same check.
  - **Attribution is by hand.** A flagged run names a range of commits;
    `script/bench.sh compare <base>` on a commit in that range bisects it.
  - **Rejected: a launchd agent at night.** It runs whether or not anyone works that
    day, needs installing on each machine, and owns a run no session watches.
  - **Rejected: GitHub Actions nightly.** No hosted runner carries the Xcode 27 beta this
    repo builds with, and the account's Actions minutes are not dependable.
  - **Rejected: per-PR comparison on a shorter suite.** Fewer processes or iterations
    would cut the noise evidence below what a two-mode case needs (below), and the run
    would still sit on every commit.
  - **Records carry their harness.** Each record carries `harness` (now 2), and `compare`
    sets only records of one harness against each other. Records of another harness stay
    as history. A change to what a run counts raises the number in `bench.sh`.
  - **A case's noise is measured, not assumed.** A case's noise is the widest range its
    processes spanned on any one commit, over the newest 10 measured commits. One commit
    is one tree, so whatever its processes disagree on is noise.
  - **When a case is flagged.** Its median over head's processes must have risen by more
    than 2% and by more than the case's noise. The rise must also be beyond every process's
    range: head's lowest sample in any process, median × (1 − spread), still exceeds base's
    highest, median × (1 + spread). The owner then decides whether to accept it.
  - **A rise that is not flagged.** A rise above 2% that fails either test is reported as
    `within noise` and does not flag the run. A smaller change is only reported.
  - **Why 2%.** It is four times the run-to-run variation of a steady case (about ±0.5%),
    so it catches a real regression there.
  - **Why the noise is read from history (2026-11-11):** two processes a side were not
    enough evidence. A case with two modes 2.4% apart was flagged whenever base's
    processes happened to land in one mode and head's in the other. That is how
    `search.readText` (+7.6%) and `search.textMatch.5k` (+2.6%) stopped unrelated PRs.
    The record already holds, per commit, how far each case's processes disagree on one
    tree. A case is held to the noise it has shown, so a steady case stays sharp and a
    two-mode case can only report a rise wider than its modes.
  - **A noisy case cannot be sharpened by the harness.** In `face.crop.x16` (about 14%) the
    noise is in Core Image's threads. A case like that shows only a rise wider than its
    noise, and is made sharper only by changing what it measures, as `face.align` was.
  - **A case that is mostly allocation measures the allocator.** In the Debug build an
    unspecialised generic sequence step allocates, and the allocator's cost differs from
    one process to the next. `face.align.x1000` read 85–94 M from process to process on
    identical code, with 0% spread inside each, and flagged +9%
    (`docs/research/2026-11-10-face-align-benchmark-variance.md`). The fix is in the
    owner code: its arithmetic no longer allocates.
  - The owner chose permission over an automatic block. Some regressions are the price
    of a feature, and that trade is a product decision.
- **A record is never lost to a parallel run.** Sessions benchmark in parallel, and
  `git notes append` moves the notes ref without checking it is unchanged: two runs
  recording in the same second both built on one parent and the later dropped the
  earlier's records (2026-11-10, and 5 of 20 concurrent appends survived in a test).
  `bench.sh` builds each append on a ref of its own and moves the shared ref only if it
  still points where the append began, starting again on a race: 20 of 20 survive.
- **A dirty tree records nothing.** A run on uncommitted changes prints its results only,
  because no commit is what it measured.

## Rejected alternatives

- **XCTest `measure` with Xcode baselines.** A baseline is one number per machine,
  compared pass/fail. It keeps no history per commit, and Xcode updates it by hand. It
  would also add XCTest to a Swift Testing suite.
- **ordo-one/package-benchmark.** It runs over a Swift package's code. Otos is an Xcode
  project whose owner code is reached through the test target. Adopting it would mean
  restructuring the build or benchmarking copies of the code, plus a third-party
  dependency.
- **An automatic block above the threshold.** A regression can be the right trade for a
  feature. The owner asked to be shown it and to decide, not to have it refused.
- **Wall-time budgets in `check.sh`.** A budget measured under parallel load either fails
  on load or is set so loose it catches nothing (ADR 0033).
- **A results file committed to the tree.** Every run would be a commit, and the file
  would conflict across worktrees. Notes record the same facts against the commit itself.

- **Each case in its own process.** Run alone, a case group read inside the range of the
  full suite's processes (2026-11-11), so the earlier cases' heap is not what moves a
  count. The cost would be one catalog fixture build per catalog case and process.
- **Tuning the allocator for benchmark runs.** xzone malloc's per-process and timing
  switches are refused on a release macOS. Even where honoured, they would measure an
  allocator the app does not run with.
- **A software `CIContext` for `face.crop`.** It stayed noisy (6.8% inside a process) and
  stopped measuring the GPU path the app takes.

## Consequences

- A regression of more than 2%, and more than the case's own noise, beyond every process's
  range, flags the day's run. It stays flagged, and `check.sh` says so on every run, until
  it is fixed or the owner accepts it. Noise alone never flags. Smaller drifts show in
  `bench.sh history`, against the commit measured.
- A PR costs no benchmark run. A working day costs one, in the background of whichever
  session sees it due: a build in a fresh checkout and three test processes (about five
  minutes), skipped when `main` has not moved.
- A regression is found within a day, as a range of commits, not on the PR that caused
  it. Bisecting the range is by hand.
- Numbers compare only on one machine and configuration. The record carries both, and
  `history` compares within a machine.
- Notes stay in the local clone unless pushed (`git push origin refs/notes/benchmarks`).
- A new hot path gets a case in `BenchmarkTests` when it is worked on. The first cases are
  the All Media window state, a duplicates build, and its same-photo pairing.
