import AppKit
@testable import OtosKit
import Testing

/// A grid made from the one on screen by an edit — removing items
/// (`CatalogMediaGridState.hiding`, Move to Trash's visible half), or removing and inserting
/// them (a stack collapsing or expanding, `CatalogGridContent.edited`) — is taken in by the
/// edit's positions: its structure, the change and the batch are what a fresh build and a
/// full comparison of the two orders make.
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
        #expect(followed.edit(since: old) != nil, sourceLocation: sourceLocation)
        #expect(rebuilt.edit(since: old) == nil, sourceLocation: sourceLocation)
        #expect(followed.sections == rebuilt.sections, sourceLocation: sourceLocation)
        #expect(followed.layoutInput == rebuilt.layoutInput, sourceLocation: sourceLocation)

        let byRemoval = MediaGridStructureChange(from: old, to: followed)
        let byComparison = MediaGridStructureChange(from: old, to: rebuilt)
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

    // Validates: ARC-023
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

    // Validates: ARC-023
    /// A grid made from a publication the window skipped follows the order on screen by the
    /// two removals composed; one made from an order not made from the one on screen is
    /// built afresh.
    @Test func aRemovalFromASkippedPublicationFollowsBothRemovals() throws {
        let shown = Self.grid([3, 3])
        let first = shown.hiding([Self.id(1)])
        let second = first.hiding([Self.id(4)])
        try Self.expectFollowsTheRemoval(shown, second)
        #expect(MediaGridStructure(grid: second, following: MediaGridStructure(grid: shown)).edit(
            since: MediaGridStructure(grid: shown)
        ) == CatalogGridContent.Edit(removed: [1, 4], inserted: []))

        let other = Self.fresh(shown).hiding([Self.id(4)])
        let structure = MediaGridStructure(grid: other, following: MediaGridStructure(grid: shown))
        #expect(structure.edit(since: MediaGridStructure(grid: shown)) == nil)
        #expect(structure.sections == MediaGridStructure(grid: Self.fresh(other)).sections)
    }

    // Validates: ARC-023
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

    /// `shown` edited: `removed` dropped and new photos inserted at `inserted` (positions in
    /// the result), each on the day of the photo it lands before, else after, else a new
    /// day — as a stack's files join the day of the tile they expand from.
    private static func edited(
        _ shown: CatalogMediaGridState,
        removing removed: [Int],
        inserting inserted: [Int],
        newDay: Date
    ) -> CatalogMediaGridState {
        let removedSet = Set(removed)
        var ids = shown.orderedAssetIDs.indices.filter { !removedSet.contains($0) }.map { shown.orderedAssetIDs[$0] }
        var buckets = shown.dayBuckets.indices.filter { !removedSet.contains($0) }.map { shown.dayBuckets[$0] }
        for (offset, position) in inserted.enumerated() {
            let day = position < buckets.count ? buckets[position] : buckets.last ?? newDay
            ids.insert(MediaGridStructureTests.id("inserted\(offset)"), at: position)
            buckets.insert(day, at: position)
        }
        let content = shown.content.edited(
            by: CatalogGridContent.Edit(removed: removed, inserted: inserted),
            to: ids,
            dayBuckets: buckets,
            stacks: .empty
        )
        return shown.replacingContent(content)
    }

    // Validates: ARC-023
    @Test func randomEditsFollowTheEdit() throws {
        var generator = SplitMix(seed: 31)
        for _ in 0 ..< 200 {
            let counts = (0 ..< Int.random(in: 1 ... 8, using: &generator)).map { _ in
                Int.random(in: 1 ... 6, using: &generator)
            }
            let shown = Self.grid(counts, unknownLast: Int.random(in: 0 ... 3, using: &generator))
            let removed = shown.orderedAssetIDs.indices.filter { _ in Int.random(in: 0 ..< 5, using: &generator) == 0 }
            let resultCount = shown.orderedAssetIDs.count - removed.count
            let insertedCount = Int.random(in: 0 ... 4, using: &generator)
            let inserted = Array((0 ..< resultCount + insertedCount).shuffled(using: &generator).prefix(insertedCount)).sorted()
            let edit = Self.edited(
                shown, removing: removed, inserting: inserted, newDay: Date(timeIntervalSince1970: 86400 * 1000)
            )
            try Self.expectFollowsTheRemoval(shown, edit)
            let updates = try #require(MediaGridBatchUpdates.between(
                MediaGridStructure(grid: shown),
                MediaGridStructure(grid: edit, following: MediaGridStructure(grid: shown))
            ))
            #expect(updates.movedItems.isEmpty)
        }
    }
}
