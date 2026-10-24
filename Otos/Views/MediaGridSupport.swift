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
    ///   the position is reset or re-anchored rather than animated, and whole-list
    ///   moves hit the quadratic cliff.
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

/// DES-069 day-bar content, pure from the geometry at the top of the viewport.
///
/// The bar is a copy of the in-flow header for whichever day owns the viewport's top
/// edge, drawn with the identical treatment at the identical place — the two are the
/// same label at two moments, which is what a pinned header is. This owns the "which
/// day" half; `MediaGridDayBar.swift` owns only reading the geometry out of the
/// layout, which is what makes DES-069 testable without a live collection view.
///
/// The bar exists because the header cannot be pinned: `pinToVisibleBounds` moves
/// every header of a section out of the collection view into the scroll view's
/// floating-subviews container, where AppKit repositions it from the main thread on
/// each bounds change while the tiles move on the compositor, and installs an
/// `NSScrollPocket` whose live blur of the passing tiles has no public opt-out
/// (`docs/research/2026-09-04-grid-day-header-pinning-and-scroll-edge-effect.md`).
nonisolated enum MediaGridDayBarPolicy {
    /// One applied section's user-facing day facts. `nil` in an applied array marks
    /// an `.ungrouped` section, which names no day.
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

    /// Below this the grid counts as resting at its top. One point, not a row height:
    /// the question is only whether the user has moved off the top at all, and scroll
    /// elasticity leaves a sub-point residue at rest. (`captureScrollAnchor` asks a
    /// different question with the same tolerance, for the same reason.)
    static let atTopThreshold: CGFloat = 1

    /// Whether the bar should draw its scroll edge.
    ///
    /// The hairline means "content passes under this bar". At the top of the grid
    /// nothing does — the bar rests exactly on the first section's header, drawing the
    /// same label in the same rect — so no line. This is the contextual behavior macOS
    /// gives the titlebar (`NSTitlebarSeparatorStyle.automatic`).
    static func showsScrollEdge(viewportMinY: CGFloat) -> Bool {
        viewportMinY > atTopThreshold
    }

    /// What the bar should render, or `nil` to hide it.
    ///
    /// The bar is on continuously under Date sort. It is hidden only when there is no
    /// day structure to name — an empty grid, or the single `.ungrouped` section that
    /// `.name`/`.size` sort produces. Nothing else turns it off, and in particular it
    /// does not withdraw at the top of the grid: there it lies exactly on the first
    /// header, drawing the same label in the same rect, so leaving it on costs nothing
    /// visible and spares the design a state to get wrong.
    ///
    /// Which day: the one owning the viewport's top edge. A header that is missing, or
    /// already level with or clipped by the top edge, means its own day owns the edge.
    /// A header lying strictly below the edge means the edge is in the inset gap above
    /// it, which still belongs to the preceding day — that is what a pinned header
    /// does: you see the day you are leaving, with the next day's header rising toward
    /// it. Naming the incoming day there would print the same date twice, a few points
    /// apart.
    static func barPresentation(
        topEdge: TopEdge?,
        viewportMinY: CGFloat,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> MediaGridDayLabelPresentation? {
        guard let topEdge else {
            return nil
        }
        if let headerMinY = topEdge.headerMinY,
           headerMinY > viewportMinY,
           let preceding = topEdge.precedingDay
        {
            return presentation(for: preceding, now: now, calendar: calendar)
        }
        return presentation(for: topEdge.day, now: now, calendar: calendar)
    }

    private static func presentation(
        for day: Day,
        now: Date,
        calendar: Calendar
    ) -> MediaGridDayLabelPresentation {
        .map(date: day.date, itemCount: day.itemCount, now: now, calendar: calendar)
    }
}

/// When scroll-driven work may run.
///
/// The grid coalesces hover refresh, viewport reporting, visible detail queries and
/// preheat behind a trailing edge, so a burst of bounds notifications does not restart
/// Store queries on every tick. A trailing edge *alone* is the wrong shape: it is
/// cancelled and rescheduled by each notification, and notifications arrive faster than
/// its window for the whole duration of a fling, so it never fires until scrolling
/// stops.
///
/// Measured on a live session before this policy existed: 3,594 bounds ticks produced
/// 221 flushes — 6.1% — with a busiest second of 153 ticks and a single flush, and one
/// full second of scrolling that flushed nothing at all. At 153 ticks per second the
/// gap between them is ~6.5 ms against a 16 ms window, so the cancel always wins.
///
/// The fix is a maximum wait, not a shorter window: the trailing edge still collapses a
/// burst that ends, and the maximum wait guarantees that sustained scrolling is served
/// too. `maximumWait` is deliberately far longer than the coalesce window — this bounds
/// Store-backed work to ten passes a second during a fling, where before it got none,
/// while staying well inside the time a thumbnail has to appear before a reader notices
/// it missing.
///
/// A rate limit standing on a measurement: a live session logged 3,594 scroll-bounds
/// ticks against 221 flushes when the trailing edge stood alone, and the maximum wait
/// is what serves sustained scrolling
/// (`docs/research/2026-09-04-grid-day-header-pinning-and-scroll-edge-effect.md`,
/// "Measurement (2026-09-05)").
nonisolated enum MediaGridScrollWorkCadence {
    /// Trailing edge for a burst that ends. One display frame at 60 Hz.
    static let coalesceWindow = Duration.milliseconds(16)

    /// Longest a dirty grid may go unflushed while scrolling continues.
    static let maximumWait = Duration.milliseconds(100)

    /// True when scroll-driven work has waited long enough that it must run now rather
    /// than be rescheduled behind another trailing edge. `nil` is work that has never run.
    static func runsImmediately(sinceLastRun: Duration?) -> Bool {
        guard let sinceLastRun else {
            return true
        }
        return sinceLastRun >= maximumWait
    }
}

/// Whether a day section draws its own in-flow header (DES-069).
///
/// Every section does, except the first. The bar covers the top-most header's rect
/// exactly, so a header at the top of the viewport is never separately visible — with
/// one exception: rubber-band scrolling past the top pushes the content down while the
/// bar stays at the viewport edge, and the first section's header slides out from under
/// it as a duplicate of the label already being drawn. No other header can do this,
/// because no other header is at the top when the content bounces. Since the first
/// header is never visible on its own anyway, not drawing it removes the duplicate and
/// nothing else; its space is still reserved, so the first row does not move.
nonisolated enum MediaGridDayHeaderVisibility {
    static func drawsInFlowHeader(section: Int) -> Bool {
        section > 0
    }
}
