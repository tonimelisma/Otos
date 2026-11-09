# ADR 0043: Benchmarks are opt-in, count instructions, are recorded per commit, and are compared before merge

- Status: Accepted
- Last updated: 2026-11-01

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
- **Each case is measured as one warm-up run and five measured runs.** For each run the
  harness records the instructions the test process retired (`proc_pid_rusage`,
  `ri_instructions`) and the wall time. The result keeps the median instructions, their
  spread, and the median and minimum milliseconds.
  - Instructions are the number to compare across commits.
  - Milliseconds are kept as what a user waits for.
  - Counting is process-wide because a case's work hops between actors. The suite is
    serialized so no other test adds to the count.
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
- **An app-changing PR is compared with its base before it merges.**
  `script/bench.sh compare` sets the PR's record against its merge base with `origin/main`,
  measuring the base first in a detached checkout when it has none.
  - A case is flagged when it retired **more than 2% more instructions** than the base
    **and** the rise is beyond both runs' own spread: the head's lowest sample,
    median × (1 − spread), still exceeds the base's highest, median × (1 + spread). The
    owner decides whether it merges.
  - A rise above 2% whose ranges overlap is reported as `within noise`, with both
    spreads, and does not stop the merge. A smaller change is only reported.
  - 2% is four times the run-to-run variation measured on unchanged code (about ±0.5%).
    It catches a real regression in a steady case.
  - **Why the spread test (2026-11-10):** the process-wide instruction count includes
    other threads, so a case retiring well under 10 M instructions varies by tens of
    percent. On unchanged code, `face.align` (0.1 M) read +26.6% with spreads of 20% and
    25%, and blocked an unrelated PR. A steady case's spread stays under 1%, so a real
    regression there is still flagged. A case that varies is itself reported, and is made
    steady by doing more work per sample.
  - The owner chose permission over an automatic block. Some regressions are the price
    of a feature, and that trade is a product decision.
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

## Consequences

- A regression of more than 2%, beyond both runs' spread, stops an app-changing PR before
  merge, until the owner says whether it ships. A noisy case never blocks a merge. Smaller drifts show in `bench.sh history`, against the commit
  that caused each one.
- Each app-changing PR costs one benchmark run before merge and one on `main` after it.
  A base without a record costs one more run, in a fresh checkout.
- Numbers compare only on one machine and configuration. The record carries both, and
  `history` compares within a machine.
- Notes stay in the local clone unless pushed (`git push origin refs/notes/benchmarks`).
- A new hot path gets a case in `BenchmarkTests` when it is worked on. The first cases are
  the All Media window state, a duplicates build, and its same-photo pairing.
