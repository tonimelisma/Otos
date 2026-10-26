import Foundation
import GRDB
import MediaMetadata
@testable import OtosKit
import Testing

/// ADR 0039: a metadata record an older MediaMetadata revision produced is re-read from
/// local bytes only, and only for library rows whose enrichment is otherwise current.
@Suite(.testDirectory)
@MainActor
struct MetadataRefresherTests {
    @Test func aStaleRecordIsReReadWhenItsOriginalIsLocalAndLeftWhenItIsNot() async throws {
        try await withEditableLibrary(fileCount: 2) { library in
            let state = try await catalogStoreTestState(library.store)
            let stale = try state.testAssets.map { asset in
                try EnrichmentResult(
                    id: asset.id,
                    metadata: AssetMetadata(family: "unknown", extractionRevision: nil),
                    thumbnailPath: nil,
                    sourceSize: #require(asset.byteSize),
                    sourceMTimeSeconds: MediaAsset.mtimeSeconds(asset.contentModifiedAt),
                    contentHash: .empty
                )
            }
            _ = await library.store.applyEnrichmentBatch(stale)
            let local = library.ids[0]
            let cloudOnly = library.ids[1]
            let refresher = MetadataRefresher(store: library.store, isLocal: { $0 == local.fileURL }, pageSize: 1)

            let summary = await refresher.refresh()

            #expect(summary == MetadataRefreshSummary(read: 1, written: 1, skipped: 1, failed: false))
            let rows = try await revisions(library.databaseURL)
            #expect(rows[local.relativePath.rawValue]?.revision == MediaMetadataReader.extractionRevision)
            #expect(rows[local.relativePath.rawValue]?.family == "jpeg")
            #expect(rows[cloudOnly.relativePath.rawValue]?.revision == nil)

            let again = await MetadataRefresher(store: library.store, isLocal: { _ in true }).refresh()
            #expect(again.written == 1)
            #expect(try await revisions(library.databaseURL)[cloudOnly.relativePath.rawValue]?.revision
                == MediaMetadataReader.extractionRevision)
        }
    }

    /// Only library rows with a current enrichment and an older or unknown revision are
    /// candidates: a card row, a row already current, and a row whose file changed (which
    /// enrichment re-reads anyway) are not.
    @Test func candidatesAreLibraryRowsWithCurrentEnrichmentAndAnOlderRecord() async throws {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let creator = CatalogStore(location: .databaseFile(databaseURL))
        try await creator.start(scansSavedLibraries: false)
        await creator.shutdown()
        try await DatabaseQueue(path: databaseURL.path(percentEncoded: false)).write { db in
            try db.execute(sql: "INSERT INTO library_root (id, path, kind) VALUES (1, '/Pictures', 'library')")
            try db.execute(sql: "INSERT INTO library_root (id, path, kind) VALUES (2, '/Volumes/Card', 'removableVolume')")
            struct Fixture {
                let root: Int
                let path: String
                let enrichedMTime: Int
                let revision: Int?
            }
            let current = MediaMetadataReader.extractionRevision
            for row in [
                Fixture(root: 1, path: "unknown.jpg", enrichedMTime: 100, revision: nil),
                Fixture(root: 1, path: "older.jpg", enrichedMTime: 100, revision: current - 1),
                Fixture(root: 1, path: "current.jpg", enrichedMTime: 100, revision: current),
                Fixture(root: 1, path: "changed.jpg", enrichedMTime: 99, revision: nil),
                Fixture(root: 2, path: "card.jpg", enrichedMTime: 100, revision: nil),
            ] {
                try db.execute(
                    sql: """
                    INSERT INTO media_asset (library_root_id, relative_path, relative_path_key, sort_key, name_sort_key,
                        kind, byte_size, content_modified_at_unix, enriched_source_size, enriched_source_mtime)
                    VALUES (?, ?, ?, ?, ?, 'image', 10, 100, 10, ?)
                    """,
                    arguments: [row.root, row.path, row.path, row.path, row.path, row.enrichedMTime]
                )
                try db.execute(
                    sql: "INSERT INTO asset_metadata (library_root_id, relative_path, family, extraction_revision) VALUES (?, ?, 'jpeg', ?)",
                    arguments: [row.root, row.path, row.revision]
                )
            }
        }
        let store = CatalogStore(location: .databaseFile(databaseURL))
        try await store.start(scansSavedLibraries: false)
        let candidates = try await store.metadataRefreshCandidates(
            belowRevision: MediaMetadataReader.extractionRevision, after: nil, limit: 10
        )
        await store.shutdown()

        #expect(candidates.map(\.id.relativePath.rawValue) == ["older.jpg", "unknown.jpg"])
    }

    private func revisions(_ databaseURL: URL) async throws -> [String: (revision: Int?, family: String?)] {
        try await DatabaseQueue(path: databaseURL.path(percentEncoded: false)).read { db in
            var result: [String: (revision: Int?, family: String?)] = [:]
            for row in try GRDB.Row.fetchAll(db, sql: "SELECT relative_path, extraction_revision, family FROM asset_metadata") {
                result[row["relative_path"]] = (row["extraction_revision"], row["family"])
            }
            return result
        }
    }
}
