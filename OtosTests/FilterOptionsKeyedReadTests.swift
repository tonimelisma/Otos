import Foundation
import GRDB
@testable import OtosKit
import Testing

/// N location writes on a catalog of the owner's shape cost options reads in proportion to N
/// (ADR 0005, "Keyed re-reads"): each write's rows are read again by key and patched
/// into All Media's tally, the row's scope is never read again, and the options shown after
/// each write are exactly what a whole read gives. On the owner's library a sync re-read All
/// Media's options whole 92 times while 152 metadata changes arrived. It runs on a fiftieth of
/// the owner's size in the suite, and at his size on demand (`OTOS_SCALE_TEST=1`), when it
/// writes each read's time to `build/filter-options-keyed/run.txt`.
@Suite(.testScope, .serialized)
struct FilterOptionsKeyedReadTests {
    @Test func locationWritesAreReadByKeyAndKeepTheOptionsAWholeReadGives() async throws {
        let scale = StallReproductionTests.ownerSize ? 1 : 0.02
        let directory = try makeTestDirectory()
        let catalog = try OwnerShapedCatalog.make(in: directory, scale: scale)
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
                // The centre of generated cell `cell` (`OwnerShapedCatalog`'s place cells).
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
            let whole = try await store.windowReads.filterOptions(
                for: .allMedia, availableLibraryPaths: Set(shown.libraries.map(\.path)), placeNameLanguages: [language]
            )
            let wholeMs = DiagnosticsTiming.milliseconds(wholeStart.duration(to: clock.now))
            #expect(shown.filterOptions == whole, "step \(step)")
            lines.append("step=\(step) writeToPublishedMs=\(keyedMs) wholeReadMs=\(wholeMs)")
        }
        // Most writes moved their row: the reads followed them.
        #expect(owed >= UInt64(moves.count - 2), "owed=\(owed)")
        await store.shutdown()
        if StallReproductionTests.ownerSize {
            let url = SourceTree.root.appending(path: "build/filter-options-keyed/run.txt")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        }
    }
}
