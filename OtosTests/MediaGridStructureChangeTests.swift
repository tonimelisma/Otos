import AppKit
@testable import OtosKit
import Testing

/// The change between two grid structures (`MediaGridStructureChange`): it looks up only
/// what lies between the runs each day shares at its ends, and the summary and batch read
/// from it answer what a full comparison of the two orders answers.
struct MediaGridStructureChangeTests {
    /// Ten photos a day over twenty days, newest day first like Date sort.
    private static let days = 20
    private static let perDay = 10

    private static func grid(_ dayOfPhoto: [Int]) -> MediaGridStructure {
        let entries = dayOfPhoto.enumerated()
            .map { (name: "g\($0.offset)", day: $0.element, position: $0.offset) }
            .sorted { $0.day != $1.day ? $0.day > $1.day : $0.position < $1.position }
        return MediaGridStructureTests.structure(entries.map {
            ($0.name, Date(timeIntervalSince1970: 86400 * Double($0.day)))
        })
    }

    /// The new positions the change looks up by identity.
    private static func lookedUp(_ change: MediaGridStructureChange) -> [Int] {
        change.pairs.indices.flatMap { Array(change.stretch(ofNewSection: $0)) }
    }

    private static var everyPhotoOnItsDay: [Int] {
        (0 ..< days * perDay).map { days - 1 - $0 / perDay }
    }

    // Validates: ARC-023
    @Test func anUnchangedGridLooksUpNothing() {
        let old = Self.grid(Self.everyPhotoOnItsDay)
        let change = MediaGridStructureChange(from: old, to: Self.grid(Self.everyPhotoOnItsDay))
        #expect(Self.lookedUp(change).isEmpty)
        #expect(change.orderIsUnchanged)
        #expect(change.retainedCount == old.orderedIDs.count)
    }

    // Validates: ARC-023
    /// A photo leaving one day for another is looked up once, where it arrives; every
    /// other photo of both days lies in a run its day shares, and stays put.
    @Test func aPhotoChangingDayIsTheOnlyItemLookedUp() throws {
        let old = Self.grid(Self.everyPhotoOnItsDay)
        var days = Self.everyPhotoOnItsDay
        days[15] = 3
        let new = Self.grid(days)
        let change = MediaGridStructureChange(from: old, to: new)
        #expect(try Self.lookedUp(change) == [#require(new.position(of: MediaGridStructureTests.id("g15")))])
        let summary = MediaGridStructuralApplyPolicy.summarize(change, descriptorChanged: false)
        #expect(summary.reorderOnly && summary.animatingDifferences)
        let updates = try #require(MediaGridBatchUpdates.between(change))
        #expect(updates.movedItems.count == 1)
        #expect(updates.insertedItems.isEmpty && updates.deletedItems.isEmpty)
        try MediaGridStructureTests.replay(updates, from: old, to: new)
    }

    /// A day can change without its photos moving in the order: the order is unchanged,
    /// so it is not a reorder, though the batch moves the photo between days.
    @Test func aPhotoChangingDayInPlaceKeepsTheOrder() throws {
        let one = MediaGridStructureTests.dayOne
        let two = MediaGridStructureTests.dayTwo
        let old = MediaGridStructureTests.structure([("a", two), ("b", two), ("c", one)])
        let new = MediaGridStructureTests.structure([("a", two), ("b", one), ("c", one)])
        let change = MediaGridStructureChange(from: old, to: new)
        #expect(change.orderIsUnchanged)
        #expect(!MediaGridStructuralApplyPolicy.summarize(change, descriptorChanged: false).reorderOnly)
        try MediaGridStructureTests.replay(#require(MediaGridBatchUpdates.between(change)), from: old, to: new)
    }

    // Validates: ARC-023
    /// Random moves, inserts and removals over a day-grouped grid: the summary's counts
    /// and order equality are what comparing every identity answers, and the batch
    /// replays to the new structure.
    @Test func randomChangesAnswerWhatAFullComparisonAnswers() throws {
        var generator = SplitMix(seed: 11)
        for _ in 0 ..< 300 {
            var days = Self.everyPhotoOnItsDay
            for _ in 0 ..< Int.random(in: 0 ... 6, using: &generator) {
                let moved = Int.random(in: days.indices, using: &generator)
                days[moved] = Int.random(in: 0 ..< Self.days, using: &generator)
            }
            let old = Self.grid(Self.everyPhotoOnItsDay)
            var new = Self.grid(days)
            var ids = new.orderedIDs
            var buckets = new.sections.flatMap { section in
                Array(repeating: section.day?.date, count: section.items.count)
            }
            for _ in 0 ..< Int.random(in: 0 ... 3, using: &generator) where !ids.isEmpty {
                let removed = Int.random(in: ids.indices, using: &generator)
                ids.remove(at: removed)
                buckets.remove(at: removed)
            }
            for index in 0 ..< Int.random(in: 0 ... 3, using: &generator) {
                let at = Int.random(in: 0 ... ids.count, using: &generator)
                ids.insert(MediaGridStructureTests.id("new\(index)"), at: at)
                buckets.insert(at < buckets.count ? buckets[at] : buckets.last ?? nil, at: at)
            }
            new = MediaGridStructure(orderedIDs: ids, dayBuckets: buckets)

            let change = MediaGridStructureChange(from: old, to: new)
            let retained = new.orderedIDs.count { old.contains($0) }
            #expect(change.retainedCount == retained)
            #expect(change.orderIsUnchanged == (old.orderedIDs == new.orderedIDs))
            if let updates = MediaGridBatchUpdates.between(change) {
                try MediaGridStructureTests.replay(updates, from: old, to: new)
            }
        }
    }
}
