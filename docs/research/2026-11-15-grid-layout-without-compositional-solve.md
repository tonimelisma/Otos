# Grid layout without the compositional solve (2026-11-15)

Follows `2026-11-14-grid-structure-without-diffable-snapshot.md`, which measured the
compositional layout's per-section solve and left it in place. It has since been decided to
replace it.

## Question

The installed app on the reference catalog (158,765 items, 4,816 day sections, All Media by
date) stalls the main thread on every structural apply, and background enrichment causes
one every few seconds:

    op=ui.mediaGrid.structuralApply appliedBy=reloadData   applyCallMs=296..306 structureBuildMs=146..217
    op=ui.mediaGrid.structuralApply appliedBy=batchUpdates applyCallMs=321..363 batchUpdatesMs=664..1188 diffPolicyMs=113..440
    op=mainThreadStall bracketedOp=MediaGridViewController.applyStructure lastLongOperationMs=326..356
    op=mainThreadStall.stack … -[NSCollectionViewCompositionalLayout invalidateLayoutWithContext:] | … _fullResolve | … _NSCollectionLayoutSectionFixedSolver initWithLayoutSection:

Can a layout of Otos's own, arithmetic over the section counts, give the same pixels at a
cost proportional to what is on screen, and what is left of an apply once it does?

## Method

- **Geometry oracle.** A standalone program against the macOS 27.2 SDK put the grid's
  compositional configuration (six to nine fractional columns, 12-pt section insets, 4-pt
  tile insets, a full-width 28-pt boundary header with `supplementariesFollowContentInsets
  = false`) and `MediaGridLayout` side by side in an on-screen window at backing scale 2,
  and compared every item frame, header frame, content size and z-index, and
  `layoutAttributesForElements(in:)` for rects swept 37 pt apart down the whole content,
  plus the collection view's realized items. 5 structures (day sections of 0–30 items, one
  ungrouped section, an empty section, no sections) × 6 widths (333, 637, 900, 1001, 1013,
  1200) × 7 column counts × both layout directions: 420 cases.
- **Animation hooks.** The same program ran one batch (a section insert, an item delete,
  a near move and a move from off screen) through the compositional layout and through a
  minimal `NSCollectionViewLayout` subclass, logging what `super` returned from the four
  appear/disappear hooks.
- **Keyboard navigation.** Arrow-key moves from every item in four directions at three
  scroll offsets, both layouts (684 moves).
- **Main-thread cost.** The same window with 158,765 items in 4,816 day sections, six
  columns at 1,200 pt, scrolled to the middle: `reloadData` plus the layout resolve, and an
  animated `performBatchUpdates` moving N items between days, timed and counted with the
  main thread's own instruction counter (`thread_selfcounts`), so the off-main work and
  other processes do not enter the count. Three rounds each, `-O`.
- **Benchmarks.** `script/bench.sh` cases through the real controller in a window (Debug
  test build, one process each, medians of five), before (commit with only the new cases)
  and after.
- **Stall monitor.** `MainRunLoopStallMonitor` reports a stall only while the app is
  active (`NSApplication.shared.isActive`), which nothing in a test run makes the test
  host, so its absence from a test-hosted window would prove nothing; the main thread's own
  instruction count stands in for it here, and the installed app's log is the reference-scale confirmation.

## Findings

### The compositional layout's geometry is plain arithmetic, with one rounding rule

All 420 cases matched once two rules were found:

- Every origin and every size is rounded to the nearest backing pixel **independently**,
  half away from zero (a 236.25-pt tile is 236.5, a 260.25-pt origin is 260.5), from exact
  positions accumulated down the grid; so a row can be 0.5 pt from its neighbours'
  spacing, and widths stay equal.
- A rect query decides membership on the **exact** frame, before rounding: a tile whose
  rounded frame starts at 248 is returned for a rect ending at 248 because its exact frame
  starts at 247.75.

Right to left mirrors the columns; the header spans the full width either way. An empty
section still holds its 24 pt of insets; no sections is zero height.

### AppKit's base layout already animates a batch exactly as the compositional one did

For every hook and element the base `NSCollectionViewLayout` returned the same attributes
as the compositional layout: inserts at their new frame with alpha 0, deletes at their old
frame with alpha 0, survivors from their old frame to their new one, the inserted
section's header fading in, and for the item moved in from off screen its new frame in both
(it appears rather than flies in). The only animation code the grid needs is the shrink of
explicitly inserted and deleted items it already had.

### Keyboard navigation: one difference in 684 moves

Arrow keys are AppKit's own: `-[NSCollectionView moveRight:]` asks the layout's private
`layoutAttributesForNextItemInDirection:fromIndexPath:constrainedToRect:`, which the base
class answers from `layoutAttributesForElements(in:)` over a band the size of the viewport.
683 of 684 moves agreed. The one that did not was → from the last tile of a short day
whose nearest tile to the right lay in a row below the viewport: the compositional layout
went there and scrolled; the base layout picked the nearest tile to the right inside the
viewport's band. Up, down, left and every → that has a tile to its right in the same row
agree.

### Main thread: about 320 ms to under 30 ms

| apply (158,765 items, 4,816 days) | compositional | `MediaGridLayout` |
|---|---|---|
| `reloadData` + layout resolve | 2,682–2,692 M instr, 315–342 ms | 23–24 M instr, 2.2–2.8 ms |
| batch of 200 moves between days | 2,947 M instr, 327–334 ms | 277–282 M instr, 23–26 ms |

The batch's remainder is AppKit's update bookkeeping, not the layout, and it grows with the
moves: 171 M instructions (19 ms) for one move, 250 M (21 ms) for 20, 280 M (24 ms) for
200, 554 M (46 ms) for 1,000 — a fixed ~170 M for the grid's size plus about 0.4 M a move.
A reorder stays under 100 ms of main thread up to roughly 2,000 moved items.

### Benchmarks through the controller

`script/bench.sh run` with one process each (Debug test build, the installed app's
configuration; load average 125–170 from other agents' checks, so the milliseconds are
several-fold inflated and only the instructions compare). Before is the commit holding only
the new cases; after is this change. `….mainThread` counts the main thread's own
instructions, so the off-main build is excluded: it is the share a user can feel.

| case | before | after |
|---|---|---|
| `grid.structureBuild.days1500` | 155 M | 153 M |
| `grid.structureBuild.days5000` | 1,648 M | 1,615 M |
| `grid.structuralApply.days5000` (whole process) | 4,709 M | 1,945 M |
| `grid.structuralApply.days5000.mainThread` | 2,917 M | **149 M** |
| `grid.reorderBuild.days5000` (off the main actor) | 8,185 M | 5,110 M |
| `grid.reorderApply.days5000` (whole process) | 11,255 M | 5,614 M |
| `grid.reorderApply.days5000.mainThread` | 3,401 M | **350 M** |

The reorder cases move 200 photos between days half the library apart in a
158,000-item, 5,000-day grid, alternating, the same query each time: the apply enrichment
publishes. The main-thread count includes the run loop's frames during the 0.35 s move
animation, not only the apply. The structured log of the same runs, under that load,
put the synchronous commit (`commitMs`, new) at 0–4 ms for a reload and 19–40 ms for a
batch (one outlier 77 ms), and the completion pass at 3–16 ms (outliers 109 and 273 ms on
first realization under load).

These were measured before rebasing onto #754, which made the grid's order one shared
`CatalogGridContent` with a position index Projection builds off the main actor at
publication. The structure now reads that index instead of building its own, so the
`structureBuild` and `reorderBuild` cases no longer include an index build; they were not
re-measured after the rebase.

### What is left off the main actor

`grid.reorderBuild` is the pure half: the structure (1.6 G of the 5.1 G), the apply
policy's membership summary, and the batch derivation. The derivation now does one
identity lookup per item and works over flat arrays (old section per position, survivor
flags, a Boolean longest-run mask instead of a set), building index paths only for what it
reports; that took the case from 8.2 G to 5.1 G. It is linear in items plus
`n log n` for the longest in-order run, runs in the mutation gate's slot off the main
actor, and is latency (about 0.3–1.5 s under this load), not a hang. Making it
proportional to the change would need a diff that finds the moved items without walking
the order; none was built.

## Conclusion

- The grid's layout is `MediaGridLayout` over `MediaGridLayoutGeometry`: `prepare()` is
  one pass over the section counts, a frame is arithmetic, a rect query is a binary search
  over sections plus arithmetic over rows. Its pixels are the compositional layout's,
  kept as `MediaGridLayoutTests`' oracle; it invalidates only on a width or backing-scale
  change. The filmstrip keeps its one-section compositional layout.
- No reorder needs a cheaper apply path at the reference library's size: the full `performBatchUpdates`
  with the derived moves is well under the hang threshold, so every surviving tile keeps
  its view and its painted thumbnail, and no reorder is damped or deferred.
- The structural-apply log line gains `commitMs`, the main thread's synchronous share, so
  the installed app's own log can confirm this at the reference library's size.
- Product-visible difference: the → case above, and nothing else measured.

## Sources

- macOS 27.2 SDK `AppKit.framework/Headers/NSCollectionViewLayout.h` (the update-animation
  hooks and their lifecycle).
- Apple, [NSCollectionViewLayout](https://developer.apple.com/documentation/appkit/nscollectionviewlayout).
- `docs/research/2026-11-14-grid-structure-without-diffable-snapshot.md`.
