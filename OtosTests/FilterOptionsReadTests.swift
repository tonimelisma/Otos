import Foundation
import GRDB
@testable import OtosKit
import Synchronization
import Testing

/// The filter's options are read beside the window, never before it or before the next pass
/// (ADR 0005): a sort, a search or a filter on the same row is built and shown while the
/// options read is parked, and an intent for another row cancels the read, whose answer is
/// never kept. On the reference catalog a search, a clear and a sort each waited 15–23 s for
/// the options read of the pass before them.
@Suite(.testScope)
struct FilterOptionsReadTests {
    /// A projection over an in-memory catalog of one empty library, whose options reads park
    /// at `gate` and answer `answer`.
    private struct Window {
        let store: CatalogStore
        let projection: CatalogProjection
        let recorder: AsyncValueRecorder<CatalogWindowState>
        let recording: Task<Void, Never>
        let library: LibraryRootPath
    }

    private static let answer = CatalogFilterOptions(formatsByKind: [.image: [MediaFormatToken(rawValue: "JPEG")]])

    private func window(gate: ArrivalGate, rows: AskedRows) async throws -> Window {
        // Two libraries: with one, All Media is that library's row.
        let directory = try makeTestDirectory()
        let root = directory.appending(path: "Pictures", directoryHint: .isDirectory)
        let other = directory.appending(path: "Archive", directoryHint: .isDirectory)
        let store = makeTestStore(location: .inMemory)
        try await store.start(scansSavedLibraries: false)
        for url in [root, other] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try await store.addLibrary(url: url)
        }
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.libraries.count == 2 }
        let projection = CatalogProjection(volumeCapacity: ampleVolumeCapacity, cadence: .seconds(3600), filterOptionsReader: { owed in
            rows.append(owed.row)
            await gate.arrive()
            try Task.checkCancellation()
            return Self.answer
        })
        let recorder = AsyncValueRecorder<CatalogWindowState>()
        let stream = await projection.states(store: store, initialDescriptor: .default)
        let recording = Task {
            for await state in stream {
                await recorder.append(state)
            }
        }
        return try Window(
            store: store, projection: projection, recorder: recorder, recording: recording,
            library: CatalogPath.normalizedDirectoryPath(for: root)
        )
    }

    // Validates: ENR-030
    /// The places All Media offers on a catalog of the reference shape, read by walking its rows
    /// and finding each located row's cell by its coordinate, are what every located row's
    /// stored cell names: the oracle joins the tables as the planner likes and counts in SQL.
    @Test func thePlacesWalkFindsWhatEveryLocatedRowsCellNames() async throws {
        let catalog = try ReferenceShapedCatalog.make(in: makeTestDirectory(), scale: 0.05)
        let queue = try makeTestDatabaseQueue(path: catalog.databaseURL.path(percentEncoded: false))
        defer { try? queue.close() }
        let language = PlaceNameLanguage(Locale.current)
        let (walked, oracle) = try await queue.read { db in
            let roots: [Int64] = [6, 7, 15]
            var tally = CatalogFilterOptionTally(language: language)
            #expect(try CatalogQueryGateway.tallyFilterOptionRows(scope: CatalogScopePredicate(rootIDs: roots), into: &tally, pairing: .paired, db: db))
            tally.names = try CatalogQueryGateway.placeCellNames(of: tally.cells, language: language, db: db)
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT place_cell.country, place_cell.town, COUNT(*) AS items
                FROM media_asset
                JOIN asset_metadata
                  ON asset_metadata.library_root_id = media_asset.library_root_id
                  AND asset_metadata.relative_path = media_asset.relative_path
                JOIN place_cell
                  ON place_cell.cell_latitude = asset_metadata.place_cell_latitude
                  AND place_cell.cell_longitude = asset_metadata.place_cell_longitude
                WHERE media_asset.library_root_id IN (6, 7, 15)
                  AND \(CatalogVisibilitySQL.isPresent("media_asset"))
                  AND NOT \(LivePhotoSQL.isPairedMotion("media_asset"))
                  AND place_cell.language = ? AND place_cell.country IS NOT NULL
                GROUP BY place_cell.country, place_cell.town
                """,
                arguments: [language.identifier]
            )
            var countryItems: [String: Int] = [:]
            var townItems: [String: [String: Int]] = [:]
            for row in rows {
                let country: String = row["country"]
                countryItems[country, default: 0] += row["items"] as Int
                if let town = row["town"] as String? {
                    townItems[country, default: [:]][town, default: 0] += row["items"] as Int
                }
            }
            let oracle = PlaceFilterCountry.mostItemsFirst(countryItems).map { country in
                PlaceFilterCountry(name: country, towns: PlaceFilterCountry.mostItemsFirst(townItems[country] ?? [:]))
            }
            return (tally.options.countries, oracle)
        }
        #expect(!walked.isEmpty)
        #expect(walked == oracle)
    }

    // Validates: ARC-019
    @Test func aSortIsShownWhileTheOptionsReadIsParked() async throws {
        let gate = ArrivalGate()
        let rows = AskedRows()
        let window = try await window(gate: gate, rows: rows)
        defer { window.recording.cancel() }
        await gate.waitForArrivals(1)

        // The options read of All Media is parked; a sort on the same row is built and shown.
        let byName = MediaSortOrder(field: .name, direction: .ascending)
        await window.projection.updateQueryDescriptor(CatalogQueryDescriptor(scope: .allMedia, sort: byName))
        let shown = await window.recorder.waitForValues { $0.last?.queryDescriptor.sort == byName }
        #expect(shown.last?.filterOptions == .empty, "the options are not read yet")
        #expect(await !window.projection.isQuiescent)

        await gate.open()
        let settled = try await waitForProjectionQuiescence(window.projection, recordedBy: window.recorder)
        #expect(settled.last?.queryDescriptor.sort == byName)
        #expect(settled.last?.filterOptions == Self.answer)
        #expect(rows.all.allSatisfy { $0 == .allMedia }, "the sort on the same row asks for no other row")
        await window.store.shutdown()
    }

    // Validates: ARC-019
    @Test func anIntentForAnotherRowCancelsTheOptionsReadAndKeepsNothingOfIt() async throws {
        let gate = ArrivalGate()
        let rows = AskedRows()
        let window = try await window(gate: gate, rows: rows)
        defer { window.recording.cancel() }
        await gate.waitForArrivals(1)

        await window.projection.updateSidebarSelection(.library(window.library))
        _ = await window.recorder.waitForValues { $0.last?.resolvedSidebarSelection == .library(window.library) }
        await gate.waitForArrivals(2)
        await gate.open()
        let settled = try await waitForProjectionQuiescence(window.projection, recordedBy: window.recorder)
        #expect(rows.all.prefix(2) == [.allMedia, .library(window.library)])
        #expect(settled.last?.resolvedSidebarSelection == .library(window.library))
        #expect(settled.last?.filterOptions == Self.answer)

        // Back on All Media, whose read was cancelled: nothing of it was kept, so it is read.
        await window.projection.updateSidebarSelection(.allMedia)
        _ = try await waitForProjectionQuiescence(window.projection, recordedBy: window.recorder)
        #expect(rows.all.last == .allMedia)
        #expect(await window.recorder.snapshot().last?.filterOptions == Self.answer)
        await window.store.shutdown()
    }
}

/// The rows the options reads were asked for, in order.
private final class AskedRows: Sendable {
    private let rows = Mutex<[SidebarSelection]>([])

    func append(_ row: SidebarSelection) {
        rows.withLock { $0.append(row) }
    }

    var all: [SidebarSelection] {
        rows.withLock { $0 }
    }
}
