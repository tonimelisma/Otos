# A grid reorder's build follows the change (2026-11-15)

Follows `2026-11-15-grid-layout-without-compositional-solve.md`, which left the reorder's
off-main build linear in the library: `grid.reorderBuild.days5000` (200 photos moving
between days in a 158,000-item, 5,000-day grid) at about 4.5 G instructions, 0.3–1.5 s of
latency under load in the app.

## Question

Where do the build's instructions go, and can the build cost what changed instead of what
the grid holds, with the same structure, the same apply policy and a batch that still
turns the structure on screen into the next one?

## Method

- **Fixture:** the benchmark's own grids (`BenchmarkTests.gridCases`): 158,000 identities
  over 5,000 days, and the same grid with 200 photos spread through it each moved to the
  day half the library away and shown first there.
- **Per phase:** temporary `Benchmark.measure` cases (never committed) around each step of
  `MediaGridViewController.buildStructure`: the structure (`MediaGridStructure(grid:)`),
  the apply policy's summary, and the batch derivation. Debug test build, the installed
  app's configuration; instructions retired by the test process, median of five, one
  process each, run with `-only-testing:OtosTests/BenchmarkTests/gridCases()`.
- **Before and after:** `script/bench.sh run` and `script/bench.sh compare` against the
  merge base, three processes each.

## Findings

### Where the build went (before)

| phase | M instructions | per item |
| --- | --- | --- |
| structure: cutting day sections | 488 | ~3,100 |
| summary: membership and order equality | 608 | ~3,800 |
| batch derivation | 3,366 | ~21,000 |
| `grid.reorderBuild.days5000` (all three) | 4,461 | |

- The **batch derivation** looked up every identity of the new order in the old order's
  position index (a lock and a dictionary probe per item), filled three per-position
  arrays, and ran the longest increasing run (patience sorting, n log n) over all 158,000
  survivors to find the 200 that moved.
- The **summary** looked up every identity again for membership, and compared the two
  orders element by element.
- The **structure** compared each day bucket with the run's first through `Array`'s
  subscript, which in a Debug build is a generic call that copies the `Date?` out.

### Design

`MediaGridStructureChange` is the one comparison of two structures that both the summary
and the batch read. Sections pair by key (a day). For each pair, the items are compared
in place from the front and from the back for the runs the two share; identities are
unique within an order, so every shared item stays at its place in its day, and every item
that moved lies in the stretch between the runs. Only that stretch, and the items of an
unpaired day, are looked up by identity. A day the change did not touch is one shared run
and looks up nothing.

- **The batch** is derived from the looked-up stretches alone. An item from another
  surviving day is a move; a day's own items in the stretch keep their longest in-order
  run and the rest move; the shared runs are in order before and after them, so the
  section's run is the stretch's run plus both shared runs. The longest run is now taken
  per day over the day's own items: an item that changed day is a move whatever the run
  is, so counting it towards the run (as the global run did) could only make an item that
  stayed in its day move instead. Surviving days keep their relative order, so per-day
  runs together are the longest run of items that stayed in their day.
- **The summary**'s retained count is the shared runs plus the looked-up items the old
  order holds; the order is unchanged when every shared run starts or ends where it did
  and every looked-up item is where it was. An empty old structure (a first apply) looks
  up nothing.
- **The structure** walks the day buckets through the buffer, comparing each with the
  run's day held in a local.

The comparison keeps the pairing, the counts and the order fact, not its lookups: the
batch, built only for a change small enough to animate, looks its few stretches up again.
A first version kept every lookup for the batch; a scope switch between two libraries of
the same days pairs every day with nothing shared, so it kept 158,000 records a reload
never reads (`grid.structuralApply.days5000` 1,177 → 1,216 M). Counting alone costs what
the old summary's membership walk did.

### After (per phase)

| phase | before | after |
| --- | --- | --- |
| structure | 488 | 90 |
| comparison (summary's membership and order, the stretches' lookups) | 608 | 339 |
| summary from the comparison | | 0 |
| batch derivation | 3,366 | 96 |

What still reads every item is the day-bucket walk (the sections cannot be cut without
reading every bucket, and a day is not trusted to be contiguous) and the in-place
comparison of the days the change left alone (about 2,000 instructions an item in Debug:
the copy of an identity and its equality, whose two path strings are compared byte for
byte when their fingerprints agree). The fixture's two orders share their path strings'
storage, so their equality takes String's identical-storage path; the app's publications
build fresh strings, whose comparison reads their bytes, so the app's comparison costs
somewhat more per item than measured here. Nothing that scales with the library is
looked up, hashed or sorted.

### Benchmarks

`script/bench.sh compare c59912c8` (the merge base), three processes a side, Debug, M
instructions; no case of the suite flagged:

| case | base | head |
| --- | --- | --- |
| `grid.reorderBuild.days5000` | 4,457 | 540 |
| `grid.reorderApply.days5000` | 4,784 | 844 |
| `grid.reorderApply.days5000.mainThread` | 318 | 298 |
| `grid.structureBuild.days1500` | 82 | 28 |
| `grid.structureBuild.days5000` | 853 | 152 |
| `grid.structuralApply.days5000` | 1,175 | 1,137 |
| `grid.structuralApply.days5000.mainThread` | 136 | 137 |

The main-thread share of a reorder is AppKit's batch bookkeeping and the move animation's
frames, which this change does not touch.

## Conclusions

- A reorder's build looks up, diffs and sorts only what changed; its remaining linear work
  is two in-place walks, about a ninth of what the build cost.
- The batch is unchanged in kind: the same deletes, inserts and moves for every existing
  test, every surviving tile keeps its view, nothing is damped or deferred.
- The longest in-order run is per day over the day's own items. It never reports more
  moves than the global run did: the global run kept only its items that stayed in their
  day, and those are an in-order run of such items, which the per-day runs together are
  the longest of.
