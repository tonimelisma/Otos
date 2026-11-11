# Why `face.align.x1000` read differently in every process (2026-11-10)

## Question

On identical code, the benchmark case `face.align.x1000` (1,000 calls of
`FaceAlignment.similarity`) read 85.4 to 94.2 M instructions, depending on which test
process ran it. Within one process its five samples agreed to about 0%. So
`script/bench.sh compare`, which flags a rise of more than 2% beyond both runs' own
spread, flagged the case at random: +8.9% and +9.2% while PR #599 merged, on code that
PR never touched. What makes the count change from one process to the next?

## Method

All measurements are on an M1 Pro, macOS 27, Xcode 27 beta, Debug build, one worktree,
with other worktrees' checks running at the same time.

- A standalone `-Onone` copy of `similarity` was profiled with `sample`, and its parts
  were timed on their own with `proc_pid_rusage` `ri_instructions`.
- A temporary probe suite in the test host counted each sample twice: the calling
  thread's instructions (`thread_selfcounts`, kind 1) and the rest of the process's.
  The probe ran in fresh processes, and also inside `BenchmarkTests` at the point where
  the face cases run, across five processes.

## Findings

1. **The case measured the Swift runtime, not the alignment.** In the Debug (`-Onone`)
   build, one call cost about 87,000 instructions; the same code optimised costs 4,100.
   The profile was dominated by `_xzm_xzone_malloc_tiny`, `_xzm_free_main` (which reads
   `mach_absolute_time` on every free), and generic metadata cache lookups (`getCache`,
   `MetadataCacheKey::operator==`, `ConcurrentReadableHashMap::find`). Each unspecialised
   generic sequence step allocates and frees a coroutine frame
   (`protocol witness for Collection.subscript.read in conformance _ArrayBuffer`), and
   `mean`'s `map(\.x)`, `reduce` and `zip` take dozens of such steps for five points.
   - On its own, `Array(zip(points, template))` cost 34 K per call.
   - On its own, `mean(points)` cost 36 K per call.
2. **Other threads were not the cause.** Other threads added 0.01–2 M to a sample,
   occasionally 3.75 M, independent of the process's mode.
3. **The allocation-heavy part changed between processes; the rest did not.** Inside
   the suite, five processes measured:

   | process | align (M) | `Array(zip)` ×1000 (M) | metadata ×20000 (M) | `map(\.x)` ×1000 (M) |
   |---|---|---|---|---|
   | 1 | 87.2–87.9 | 33.7 | 57.4 | 9.6 |
   | 2 | 88.5–89.0 | 34.9–35.3 | 57.6–58.1 | 9.6 |
   | 3 | 90.4–91.6 | 36.7–37.0 | 57.9–58.2 | 9.7–9.8 |
   | 4 | 87.8–88.0 | 33.5–33.6 | 57.4–57.8 | 9.7–9.8 |
   | 5 | 90.4–90.9 | 36.3–36.5 | 57.4–57.8 | 9.7 |

   - The align case tracks the allocating `Array(zip)` probe, which varies by 10%.
   - Metadata lookups vary by 1.4%.
   - An allocation-free index loop read 13.48 M in every process.
   - Run alone in a fresh process, the align case held at 85.4–87.0 M. So the swing
     needs the heap left behind by the suite's earlier cases.
   - The cost of the allocator's paths depends on that heap layout, which differs
     between processes.

## Conclusion

A Debug-build case whose instructions are mostly allocation measures the heap, and the
heap is different in every process. The within-run spread cannot see that, because all
five samples share one heap.

## What changed

`FaceAlignment.similarity` now takes `FaceAlignment.Landmarks`, a struct of the five
named points, and sums them directly, with no arrays and no generic iteration. Measured
on that code in five fresh processes, inside `BenchmarkTests`:

- **This thread:** 2.66–2.68 M per 1,000 calls in every process (it was 85–92 M); about
  33× less work in the Debug build the app ships as.
- **Process-wide:** 2.749–2.784 M.

Because another thread's burst can be a few million instructions, the case now runs
20,000 alignments per sample (`face.align.x20000`, about 55 M).

## Sources

- `OtosTests/BenchmarkSupport.swift`: the `proc_pid_rusage` counter.
- `sample(1)` profiles of the standalone `-Onone` copy.
- The probe outputs, kept outside the repository.
