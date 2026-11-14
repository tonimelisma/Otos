import Foundation
@testable import OtosKit
import Testing

/// The On This Day scope (ADR 0049): the fixed libraries' items whose day bucket has the
/// day's month and day in an earlier year — else its day of the month in an earlier
/// month — in the scope's own order — newest first,
/// whatever the sort control says — with every scoped read agreeing. Store answers what
/// the scope holds; `CatalogWindowPolicy` turns it into the anniversaries and the empty
/// state.
@Suite(.testDirectory)
struct CatalogOnThisDayScopeTests {
    private static let today = CalendarDay(year: 2026, month: 11, day: 9)

    /// A local wall-clock instant in the user's zone, on the Gregorian calendar the scope counts with.
    private static func local(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
        CalendarDay.calendar().date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second
        )) ?? Date(timeIntervalSince1970: 0)
    }

    @Test func onThisDayHoldsEarlierYearsOfTheDayNewestFirstAndEveryReadAgrees() async throws {
        let temp = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let captured: [(String, Date)] = [
            ("2023-morning.jpg", Self.local(2023, 11, 9, 10)),
            ("2020-late.mp4", Self.local(2020, 11, 9, 23, 30)),
            ("2020-midnight.jpg", Self.local(2020, 11, 9, 0)),
            // The next day's first instant, and the day before's last second: not this day.
            ("2023-next-day.jpg", Self.local(2023, 11, 10, 0)),
            ("2023-day-before.jpg", Self.local(2023, 11, 8, 23, 59, 59)),
            // Today itself is not an earlier year.
            ("2026-today.jpg", Self.local(2026, 11, 9, 8)),
            ("2018-other-day.jpg", Self.local(2018, 6, 1, 12)),
        ]
        for (name, _) in captured {
            try writeCatalogStoreFile(root.appending(path: name), contents: name)
        }
        // Never enriched: no capture date, so no anniversary.
        try writeCatalogStoreFile(root.appending(path: "undated.jpg"), contents: "undated")

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == captured.count + 1 }
        let rootPath = try #require(await store.currentLibraries().first { $0.kind == .library }?.path)
        func id(_ name: String) -> MediaAssetID {
            MediaAssetID(libraryRootPath: rootPath, relativePath: MediaRelativePath(rawValue: name))
        }
        for (name, instant) in captured {
            let asset = try #require(try await store.mediaAssets(for: [id(name)])[id(name)])
            _ = await store.applyEnrichmentBatch([
                EnrichmentResult(
                    id: id(name),
                    metadata: AssetMetadata.absoluteCapture(instant: instant),
                    thumbnailPath: "\(name)-thumb.jpg",
                    sourceSize: asset.byteSize,
                    sourceMTimeSeconds: asset.contentModifiedAt.map { Int($0.timeIntervalSince1970) },
                    contentHash: .empty
                ),
            ])
        }
        let available: Set<LibraryRootPath> = [rootPath]
        let scope = SidebarSelection.onThisDay(Self.today)

        // The user's sort is by name; the scope plays newest first regardless.
        let ordered = try await store.orderedAssetIDs(
            for: CatalogQueryDescriptor(scope: scope, sort: .filenameAscending),
            availableLibraryPaths: available
        )
        let videos = try await store.orderedAssetIDs(
            for: CatalogQueryDescriptor(scope: scope, filter: MediaFilter(kinds: [.video])),
            availableLibraryPaths: available
        )
        let count = try await store.visibleAssetCount(for: scope, availableLibraryPaths: available)
        let cataloged = try await store.catalogedAssetCount(for: scope)
        let anotherDay = try await store.orderedAssetIDs(
            for: CatalogQueryDescriptor(scope: .onThisDay(CalendarDay(year: 2026, month: 6, day: 1))),
            availableLibraryPaths: available
        )
        await store.shutdown()

        #expect(ordered.ids.map(\.relativePath.rawValue) == ["2023-morning.jpg", "2020-late.mp4", "2020-midnight.jpg"])
        // Day buckets travel with the scope's fixed date order even under a name sort.
        #expect(ordered.dayBuckets.count == ordered.ids.count)
        #expect(videos.ids.map(\.relativePath.rawValue) == ["2020-late.mp4"])
        #expect(count == 3)
        #expect(cataloged == 3)
        #expect(anotherDay.ids.map(\.relativePath.rawValue) == ["2018-other-day.jpg"])

        let state = try #require(CatalogWindowPolicy.onThisDayState(
            for: CatalogQueryDescriptor(scope: scope),
            scopedAssetIDs: ordered.ids,
            scopedDayBuckets: ordered.dayBuckets
        ))
        #expect(state.anniversaries.map(\.day.year) == [2023, 2020])
        #expect(state.anniversaries.map(\.count) == [1, 2])
        #expect(state.anniversaries[1].keyItem == id("2020-late.mp4"))
        #expect(state.itemCount == 3)
        #expect(state.isYears)
    }

    /// No earlier year holds the day: the scope holds the day of the month in earlier
    /// months instead, newest first. Any earlier year that does hold it wins, and a filter
    /// that hides that year's items only narrows — it never turns the years into months.
    @Test func onThisDayFallsBackToEarlierMonthsOnlyWhenNoEarlierYearHoldsTheDay() async throws {
        let temp = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let captured: [(String, Date)] = [
            ("2025-11-09.jpg", Self.local(2025, 11, 9, 12)),
            ("2026-10-09-evening.mp4", Self.local(2026, 10, 9, 18)),
            ("2026-10-09-morning.jpg", Self.local(2026, 10, 9, 9)),
            ("2026-08-09.jpg", Self.local(2026, 8, 9, 12)),
            ("2026-10-10.jpg", Self.local(2026, 10, 10, 12)),
        ]
        for (name, _) in captured {
            try writeCatalogStoreFile(root.appending(path: name), contents: name)
        }
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == captured.count }
        let rootPath = try #require(await store.currentLibraries().first { $0.kind == .library }?.path)
        func id(_ name: String) -> MediaAssetID {
            MediaAssetID(libraryRootPath: rootPath, relativePath: MediaRelativePath(rawValue: name))
        }
        for (name, instant) in captured {
            let asset = try #require(try await store.mediaAssets(for: [id(name)])[id(name)])
            _ = await store.applyEnrichmentBatch([
                EnrichmentResult(
                    id: id(name),
                    metadata: AssetMetadata.absoluteCapture(instant: instant),
                    thumbnailPath: "\(name)-thumb.jpg",
                    sourceSize: asset.byteSize,
                    sourceMTimeSeconds: asset.contentModifiedAt.map { Int($0.timeIntervalSince1970) },
                    contentHash: .empty
                ),
            ])
        }
        let available: Set<LibraryRootPath> = [rootPath]
        let november = SidebarSelection.onThisDay(Self.today)
        let december = CalendarDay(year: 2026, month: 12, day: 9)
        let videos = MediaFilter(kinds: [.video])

        let yearsOrdered = try await store.orderedAssetIDs(
            for: CatalogQueryDescriptor(scope: november),
            availableLibraryPaths: available
        )
        let yearsVideos = try await store.orderedAssetIDs(
            for: CatalogQueryDescriptor(scope: november, filter: videos),
            availableLibraryPaths: available
        )
        let monthsOrdered = try await store.orderedAssetIDs(
            for: CatalogQueryDescriptor(scope: .onThisDay(december)),
            availableLibraryPaths: available
        )
        let monthsVideos = try await store.orderedAssetIDs(
            for: CatalogQueryDescriptor(scope: .onThisDay(december), filter: videos),
            availableLibraryPaths: available
        )
        let monthsCount = try await store.visibleAssetCount(for: .onThisDay(december), availableLibraryPaths: available)
        await store.shutdown()

        // 9 November 2025 is a year before 9 November 2026: years, and only years.
        #expect(yearsOrdered.ids.map(\.relativePath.rawValue) == ["2025-11-09.jpg"])
        #expect(yearsVideos.ids.isEmpty)
        // No 9 December in an earlier year: the 9th of each earlier month, newest first.
        #expect(monthsOrdered.ids.map(\.relativePath.rawValue) == [
            "2026-10-09-evening.mp4", "2026-10-09-morning.jpg", "2026-08-09.jpg", "2025-11-09.jpg",
        ])
        #expect(monthsVideos.ids.map(\.relativePath.rawValue) == ["2026-10-09-evening.mp4"])
        #expect(monthsCount == 4)

        let state = try #require(CatalogWindowPolicy.onThisDayState(
            for: CatalogQueryDescriptor(scope: .onThisDay(december)),
            scopedAssetIDs: monthsOrdered.ids,
            scopedDayBuckets: monthsOrdered.dayBuckets
        ))
        #expect(!state.isYears)
        #expect(state.anniversaries.map(\.count) == [2, 1, 1])
        #expect(state.anniversaries.map { OnThisDayAnniversaryPolicy.interval($0, today: december) }
            == [.months(2), .months(4), .months(13)])
    }

    /// On This Day picks (owner, 2026-11-13, as Apple Photos' Memories): a Disliked photo and
    /// one Vision is confident is a screenshot are left out, a day's Liked photos come first,
    /// and a day holding only left-out photos is no anniversary.
    @Test func onThisDayLeavesOutDislikedPhotosAndScreenshotsAndPutsLikedFirst() async throws {
        let temp = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let captured: [(String, Date)] = [
            ("2023-evening.jpg", Self.local(2023, 11, 9, 20)),
            ("2023-noon.jpg", Self.local(2023, 11, 9, 12)),
            ("2023-morning.jpg", Self.local(2023, 11, 9, 8)),
            ("2023-screen.png", Self.local(2023, 11, 9, 9)),
            ("2022-disliked.jpg", Self.local(2022, 11, 9, 10)),
        ]
        for (name, _) in captured {
            try writeCatalogStoreFile(root.appending(path: name), contents: name)
        }
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == captured.count }
        let rootPath = try #require(await store.currentLibraries().first { $0.kind == .library }?.path)
        func id(_ name: String) -> MediaAssetID {
            MediaAssetID(libraryRootPath: rootPath, relativePath: MediaRelativePath(rawValue: name))
        }
        for (name, instant) in captured {
            let asset = try #require(try await store.mediaAssets(for: [id(name)])[id(name)])
            _ = await store.applyEnrichmentBatch([
                EnrichmentResult(
                    id: id(name),
                    metadata: AssetMetadata.absoluteCapture(instant: instant),
                    thumbnailPath: "\(name)-thumb.jpg",
                    sourceSize: asset.byteSize,
                    sourceMTimeSeconds: asset.contentModifiedAt.map { Int($0.timeIntervalSince1970) },
                    contentHash: .empty
                ),
            ])
        }
        _ = try await store.setMediaChoice(.liked, for: [id("2023-morning.jpg")])
        _ = try await store.setMediaChoice(.disliked, for: [id("2022-disliked.jpg")])
        let screen = try #require(try await store.searchEmbeddingCandidates(limit: 10).first { $0.id == id("2023-screen.png") })
        var changes = await store.changeNotifications().makeAsyncIterator()
        let vector = [Float](repeating: 0, count: SearchEmbedding.dimensions)
        let written = try await store.applySearchEmbeddings([
            SearchEmbeddingResult(id: screen.id, source: screen.source, embedding: vector, confidentLabels: ["screenshot"]),
        ])
        #expect(written.count == 1)
        // The label takes the photo out of On This Day, so the scope is read again.
        #expect(await changes.next() == .changed(.searchReadings))

        let ordered = try await store.orderedAssetIDs(
            for: CatalogQueryDescriptor(scope: .onThisDay(Self.today)),
            availableLibraryPaths: [rootPath]
        )
        #expect(ordered.ids == [id("2023-morning.jpg"), id("2023-evening.jpg"), id("2023-noon.jpg")])
        await store.shutdown()
    }

    /// A RAW+JPEG pair is one photo, and a choice on it is its key's (ADR 0052): a Disliked
    /// key leaves the whole pair out, its RAW twin included; a Disliked RAW behind its key
    /// leaves the key on the day.
    @Test func onThisDayJudgesAPairByItsKey() async throws {
        let temp = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let captured: [(String, MediaKind, Date)] = [
            ("DSC1.ARW", .raw, Self.local(2023, 11, 9, 8)),
            ("DSC1.JPG", .image, Self.local(2023, 11, 9, 8)),
            ("DSC2.ARW", .raw, Self.local(2022, 11, 9, 8)),
            ("DSC2.JPG", .image, Self.local(2022, 11, 9, 8)),
        ]
        for (name, _, _) in captured {
            try writeCatalogStoreFile(root.appending(path: name), contents: name)
        }
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == captured.count }
        let rootPath = try #require(await store.currentLibraries().first { $0.kind == .library }?.path)
        func id(_ name: String) -> MediaAssetID {
            MediaAssetID(libraryRootPath: rootPath, relativePath: MediaRelativePath(rawValue: name))
        }
        for (name, kind, instant) in captured {
            let asset = try #require(try await store.mediaAssets(for: [id(name)])[id(name)])
            _ = await store.applyEnrichmentBatch([
                EnrichmentResult(
                    id: id(name),
                    metadata: AssetMetadata.absoluteCapture(instant: instant),
                    enrichedKind: kind,
                    thumbnailPath: "\(name)-thumb.jpg",
                    sourceSize: asset.byteSize,
                    sourceMTimeSeconds: asset.contentModifiedAt.map { Int($0.timeIntervalSince1970) },
                    contentHash: .empty
                ),
            ])
        }
        _ = try await store.setMediaChoice(.disliked, for: [id("DSC1.JPG"), id("DSC2.ARW")])

        let ordered = try await store.orderedAssetIDs(
            for: CatalogQueryDescriptor(scope: .onThisDay(Self.today)),
            availableLibraryPaths: [rootPath]
        )
        #expect(ordered.ids == [id("DSC2.JPG")])
        #expect(ordered.stacks.stack(containing: id("DSC2.JPG"))?.id.kind == .pair)
        await store.shutdown()
    }

    /// A year is offered exactly when its card would hold a photo (`OnThisDayPicks.shows`):
    /// an earlier year whose only photo is a pair with a Disliked key holds no photo On This
    /// Day shows — its RAW twin is not Disliked, but leaves with its key — so the day falls
    /// back to earlier months, and every read of the scope agrees. Once the key is Liked
    /// again, the year is offered.
    @Test func onThisDayOffersAYearOnlyWhenItsCardWouldHoldAPhoto() async throws {
        let temp = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let captured: [(String, MediaKind, Date)] = [
            ("DSC1.ARW", .raw, Self.local(2023, 11, 9, 8)),
            ("DSC1.JPG", .image, Self.local(2023, 11, 9, 8)),
            ("2026-10-09.jpg", .image, Self.local(2026, 10, 9, 12)),
        ]
        for (name, _, _) in captured {
            try writeCatalogStoreFile(root.appending(path: name), contents: name)
        }
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == captured.count }
        let rootPath = try #require(await store.currentLibraries().first { $0.kind == .library }?.path)
        func id(_ name: String) -> MediaAssetID {
            MediaAssetID(libraryRootPath: rootPath, relativePath: MediaRelativePath(rawValue: name))
        }
        for (name, kind, instant) in captured {
            let asset = try #require(try await store.mediaAssets(for: [id(name)])[id(name)])
            _ = await store.applyEnrichmentBatch([
                EnrichmentResult(
                    id: id(name),
                    metadata: AssetMetadata.absoluteCapture(instant: instant),
                    enrichedKind: kind,
                    thumbnailPath: "\(name)-thumb.jpg",
                    sourceSize: asset.byteSize,
                    sourceMTimeSeconds: asset.contentModifiedAt.map { Int($0.timeIntervalSince1970) },
                    contentHash: .empty
                ),
            ])
        }
        _ = try await store.setMediaChoice(.disliked, for: [id("DSC1.JPG")])
        let scope = SidebarSelection.onThisDay(Self.today)
        let available: Set<LibraryRootPath> = [rootPath]

        let disliked = try await store.orderedAssetIDs(for: CatalogQueryDescriptor(scope: scope), availableLibraryPaths: available)
        let dislikedCount = try await store.visibleAssetCount(for: scope, availableLibraryPaths: available)
        let dislikedCataloged = try await store.catalogedAssetCount(for: scope)

        _ = try await store.setMediaChoice(.liked, for: [id("DSC1.JPG")])
        let liked = try await store.orderedAssetIDs(for: CatalogQueryDescriptor(scope: scope), availableLibraryPaths: available)
        await store.shutdown()

        // The months' match: the 9th of October, not an empty 2023. The pair's 9 November
        // is a 9th too, and leaves with its key.
        #expect(disliked.ids == [id("2026-10-09.jpg")])
        // The counts read the months as well, and count what the cards show: the RAW twin
        // leaves with its key.
        #expect(dislikedCount == 1)
        #expect(dislikedCataloged == 1)
        let state = try #require(CatalogWindowPolicy.onThisDayState(
            for: CatalogQueryDescriptor(scope: scope),
            scopedAssetIDs: disliked.ids,
            scopedDayBuckets: disliked.dayBuckets
        ))
        #expect(!state.isYears)
        // A Liked key shows the pair: 2023 is offered, and the months are not.
        #expect(Set(liked.ids) == [id("DSC1.ARW"), id("DSC1.JPG")])
        #expect(liked.stacks.stack(containing: id("DSC1.JPG"))?.key == id("DSC1.JPG"))
    }

    /// On This Day's counts come from the rule its cards use (`OnThisDayPicks.shows`): its
    /// only visible use of them is the empty state, and a scope whose every photo is a file of
    /// a Disliked-key stack is nothing on this day — under a filter it is not "no matches",
    /// which would say clearing the filter shows something.
    @Test func onThisDaysEmptyStateCountsOnlyWhatItsCardsWouldShow() async throws {
        let temp = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let captured: [(String, MediaKind, Date)] = [
            ("DSC1.ARW", .raw, Self.local(2023, 11, 9, 8)),
            ("DSC1.JPG", .image, Self.local(2023, 11, 9, 8)),
        ]
        for (name, _, _) in captured {
            try writeCatalogStoreFile(root.appending(path: name), contents: name)
        }
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == captured.count }
        let rootPath = try #require(await store.currentLibraries().first { $0.kind == .library }?.path)
        func id(_ name: String) -> MediaAssetID {
            MediaAssetID(libraryRootPath: rootPath, relativePath: MediaRelativePath(rawValue: name))
        }
        for (name, kind, instant) in captured {
            let asset = try #require(try await store.mediaAssets(for: [id(name)])[id(name)])
            _ = await store.applyEnrichmentBatch([
                EnrichmentResult(
                    id: id(name),
                    metadata: AssetMetadata.absoluteCapture(instant: instant),
                    enrichedKind: kind,
                    thumbnailPath: "\(name)-thumb.jpg",
                    sourceSize: asset.byteSize,
                    sourceMTimeSeconds: asset.contentModifiedAt.map { Int($0.timeIntervalSince1970) },
                    contentHash: .empty
                ),
            ])
        }
        _ = try await store.setMediaChoice(.disliked, for: [id("DSC1.JPG")])
        let scope = SidebarSelection.onThisDay(Self.today)
        let rawOnly = MediaFilter(kinds: [.raw])
        let filtered = try await store.orderedAssetIDs(
            for: CatalogQueryDescriptor(scope: scope, filter: rawOnly), availableLibraryPaths: [rootPath]
        )
        let unfiltered = try await store.visibleAssetCount(for: scope, availableLibraryPaths: [rootPath])
        let cataloged = try await store.catalogedAssetCount(for: scope)
        let filteredCount = try await store.visibleAssetCount(for: scope, filter: rawOnly, availableLibraryPaths: [rootPath])
        await store.shutdown()

        #expect(filtered.ids.isEmpty)
        #expect(unfiltered == 0)
        #expect(cataloged == 0)
        #expect(filteredCount == 0)
        let library = CatalogLibraryState(root: LibraryRoot(path: rootPath), availability: .available, activity: .idle)
        let empty = CatalogWindowPolicy.mediaEmptyState(
            for: CatalogQueryDescriptor(scope: scope, filter: rawOnly),
            libraries: [library],
            allAssetCount: cataloged,
            unfilteredVisibleAssetCount: unfiltered,
            selectedAssetCount: filtered.ids.count
        )
        #expect(empty == .nothingOnThisDay(Self.today))
    }

    @MainActor
    @Test func onThisDayResolvesWithTheFixedLibrariesAndNamesItsEmptiness() {
        let pictures = CatalogLibraryState(
            root: LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Pictures")),
            availability: .available,
            activity: .idle
        )
        let scope = SidebarSelection.onThisDay(Self.today)

        #expect(CatalogWindowPolicy.resolvedSidebarSelection(scope, libraries: [pictures], removableSources: []) == scope)
        #expect(CatalogWindowPolicy.title(for: scope, libraries: [pictures]) == "On This Day")
        let empty = CatalogWindowPolicy.mediaEmptyState(
            for: CatalogQueryDescriptor(scope: scope),
            libraries: [pictures],
            allAssetCount: 0,
            unfilteredVisibleAssetCount: 0,
            selectedAssetCount: 0
        )
        let filtered = CatalogWindowPolicy.mediaEmptyState(
            for: CatalogQueryDescriptor(scope: scope, filter: MediaFilter(kinds: [.video])),
            libraries: [pictures],
            allAssetCount: 3,
            unfilteredVisibleAssetCount: 3,
            selectedAssetCount: 0
        )
        #expect(empty == .nothingOnThisDay(Self.today))
        #expect(empty.title == "Nothing on This Day")
        #expect(filtered == .noFilterMatches)
        // Another scope publishes no anniversaries.
        #expect(CatalogWindowPolicy.onThisDayState(
            for: CatalogQueryDescriptor(scope: .allMedia),
            scopedAssetIDs: [],
            scopedDayBuckets: []
        ) == nil)
    }
}
