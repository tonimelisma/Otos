import Foundation
@testable import OtosKit
import Testing

/// A publication's grid order says how it was made from the orders before it
/// (`CatalogGridContent.Edit`, ADR 0006): a read that moved photos is published as an edit of
/// the order published before it, an act on top of it as an edit of that, and the edits
/// compose across publications the window skipped, so the grid takes an act in by its edit
/// whatever it showed last, and compares two orders only for a new query's.
struct GridContentEditTests {
    private static func id(_ index: Int) -> MediaAssetID {
        MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
            relativePath: MediaRelativePath(rawValue: "e\(index).jpg")
        )
    }

    private static func day(_ index: Int) -> Date {
        Date(timeIntervalSince1970: 86400 * Double(index))
    }

    // MARK: - Composing edits

    /// An edit of `order` drawn at random: some items removed, and some inserted at random
    /// places in the result — new ones, or ones removed now or before, which is a move.
    private static func randomEdit(
        of order: [Int],
        removedBefore: inout [Int],
        nextNew: inout Int,
        using generator: inout SplitMix
    ) -> (edit: CatalogGridContent.Edit, result: [Int]) {
        let removed = order.indices.filter { _ in Int.random(in: 0 ..< 5, using: &generator) == 0 }
        removedBefore.append(contentsOf: removed.map { order[$0] })
        let kept = order.count - removed.count
        let count = Int.random(in: 0 ... 4, using: &generator)
        let positions = Array((0 ..< kept + count).shuffled(using: &generator).prefix(count)).sorted()
        var inserted: [(position: Int, element: Int)] = []
        for position in positions {
            let element: Int
            if !removedBefore.isEmpty, Bool.random(using: &generator) {
                element = removedBefore.remove(at: Int.random(in: 0 ..< removedBefore.count, using: &generator))
            } else {
                element = nextNew
                nextNew += 1
            }
            inserted.append((position, element))
        }
        let result = order.editing(removing: removed, inserting: inserted)
        return (CatalogGridContent.Edit(removed: removed, inserted: positions), result)
    }

    /// Composing edits drawn at random is applying them one by one: checked against the
    /// orders the edits make in turn.
    @Test func composedEditsMakeWhatApplyingThemInTurnMakes() throws {
        var generator = SplitMix(seed: 47)
        var composedSomething = 0
        for _ in 0 ..< 400 {
            let base = Array(0 ..< Int.random(in: 0 ... 30, using: &generator))
            var removedBefore: [Int] = []
            var nextNew = 1000
            var order = base
            var composed: CatalogGridContent.Edit?
            for _ in 0 ..< Int.random(in: 1 ... 5, using: &generator) {
                let (edit, result) = Self.randomEdit(
                    of: order, removedBefore: &removedBefore, nextNew: &nextNew, using: &generator
                )
                composed = composed.map { $0.followed(by: edit) } ?? edit
                order = result
            }
            let edit = try #require(composed)
            #expect(edit.removed == edit.removed.sorted() && Set(edit.removed).count == edit.removed.count)
            #expect(edit.inserted == edit.inserted.sorted() && Set(edit.inserted).count == edit.inserted.count)
            let made = base.editing(
                removing: edit.removed,
                inserting: edit.inserted.map { (position: $0, element: order[$0]) }
            )
            #expect(made == order)
            composedSomething += edit.isEmpty ? 0 : 1
        }
        #expect(composedSomething > 300)
    }

    // MARK: - The edit between two orders

    private struct Item: Equatable {
        let id: MediaAssetID
        let day: Date?
    }

    private static func content(_ items: [Item]) -> CatalogGridContent {
        CatalogGridContent(orderedAssetIDs: items.map(\.id), dayBuckets: items.map(\.day), stacks: .empty)
    }

    /// The edit between two orders drawn at random — photos moved, removed, added, or given
    /// another day where they stand — makes the new order from the old, keeping every item it
    /// does not name at its day.
    @Test func theEditBetweenTwoOrdersMakesTheNewOneFromTheOld() {
        var generator = SplitMix(seed: 53)
        for _ in 0 ..< 300 {
            let old = (0 ..< Int.random(in: 0 ... 40, using: &generator)).map {
                Item(id: Self.id($0), day: Self.day($0 / 4))
            }
            var new = old.filter { _ in Int.random(in: 0 ..< 8, using: &generator) != 0 }
            for _ in 0 ..< Int.random(in: 0 ... 4, using: &generator) where !new.isEmpty {
                let item = new.remove(at: Int.random(in: 0 ..< new.count, using: &generator))
                new.insert(item, at: Int.random(in: 0 ... new.count, using: &generator))
            }
            for _ in 0 ..< Int.random(in: 0 ... 3, using: &generator) {
                new.insert(
                    Item(id: Self.id(1000 + Int.random(in: 0 ..< 1000, using: &generator)), day: nil),
                    at: Int.random(in: 0 ... new.count, using: &generator)
                )
            }
            if !new.isEmpty, Bool.random(using: &generator) {
                let position = Int.random(in: 0 ..< new.count, using: &generator)
                new[position] = Item(id: new[position].id, day: Self.day(99))
            }
            // Drawn new photos may repeat an identity; an order holds each once.
            var seen = Set<MediaAssetID>()
            new = new.filter { seen.insert($0.id).inserted }

            let edit = CatalogGridContent.Edit.between(Self.content(old), Self.content(new))
            let made = old.editing(
                removing: edit.removed,
                inserting: edit.inserted.map { (position: $0, element: new[$0]) }
            )
            #expect(made == new)
        }
    }

    /// One photo moving far in a large order is one move: removed where it was and
    /// inserted where it is, whichever way it went.
    @Test func onePhotoMovingFarIsOneMove() {
        let old = (0 ..< 1000).map { Item(id: Self.id($0), day: Self.day(1000 - $0)) }
        for (from, to) in [(10, 900), (900, 10)] {
            var new = old
            let moved = new.remove(at: from)
            new.insert(Item(id: moved.id, day: new[to].day), at: to)
            let edit = CatalogGridContent.Edit.between(Self.content(old), Self.content(new))
            #expect(edit == CatalogGridContent.Edit(removed: [from], inserted: [to]))
        }
    }

    // MARK: - Lineage across skipped publications

    /// A publication the window skipped need not be held: an act made from it is an edit
    /// of the order the window shows, by the two edits composed, once nothing holds it.
    @Test func anActIsAnEditOfTheOrderShownThroughAPublicationNothingHolds() throws {
        let shown = CatalogMediaGridState(
            scope: .allMedia,
            orderedAssetIDs: (0 ..< 8).map(Self.id),
            dayBuckets: (0 ..< 8).map { Self.day(8 - $0 / 2) }
        )
        weak var skippedContent: CatalogGridContent?
        let hidden: CatalogMediaGridState = {
            // A read that moved the last photo to the front, published after `shown`.
            var ids = shown.orderedAssetIDs
            var days = shown.dayBuckets
            ids.insert(ids.removeLast(), at: 0)
            days.removeLast()
            days.insert(Self.day(9), at: 0)
            let skipped = CatalogMediaGridState(scope: .allMedia, orderedAssetIDs: ids, dayBuckets: days)
                .sharingContent(of: shown)
            skippedContent = skipped.content
            #expect(skipped.content.edit(from: shown.content) == CatalogGridContent.Edit(removed: [7], inserted: [0]))
            return skipped.hiding([Self.id(3)])
        }()
        #expect(skippedContent == nil, "nothing holds the skipped publication")
        let edit = try #require(hidden.content.edit(from: shown.content))
        let made = shown.orderedAssetIDs.editing(
            removing: edit.removed,
            inserting: edit.inserted.map { (position: $0, element: hidden.orderedAssetIDs[$0]) }
        )
        #expect(made == hidden.orderedAssetIDs)
        #expect(edit.size == 3)
    }

    /// A new query's order is published whole: the grid reloads it.
    @Test func aNewQuerysOrderIsPublishedWhole() {
        let shown = CatalogMediaGridState(scope: .allMedia, orderedAssetIDs: (0 ..< 4).map(Self.id))
        let library = CatalogMediaGridState(
            scope: .library(LibraryRootPath(rawValue: "/Pictures")),
            orderedAssetIDs: (0 ..< 3).map(Self.id)
        )
        #expect(library.sharingContent(of: shown).content.edit(from: shown.content) == nil)
        let reread = CatalogMediaGridState(scope: .allMedia, orderedAssetIDs: (0 ..< 3).map(Self.id))
        #expect(reread.sharingContent(of: shown).content.edit(from: shown.content) == CatalogGridContent.Edit(removed: [3], inserted: []))
    }

    // MARK: - An act on a reorder the grid has not shown, at the owner's size

    /// The owner's size: 160,000 photos over 5,000 days, newest first.
    private static let ownerDays = 5000
    private static let ownerPhotosPerDay = 32

    private static func ownerGrid() -> (grid: CatalogMediaGridState, days: [[MediaAssetID]]) {
        let days = (0 ..< ownerDays).map { day in
            (0 ..< ownerPhotosPerDay).map { id(day * ownerPhotosPerDay + $0) }
        }
        return (grid(days), days)
    }

    private static func grid(_ days: [[MediaAssetID]]) -> CatalogMediaGridState {
        var ids: [MediaAssetID] = []
        var buckets: [Date?] = []
        ids.reserveCapacity(ownerDays * ownerPhotosPerDay)
        buckets.reserveCapacity(ownerDays * ownerPhotosPerDay)
        for (index, photos) in days.enumerated() {
            ids.append(contentsOf: photos)
            buckets.append(contentsOf: repeatElement(day(ownerDays - index), count: photos.count))
        }
        return CatalogMediaGridState(scope: .allMedia, orderedAssetIDs: ids, dayBuckets: buckets)
    }

    /// The grid shows an order; a read that moved 200 photos to other days is published and
    /// the window skips it; a Move to Trash is made from it, then its Put Back. The grid
    /// takes each act in by the composed edit: it compares no item of the 160,000 and looks
    /// up only what the edits inserted, its batch moves the 200 and removes, then moves, the
    /// trashed photo, and the structure is what a fresh build of the act's order makes. The
    /// same order published whole is compared item by item, which is what an act on an
    /// unshown reorder cost before.
    @Test func anActOnAReorderTheGridHasNotShownIsTakenInByItsEdit() throws {
        let (shownGrid, shownDays) = Self.ownerGrid()
        let shown = CatalogWindowState.empty.replacingGrid(shownGrid).sharingUnchanged(with: nil)
        var movedDays = shownDays
        var generator = SplitMix(seed: 61)
        var moved = Set<MediaAssetID>()
        while moved.count < 200 {
            let from = Int.random(in: 0 ..< Self.ownerDays, using: &generator)
            let to = Int.random(in: 0 ..< Self.ownerDays, using: &generator)
            guard from != to, let photo = movedDays[from].first, !moved.contains(photo) else {
                continue
            }
            movedDays[from].removeFirst()
            movedDays[to].append(photo)
            moved.insert(photo)
        }
        let read = CatalogWindowState.empty.replacingGrid(Self.grid(movedDays))
        let skipped = read.sharingUnchanged(with: shown)
        let readEdit = try #require(skipped.mediaGrid.content.edit(from: shown.mediaGrid.content))
        #expect(readEdit.size == 400, "each moved photo is removed and inserted once")

        let trashed = try #require(movedDays[2500].dropFirst(5).first)
        let hidden = skipped.hidingItems([trashed])
        let old = MediaGridStructure(grid: shown.mediaGrid)
        try Self.expectTakenInByTheEdit(old: old, next: hidden.mediaGrid, moves: 200, deletes: 1)

        // Its Put Back, made from the hidden order beside its neighbours: still an edit of
        // the order shown, the trashed photo moved back to its place.
        let position = try #require(skipped.mediaGrid.content.position(of: trashed))
        let backContent = hidden.mediaGrid.content.edited(
            by: CatalogGridContent.Edit(removed: [], inserted: [position]),
            to: skipped.mediaGrid.orderedAssetIDs,
            dayBuckets: skipped.mediaGrid.dayBuckets,
            stacks: .empty
        )
        try Self.expectTakenInByTheEdit(
            old: old, next: hidden.mediaGrid.replacingContent(backContent), moves: 201, deletes: 0
        )

        // Published whole, the same order is compared item by item.
        let whole = MediaGridStructureChange(
            from: old,
            to: MediaGridStructure(grid: Self.fresh(hidden.mediaGrid), following: old)
        )
        #expect(whole.comparedCount > 150_000)
    }

    private static func fresh(_ grid: CatalogMediaGridState) -> CatalogMediaGridState {
        CatalogMediaGridState(scope: .allMedia, orderedAssetIDs: grid.orderedAssetIDs, dayBuckets: grid.dayBuckets)
    }

    private static func expectTakenInByTheEdit(
        old: MediaGridStructure,
        next grid: CatalogMediaGridState,
        moves: Int,
        deletes: Int,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let edit = try #require(old.edit(into: grid.content), sourceLocation: sourceLocation)
        let next = MediaGridStructure(grid: grid, following: old)
        let change = MediaGridStructureChange(from: old, to: next)
        #expect(change.comparedCount == 0, sourceLocation: sourceLocation)
        #expect(change.lookedUpCount <= edit.size, sourceLocation: sourceLocation)
        let summary = MediaGridStructuralApplyPolicy.summarize(change, descriptorChanged: false)
        #expect(summary.animatingDifferences, sourceLocation: sourceLocation)
        let updates = try #require(MediaGridBatchUpdates.between(change), sourceLocation: sourceLocation)
        #expect(updates.movedItems.count == moves, sourceLocation: sourceLocation)
        #expect(updates.deletedItems.count == deletes, sourceLocation: sourceLocation)
        #expect(updates.insertedItems.isEmpty, sourceLocation: sourceLocation)
        let rebuilt = MediaGridStructure(grid: fresh(grid))
        #expect(next.sections == rebuilt.sections, sourceLocation: sourceLocation)
        try MediaGridStructureTests.replay(updates, from: old, to: rebuilt, sourceLocation: sourceLocation)
    }
}

private extension CatalogWindowState {
    func replacingGrid(_ grid: CatalogMediaGridState) -> CatalogWindowState {
        var state = self
        state.mediaGrid = grid
        return state
    }
}
