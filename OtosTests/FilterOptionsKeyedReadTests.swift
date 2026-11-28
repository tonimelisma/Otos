import Foundation
import GRDB
@testable import OtosKit
import Testing

/// N location writes on a catalog of the reference shape cost options reads in proportion to N
/// (ADR 0005, "Keyed re-reads"): each write's rows are read again by key and patched
/// into All Media's tally, the row's scope is never read again, and the options shown after
/// each write are exactly what a whole read gives. On the reference library a sync re-read All
/// Media's options whole 92 times while 152 metadata changes arrived. It runs on a fiftieth of
/// the reference size in the suite, and at the reference size on demand (`OTOS_SCALE_TEST=1`), when it
/// writes each read's time to `build/filter-options-keyed/run.txt`.
@Suite(.testScope, .serialized)
struct FilterOptionsKeyedReadTests {
    // Validates: ARC-022
    @Test func locationWritesAreReadByKeyAndKeepTheOptionsAWholeReadGives() async throws {
        let scale = StallReproductionTests.referenceSize ? 1 : 0.02
        let directory = try makeTestDirectory()
        let catalog = try ReferenceShapedCatalog.make(in: directory, scale: scale)
        let store = makeTestStore(location: .databaseFile(catalog.databaseURL))
        try await store.start(scansSavedLibraries: false)
        let projection = CatalogProjection(
            volumeCapacity: ampleVolumeCapacity,
            cadence: .milliseconds(25),
            backgroundOwners: BackgroundOwners(off: Set(BackgroundOwner.allCases))
        )
        let recorder = AsyncValueRecorder<CatalogWindowState>()
        let stream = await projection.states(store: store, initialDescriptor: .default)
        let recording = Task {
            for await state in stream {
                await recorder.append(state)
            }
        }
        defer { recording.cancel() }
        _ = await recorder.waitForValues {
            $0.last?.resolvedSidebarSelection == .allMedia && $0.last?.filterOptions.placeNameLanguage != nil
        }
        let settled = try await waitForProjectionQuiescence(projection, recordedBy: recorder)
        let shownIDs = try #require(settled.last?.mediaGrid.orderedAssetIDs)
        let language = try #require(settled.last?.filterOptions.placeNameLanguage)
        let wholeBefore = await projection.filterOptionsQueryCount
        let keyedBefore = await projection.keyedFilterOptionsQueryCount
        let clock = ContinuousClock()

        // Rows from across the order move between the catalog's named cells (`Town k`, k from 0)
        // and out of every cell, one write at a time as a sync writes them.
        let moves: [(position: Int, cell: Int?)] = [
            (0, 3), (shownIDs.count / 2, 3), (shownIDs.count - 1, 7), (0, 7), (17, nil), (shownIDs.count / 3, 0),
            (shownIDs.count / 2, nil), (42, 11), (17, 3), (shownIDs.count - 1, 0),
        ]
        // A write that leaves a row where it was changes no fact and reads nothing, so the reads
        // owed are the writes that move a row's coordinate, read from the catalog beside the Store.
        let queue = try makeTestDatabaseQueue(path: catalog.databaseURL.path(percentEncoded: false))
        defer { try? queue.close() }
        func coordinate(of id: MediaAssetID) async throws -> [Double?] {
            try await queue.read { db in
                let row = try Row.fetchOne(db, sql: """
                SELECT m.primary_latitude, m.primary_longitude FROM media_asset AS a
                JOIN library_root AS r ON r.id = a.library_root_id
                LEFT JOIN asset_metadata AS m USING (library_root_id, relative_path)
                WHERE r.path = ? AND a.relative_path = ?
                """, arguments: [id.libraryRootPath.rawValue, id.relativePath.rawValue])
                return [row?[0], row?[1]]
            }
        }
        var owed: UInt64 = 0
        var lines: [String] = []
        for (step, move) in moves.enumerated() {
            let id = shownIDs[move.position]
            let was = try await coordinate(of: id)
            let asset = try #require(try await store.windowReads.mediaAssets(for: [id])[id])
            var metadata = AssetMetadata.absoluteCapture(instant: asset.captureLocalTime?.presentationDate())
            if let cell = move.cell {
                // The centre of generated cell `cell` (`ReferenceShapedCatalog`'s place cells).
                metadata.locations = [GeoRecord(
                    source: "exifGPS",
                    latitude: (2000 + Double(cell / 40) + 0.5) / 50,
                    longitude: (1000 + Double(cell % 40) + 0.5) / 50,
                    altitudeMeters: nil
                )]
            }
            let generation = await recorder.snapshot().last?.mediaGrid.detailRefreshGeneration ?? 0
            let start = clock.now
            _ = await store.applyEnrichmentBatch([EnrichmentResult(
                id: id, metadata: metadata, enrichedKind: asset.bestKind, enrichedFormat: asset.bestFormat,
                thumbnailPath: nil, sourceSize: asset.byteSize,
                sourceMTimeSeconds: MediaAsset.mtimeSeconds(asset.contentModifiedAt), contentHash: nil
            )])
            _ = await recorder.waitForValues { ($0.last?.mediaGrid.detailRefreshGeneration ?? 0) > generation }
            let shown = try #require(try await waitForProjectionQuiescence(projection, recordedBy: recorder).last)
            let keyedMs = DiagnosticsTiming.milliseconds(start.duration(to: clock.now))

            #expect(await projection.filterOptionsQueryCount == wholeBefore, "step \(step)")
            if try await coordinate(of: id) != was {
                owed += 1
            }
            #expect(await projection.keyedFilterOptionsQueryCount == keyedBefore + owed, "step \(step)")
            let wholeStart = clock.now
            let whole = try await store.windowReads.filterOptionTally(
                for: .allMedia, availableLibraryPaths: Set(shown.libraries.map(\.path)), placeNameLanguages: [language]
            ).options
            let wholeMs = DiagnosticsTiming.milliseconds(wholeStart.duration(to: clock.now))
            #expect(shown.filterOptions == whole, "step \(step)")
            lines.append("step=\(step) writeToPublishedMs=\(keyedMs) wholeReadMs=\(wholeMs)")
        }
        // Most writes moved their row: the reads followed them.
        #expect(owed >= UInt64(moves.count - 2), "owed=\(owed)")
        await store.shutdown()
        if StallReproductionTests.referenceSize {
            let url = SourceTree.root.appending(path: "build/filter-options-keyed/run.txt")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        }
    }

    /// A tally holds the names of its own cells only: a row that moves into a named cell the
    /// tally never counted brings that cell's name with its keyed re-read, and a renamed cell is
    /// named again by its key. After each, the patched tally offers what a whole read does.
    @Test func aKeyedReadNamesTheCellsItsRowsMoveIntoAndTheCellsRenamed() async throws {
        // The reference library's 1,435 named cells on a small catalog: Archive's eight rows count a few.
        let catalog = try ReferenceShapedCatalog.make(in: makeTestDirectory(), scale: 0.01, referencePlaces: true)
        let store = makeTestStore(location: .databaseFile(catalog.databaseURL))
        try await store.start(scansSavedLibraries: false)
        let libraries = try #require(await store.loadedLibraries())
        let available = CatalogWindowPolicy.availablePaths(from: libraries)
        let language = PlaceNameLanguage(Locale.current)
        let row = SidebarSelection.library(catalog.archive)
        func whole() async throws -> CatalogFilterOptionTally {
            try await store.windowReads.filterOptionTally(for: row, availableLibraryPaths: available, placeNameLanguages: [language])
        }
        var tally = try await whole()
        #expect(tally.names.count == tally.cells.count && tally.cells.count < 1435, "a tally names only its own cells")

        // One of Archive's rows moves into a named cell none of its rows is in.
        let id = try #require(try await store.windowReads.orderedAssetIDs(
            for: CatalogQueryDescriptor(scope: row), availableLibraryPaths: available
        ).ids.first)
        let k = try #require((0 ..< 1435).first { !tally.cells.contains(PlaceCell(latitude: 2000 + $0 / 40, longitude: 1000 + $0 % 40)) })
        let asset = try #require(try await store.windowReads.mediaAssets(for: [id])[id])
        var metadata = AssetMetadata.absoluteCapture(instant: asset.captureLocalTime?.presentationDate())
        metadata.locations = [GeoRecord(
            source: "exifGPS", latitude: (2000 + Double(k / 40) + 0.5) / 50, longitude: (1000 + Double(k % 40) + 0.5) / 50, altitudeMeters: nil
        )]
        _ = await store.applyEnrichmentBatch([EnrichmentResult(
            id: id, metadata: metadata, enrichedKind: asset.bestKind, enrichedFormat: asset.bestFormat,
            thumbnailPath: nil, sourceSize: asset.byteSize,
            sourceMTimeSeconds: MediaAsset.mtimeSeconds(asset.contentModifiedAt), contentHash: nil
        )])
        let moved = try #require(try await store.windowReads.filterOptionsOfRows(
            [id], namesIn: language, renamed: [], for: row, availableLibraryPaths: available
        ))
        let tookMoved = tally.take(moved)
        #expect(tookMoved)
        #expect(tally.names[PlaceCell(latitude: 2000 + k / 40, longitude: 1000 + k % 40)]?.town == "Town \(k)")
        #expect(try await tally.options == whole().options)

        // Every counted cell is renamed: the keyed read names the tally's cells again.
        let renamed = tally.cells
        try await store.applyPlaceNames(
            Dictionary(uniqueKeysWithValues: renamed.map { ($0, PlaceNames(country: "Renamed Country", town: "Renamed \($0.longitude)")) }),
            language: language
        )
        let names = try #require(try await store.windowReads.filterOptionsOfRows(
            [], namesIn: language, renamed: renamed, for: row, availableLibraryPaths: available
        ))
        #expect(names.namedCells == renamed)
        let tookNames = tally.take(names)
        #expect(tookNames)
        #expect(tally.options.countries.map(\.name) == ["Renamed Country"])
        #expect(try await tally.options == whole().options)
        await store.shutdown()
    }
}
