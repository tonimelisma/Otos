import AppKit
@testable import OtosKit
import Testing

/// The grid's structure value (DES-069 grouping, index paths) and the batch that turns one
/// structure into the next. The batch is checked by replaying it the way
/// `NSCollectionView.performBatchUpdates` applies one, against the structure it must
/// produce, and once against a live collection view, which raises on any inconsistency.
struct MediaGridStructureTests {
    // MARK: - Grouping

    @Test func noDayBucketsIsOneUngroupedSection() {
        let ids = Self.ids("a", "b", "c")
        let structure = MediaGridStructure(orderedIDs: ids)
        #expect(structure.sections == [.init(key: .ungrouped, items: 0 ..< 3)])
        #expect(structure.day(inSection: 0) == nil)
    }

    @Test func anEmptyOrderIsOneEmptyUngroupedSection() {
        let structure = MediaGridStructure(orderedIDs: [], dayBuckets: [])
        #expect(structure.sections == [.init(key: .ungrouped, items: 0 ..< 0)])
        #expect(MediaGridStructure.empty.numberOfSections == 0)
    }

    @Test func contiguousSameDayRunsAreOneSectionEach() {
        let ids = Self.ids("a", "b", "c", "d")
        let structure = MediaGridStructure(orderedIDs: ids, dayBuckets: [Self.dayTwo, Self.dayTwo, Self.dayOne, Self.dayOne])
        #expect(structure.sections == [
            .init(key: .day(Self.dayTwo), items: 0 ..< 2),
            .init(key: .day(Self.dayOne), items: 2 ..< 4),
        ])
        #expect(structure.day(inSection: 1) == MediaGridDayBarPolicy.Day(date: Self.dayOne, itemCount: 2))
    }

    @Test func anUnknownDayIsItsOwnSection() {
        let ids = Self.ids("a", "b", "c")
        let structure = MediaGridStructure(orderedIDs: ids, dayBuckets: [Self.dayOne, nil, nil])
        #expect(structure.sections.map(\.key) == [.day(Self.dayOne), .day(nil)])
        #expect(structure.day(inSection: 1) == MediaGridDayBarPolicy.Day(date: nil, itemCount: 2))
    }

    @Test func bucketsThatDoNotPairWithTheOrderAreUngrouped() {
        let structure = MediaGridStructure(orderedIDs: Self.ids("a", "b"), dayBuckets: [Self.dayOne])
        #expect(structure.sections.map(\.key) == [.ungrouped])
    }

    // MARK: - Index paths

    @Test func everyItemRoundTripsBetweenIdentityAndIndexPath() {
        let ids = Self.ids("a", "b", "c", "d", "e", "f")
        let structure = MediaGridStructure(
            orderedIDs: ids,
            dayBuckets: [Self.dayThree, Self.dayTwo, Self.dayTwo, Self.dayTwo, Self.dayOne, Self.dayOne]
        )
        // AppKit holds the order as one section: an item's path is its position.
        #expect(structure.indexPath(of: ids[0]) == IndexPath(item: 0, section: 0))
        #expect(structure.indexPath(of: ids[3]) == IndexPath(item: 3, section: 0))
        #expect(structure.indexPath(of: ids[5]) == IndexPath(item: 5, section: 0))
        for id in ids {
            #expect(structure.indexPath(of: id).flatMap(structure.id(at:)) == id)
        }
        #expect(structure.numberOfItems == 6)
        #expect((0 ..< 6).map { structure.section(containing: $0) } == [0, 1, 1, 1, 2, 2])
    }

    @Test func pathsOutsideTheStructureNameNothing() {
        let structure = MediaGridStructure(orderedIDs: Self.ids("a", "b"), dayBuckets: [Self.dayTwo, Self.dayOne])
        #expect(structure.id(at: IndexPath(item: 2, section: 0)) == nil)
        #expect(structure.id(at: IndexPath(item: 0, section: 1)) == nil)
        #expect(structure.id(at: IndexPath(item: -1, section: 0)) == nil)
        #expect(structure.indexPath(of: Self.id("zzz")) == nil)
        #expect(structure.section(containing: 2) == nil)
        #expect(structure.day(inSection: -1) == nil)
    }

    // MARK: - Day headers

    /// A day's header keeps its index path in every structure holding that day, so a batch
    /// keeps its view while days before it come and go.
    @Test func aDaysHeaderSitsAtTheSamePathInEveryStructure() throws {
        let three = Self.structure([("a", Self.dayThree), ("b", Self.dayOne)])
        // Newest first, as Date sort shows them: a newer day lands above, another between.
        let four = Self.structure([
            ("n", Date(timeIntervalSince1970: 86400 * 4)), ("a", Self.dayThree), ("m", Self.dayTwo), ("b", Self.dayOne),
        ])
        #expect(three.keysAreUnique && four.keysAreUnique)
        #expect(three.headerIndexPath(ofSection: 0) == four.headerIndexPath(ofSection: 1))
        #expect(three.headerIndexPath(ofSection: 1) == four.headerIndexPath(ofSection: 3))
        let paths = (0 ..< 4).compactMap(four.headerIndexPath(ofSection:))
        #expect(Set(paths).count == 4)
        for (section, path) in paths.enumerated() {
            #expect(path.section == 0)
            #expect(four.section(ofHeaderAt: path) == section)
        }
        let unknown = Self.structure([("a", Self.dayOne), ("u", nil)])
        #expect(try unknown.section(ofHeaderAt: #require(unknown.headerIndexPath(ofSection: 1))) == 1)
        // Oldest first, the unknown day between: each header is found by its day.
        let ascending = Self.structure([("a", Self.dayZero), ("u", nil), ("b", Self.dayTwo), ("c", Self.dayThree)])
        #expect(ascending.keysAreUnique)
        for section in 0 ..< 4 {
            #expect(try ascending.section(ofHeaderAt: #require(ascending.headerIndexPath(ofSection: section))) == section)
            let input = ascending.layoutInput
            #expect(input.headers.section(ofItem: input.headers.item(ofSection: section)) == section)
        }
    }

    /// The ungrouped section has no header, and a day met twice has its headers by section,
    /// never by day.
    @Test func headersWithoutADayToKeyThem() {
        let ungrouped = MediaGridStructure(orderedIDs: Self.ids("a", "b"))
        #expect(ungrouped.headerIndexPath(ofSection: 0) == nil)
        #expect(ungrouped.section(ofHeaderAt: IndexPath(item: 0, section: 0)) == nil)
        let repeated = Self.structure([("a", Self.dayOne), ("b", Self.dayTwo), ("c", Self.dayOne)])
        #expect(!repeated.keysAreUnique)
        #expect((0 ..< 3).map(repeated.headerIndexPath(ofSection:)) == (0 ..< 3).map { IndexPath(item: $0, section: 0) })
    }

    // MARK: - Batch updates

    @Test func anInsertIsOneInsertedItem() throws {
        let old = Self.structure([("a", Self.dayOne), ("b", Self.dayOne)])
        let new = Self.structure([("a", Self.dayOne), ("n", Self.dayOne), ("b", Self.dayOne)])
        let updates = try #require(MediaGridBatchUpdates.between(old, new))
        #expect(updates == MediaGridBatchUpdates(insertedItems: [IndexPath(item: 1, section: 0)]))
        try Self.replay(updates, from: old, to: new)
    }

    @Test func aRemovalIsOneDeletedItem() throws {
        let old = Self.structure([("a", Self.dayOne), ("b", Self.dayOne), ("c", Self.dayOne)])
        let new = Self.structure([("a", Self.dayOne), ("c", Self.dayOne)])
        let updates = try #require(MediaGridBatchUpdates.between(old, new))
        #expect(updates == MediaGridBatchUpdates(deletedItems: [IndexPath(item: 1, section: 0)]))
        try Self.replay(updates, from: old, to: new)
    }

    @Test func aReorderMovesOnlyTheItemThatMoved() throws {
        let names = (0 ..< 50).map { "p\($0)" }
        let old = MediaGridStructure(orderedIDs: names.map(Self.id))
        var reordered = names
        reordered.insert(reordered.remove(at: 40), at: 3)
        let new = MediaGridStructure(orderedIDs: reordered.map(Self.id))
        let updates = try #require(MediaGridBatchUpdates.between(old, new))
        #expect(updates.movedItems == [.init(from: IndexPath(item: 40, section: 0), to: IndexPath(item: 3, section: 0))])
        #expect(updates.insertedItems.isEmpty && updates.deletedItems.isEmpty)
        try Self.replay(updates, from: old, to: new)
    }

    @Test func aDayGainingItsFirstItemIsAnInsertedSection() throws {
        let old = Self.structure([("a", Self.dayThree), ("b", Self.dayOne)])
        let new = Self.structure([("a", Self.dayThree), ("n", Self.dayTwo), ("b", Self.dayOne)])
        let updates = try #require(MediaGridBatchUpdates.between(old, new))
        #expect(try updates == MediaGridBatchUpdates(
            insertedItems: [IndexPath(item: 1, section: 0)],
            headers: MediaGridHeaderUpdates(inserted: [#require(new.headerIndexPath(ofSection: 1))])
        ))
        try Self.replay(updates, from: old, to: new)
    }

    @Test func aDayLosingItsLastItemIsADeletedSection() throws {
        let old = Self.structure([("a", Self.dayThree), ("b", Self.dayTwo), ("c", Self.dayOne)])
        let new = Self.structure([("a", Self.dayThree), ("c", Self.dayOne)])
        let updates = try #require(MediaGridBatchUpdates.between(old, new))
        #expect(try updates == MediaGridBatchUpdates(
            deletedItems: [IndexPath(item: 1, section: 0)],
            headers: MediaGridHeaderUpdates(deleted: [#require(old.headerIndexPath(ofSection: 1))])
        ))
        try Self.replay(updates, from: old, to: new)
    }

    /// An enrichment that corrects a capture date moves a photo from one surviving day to
    /// another: same membership, a different section, and a move in the batch, though the
    /// photo keeps its place in the order.
    @Test func aPhotoChangingDayBetweenSurvivingDaysIsAMove() throws {
        let old = Self.structure([("a", Self.dayTwo), ("b", Self.dayTwo), ("c", Self.dayOne)])
        let new = Self.structure([("a", Self.dayTwo), ("b", Self.dayOne), ("c", Self.dayOne)])
        let updates = try #require(MediaGridBatchUpdates.between(old, new))
        #expect(updates == MediaGridBatchUpdates(movedItems: [
            .init(from: IndexPath(item: 1, section: 0), to: IndexPath(item: 1, section: 0)),
        ]))
        try Self.replay(updates, from: old, to: new)
    }

    /// A photo moving to a new day and leaving its old one empty keeps its view: a move,
    /// with one day's header going and the other's coming.
    @Test func aPhotoMovingToANewDayLeavingItsOldDayEmptyKeepsItsView() throws {
        let old = Self.structure([("a", Self.dayThree), ("b", Self.dayOne)])
        let new = Self.structure([("a", Self.dayThree), ("b", Self.dayTwo)])
        let updates = try #require(MediaGridBatchUpdates.between(old, new))
        #expect(try updates == MediaGridBatchUpdates(
            movedItems: [.init(from: IndexPath(item: 1, section: 0), to: IndexPath(item: 1, section: 0))],
            headers: MediaGridHeaderUpdates(
                deleted: [#require(old.headerIndexPath(ofSection: 1))],
                inserted: [#require(new.headerIndexPath(ofSection: 1))]
            )
        ))
        try Self.replay(updates, from: old, to: new)

        let crossing = Self.structure([("a", Self.dayThree), ("b", Self.dayThree), ("c", Self.dayOne)])
        let intoNewDay = Self.structure([("a", Self.dayThree), ("c", Self.dayOne), ("b", Self.dayOne), ("n", Self.dayZero)])
        let mixed = try #require(MediaGridBatchUpdates.between(crossing, intoNewDay))
        try Self.replay(mixed, from: crossing, to: intoNewDay)
        let survivorOutOfDeleted = Self.structure([("b", Self.dayOne)])
        let fromDeleted = try #require(MediaGridBatchUpdates.between(old, survivorOutOfDeleted))
        try Self.replay(fromDeleted, from: old, to: survivorOutOfDeleted)
    }

    @Test func aFirstApplyReplacesTheEmptyStructure() throws {
        let new = Self.structure([("a", Self.dayTwo), ("b", Self.dayOne)])
        let updates = try #require(MediaGridBatchUpdates.between(.empty, new))
        #expect(updates == MediaGridBatchUpdates(
            insertedItems: [IndexPath(item: 0, section: 0), IndexPath(item: 1, section: 0)],
            headers: MediaGridHeaderUpdates(inserted: Set((0 ..< 2).compactMap(new.headerIndexPath(ofSection:))))
        ))
        try Self.replay(updates, from: .empty, to: new)

        let ungroupedEmpty = MediaGridStructure(orderedIDs: [])
        let fromUngrouped = try #require(MediaGridBatchUpdates.between(ungroupedEmpty, new))
        try Self.replay(fromUngrouped, from: ungroupedEmpty, to: new)
    }

    @Test func anEqualStructureIsAnEmptyBatch() throws {
        let structure = Self.structure([("a", Self.dayTwo), ("b", Self.dayOne), ("c", Self.dayOne)])
        let same = Self.structure([("a", Self.dayTwo), ("b", Self.dayOne), ("c", Self.dayOne)])
        let updates = try #require(MediaGridBatchUpdates.between(structure, same))
        #expect(updates.isEmpty)
    }

    @Test func survivingDaysThatSwapOrderHaveNoBatch() {
        let old = Self.structure([("a", Self.dayTwo), ("b", Self.dayOne)])
        let new = Self.structure([("b", Self.dayOne), ("a", Self.dayTwo)])
        #expect(MediaGridBatchUpdates.between(old, new) == nil)
    }

    @Test func aRepeatedDayHasNoBatch() {
        let old = Self.structure([("a", Self.dayOne)])
        let new = Self.structure([("a", Self.dayOne), ("b", Self.dayTwo), ("c", Self.dayOne)])
        #expect(MediaGridBatchUpdates.between(old, new) == nil)
    }

    /// Randomized changes to a day-grouped grid: inserts, removals, reorders and date
    /// changes at once, each batch replayed against the structure it must produce.
    @Test func randomChangesReplayToTheNewStructure() throws {
        var generator = SplitMix(seed: 7)
        var replayed = 0
        for _ in 0 ..< 300 {
            let old = Self.randomStructure(using: &generator)
            let new = Self.randomStructure(using: &generator)
            guard let updates = MediaGridBatchUpdates.between(old, new) else {
                continue
            }
            try Self.replay(updates, from: old, to: new)
            replayed += 1
        }
        // Days are in date order on both sides, so every random change has a batch.
        #expect(replayed == 300)
    }

    // MARK: - Fixtures

    static let dayZero = Date(timeIntervalSince1970: 86400 * 0)
    static let dayOne = Date(timeIntervalSince1970: 86400 * 1)
    static let dayTwo = Date(timeIntervalSince1970: 86400 * 2)
    static let dayThree = Date(timeIntervalSince1970: 86400 * 3)

    static func id(_ name: String) -> MediaAssetID {
        MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
            relativePath: MediaRelativePath(rawValue: "\(name).jpg")
        )
    }

    static func ids(_ names: String...) -> [MediaAssetID] {
        names.map(id)
    }

    static func structure(_ entries: [(String, Date?)]) -> MediaGridStructure {
        MediaGridStructure(orderedIDs: entries.map { id($0.0) }, dayBuckets: entries.map(\.1))
    }

    /// Up to 24 of 30 photos over up to six days, newest day first like Date sort.
    static func randomStructure(using generator: inout SplitMix) -> MediaGridStructure {
        let pool = (0 ..< 30).map { "r\($0)" }.shuffled(using: &generator)
        let chosen = pool.prefix(Int.random(in: 0 ... 24, using: &generator))
        let entries = chosen
            .map { ($0, Date(timeIntervalSince1970: 86400 * Double(Int.random(in: 0 ..< 6, using: &generator)))) }
            .sorted { $0.1 > $1.1 }
        return structure(entries.map { ($0.0, Optional($0.1)) })
    }

    /// Applies `updates` to `old` the way `NSCollectionView.performBatchUpdates` does to the
    /// grid's one AppKit section and checks the result is `new`: deletions and move sources
    /// at old positions, insertions and move destinations at new ones, every unmentioned
    /// item keeping its relative order; and the headers that go and come are exactly the
    /// days one structure has and the other lacks.
    static func replay(
        _ updates: MediaGridBatchUpdates,
        from old: MediaGridStructure,
        to new: MediaGridStructure,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let moveSources = Set(updates.movedItems.map(\.from))
        let moveTargets = Set(updates.movedItems.map(\.to))
        #expect(moveSources.count == updates.movedItems.count, sourceLocation: sourceLocation)
        #expect(moveTargets.count == updates.movedItems.count, sourceLocation: sourceLocation)
        #expect(moveSources.isDisjoint(with: updates.deletedItems), sourceLocation: sourceLocation)
        #expect(moveTargets.isDisjoint(with: updates.insertedItems), sourceLocation: sourceLocation)
        for path in updates.deletedItems.union(moveSources) {
            #expect(old.id(at: path) != nil, sourceLocation: sourceLocation)
        }
        for path in updates.insertedItems.union(moveTargets) {
            #expect(new.id(at: path) != nil, sourceLocation: sourceLocation)
        }

        var result = [MediaAssetID?](repeating: nil, count: new.numberOfItems)
        for path in updates.insertedItems {
            result[path.item] = new.id(at: path)
        }
        for move in updates.movedItems {
            result[move.to.item] = old.id(at: move.from)
        }
        let staying = (0 ..< old.numberOfItems)
            .map(MediaGridStructure.indexPath(atPosition:))
            .filter { !updates.deletedItems.contains($0) && !moveSources.contains($0) }
            .compactMap(old.id(at:))
        let openSlots = result.indices.filter { result[$0] == nil }
        try #require(staying.count == openSlots.count, sourceLocation: sourceLocation)
        for (slot, id) in zip(openSlots, staying) {
            result[slot] = id
        }
        #expect(result == new.orderedIDs, sourceLocation: sourceLocation)

        let oldHeaders = Set((0 ..< old.numberOfSections).compactMap(old.headerIndexPath(ofSection:)))
        let newHeaders = Set((0 ..< new.numberOfSections).compactMap(new.headerIndexPath(ofSection:)))
        #expect(updates.headers.deleted == oldHeaders.subtracting(newHeaders), sourceLocation: sourceLocation)
        #expect(updates.headers.inserted == newHeaders.subtracting(oldHeaders), sourceLocation: sourceLocation)
    }
}

/// A seeded generator, so a failing random case reproduces.
struct SplitMix: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

extension AppKitWindowTests {
    /// The batches drive a real collection view through the controller's own animated
    /// apply path: AppKit raises on any batch that does not turn its counts into the data
    /// source's, so a wrong derivation fails here as a crash rather than a quiet misdraw.
    @MainActor
    struct MediaGridBatchApplyTests {
        @Test func animatedAppliesKeepTheCollectionViewAndStructureInStep() async throws {
            let controller = MediaGridViewController()
            _ = controller.view
            let window = orderedInTestWindow(width: 800, height: 600, contentView: controller.view)
            defer { window.close() }
            controller.view.layoutSubtreeIfNeeded()

            let one = MediaGridStructureTests.dayOne
            let two = MediaGridStructureTests.dayTwo
            let three = MediaGridStructureTests.dayThree
            let steps: [[(String, Date?)]] = [
                [("a", three), ("b", one)],
                // A day gains its first item.
                [("a", three), ("n", two), ("b", one)],
                // A photo changes day, another is inserted, a day loses its last item.
                [("a", two), ("n", two), ("m", one), ("b", one)],
                // A reorder within a day, one item removed.
                [("n", two), ("a", two), ("b", one)],
                // A photo changes day without moving in the order.
                [("n", two), ("a", one), ("b", one)],
            ]
            let applied = try await applyEach(steps, to: controller)

            // A republished grid with the same order over the same days — handed on as the
            // same order, as Projection publishes it — touches nothing: no apply starts, and
            // the views on screen stay the same objects.
            let last = try #require(steps.last)
            let shown = Set(controller.collectionView.visibleItems().map(ObjectIdentifier.init))
            #expect(!shown.isEmpty)
            let republished = try CatalogMediaGridState(
                scope: .allMedia,
                orderedAssetIDs: last.map { MediaGridStructureTests.id($0.0) },
                dayBuckets: last.map(\.1),
                detailRefreshGeneration: 99
            ).sharingContent(of: #require(applied))
            controller.receive(republished)
            #expect(controller.mutationGate.inFlight == .none)
            controller.collectionView.layoutSubtreeIfNeeded()
            #expect(Set(controller.collectionView.visibleItems().map(ObjectIdentifier.init)) == shown)
        }

        /// Move to Trash's hide at a size the old policy reloaded (1,000 tiles or more):
        /// a batch, so every surviving tile on screen keeps its view, and the header of a
        /// day that survives keeps its view while the day before it empties.
        @Test func aHideKeepsTheViewsOfWhatSurvives() async throws {
            let controller = MediaGridViewController()
            _ = controller.view
            let window = orderedInTestWindow(width: 800, height: 600, contentView: controller.view)
            defer { window.close() }
            controller.view.layoutSubtreeIfNeeded()
            let ids = (0 ..< 1500).map { MediaGridStructureTests.id("h\($0)") }
            // Day three holds two photos, day two one, day one the rest.
            let buckets = ids.indices.map { index -> Date? in
                index < 2 ? MediaGridStructureTests.dayThree : index == 2 ? MediaGridStructureTests.dayTwo : MediaGridStructureTests.dayOne
            }
            let shown = CatalogMediaGridState(scope: .allMedia, orderedAssetIDs: ids, dayBuckets: buckets)
            controller.receive(shown)
            try await awaitGridShows(controller, shown)
            controller.collectionView.layoutSubtreeIfNeeded()
            let dayOneHeader = try #require(controller.structure.headerIndexPath(ofSection: 2))
            let headerView = try #require(controller.collectionView.supplementaryView(
                forElementKind: MediaGridDayHeaderView.elementKind, at: dayOneHeader
            ))
            let survivors = ids[3 ..< 8]
            let tiles = try survivors.map { id in
                let path = try #require(controller.structure.indexPath(of: id))
                return try #require(controller.collectionView.item(at: path))
            }

            let hidden = shown.hiding([ids[1], ids[2]])
            controller.receive(hidden)
            try await awaitGridShows(controller, hidden)
            controller.collectionView.layoutSubtreeIfNeeded()
            #expect(controller.structure.numberOfSections == 2)
            #expect(controller.structure.headerIndexPath(ofSection: 1) == dayOneHeader)
            #expect(controller.collectionView.supplementaryView(
                forElementKind: MediaGridDayHeaderView.elementKind, at: dayOneHeader
            ) === headerView)
            for (id, tile) in zip(survivors, tiles) {
                let path = try #require(controller.structure.indexPath(of: id))
                #expect(controller.collectionView.item(at: path) === tile)
            }
        }

        /// Applies each step in turn and returns the last grid applied.
        private func applyEach(
            _ steps: [[(String, Date?)]], to controller: MediaGridViewController
        ) async throws -> CatalogMediaGridState? {
            var applied: CatalogMediaGridState?
            for entries in steps {
                let ids = entries.map { MediaGridStructureTests.id($0.0) }
                let grid = CatalogMediaGridState(scope: .allMedia, orderedAssetIDs: ids, dayBuckets: entries.map(\.1))
                controller.receive(grid)
                try await awaitGridShows(controller, grid)
                applied = grid
                controller.collectionView.layoutSubtreeIfNeeded()
                let expected = MediaGridStructure(orderedIDs: ids, dayBuckets: entries.map(\.1))
                #expect(controller.structure.sections == expected.sections)
                #expect(controller.collectionView.numberOfSections == 1)
                #expect(controller.collectionView.numberOfItems(inSection: 0) == ids.count)
            }
            return applied
        }
    }
}
