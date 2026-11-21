# What holds the Store actor in `filterOptionTally` (2026-11-20)

## Question

`docs/research/2026-11-19-store-change-facts-actor-hold-read-turns.md` (M2) measured
`filterOptionTally` holding the `CatalogStore` actor for 79 ms at p99 (64 holds, max 78.6 ms) on
the generated owner-shaped catalog. Plan 0117 step 1 left it "not yet attributed". Which part of
it holds the actor: synchronous work on the actor, or read time charged to it?

## Method

Nothing touched the owner's catalog or library. Every run used the catalog the tests generate
(`OwnerShapedCatalog`, scale 1).

The hold harness from the M2 note was reused on a new local branch,
`experiment/2026-11-20-filter-option-tally-hold` (commit `26397413`, on top of `6216befe`). It
was never pushed or merged. The branch added two probes:

- **In `filterOptionTally`:** the time before the read (`optionsScope`), and the time from the
  read's return to the function's return. That second span holds only the finish log.
- **In `filterOptions`:** the time `tally.options` takes, and the time to release the tally.
  `filterOptions` is the wrapper that calls `filterOptionTally` and builds the options on the
  actor.

Each span was timed twice: as wall-clock time (`ContinuousClock`) and as the thread's own CPU
time (`CLOCK_THREAD_CPUTIME_ID`). The harness's per-hold timing and its async-context chains
were symbolicated with `atos`, as in M2.

Each run was `OTOS_SCALE_TEST=1 script/check.sh --only StallReproductionTests`, alone. Two runs:

- **B1:** wall-clock time only.
- **B2:** wall-clock and CPU time.

The load average was 56–98, with other sessions' checks running, and the test host is an
unoptimized Debug build.

## Results

The call chains of the holds, from the B1 and B2 live phases:

| Chain above `filterOptionTally` | Holds | p50 | Max |
| --- | --- | --- | --- |
| `CatalogStore.filterOptions` ← `CatalogReads.filterOptions` ← `StallReproduction.scopeChange` | 31 per run | 8.2 / 13.4 ms | 471.8 / 111.8 ms |
| `CatalogReads.filterOptionTally` ← `CatalogProjection.readFilterOptions` (the app's path) | 1–2 per run | 0.2–0.7 ms | 0.7 ms |

M2's attribution names the first `CatalogStore` frame of the chain, which is
`filterOptionTally`. But the hold starts when the read's continuation resumes, and it lasts until
the next suspension. `filterOptionTally` returns to `filterOptions` without suspending, so
`filterOptions`'s own work falls inside the same hold.

The sections of that hold, in B2 (46–48 calls):

| Section | Runs on | CPU p50 | CPU p99 / max | Wall p99 / max |
| --- | --- | --- | --- | --- |
| `filterOptionTally` before the read | Store actor | – | – | 0.30 ms |
| `filterOptionTally` after the read (the finish log) | Store actor | 0.14 ms | 0.42 ms | 38.8 ms |
| `tally.options`, in `filterOptions` | Store actor, test-only wrapper | 5.9 ms | 16.2 ms | 99.3 ms |
| Releasing the tally, in `filterOptions` | Store actor, test-only wrapper | 0.11 ms | 0.41 ms | 12.1 ms |

`tally.options` peaked at 371 ms wall-clock in B1. Its cost is in CPU time, and it runs for
library 7's tally: 147,000–165,000 rows and 1,435 named cells. Most of its wall-clock time is
preemption: 11.9 ms of CPU in a 99.3 ms span.

- `filterOptionTally`'s own work on the actor is under 0.5 ms of CPU. The read itself (`execMs`
  up to 1,294 ms) runs on a reader connection's queue, off the actor.
- The 79 ms holds come from `filterOptions`'s `tally.options`, plus machine load.
- No product code calls `CatalogStore.filterOptions` or `CatalogReads.filterOptions`. Only
  tests call them: `StallReproductionTests`, `CatalogBatchScopeTests`,
  `FilterOptionsKeyedReadTests`, `PlaceNamesTests` and `ProjectionEnrichmentCoalescingTests`.
- The window asks `filterOptionTally` through `CatalogProjection`. The projection then builds
  `.options` on its own actor (`CatalogProjection.swift`, `CatalogProjectionWindowStateBuild`).
  So `.options` never runs on the Store actor in the app.

## Conclusion

In the app, `filterOptionTally` does not hold the actor: its synchronous work there is under
0.5 ms of CPU. The 79 ms p99 was a test-only wrapper building `.options` on the actor
(6–16 ms of CPU in Debug), stretched by machine load. M2 charged that hold to
`filterOptionTally` because the hold continues past its return.

**Fix.**
- Delete `CatalogStore.filterOptions` and `CatalogReads.filterOptions`.
- Have the tests that call them read `filterOptionTally(...).options`, as the projection does.
  The test then builds the options in its own context.

**For plan 0117 step 1.**
- The `filterOptionTally` row needs no actor change.
- Once the wrapper is gone, the hold harness's stock-shape run asks for options through
  `filterOptionTally`, as the app does, so this entry stops crossing the 50 ms bar.
- `tally.options` costs about 6–16 ms of CPU on the projection actor for a scope of 1,435 named
  cells. That is below the 50 ms bar, so it is noted here, not owed.

## What it does not capture

- Wall-clock times are on a loaded machine (load average 56–98) and a Debug build.
- The CPU split was measured in B2 only.
- The app's own path was sampled only 1–2 times per run. Its sections are the same code as the
  wrapper's first part (before the read, after the read), so the per-section CPU times above
  bound it.
