# A grid hide follows the removal (2026-11-15)

Follows `2026-11-15-immediate-feedback-for-every-act.md` (#778), which made Move to Trash
take its items off the held window state (`CatalogWindowState.hidingItems`,
`CatalogGridContent.removing`) so the tiles go before the store records the move, and
measured `grid.hideApply.days5000.mainThread` at 138 M instructions and 116 ms on the main
thread to remove 5 items from a 158,000-tile grid: the cost of a whole-grid structural
apply, for any number of items.

## Question

Where does a hide's apply spend, on the main thread and off it, and can it cost what the
removal is rather than what the grid holds?

## Method

- **Fixture:** `BenchmarkTests.hideCases`: 158,000 identities over 5,000 days; 5 photos
  spread through it hidden, then shown again, alternately, through the real controller in a
  window.
- **Per phase:** temporary instrumentation, never committed: the main thread's own
  instruction count (`thread_selfcounts`) read at each step of the receive, the commit,
  the post-apply pass, `MediaGridLayout.prepare()` and the post-layout queue's flush; and
  temporary `Benchmark.measure` cases around the off-main build's structure and comparison.
  Debug test build, `-only-testing:OtosTests/BenchmarkTests/hideCases()`.
- **Before and after:** `script/bench.sh run` and `script/bench.sh compare` against the
  merge base, three processes each.

## Findings

### Before

A hide of 5 items from 158,000 is a large membership change (the grid holds 1,000 items or
more), so the apply policy reloads (`reloadData`), as it does for every large membership
change; that is unchanged here.

Main thread, per apply (M instructions):

| phase | M |
| --- | --- |
| `MediaGridLayout.prepare()`: AppKit's section model (`super.prepare`, `numberOfSections`) | 21 |
| `prepare()`: `numberOfItems(inSection:)` for each of 5,000 sections | 17 |
| `prepare()`: `sectionHasDayHeader` for each section (`structure.day(inSection:)`) | 36 |
| `prepare()`: building the section list | 12 |
| `prepare()`: the geometry (prefix sums over the sections) | 8 |
| the flush's remainder: AppKit realizing the visible tiles again after the reload | 38 |
| `reloadData` itself | 7 |
| visible details, preheat, day bar, viewport, hover, anchor, logging | ~12 |
| the benchmark's own wait for the apply (`awaitGridShows`) | 13 |

Off the main actor, the build (`buildStructure`) was 428 M: the structure's day-bucket walk
(90 M) and the comparison of the two orders (338 M), both linear in the grid.

### Design

- **The removal travels with the content.** `CatalogGridContent.removing` records, on the
  new order, the order it was made from (weakly) and the positions it dropped, ascending
  (`positionsRemoved(from:)`). A structure following the one on screen whose order this is
  (`MediaGridStructure.init(grid:following:)`) takes the old sections, takes from each the
  removed positions that fell in it and shifts the rest down; a section left empty is
  dropped and same-day neighbours that meet become one run, as a walk of the buckets would
  make them. `MediaGridStructureChange` reads each day's shared runs from the first and last
  removed position in it instead of comparing its items, and its counts from the removal.
  Anything else (a reorder, a removal from another publication) is built and compared as
  before.
- **The layout takes its sections in one value.** The grid's `MediaGridLayout` takes the
  structure's section list (`layoutSections`: each section's count and whether it has a day
  header) in one call in `prepare()`, written in place in one pass, instead of asking the
  collection view for 5,000 counts and the controller for 5,000 header flags. Its counts are
  the ones AppKit holds, since AppKit takes the structure in the same synchronous region
  (inside a batch, in the update block). The layout's convenience initializer still asks per
  section, for a collection view with any data source (`MediaGridLayoutTests`).
- **Key uniqueness for the pairing.** Pairing days by position needs the old keys unique,
  as a batch does. A structure knows it without a walk when it follows a removal from one
  whose keys are unique; otherwise one pass over the sections answers it, comparing each
  day with the one before (days in date order), counting only when they are not in order.
  A fresh build does not compute it, so a reorder pays nothing for it.

A first version built the layout's section list with every structure, off the main actor.
It cost every off-main build about 5 M (`grid.structureBuild.days5000` 152 to 158 M,
`.days1500` 28 to 30 M) to save the same 5 M on the main thread; making it once per layout
pass from the structure's sections costs the main thread those 5 M and the builds nothing.

### After (probe, one process)

| | before | after |
| --- | --- | --- |
| hide apply, main thread (`grid.hideApply.days5000.mainThread`) | 146 | 95–99 |
| hide build off the main actor (structure and comparison) | 428 | 79–95 |
| of which, the comparison | 338 | 36 |
| `projection.hide.days5000` (the copy of the order without the items) | 20 | 20 |

What is left of a hide on the main thread is AppKit's: its section model after the reload
(about 21 M at 5,000 days), realizing the visible tiles again (38 M, in proportion to the
tiles on screen), `reloadData` (7 M), the geometry's pass over the section counts (8 M),
and the benchmark's own wait (13 M). The reload is the apply policy's for every large
membership change and is unchanged; a batch at this grid size costs AppKit more on the main
thread than a reload (`2026-11-15-grid-layout-without-compositional-solve.md`). Off the
main actor, what is left is in the sections (the derived section list, the pairing), not
the items. Projection's copy of the order without the items stays a copy of the order:
every other reader holds the order as one array.

### Benchmarks

`script/bench.sh compare 79a24a5d` (the merge base), three processes a side, Debug, M
instructions; no case of the suite flagged:

| case | base | head |
| --- | --- | --- |
| `grid.hideApply.days5000.mainThread` | 137 | 99 |
| `projection.hide.days5000` | 20 | 20 |
| `grid.structuralApply.days5000.mainThread` | 136 | 99 |
| `grid.structuralApply.days5000` | 1,116 | 1,087 |
| `grid.reorderBuild.days5000` | 541 | 541 |
| `grid.reorderApply.days5000` | 838 | 802 |
| `grid.reorderApply.days5000.mainThread` | 294 | 256 |
| `grid.structureBuild.days1500` | 28 | 28 |
| `grid.structureBuild.days5000` | 152 | 152 |

The hide case counts the main thread only; its off-main build is the probe above (428 to
79–95 M).

## Conclusions

- A hide no longer compares, looks up or walks the grid's items: its build costs the
  sections and the removed items, and its main-thread pass no longer asks AppKit and the
  controller about every section.
- The same one-value layout input lowers every reload's and every batch's main-thread
  pass (`grid.structuralApply.days5000.mainThread`, `grid.reorderApply.days5000.mainThread`).
- Not proportional to the removal: AppKit's own work per section and per visible tile after
  a reload, the geometry's pass over the section counts, and Projection's copy of the order.
