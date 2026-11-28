# The performance process: one weekly run, one verdict (2026-11-18)

The question was why Otos runs two performance instruments, the daily benchmarks (ADR 0043)
and the scorecard tour (ADR 0015), as two processes when both look for the same outcome, and
asked for the smallest process that keeps performance from regressing, run rarely. This note
records what other projects do, what this repo's own history shows, the options and the
recommendation that ADR 0043 now carries.

## What the two instruments are

| | Benchmarks (`script/bench.sh`) | Tour (`script/scorecard.sh --tour`) |
| --- | --- | --- |
| Measures | instructions retired by owner code on a generated catalog, Debug at `-Onone` | what a session felt on the reference library: launch, clicks, search, stalls, memory, machine pressure, in the installed app at `-O` |
| Noise | about 1% for a steady case, up to 45% for a case in Apple's frameworks | wall time; moves with other load on the machine |
| Load | runs fine beside other builds | wants a quiet machine; quits nothing it did not launch |
| Cadence before this note | once a day, started by the session whose check said due | every performance PR, before and after, plus `--ablate` attribution; nothing scheduled |
| Failure meant | `verdict=flagged`: fixing it is the next work unless the maintainer accepts | nothing: a report |

## What this repo's history shows (2026-11-01 to 2026-11-18)

- **The tour found every felt win; the benchmarks found none of them.** A view went from
  48.8 s to 51 ms and launch from 4.0 s to 1.1 s; both were found and verified by tours of the
  reference library (`2026-11-16-performance-baseline.md`).
- **The benchmarks' flags were not felt.** The last three flags (#898, #904, #945) each took a
  bisection, a research note and a fix. The most recent: a two-line SQL comment holding `§`
  raised `immich.listing.batch500.of20k` by about 10%, and an order walk raised
  `window.publish.orderChanged.158k` by about 24%, both in a `-Onone` build
  (`2026-11-18-bench-flag-publish-walk-and-upsert-comment.md`). No tour showed either.
- **Both cost a lot of session time.** About 38 of 518 commits in the period are about
  benchmarks, flags, tours or the scorecard; the harness alone was reworked six times (#602,
  #624, #627, #645, #710, #760). The program's record was edited 27 times after it opened, once
  after nearly every install. 145 commits were measured with the current harness in eight
  days, most of them by bisections.
- **Five cases measure Apple's frameworks, not Otos's code**: `face.crop.x16` (Core Image,
  up to 45% between processes, ADR 0043 already called it unsharpenable), `face.embed`,
  `search.embedImage`, `search.embedQuery` (Core ML) and `search.readText` (Vision, two
  modes, sometimes lost to a cache purge). Otos cannot change what they count, and their own
  suites already test their results.

## What well-run projects do

- **Chromium.** Lab benchmarks run continuously on a perf waterfall; alerts go to a rotating
  perf sheriff, who groups them by revision range, lets Pinpoint bisect each filed bug
  automatically, marks alerts within noise invalid, and reverts a CL only when certain it
  caused the regression and its author has no plan to fix it. Benchmark health is a separate
  rotation. A regression does not block landing; it is triaged after.
  [Perf regression sheriffing](https://chromium.googlesource.com/chromium/src/+/a753229/docs/speed/perf_regression_sheriffing.md)
- **Lab versus field (web.dev, Core Web Vitals).** "Field data is what you should use to
  prioritize your efforts"; lab data is for debugging and testing before release because it is
  reproducible. Use both. [web.dev](https://web.dev/articles/lab-and-field-data-differences)
  Speedometer 3 exists because the browser vendors wanted a lab benchmark whose wins reach real
  users, which is to say a lab number is worth what it predicts in the field.
  [browserbench.org](https://browserbench.org/announcements/speedometer3/)
- **rustc-perf.** Every merge is measured, instructions first. Significance is judged against
  each benchmark's own history (an IQR fence), not a fixed percent. People do weekly triage, at
  a fixed time each week: they ask the author about a regression, revert only a large one, and
  publish one weekly report.
  [triage README](https://github.com/rust-lang/rustc-perf/blob/master/triage/README.md),
  [comparison analysis](https://github.com/rust-lang/rustc-perf/blob/master/docs/comparison-analysis.md)
- **Firefox Perfherder.** An alert needs a sustained change (the point and 12 later points).
  Sheriffs triage within days. A regression becomes a backout candidate only when its author
  and manager do not answer within 24 hours, and an older rule backed out only regressions of
  10% or more. One month in 2021 had 288 alerts and 28 regression bugs, so most alerts were
  not work. [Performance sheriffing](https://wiki.mozilla.org/Performance_sheriffing),
  [newsletter, March 2021](https://blog.mozilla.org/performance/?p=152)
- **SQLite (a very small team).** It counts cycles with cachegrind on one fixed workload,
  because the count repeats to seven digits where wall time repeats to one, and uses it to
  steer many micro-optimizations. The count is a guide for its developers, not a gate, and it
  does not see I/O. [sqlite.org/cpu.html](https://www.sqlite.org/cpu.html)
- **CI on deterministic counters.** Instruction counts (cachegrind, iai-callgrind, the rustls
  CI bench) stay stable on noisy shared runners, so small projects gate on them and report
  wall time without gating. The tools' own docs warn that counts miss memory layout,
  allocation and I/O, so wall time is still needed beside them.
  [pythonspeed](https://pythonspeed.com/articles/consistent-benchmarking-in-ci),
  [rustls ci-bench](https://github.com/rustls/rustls/blob/main/ci-bench)
- **Performance budgets (Lighthouse CI).** A budget is a user-facing number with a limit,
  asserted as `error` (blocks) or `warn` (reports).
  [Lighthouse CI budgets](https://unlighthouse.dev/learn-lighthouse/lighthouse-ci/budgets)

What they share: the user-felt number sets priorities and the deterministic counter helps
find the cause. A counter's alert is triaged; it is not a block, and most alerts are not
work. Large projects pay a sheriff to triage. A one-maintainer project has no sheriff, so a
process that makes every alert someone's next work costs exactly the toil this repo saw.

## Options

1. **Keep both as they are.** Daily benchmarks that flag work, per-PR tours of the reference library. Rejected:
   this is the toil above, and the flags it turned into work were not felt.
2. **One scheduled run with one verdict, judged on the felt targets, counts reported.** The
   tour and the benchmarks run together on one schedule. The tour's target misses decide the
   verdict, and instruction rises are listed beside it for the maintainer to triage. Per PR,
   nothing beyond `script/check.sh`.
3. **Keep only the tour.** It sees what the user feels. Rejected: without the counts, a felt
   miss has no per-commit trail, and bisecting by tour costs about ten minutes on a quiet
   machine for each step.
4. **Keep only the benchmarks.** Rejected: they missed every felt win of the program, and
   they measure a `-Onone` build on a generated catalog with none of the reference library's waits,
   cold reads or memory pressure.
5. **Change only the cadence (weekly, or before an install), both still blocking.** This
   would cut runs to a seventh, but each flag would still be work, and a run gated on an
   install would land on every merge day, which in practice is daily.

## Recommendation (built in this increment)

Option 2:

- **What runs.** One command, `script/perf.sh run`. It tours the installed app on the
  reference library, read-only (a launch tour with the ten-minute idle the program measured
  with), then counts the benchmark cases on `origin/main` against the previous run's head
  (`script/bench.sh compare`). It writes one verdict line.
- **How often.** Once a week. It is due when the last run finished seven or more days ago and
  `main` has moved since. A run that could not measure is due again the next day.
- **Who starts it.** The session whose `script/check.sh` prints `op=perf.status verdict=due`
  starts it in the background and keeps working, as with the daily run. A launchd agent was
  rejected again (ADR 0043): it is persistent configuration on the test Mac, and nobody
  watches its runs.
- **The installed app.** The tour needs the installed app not running, and the app runs
  almost always, because each install relaunches it. The run quits it the way
  `script/install.sh` does: never while an import or reorganization is in flight (then the run
  is `pending` and stays due), with a normal Quit, never a kill, and it reopens the app in the
  background afterwards.
- **What a failure means.** `verdict=fail` means a target in `docs/scorecard-targets.json`
  was missed on the reference library. Fixing it is the next work. The fix starts with one tour
  that reproduces the miss; a miss that does not reproduce is noted in the DoD and left to the
  next weekly run. A target changes only by a recorded decision, in the targets file.
- **The instruction counts.** Rises beyond a case's noise are listed in the verdict
  (`cpu=`). They decide nothing, the baseline moves to each run's head, and the maintainer decides
  whether a rise is work. They remain the per-commit trail (`bench.sh history`,
  `bench.sh compare`) for finding the commit behind a felt miss.
- **Per PR.** Nothing beyond the one `script/check.sh`. A performance PR adds a
  deterministic twin test for its win (rows visited, stall lines, a hosted footprint) and says
  "measured in the next weekly run". No before-and-after tour is required. A tour or a
  bench comparison happens only to reproduce a fail or when the maintainer asks.
- **Cases kept.** All cases on Otos's own code. The five that count Apple's frameworks
  (`face.crop.x16`, `face.embed`, `search.embedImage`, `search.embedQuery`,
  `search.readText`) are removed.

### Trade-offs accepted

- A CPU regression the maintainer does not take up stays in the code. It is visible once in the
  weekly line and always in `bench.sh history`. Slow drift under the per-run noise is not
  flagged run to run.
- A felt regression is found within a week, not within a day, and as a range of a week's
  commits. The counts' per-commit trail narrows the range.
- The weekly tour runs whatever else the machine is doing. The scorecard's `MACHINE` section
  records the load, and the reproduce-first rule keeps a miss caused by load from becoming a
  fix.
- Acts (Like, Trash) are timed only in a sandbox library, so the weekly run on the reference
  library does not judge `act.resultMs`. Their CPU paths have cases
  (`grid.choiceReconfigure…`, `grid.hideApply…`), and the sandbox tour remains the tool for
  measuring them.
- The benchmarks still build at `-Onone`, which the installed app does not run. Moving them to
  `-O` changes what every record means, needs a new harness number and a re-measured baseline,
  and was not done without a run to prove it.

## Not verified here

No run of the new process happened in this increment; no benchmark and no tour was run. The
first real run is the next one `script/perf.sh status` reports due. The scripts were exercised
by `script/perf.sh self-test`, which stubs the tour and the counts and measures nothing.
