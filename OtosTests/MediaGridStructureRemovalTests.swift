import AppKit
@testable import OtosKit
import Testing

/// A grid made from the one on screen by removing items (`CatalogMediaGridState.hiding`,
/// Move to Trash's visible half) is taken in by its removed positions: its structure, the
/// change and the batch are what a fresh build and a full comparison of the two orders
/// make.
struct MediaGridStructureRemovalTests {
    private static func id(_ index: Int) -> MediaAssetID {
        MediaGridStructureTests.id("h\(index)")
    }

    /// `days` with photos per day `counts`, newest first like Date sort; `nil` days are
    /// the unknown-date run, placed last.
    private static func grid(_ counts: [Int], unknownLast: Int = 0) -> CatalogMediaGridState {
        var ids: [MediaAssetID] = []
        var buckets: [Date?] = []
        for (day, count) in counts.enumerated() {
            for _ in 0 ..< count {
                ids.append(id(ids.count))
                buckets.append(Date(timeIntervalSince1970: 86400 * Double(counts.count - day)))
            }
        }
        for _ in 0 ..< unknownLast {
            ids.append(id(ids.count))
            buckets.append(nil)
        }
        return CatalogMediaGridState(scope: .allMedia, orderedAssetIDs: ids, dayBuckets: buckets)
    }

    /// The same order and days as `grid`, published fresh: no removal to follow.
    private static func fresh(_ grid: CatalogMediaGridState) -> CatalogMediaGridState {
        CatalogMediaGridState(scope: .allMedia, orderedAssetIDs: grid.orderedAssetIDs, dayBuckets: grid.dayBuckets)
    }

    /// Checks `hidden`, taken in after `shown`, against a fresh build and a full comparison.
    private static func expectFollowsTheRemoval(
        _ shown: CatalogMediaGridState,
        _ hidden: CatalogMediaGridState,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let old = MediaGridStructure(grid: shown)
        let followed = MediaGridStructure(grid: hidden, following: old)
        let rebuilt = MediaGridStructure(grid: fresh(hidden), following: old)
        #expect(followed.positionsRemoved(since: old) != nil, sourceLocation: sourceLocation)
        #expect(rebuilt.positionsRemoved(since: old) == nil, sourceLocation: sourceLocation)
        #expect(followed.sections == rebuilt.sections, sourceLocation: sourceLocation)
        #expect(followed.layoutSections == rebuilt.layoutSections, sourceLocation: sourceLocation)

        let byRemoval = MediaGridStructureChange(from: old, to: followed)
        let byComparison = MediaGridStructureChange(from: old, to: rebuilt)
        #expect(byRemoval.pairs == byComparison.pairs, sourceLocation: sourceLocation)
        #expect(byRemoval.newIndexOfOldSection == byComparison.newIndexOfOldSection, sourceLocation: sourceLocation)
        #expect(byRemoval.retainedCount == byComparison.retainedCount, sourceLocation: sourceLocation)
        #expect(byRemoval.orderIsUnchanged == byComparison.orderIsUnchanged, sourceLocation: sourceLocation)
        let updates = MediaGridBatchUpdates.between(byRemoval)
        #expect(updates == MediaGridBatchUpdates.between(byComparison), sourceLocation: sourceLocation)
        if let updates {
            try MediaGridStructureTests.replay(updates, from: old, to: rebuilt, sourceLocation: sourceLocation)
        }
    }

    @Test func aRemovalInsideDaysFollowsTheRemovedPositions() throws {
        let shown = Self.grid([5, 8, 3, 6])
        #expect(MediaGridStructure(grid: shown).keysAreUnique)
        try Self.expectFollowsTheRemoval(shown, shown.hiding([Self.id(0), Self.id(7), Self.id(9), Self.id(21)]))
    }

    /// A day losing its every photo is gone, and a removal from the unknown-date run
    /// keeps that run's section.
    @Test func aDayLeftEmptyIsDroppedAndTheUnknownRunKeepsItsSection() throws {
        let shown = Self.grid([2, 3, 2], unknownLast: 3)
        let hidden = shown.hiding([Self.id(2), Self.id(3), Self.id(4), Self.id(8)])
        try Self.expectFollowsTheRemoval(shown, hidden)
        let followed = MediaGridStructure(grid: hidden, following: MediaGridStructure(grid: shown))
        #expect(followed.sections.map(\.items.count) == [2, 2, 2])
        #expect(followed.sections.last?.key == .day(nil))
    }

    /// Removing every photo leaves the one empty ungrouped section a fresh build makes.
    @Test func removingEveryPhotoLeavesTheEmptyGrid() throws {
        let shown = Self.grid([2, 2])
        try Self.expectFollowsTheRemoval(shown, shown.hiding(Set((0 ..< 4).map(Self.id))))
    }

    /// An order with no day buckets (any sort but Date) is one ungrouped section.
    @Test func anUngroupedOrderFollowsTheRemoval() throws {
        let shown = CatalogMediaGridState(scope: .allMedia, orderedAssetIDs: (0 ..< 20).map(Self.id))
        try Self.expectFollowsTheRemoval(shown, shown.hiding([Self.id(3), Self.id(19)]))
    }

    /// A day met twice in the order (never under Date sort) has no batch; removing what
    /// stood between its two runs makes them one, as a walk of the buckets would.
    @Test func runsOfOneDayThatMeetBecomeOne() throws {
        let one = Date(timeIntervalSince1970: 86400)
        let two = Date(timeIntervalSince1970: 2 * 86400)
        let shown = CatalogMediaGridState(
            scope: .allMedia,
            orderedAssetIDs: (0 ..< 5).map(Self.id),
            dayBuckets: [one, one, two, one, one]
        )
        try Self.expectFollowsTheRemoval(shown, shown.hiding([Self.id(2)]))
        let shownStructure = MediaGridStructure(grid: shown)
        #expect(!shownStructure.keysAreUnique)
        #expect(MediaGridStructure(grid: shown.hiding([Self.id(2)]), following: shownStructure).numberOfSections == 1)
    }

    /// A grid made from another publication than the one on screen is built afresh.
    @Test func aRemovalFromAnotherOrderIsBuiltAfresh() {
        let shown = Self.grid([3, 3])
        let first = shown.hiding([Self.id(1)])
        let second = first.hiding([Self.id(4)])
        let structure = MediaGridStructure(grid: second, following: MediaGridStructure(grid: shown))
        #expect(structure.positionsRemoved(since: MediaGridStructure(grid: shown)) == nil)
        #expect(structure.sections == MediaGridStructure(grid: Self.fresh(second)).sections)
    }

    @Test func randomRemovalsFollowTheRemovedPositions() throws {
        var generator = SplitMix(seed: 23)
        var followed = 0
        for _ in 0 ..< 200 {
            let counts = (0 ..< Int.random(in: 1 ... 8, using: &generator)).map { _ in
                Int.random(in: 1 ... 6, using: &generator)
            }
            let shown = Self.grid(counts, unknownLast: Int.random(in: 0 ... 3, using: &generator))
            let ids = shown.orderedAssetIDs
            let hidden = Set(ids.filter { _ in Int.random(in: 0 ..< 4, using: &generator) == 0 })
            guard !hidden.isEmpty else {
                continue
            }
            try Self.expectFollowsTheRemoval(shown, shown.hiding(hidden))
            followed += 1
        }
        // Most draws hide something: the comparison ran, not a skipped loop.
        #expect(followed > 150)
    }
}
