# Grid snapshot build off the main actor (2026-11-04)

## Question

Switching to All Media (16,869 items, 143 capture days) blocked the main thread for
137 ms in the installed Debug build: `op=ui.mediaGrid.structuralApply phase=finish`
reported `snapshotBuildMs=68 applyCallMs=37 completionMs=28 applyMs=137`, over Apple's
100 ms hang threshold. Where does the time go, does it grow with the library, and can
it be removed without replacing `NSCollectionViewDiffableDataSource` or
`NSCollectionViewCompositionalLayout`?

## Method

Standalone Swift programs against the macOS 27.2 SDK (Xcode 27 beta), 16,869
`Hashable` identifiers shaped like `MediaAssetID`, split into N equal day sections.
Built `-Onone` like the installed app unless noted; run on a machine also running other
agents' checks, so milliseconds are indicative and the profiles carry the conclusions.

1. Snapshot build: `appendSections` + `appendItems(toSection:)` once per day, in several
   call orders, against the Objective-C `NSDiffableDataSourceSnapshotReference`, and with
   every item in one section.
2. `sample` of a loop of 1,534-section builds (`-O`).
3. A real `NSCollectionView` with a compositional layout and one boundary header per
   section in an on-screen window: the snapshot built in a `@concurrent` function
   returning `sending`, then `dataSource.apply` timed on the main actor, then `sample` of
   repeated applies.

## Findings

### The build grows with days × items, inside AppKit

| days | per-day appends | all sections first | sections reversed | one section |
|---|---|---|---|---|
| 151 | 61–78 ms | similar | similar | 17–25 ms |
| 1,534 | 315–372 ms | similar | similar | 10–23 ms |

The Objective-C reference type is the same (45–67 ms at 151 days). Under load the same
programs read several times higher; the ratio holds.

The profile names the mechanism. Each mutating call goes through
`-[__NSDiffableDataSourceSnapshot _commitUpdateAtomic:]`, which builds a new immutable
state: `NSMutableOrderedSet insertObjects:` triggers `_cow_mutate_slow` →
`CFBasicHashCreateCopy` of the whole item set (37% of samples), and the previous state's
`__NSFrozenOrderedSetM dealloc` drains it again (28%). The cost per call is proportional
to the items already in the snapshot, and a day-grouped grid makes one call per day. No
public API appends to several sections in one call, and call order only changes the
constant.

### The snapshot is plain data that can be built off the main actor

`NSDiffableDataSourceSnapshot` is not `Sendable` in the SDK's Swift interface, and its
Objective-C header carries no main-thread annotation. A `@concurrent` function that
creates the snapshot and returns it as `sending` compiles under Swift 6 strict
concurrency with no unchecked conformance: the value is disconnected, so region
isolation lets it move to the main actor. Applying such a snapshot on the main actor
works normally.

### The apply also grows with days, but linearly, in the layout

| days | build (off main) | `apply`, no animation | same snapshot, animated |
|---|---|---|---|
| 1 | 10 ms | 8–13 ms | 4–5 ms |
| 152 | 45–57 ms | 21–27 ms | 17 ms |
| 1,687 | ~400 ms | ~150 ms | ~154 ms |

The `apply` profile is `NSCollectionView reloadData` → `NSCollectionViewCompositionalLayout
_fullResolve`: the layout solver re-solves every section, its items and its boundary
header (`_NSCollectionLayoutSectionFixedSolver`, `_NSCollectionLayoutAuxiliaryItemSolver`),
plus one `sectionProvider` call per section. That is about 0.09 ms per section, it is the
layout itself, and it must run on the main actor.

## Conclusion

Build the diff summary, the snapshot and the day facts off the main actor inside the
mutation gate's existing exclusive slot, and keep `dataSource.apply` where it is. This
removes the quadratic term from the main thread without touching AppKit's data source or
layout. The linear layout term remains: about 20–40 ms today, about 150–200 ms for a
library spanning 1,500–2,000 days. Removing that would mean a different layout model,
which is out of scope (replacing tried and true AppKit parts for it was rejected).

## Sources

- macOS 27.2 SDK: `AppKit.framework/Headers/NSDiffableDataSource.h` and
  `AppKit.swiftmodule/arm64e-apple-macos.swiftinterface` (`NSDiffableDataSourceSnapshot`
  declares no `Sendable` conformance).
- Apple, [NSDiffableDataSourceSnapshot](https://developer.apple.com/documentation/appkit/nsdiffabledatasourcesnapshot)
- Swift Evolution, [SE-0414 Region based isolation](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0414-region-based-isolation.md)
  and [SE-0430 `sending` parameter and result values](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0430-transferring-parameters-and-results.md).
- Time Profiler trace of the installed app, 2026-11-04 (`build/Profiles/`, not committed).
