import Foundation
import MediaMetadata
@testable import OtosKit
import Testing

/// The timeline runs on local capture time (ADR 0039): an item is ordered by, and sits on,
/// the day its own clock read when it was taken — in the grid's day sections, the Date sort
/// and On This Day alike — whatever zone this Mac is in. An item whose file records no wall
/// clock is placed by its absolute time in the zone Otos assumed when it recorded that time.
@Suite(.testScope)
struct CaptureLocalTimeTests {
    private static let utc = TimeZone(secondsFromGMT: 0) ?? .gmt

    /// A wall-clock record as the library stores it: `localFloating` (no offset, no
    /// instant), or `localWithOffset` with the instant the offset pins.
    private static func wall(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int,
        offsetHours: Int? = nil
    ) -> CaptureTimestampRecord {
        let instant = offsetHours.map { hours in
            Date(timeIntervalSince1970: localSeconds(year, month, day, hour, minute) - Double(hours * 3600))
        }
        return CaptureTimestampRecord(
            role: CaptureTimestamps.Role.original.rawValue,
            instant: instant,
            utcOffsetSeconds: offsetHours.map { $0 * 3600 },
            precision: (offsetHours == nil ? CaptureTime.Precision.localFloating : .localWithOffset).rawValue,
            year: year, month: month, day: day, hour: hour, minute: minute, second: 0
        )
    }

    /// A reading counted on a UTC calendar, as `best_capture_local` stores it.
    private static func localSeconds(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))?
            .timeIntervalSince1970 ?? 0
    }

    /// Catalogs `files` as one library, enriches each with its records, and returns the store
    /// and how to name an asset.
    private static func catalog(
        _ files: [(name: String, records: [CaptureTimestampRecord])],
        in temp: URL
    ) async throws -> (CatalogStore, LibraryRootPath) {
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for file in files {
            try writeCatalogStoreFile(root.appending(path: file.name), contents: file.name)
        }
        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == files.count }
        let rootPath = try #require(await store.currentLibraries().first { $0.kind == .library }?.path)
        for file in files {
            let id = MediaAssetID(libraryRootPath: rootPath, relativePath: MediaRelativePath(rawValue: file.name))
            let asset = try #require(try await store.mediaAssets(for: [id])[id])
            _ = await store.applyEnrichmentBatch([
                EnrichmentResult(
                    id: id,
                    metadata: AssetMetadata(timestamps: file.records),
                    thumbnailPath: "\(file.name)-thumb.jpg",
                    sourceSize: asset.byteSize,
                    sourceMTimeSeconds: asset.contentModifiedAt.map { Int($0.timeIntervalSince1970) },
                    contentHash: .empty
                ),
            ])
        }
        return (store, rootPath)
    }

    /// A floating Exif time has no instant. The photo is still on the day its clock read,
    /// not the day its file was created (today, for a file just written), and it is ordered
    /// and matched by On This Day on that day.
    @Test func aFloatingPhotoIsOnTheDayItsClockRead() async throws {
        let temp = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let (store, rootPath) = try await Self.catalog([
            ("floating.jpg", [Self.wall(2024, 4, 25, 14, 51)]),
            ("later.jpg", [Self.wall(2024, 4, 26, 9, 0)]),
        ], in: temp)
        let available: Set<LibraryRootPath> = [rootPath]
        let grid = try await store.orderedAssetIDs(
            for: CatalogQueryDescriptor(scope: .allMedia, sort: .dateNewest),
            availableLibraryPaths: available
        )
        let onThisDay = try await store.orderedAssetIDs(
            for: CatalogQueryDescriptor(scope: .onThisDay(CalendarDay(year: 2026, month: 4, day: 25))),
            availableLibraryPaths: available
        )
        let floating = MediaAssetID(libraryRootPath: rootPath, relativePath: MediaRelativePath(rawValue: "floating.jpg"))
        let asset = try #require(try await store.mediaAssets(for: [floating])[floating])
        await store.shutdown()

        #expect(grid.ids.map(\.relativePath.rawValue) == ["later.jpg", "floating.jpg"])
        #expect(grid.dayBuckets.map { $0.map { CalendarDay($0) } } == [
            CalendarDay(year: 2024, month: 4, day: 26),
            CalendarDay(year: 2024, month: 4, day: 25),
        ])
        #expect(onThisDay.ids.map(\.relativePath.rawValue) == ["floating.jpg"])
        #expect(asset.captureLocalTime == CaptureLocalTime(seconds: Self.localSeconds(2024, 4, 25, 14, 51)))
    }

    /// Two photos taken in different zones are each on their own clock's day, whatever
    /// zone this Mac is in: 20:00 in California is that California evening, though the
    /// instant is the next day in UTC and in Sydney.
    @Test func aPhotoTakenElsewhereKeepsItsOwnDay() async throws {
        let temp = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let (store, rootPath) = try await Self.catalog([
            ("california.heic", [Self.wall(2025, 11, 9, 20, 0, offsetHours: -8)]),
            ("sydney.heic", [Self.wall(2025, 11, 10, 8, 0, offsetHours: 11)]),
        ], in: temp)
        let available: Set<LibraryRootPath> = [rootPath]
        let grid = try await store.orderedAssetIDs(
            for: CatalogQueryDescriptor(scope: .allMedia, sort: .dateOldest),
            availableLibraryPaths: available
        )
        let ninth = try await store.orderedAssetIDs(
            for: CatalogQueryDescriptor(scope: .onThisDay(CalendarDay(year: 2026, month: 11, day: 9))),
            availableLibraryPaths: available
        )
        let tenth = try await store.orderedAssetIDs(
            for: CatalogQueryDescriptor(scope: .onThisDay(CalendarDay(year: 2026, month: 11, day: 10))),
            availableLibraryPaths: available
        )
        await store.shutdown()

        // By instant, Sydney's 08:00 (21:00 UTC on the 9th) is before California's 20:00
        // (04:00 UTC on the 10th); by its own clock it is the next morning.
        #expect(grid.ids.map(\.relativePath.rawValue) == ["california.heic", "sydney.heic"])
        #expect(grid.dayBuckets.map { $0.map { CalendarDay($0) } } == [
            CalendarDay(year: 2025, month: 11, day: 9),
            CalendarDay(year: 2025, month: 11, day: 10),
        ])
        #expect(ninth.ids.map(\.relativePath.rawValue) == ["california.heic"])
        #expect(tenth.ids.map(\.relativePath.rawValue) == ["sydney.heic"])
    }

    /// The zone assumed for an absolute time is made once for that time and kept: an
    /// unchanged time keeps its offset in any later zone, a changed one takes the zone of
    /// the moment it is recorded, and no time has no offset.
    @Test func anAssumedOffsetIsKeptWhileItsTimeIsUnchanged() throws {
        let sydney = try #require(TimeZone(identifier: "Australia/Sydney"))
        let pacific = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let july = Self.localSeconds(2025, 7, 1, 12)
        let january = Self.localSeconds(2025, 1, 1, 12)

        #expect(CaptureLocalTime.assumedUTCOffset(for: july, previousAbsolute: nil, previousOffset: nil, timeZone: pacific)
            == -7 * 3600)
        #expect(CaptureLocalTime.assumedUTCOffset(for: january, previousAbsolute: nil, previousOffset: nil, timeZone: pacific)
            == -8 * 3600)
        #expect(CaptureLocalTime.assumedUTCOffset(for: july, previousAbsolute: july, previousOffset: -7 * 3600, timeZone: sydney)
            == -7 * 3600)
        #expect(CaptureLocalTime.assumedUTCOffset(for: january, previousAbsolute: july, previousOffset: -7 * 3600, timeZone: sydney)
            == 11 * 3600)
        #expect(CaptureLocalTime.assumedUTCOffset(for: july + 0.4, previousAbsolute: july, previousOffset: -7 * 3600, timeZone: sydney)
            == -7 * 3600)
        #expect(CaptureLocalTime.assumedUTCOffset(for: nil, previousAbsolute: july, previousOffset: -7 * 3600, timeZone: sydney)
            == nil)
    }

    /// A reading is written as its own clock showed it in every zone, and its presentation
    /// date is when a clock in a zone shows that reading.
    @Test func aReadingIsWrittenAsItsClockShowedIt() throws {
        let sydney = try #require(TimeZone(identifier: "Australia/Sydney"))
        let local = CaptureLocalTime(seconds: Self.localSeconds(2024, 4, 25, 14, 51))
        var style = Date.FormatStyle(date: .numeric, time: .shortened, locale: Locale(identifier: "en_GB"))
        style.timeZone = sydney

        #expect(local.formatted(style) == "25/04/2024, 14:51")
        #expect(local.day == CalendarDay(year: 2024, month: 4, day: 25))
        #expect(CaptureLocalTime(dayNumber: local.dayNumber) == CaptureLocalTime(startOf: local.day))
        #expect(CaptureLocalTime(seconds: -1).dayNumber == -1)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = sydney
        let shown = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: local.presentationDate(in: sydney))
        #expect(shown == DateComponents(year: 2024, month: 4, day: 25, hour: 14, minute: 51))
        #expect(CaptureLocalTime(readingOf: local.presentationDate(in: sydney), in: sydney) == local)
        #expect(CaptureLocalTime(startOf: CalendarDay(year: 2023, month: 2, day: 29)) == nil)
    }
}
