# Why benchmark counts differ between test processes, and what can be held still (2026-11-11)

## Question

`script/bench.sh compare` kept flagging cases on PRs that never touched them: `face.align`
(+8.9%, +9.2%), `search.readText` (+7.6%), `search.textMatch.5k` (+2.6%). Each case is
steady inside one test process, yet its count moves from one process to the next. What
makes a process's count differ? Which of those causes can a run hold still? And what
must the comparison measure, because it cannot be held still?

## Method

The machine was an M1 Pro (`MacBookPro18,3`) on macOS 27 with Xcode 27 beta, running a
Debug build from one worktree on `main` `8907221`. Other worktrees' checks ran at the same
time, as they normally do.

- **The record so far.** `refs/notes/benchmarks` held 2,805 records from about 30 commits
  with two or more runs each. One commit is one tree, so any difference between its runs
  is noise.
- **Two experiments.** The whole suite ran in ten fresh test processes:
  - five with Swift's default per-process hash seed (A);
  - five with `SWIFT_DETERMINISTIC_HASHING=1` (H);
  - alternating A and H, so the machine's load hit both alike.
- **A temporary probe.** Four more processes (P) split each sample's count four ways:
  - the calling thread's instructions (`thread_selfcounts`);
  - other threads' instructions (the process count minus the thread's);
  - page faults (`task_info` `TASK_EVENTS_INFO`);
  - system time (`proc_pid_rusage`).
- **Each case group on its own.** `catalogCases`, `gridCases` and `faceCases` each ran
  alone in a fresh process, to see whether the cases that ran earlier change a case's
  count.
- **The allocator.** `libsystem_malloc`'s configuration was read with
  `MallocReportConfig=1 MallocDebugReport=stderr`, and its `Malloc*` environment switches
  were tried on a small C program.

## Findings

1. **Recorded history: some cases are steady, others swing.** The table shows the range
   between runs on one commit.

   | case | median | worst | within one process |
   |---|---|---|---|
   | `face.crop.x16` | 9.7% | 77.7% | 8.2% |
   | `face.align.x1000` | 1.7% | 19.0% | 0.2% |
   | `search.readText` | 0.8% | 18.3% | 3.0% |
   | `search.match.20k` | 0.2% | 10.7% | 0.5% |
   | `people.suggestions` | 1.9% | 5.3% | 0.2% |
   | `people.unnamedGroups.9k` | 1.5% | 5.3% | 0.1% |
   | `search.textMatch.5k` | 0.6% | 2.6% | 0.8% |

   The rest stay under 2% at worst. The `within one process` column is the spread the
   old gate looked at, and for most of these cases it shows none of the swing.

2. **Swift's per-process hash seed is the largest cause that can be removed.** Each
   process seeds `Set` and `Dictionary` hashing at random, which changes their layout,
   probe chains and growth. The table shows the range across five processes.

   | case | default seed (A) | one seed (H) |
   |---|---|---|
   | `people.suggestions` | 4.62% | 1.76% |
   | `people.unnamedGroups.9k` | 4.40% | 1.70% |
   | `people.suggestions.10k` | 3.21% | 1.25% |
   | `search.textMatch.5k` | 4.96% | 2.35% |
   | `duplicates.samePhotoPairs` | 1.56% | 0.37% |
   | `search.resample.x16` | 1.58% | 0.71% |

   The other cases moved less than 0.5% either way.

3. **What is left in the People cases comes from the allocator, on the calling thread.**
   In the P processes, `people.suggestions` read 1,565–1,580 M on the calling thread and
   exactly 37.73 M on other threads in every process. It had no page faults and the same
   system time. The count settles in one of two modes per process, about 1.5% apart.
   PR #624's research on `face.align` (2026-11-10) found the same mechanism: the
   allocator's paths cost a different number of instructions in each process.
   - **The allocator is xzone malloc.** It reports `Initial Slot Config: CLUSTER/CPU`,
     `Pointer Bucket Count: 4` and thrash thresholds in milliseconds. So its paths depend
     on which cluster a thread ran on, on a per-process bucket assignment and on timing.
   - **Its switches are locked on a release macOS.** `MallocReportConfig` showed that
     `MallocXzonePtrBucketCount`, `MallocXzoneSlotConfig`,
     `MallocXzoneInitialSlotConfig`, `MallocXzoneTinyThrashThreshold` and
     `MallocSecureAllocator=0` changed nothing (`Internal Security Policy: 0`). Only
     `MallocXzoneThreadCaching` took effect.
   - **So a run cannot hold the allocator still.** It can only measure it, across
     processes.
4. **Some cases' noise is on other threads, in Apple's frameworks.**
   - **`face.crop.x16`.** On the calling thread it read 7.2–7.6 M. On Core Image's other
     threads it read either 4.5 or 6.2 M, alternating between processes. A software
     `CIContext` (`.useSoftwareRenderer`) did not make it steady: 11.4–11.7 M across
     processes, 6.8% inside one. It also stops measuring the GPU path the app runs.
   - **`search.readText`.** In the P processes, Vision's other threads read 66.5–67.3 M
     and the calling thread 7.7 M. Neither the A nor the H runs reproduced the 80 M mode
     seen on `55b3383` and `e62ea97`.
   - **Neither count is Otos's to hold still.**
5. **Earlier case groups do not shift a later case's count beyond the noise between
   processes.** Run alone, each group read inside the range the full suite's processes
   spanned. For example, `people.suggestions` read 1,625.6 M alone, against
   1,602–1,630 M in the suite. So running each case in its own process would not buy
   steadier numbers.

## Conclusion

A run can hold one cause still: the hash seed. It cannot hold still the allocator's
per-process paths or the frameworks' worker threads. The old gate read noise from inside
one process, then confirmed a suspected rise with one more process. That could not tell
a two-mode case from a regression whenever the two sides happened to land in different
modes.

The comparison therefore has to measure what it cannot remove:

- **Several processes per run.** Every run measures several fresh processes, so the
  evidence includes the drift between them.
- **Each case's own noise.** A case's noise is the widest range its processes span on a
  single commit, read from the recent record. A case is flagged only when it rises by
  more than that noise, and by more than 2%.

A case whose noise is wide can then only show a rise wider than its noise. That is the
honest limit of an instruction count for that case. Making such a case steadier means
changing what it measures, as `face.align` did on 2026-11-10.

## What changed

- **The hash seed is fixed.** `script/bench.sh` passes
  `TEST_RUNNER_SWIFT_DETERMINISTIC_HASHING=1` to the test process.
- **Every run is several processes.** A run measures `OTOS_BENCH_PROCESSES` fresh test
  processes (default 3) and records one record per case and process.
- **Records carry a harness number.** `harness: 2` marks them, and `compare` sets only
  records of one harness against each other. It measures base with the current harness
  when base has none.
- **The flag bar includes each case's noise.** `compare` flags a rise only when it is
  above both 2% and the case's noise over the newest 10 measured commits, and beyond
  every process's range. A rise above 2% that is within the case's noise is reported as
  `within noise`.

## Sources

- `refs/notes/benchmarks` (2,805 records, read 2026-11-11).
- The A, H, P and per-group outputs, kept in the worktree's `logs/exp/` while the work
  ran (not committed).
- `MallocReportConfig=1 MallocDebugReport=stderr` output of `libsystem_malloc`.
- PR #624's research note on `face.align.x1000` (2026-11-10).
