# Grid structure without a diffable snapshot (2026-11-14)

Supersedes the conclusion of `2026-11-04-grid-snapshot-build-off-main.md`, which moved
the snapshot build off the main actor at 16,869 items but left its quadratic term.

## Question

At the owner's scale the grid stays blank for 13–15 s after the window state lands, at
launch and on every sidebar, sort or filter switch. Installed app, owner's catalog:

    op=ui.mediaGrid.structuralApply phase=finish items=157971 inserted=157971 largeApply=true
      reloadDataFallback=true diffPolicyMs=22 snapshotBuildMs=13390 applyCallMs=591
      completionMs=68 applyMs=14184

Is there a public diffable API that builds a many-section snapshot in linear time, and if
not, what does the grid's structure cost when it is Otos's own value? Separately, what is
the 591 ms main-thread `applyCallMs`, and can it shrink inside the existing layout?

## Method

Standalone Swift programs against the macOS 27.2 SDK, `-O`, 158,000 `Hashable`
identifiers shaped like `MediaAssetID` split into equal day sections, on a machine with
a load average of 100–140 from other agents' checks. Wall time under that load is noise,
so costs are **instructions retired** (`/usr/bin/time -l`), taken as the difference
between a run that does the work and one that only builds the identifiers.

1. SDK survey: `NSDiffableDataSource.h` and the AppKit Swift interface for any call that
   appends to several sections at once, or a section snapshot.
2. Build cost: AppKit's snapshot (`appendSections` + `appendItems(toSection:)` per day)
   against one linear pass producing section ranges and an identity → position index.
3. Layout: a real `NSCollectionView` in an on-screen window with the grid's compositional
   section (six fractional columns, 12-pt insets) and one boundary header per section,
   `reloadData` then the layout resolve, per reload, varying sections and the header's
   height dimension.

## Findings

### No public linear path exists in AppKit

macOS has `NSDiffableDataSourceSnapshot` only. Its mutators are `appendItems(_:toSection:)`,
`insertItems(_:before/afterItem:)`, `moveItem`, `appendSections`, `insertSections`,
`moveSection` and the deletes, each a single-target call; there is no
`NSDiffableDataSourceSectionSnapshot` (UIKit-only) and no initializer from sections. Every
mutating call goes through `_commitUpdateAtomic` and copies the item set
(`2026-11-04` profile), so describing D sections costs D copies whatever the call order.

### The build: 54 billion instructions against 0.16 billion

| sections | diffable snapshot | ranges + position index |
|---|---|---|
| 1,505 | 16.6 G instructions (41 s wall, loaded) | 0.16 G |
| 5,097 | 54.0 G instructions (111 s wall, loaded) | 0.16 G |

The owner's 13.4 s `snapshotBuildMs` on a quiet machine is the 5,000-day row. The plain
build is flat in sections and linear in items.

### The layout resolve is per section, and the header's estimated height doubles it

Per `reloadData` plus resolve, 158,000 items:

| sections | header | instructions |
|---|---|---|
| 1 | — | ~0 (below run-to-run noise) |
| 1,505 | absolute 32 pt | 0.82 G |
| 5,097 | none | 2.47 G |
| 5,097 | absolute 32 pt | 2.72 G |
| 5,097 | estimated 32 pt (self-sizing) | 5.96 G |
| 5,097 | estimated, one section object reused | 5.79 G |

Linear in sections (about 0.5 M instructions each with a fixed-height header), nothing per
item. A self-sizing header (`.estimated`) makes the solver fit every section's header,
about 0.65 M instructions more per section; returning one cached section object from the
provider saves only 3%. The installed app's header is `.estimated(32)`, so its 591 ms
`applyCallMs` is this table's 5.96 G row.

### NSCollectionView `reloadData` drops the selection

After `reloadData` `selectionIndexPaths` is empty, as the diffable non-animated apply
(which calls `reloadData`) already left it; the completion's `renderSelectionFromModel`
re-selects the model's identities from an empty live set.

### Layout header height

A test of DES-069's "identical height" (`everyHeaderIsTheBarsHeight`) against the
self-sizing header measured the blank first header at **12 pt** and every drawn header and
the bar at **28 pt**: the first header self-sized to its padding alone, so at rest the bar
covered the top 16 pt of the first row instead of the space DES-069 reserves. Giving the
header the label's own fitting height (`MediaGridDayHeaderView.height`, measured once from
a header holding a date and a count) as an `.absolute` dimension fixes that and moves the
resolve from the 5.96 G row to the 2.72 G row above: about half the main-thread layout
cost of every reload and every batch at the owner's 5,000 days.

The remaining ~0.5 M instructions per section are the compositional layout's own section
solve. Removing them needs a different layout model (one section with day headers drawn as
decorations, or a custom layout), which the owner declined; it stays.

### Most large applies were reorders of the whole grid

The installed app's own log over six hours on 2026-11-14 holds 530 structural applies at
158,758 items: 524 same-query reorder-only applies (the enrichment trickle; each one's
order differed from the order on screen, which is what `reorderOnly` means) and 6
membership changes. Each spent 14.5–17 s building the diffable snapshot and 0.8–1.1 s of
main-thread `applyCallMs`, back to back, so the grid was nearly always inside an apply.
None of them repeated the order on screen: a repeat already started no apply, because the
mutation gate compares the order. The gate now compares the day buckets as well, so a photo
that changes day without moving in the order re-sections (before, it kept its old header),
and an apply that still arrives at an equal structure is an empty batch that touches no
view or layout. How often the projection republishes a reorder is the projection's
question, outside the grid.

### After: the benchmark cases

`script/bench.sh run` on commit 2d697fa9 (Debug test build, three processes, medians;
wall time under load average 30–50):

| case | instructions | median ms | before |
|---|---|---|---|
| `grid.structureBuild.days1500` (15,000 items) | 161 M | 13 | 1,980 M, 292–433 ms (3a2c022f) |
| `grid.structureBuild.days5000` (158,000 items) | 1,697 M | 177 | new case; the diffable build was 54 G at `-O` |
| `grid.structuralApply.days5000` | 4,569 M | 654 | new case |

`grid.structuralApply.days5000` is the whole apply a sidebar switch costs at the owner's
size, through the controller in a window: the off-main build, `reloadData`, the layout
resolve with fixed-height headers, and the post-apply pass, alternating two 158,000-item
libraries. Against the installed app's 15.5–18 s `applyMs` for the same item count, that
is the blank-grid time going from seconds to well under one.

A sandbox run of the dev build against a copy of the owner's catalog did not reach a grid:
the catalog started (166,555 assets, 9 roots) but the first window-state publication had
not finished after 11 minutes under the machine's load, so no `structuralApply` line was
logged. The installed app's log after install is the owner-scale confirmation.

## Conclusion

- The grid's structure is Otos's own value, `MediaGridStructure`: the ordered identities,
  sections as contiguous ranges with their day key, and the identity → position index,
  built in one pass off the main actor. The controller is a classic
  `NSCollectionViewDataSource` reading it. Query changes and large membership changes call
  `reloadData`; small and same-query reorder applies run `performBatchUpdates` with the
  inserts, deletes and moves derived from the two structures (sections matched by day,
  the longest run already in order left in place). The diffable data source is gone.
- The layout resolve stays in AppKit's compositional layout (the owner declined replacing
  it). Headers take the label's fixed height, which halves the resolve and gives the blank
  first header its reserved space; the per-section solve that remains is the main thread's
  share of a large apply.

## Sources

- macOS 27.2 SDK: `AppKit.framework/Headers/NSDiffableDataSource.h`,
  `AppKit.swiftmodule/arm64e-apple-macos.swiftinterface`.
- Apple, [NSCollectionView.performBatchUpdates(_:completionHandler:)](https://developer.apple.com/documentation/appkit/nscollectionview/performbatchupdates(_:completionhandler:)).
- `docs/research/2026-11-04-grid-snapshot-build-off-main.md` (the `_commitUpdateAtomic`
  profile).
