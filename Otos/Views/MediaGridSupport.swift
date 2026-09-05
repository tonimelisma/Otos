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

/// DES-069 day-bar content and visibility, pure from the geometry at the top of the
/// viewport.
///
/// The bar exists because the day headers are **not** pinned: `pinToVisibleBounds`
/// moves every header of a section out of the collection view into the scroll view's
/// floating-subviews container, where AppKit repositions it from the main thread on
/// each bounds change while the tiles move on the compositor, and installs an
/// `NSScrollPocket` whose live blur of the passing tiles has no public opt-out
/// (`docs/research/2026-09-04-grid-day-header-pinning-and-scroll-edge-effect.md`).
/// A controller-owned bar with a constant frame has neither problem.
///
/// The rule it implements is the one a pinned header implements implicitly: name the
/// day that owns the viewport's top edge. Keying off the topmost visible *item*
/// instead is the near-miss — between one day's last row and the next day's header
/// lies up to 24 pt of section inset, and a bar that hid while the top edge sat in
/// that gap would blink out and back at every single day boundary.
nonisolated enum MediaGridDayBarPolicy {
    /// One day section's user-facing facts.
    struct Day: Equatable {
        let date: Date?
        let itemCount: Int

        init(date: Date?, itemCount: Int) {
            self.date = date
            self.itemCount = itemCount
        }
    }

    /// What the layout reports about the top of the viewport.
    struct TopEdge: Equatable {
        /// The day section holding the topmost visible item.
        let day: Day
        /// The top of that section's own header, or `nil` once the header has scrolled
        /// above the viewport — the ordinary case inside a run of any length.
        let headerMinY: CGFloat?
        /// The day section immediately before it, where there is one.
        let precedingDay: Day?

        init(day: Day, headerMinY: CGFloat?, precedingDay: Day?) {
            self.day = day
            self.headerMinY = headerMinY
            self.precedingDay = precedingDay
        }
    }

    /// What the bar should render, or `nil` to hide it.
    ///
    /// `topEdge == nil` covers an empty grid and every `.ungrouped` case — under
    /// `.name`/`.size` sort there is no day relationship to name, so no bar.
    ///
    /// A header that is missing, or clipped by the top edge, means its day owns the
    /// top edge and the bar names it; the bar is opaque and sits exactly where that
    /// header is, so it covers rather than duplicates it.
    ///
    /// A header lying wholly below the top edge means the edge is in the inset gap
    /// above it, which still belongs to the preceding day — so the bar names *that*
    /// day and its text changes exactly once per boundary. Only at the very start of
    /// the grid is there no preceding day, and only there does the bar hide, leaving
    /// the first day's own header to name it.
    static func barPresentation(
        topEdge: TopEdge?,
        viewportMinY: CGFloat,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> MediaGridDayHeaderPresentation? {
        guard let topEdge else {
            return nil
        }
        guard let headerMinY = topEdge.headerMinY, headerMinY >= viewportMinY else {
            return presentation(for: topEdge.day, now: now, calendar: calendar)
        }
        guard let preceding = topEdge.precedingDay else {
            return nil
        }
        return presentation(for: preceding, now: now, calendar: calendar)
    }

    private static func presentation(
        for day: Day,
        now: Date,
        calendar: Calendar
    ) -> MediaGridDayHeaderPresentation {
        .map(date: day.date, itemCount: day.itemCount, now: now, calendar: calendar)
    }
}
