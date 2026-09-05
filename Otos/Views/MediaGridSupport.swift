// Media grid support guide
//
// These value helpers back the AppKit collection bridge without belonging to the
// bridge's view-controller lifecycle. Sticky paint truth lives in `TileContentStore`;
// `MediaTileDetailReader` lives in Services because it queries the catalog; this file
// keeps structural-apply, section-grouping, and day-bar policy. `MediaAssetTile*`
// types intentionally keep the per-asset prefix — they are not grid-level and are
// not part of this rename.

import Foundation

nonisolated struct MediaGridStructuralApplyPolicy: Equatable {
    static let reloadDataFallbackItemCountThreshold = 1000

    let insertedCount: Int
    let removedCount: Int
    let reorderOnly: Bool
    let largeApply: Bool
    let animatingDifferences: Bool
    let usesReloadDataFallback: Bool

    /// Chooses animated true-diff vs reloadData-class fallback.
    ///
    /// - Same-descriptor same-membership reorder (enrichment trickle): animate —
    ///   moves surviving items instead of recreating them.
    /// - Descriptor-changed reorder (sort/scope/filter flip): reloadData fallback;
    ///   scroll resets anyway and whole-list moves hit the quadratic cliff.
    /// - Large insert/remove (`n ≥ 1000`): reloadData fallback.
    /// - Small insert/remove: animate (existing behavior).
    ///
    /// `previousOrderedIDSet` must match `Set(previousOrderedIDs)` — the gate retains
    /// both so each apply does not rebuild the membership set from 23k IDs.
    static func summarize(
        previousOrderedIDs: [MediaAssetID],
        previousOrderedIDSet: Set<MediaAssetID>,
        nextOrderedIDs: [MediaAssetID],
        descriptorChanged: Bool
    ) -> MediaGridStructuralApplyPolicy {
        let retainedCount = nextOrderedIDs.reduce(into: 0) { count, id in
            if previousOrderedIDSet.contains(id) {
                count += 1
            }
        }
        let insertedCount = nextOrderedIDs.count - retainedCount
        let removedCount = previousOrderedIDs.count - retainedCount
        let reorderOnly = insertedCount == 0
            && removedCount == 0
            && previousOrderedIDs != nextOrderedIDs
        let largeApply = nextOrderedIDs.count >= reloadDataFallbackItemCountThreshold
        let usesReloadDataFallback = if reorderOnly {
            descriptorChanged
        } else if largeApply {
            true
        } else {
            false
        }
        return MediaGridStructuralApplyPolicy(
            insertedCount: insertedCount,
            removedCount: removedCount,
            reorderOnly: reorderOnly,
            largeApply: largeApply,
            animatingDifferences: !usesReloadDataFallback,
            usesReloadDataFallback: usesReloadDataFallback
        )
    }
}

/// DES-069 section grouping, pure from identity + day buckets — no `NSCollectionView`
/// dependency, so it is testable without a live collection view. `mediaSnapshot(for:)`
/// (`MediaGridStructuralApply.swift`) is a thin adapter that turns these runs into a
/// diffable snapshot.
nonisolated enum MediaGridSectionGroupingPolicy {
    /// One `.ungrouped` run when `dayBuckets` doesn't pair 1:1 with `orderedIDs`
    /// (any sort but `.bestDate`, or before any capture dates are known) — matches
    /// grid behavior from before day headers existed. Otherwise a single linear
    /// pass over the already date-sorted list, splitting into a new `.day` run
    /// each time the bucket changes; a nil bucket still gets its own run rather
    /// than being dropped or folded into `.ungrouped`.
    static func sectionRuns(
        orderedIDs: [MediaAssetID],
        dayBuckets: [Date?]
    ) -> [(section: MediaGridViewController.Section, ids: [MediaAssetID])] {
        guard dayBuckets.count == orderedIDs.count, !orderedIDs.isEmpty else {
            return [(.ungrouped, orderedIDs)]
        }
        var runs: [(section: MediaGridViewController.Section, ids: [MediaAssetID])] = []
        var currentSection: MediaGridViewController.Section?
        var currentRun: [MediaAssetID] = []
        for (id, bucket) in zip(orderedIDs, dayBuckets) {
            let section = MediaGridViewController.Section.day(bucket)
            if section != currentSection {
                if let currentSection, !currentRun.isEmpty {
                    runs.append((currentSection, currentRun))
                }
                currentSection = section
                currentRun = []
            }
            currentRun.append(id)
        }
        if let currentSection, !currentRun.isEmpty {
            runs.append((currentSection, currentRun))
        }
        return runs
    }
}

/// DES-069 day-bar content, pure from the applied day structure plus which section
/// sits at the top of the viewport.
///
/// The bar is the grid's only rendering of the current day. There is no in-flow
/// header, so there is no second thing to agree with and no visibility rule: under
/// Date sort the bar always names a day, and under any other sort there is no day
/// relationship to name and it shows nothing.
///
/// The bar exists in this shape because the day headers cannot be pinned.
/// `pinToVisibleBounds` moves every header of a section out of the collection view
/// into the scroll view's floating-subviews container, where AppKit repositions it
/// from the main thread on each bounds change while the tiles move on the
/// compositor, and installs an `NSScrollPocket` whose live blur of the passing tiles
/// has no public opt-out
/// (`docs/research/2026-09-04-grid-day-header-pinning-and-scroll-edge-effect.md`).
/// A controller-owned bar with a constant frame has neither problem.
nonisolated enum MediaGridDayBarPolicy {
    /// One applied section's user-facing day facts. `nil` in a `days` array marks an
    /// `.ungrouped` section, which names no day.
    struct Day: Equatable {
        let date: Date?
        let itemCount: Int

        init(date: Date?, itemCount: Int) {
            self.date = date
            self.itemCount = itemCount
        }
    }

    /// What the bar should render, or `nil` to hide it.
    ///
    /// `topmostSection` is the section holding the topmost visible item, which is the
    /// section that owns the viewport's top edge: a section's items run from its own
    /// start to the next section's, so whichever section an item at the top belongs
    /// to is the run the reader is looking at — including when the edge sits in the
    /// inset gap between two runs, where the row above has already left the viewport.
    ///
    /// `nil` in, `nil` out. An out-of-range index answers `nil` rather than trapping:
    /// the caller reads geometry from the layout and this array from the last applied
    /// snapshot, and while those cannot disagree in practice, a bar that blanks is a
    /// better failure than a crash.
    static func barPresentation(
        days: [Day?],
        topmostSection: Int?,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> MediaGridDayBarPresentation? {
        guard let topmostSection,
              topmostSection >= 0,
              topmostSection < days.count,
              let day = days[topmostSection]
        else {
            return nil
        }
        return .map(
            date: day.date,
            itemCount: day.itemCount,
            now: now,
            calendar: calendar
        )
    }
}
