# A grid removal without a reload (2026-11-15)

Follows `2026-11-15-grid-hide-follows-the-removal.md` (#780), which left a Move to Trash
hide at about 99 M main-thread instructions at 158,000 tiles / 5,000 days for any number
of removed items — a `reloadData`, because the apply policy reloaded every membership
change of a grid holding 1,000 items or more — and `2026-11-15-immediate-feedback-for-every-act.md`
(#781), which shows a stack's expansion from the held collapse by collapsing the whole
held order again (`projection.expandHeld.days5000`, 1,867 M instructions).

## Questions

1. Why does a hide go through `reloadData`, what would `performBatchUpdates` cost
   instead, and can a removal of N items cost the main thread in proportion to N and the
   tiles on screen?
2. Can expanding or collapsing one stack cost what that stack holds?

## Method

- **Probe (temporary, never committed):** a test-hosted `MediaGridViewController` in a
  1,200 × 800 window holding 158,000 identities over 5,000 days, six columns, scrolled to
  the top. The main thread's own instructions (`thread_selfcounts`) and CPU time
  (`CLOCK_THREAD_CPUTIME_ID`) read around (a) a bare `performBatchUpdates` deleting or
  inserting N items, against `reloadData` of the same change, and (b) the real path:
  `receive` of a hidden grid, the gate's apply to its completion and a layout pass, with
  the synchronous commit counted apart (instrumentation in `CommitDuration`, removed).
  N = 1, 10, 200, removed from the first tiles on, every other one, so visible tiles go.
  Debug test build, and the same probe in a build with `SWIFT_OPTIMIZATION_LEVEL=-O`
  (whole module) in a separate DerivedData, for optimized time.
- **Where the batch spends:** `sample` of the probe's test process during 40 rounds.
- **Benchmarks:** `script/bench.sh run` and `script/bench.sh compare 3853e440` (the merge
  base), three processes a side.

## Findings

### Per phase, before

A hide was a reload by policy: `largeApply` was "either grid holds ≥ 1,000 items", so
every membership change of a library-sized grid reloaded, whatever it changed. The
reload's main-thread cost was AppKit's (#780): its section model after the reload, every
visible tile realized again, and the geometry's pass over the sections.

A batch instead was worse at this size. One deleted item off screen, bare
`performBatchUpdates`, Debug, M instructions (median of 3 rounds):

| AppKit sections | 1 item | 10 | 200 | `reloadData` + layout |
| --- | --- | --- | --- | --- |
| 5,000 (one per day) | 93 | 93 | 121 | 7 + 70 |
| 1, 15,800 items | 7.7 | 8.0 | 34 | 2.7 + 36 |
| 1, 158,000 items | 17 | 17 | 43 | 7 + 39 |

The sample of the 5,000-section batch named the per-section work: AppKit re-asks every
section's count after the update (`-[NSCollectionViewData _updateItemCounts]`, 16 % of
the batch), walks each section's supplementaries while building the view animations
(`existingSupplementaryLayoutAttributesInSection:`, 17 %), computes supplementary updates
per section (`_computeSupplementaryUpdates`) and frees per-section bookkeeping; the layout's
`prepare()` was 9 %. None of it is the change: 75 of the 93 M follow the section count.
With one section the remainder is AppKit's index map over the items
(`NSCollectionViewIndexMapper`, about 65 instructions an item: 7.7 M at 15,800 items, 17 M at
158,000) and the tiles the batch realizes.

Of a batch's per-tile cost, the largest part was AppKit asking each newly realized tile to
fit its constraints in a temporary Auto Layout engine
(`-[NSView(NSCollectionViewReusable) preferredLayoutAttributesFittingAttributes:]` →
`systemLayoutSizeFittingSize:`), for tiles whose size the layout already fixes. It is the
same in a reload's re-realization.

### Design

- **AppKit holds the order as one section.** `numberOfSections` is 1; an item's index path
  is `IndexPath(item: position, section: 0)`; the day sections are `MediaGridLayout`'s,
  which maps positions to (day, item) by binary search over the sections' first items
  (`MediaGridLayoutGeometry.indexPath(atPosition:)`). The geometry is unchanged, and its
  oracle tests run unmodified.
- **A day header's index path names its day.** AppKit carries a supplementary view's
  index path across a batch by its section alone, so a header keyed by its section index
  would hand its view to the next day when a day before it empties. The header sits at
  `IndexPath(item: headerItem, section: 0)` where `headerItem` is the day's start in whole
  seconds, offset positive (the unknown day is 0): a header whose day survives keeps its
  view and moves; the layout names to AppKit the headers a batch removes and adds
  (`indexPathsToDelete/InsertForSupplementaryView(ofKind:)`, from
  `MediaGridBatchUpdates.headers`), which fade as the base layout fades them. Keyed headers
  run in the sections' day order, so a header's section is found by binary search on its
  item; which way the days run, and that they run one way at all, is told by one pass over
  the sections the first time it is asked (`MediaGridStructure.Headers`) — a batch's
  derivation off the main actor, or the layout's first pass — so a fresh build pays nothing
  for it. A structure whose days do not run one way (a day met twice; never under Date
  sort) keys its headers by section and is only ever reloaded.
- **That bookkeeping's cost, and why it is shaped so** (Debug). A dictionary from header
  item to section built with every structure cost every fresh build about 25 M
  instructions at 5,000 days (`grid.structureBuild.days5000` 153 to 179 M, flagged by the
  first compare); the order told inside the bucket walk still cost about 0.7 K
  instructions a section; the lazy pass written with `enumerated()` and `Date` comparisons
  about 5 K a section, 25 M on the main thread at the first layout pass after a reload. A
  pass through the sections' buffer comparing seconds costs a few hundred a section, and a
  fresh build nothing. A batch derivation that walked every old section to find the deleted
  ones cost a reorder 9 M; they are now collected in the pass that finds them.
- **An order carries the edit that made it.** `CatalogGridContent.Edit` (positions
  removed from the source, positions inserted in the result, survivors in order) replaces
  #780's removed-positions-only provenance: `removing` (Move to Trash) and `edited` (a
  stack expanding or collapsing). A structure following an edit of the one on screen is
  cut from the old sections and the edit (`MediaGridStructure.init(grid:following:)`), and
  its batch is the edit's deletes and inserts plus the headers of the days it emptied or
  started, each told by its key in the other structure: no identity is compared or looked
  up, and nothing moves.
- **The apply policy counts the change, not the grid.** A membership change reloads only
  at 1,000 or more inserted plus removed items (`reloadDataFallbackChangedItemThreshold`);
  anything smaller is a batch at any grid size. An import's arrival (a fresh order, not an
  edit) takes the compared path and is a batch too.
- **A compared change keeps every view it can.** With one AppKit section an item that
  changes day, or lands in a day that is new, is a move, never a delete and an insert:
  the old rule existed only because AppKit cannot move an item into an inserted section.
- **Tiles and headers are not fitted.** `MediaAssetTileView` and `MediaGridDayHeaderView`
  answer `preferredLayoutAttributesFitting(_:)` with the layout's attributes.

### After (probe, real path, 158,000 tiles, 5,000 days)

Main thread for a hide of N visible tiles: the synchronous commit (from taking the built
structure to `performBatchUpdates` returning), and everything on the main thread from
`receive` to the next layout pass after the batch's completion, including the 0.35 s of
animation frames and the post-apply detail and preheat pass. Medians of five.

| N | commit, Debug | commit, -O | whole apply, -O |
| --- | --- | --- | --- |
| 1 | 30 M, 3.5 ms | 16.5 M, 1.9 ms | 39 M, 7.6 ms CPU |
| 10 | 37.6 M, 4.3 ms | 23.2 M, 2.8 ms | 55 M, 9.6 ms CPU |
| 200 | 49 M, 6.6 ms | 33.7 M, 4.1 ms | 69 M, 12.5 ms CPU |

Returning the same items (an undo, a fresh order: the compared path's batch of inserts)
costs 20 / 29 / 42 M in the commit, -O. Off the main actor, a hide's build is the sections
and the edit (#780), and the projection's copy of the order stays a copy of the order.

So a removal of N items costs the main thread, optimized,

    commit ≈ 6 M + ~65 instructions × items in the grid (AppKit's index map)
             + about 0.35 M for each tile on screen the batch removes or brings into view
             + a removed item off screen: too little to separate in these runs

about 1.9 ms for one and 4 ms for 200 at the reference library's size, and the whole apply under one
60 Hz frame of CPU spread over the animation's frames. The term in the grid's items is
AppKit's own and small (about 10 M instructions, a millisecond, at 158,000); nothing of
Otos's walks the items or the days on the main thread except the layout's one pass over the
section counts in `prepare()` (arithmetic, about 1 M instructions optimized at 5,000 days).

### Expansion

`PhotoStackCollapse.collapse` reads, per stack, only that stack's files present: a pair
decides from its files, a burst from its frames among the pair level's kept files. So a
change of expansion collapses again only the stacks it reaches, closed over shared files (a
pair and the burst it is a frame of), over their files alone, and merges the result into the
held one. The collapse now records the input positions it hides and where each stacked file
sits (`hiddenPositions`, `stackedPositions`), so the edit's positions in the collapsed
order are a binary search away; the new order, days and coordinates are one copy of the
held arrays with the edit applied (`Array.editing`). The grid takes the new order as an
edit of the one it shows (`CatalogGridContent.edited`), so its apply is the expansion's
inserts.

What else reads the collapse: the empty state (unchanged: a collapse keeps one tile of every
stack, so an order is empty expanded exactly when collapsed), the Places map's located
photos (the same edit, `CatalogMapState.editing`, whose pan band widens by what is added and
is measured again only when a removed photo reached its edge), and On This Day's
anniversaries (counted again from its few photos; an expansion that the anniversary cap
would cut waits for the pass, as one from a capped grid already did). The pass the
expansion rings finds the collapse made and reuses it.

`PhotoStackTests.aChangedExpansionIsTheFullCollapse` checks the result against a full
collapse for 300 random libraries of pairs and bursts, partly present, with random
expansions on both sides.

## Benchmarks

`script/bench.sh compare 3853e440` (the merge base), three processes a side, Debug, M
instructions; no case of the suite flagged. `….mainThread` counts the main thread alone,
including the batch's animation frames until its completion.

| case | base | head |
| --- | --- | --- |
| `grid.hideApply.days5000.mainThread` (6 photos off screen) | 99.7 | 51.9 |
| `grid.insertApply.days5000.mainThread` (10 arrive on screen, new) | — | 85.9 |
| `grid.expandApply.days5000.mainThread` (a pair on screen, new) | — | 61.3 |
| `projection.expandHeld.days5000` | 1,866.4 | 25.1 |
| `projection.hide.days5000` | 19.7 | 19.8 |
| `grid.structuralApply.days5000.mainThread` (a scope switch, a reload) | 103.0 | 61.6 |
| `grid.reorderApply.days5000.mainThread` | 256.9 | 186.8 |
| `grid.reorderBuild.days5000` | 542.1 | 542.5 |
| `grid.structureBuild.days5000` | 153.0 | 153.2 |
| `grid.structureBuild.days1500` | 27.9 | 27.9 |

The reload and the reorder drop with the rest because every realized tile no longer fits
its constraints, and AppKit no longer walks 5,000 sections after either.

## Conclusions

- A Move to Trash of a few hundred items at the reference library's size is a batch: every surviving
  tile keeps its view and its painted thumbnail, the removed ones shrink and fade, and the
  main thread's synchronous share is 2–4 ms optimized.
- The grid's AppKit section is one; days are the layout's. Headers are keyed by day.
- Expanding a stack costs that stack and one copy of the order, and is an insert batch.
- Not proportional to the change: AppKit's index map over the items (about 65 instructions an
  item) and the layout's pass over the section counts; off the main actor, the copy of the
  order and the publication's position index.

## Sources

- macOS 27.2 SDK `AppKit.framework/Headers/NSCollectionViewLayout.h`
  (`indexPathsToDeleteForSupplementaryViewOfKind:`, the update lifecycle).
- `docs/research/2026-11-15-grid-layout-without-compositional-solve.md`,
  `docs/research/2026-11-15-grid-hide-follows-the-removal.md`.
