import Foundation
import GRDB
@testable import Otos
import Testing

struct CatalogQueryGatewayTests {
    @Test func orderedAssetIDQueryReturnsNilForScopeSelectingNothing() {
        #expect(CatalogQueryGateway.orderedAssetIDQuery(descriptor: .default, scope: .nothing) == nil)
    }

    @Test func countAssetsReturnsZeroForScopeSelectingNothing() async throws {
        let dbQueue = try DatabaseQueue()
        try CatalogStore.migrator.migrate(dbQueue)
        let count = try await dbQueue.read { db in
            try CatalogQueryGateway.countAssets(scope: .nothing, db: db)
        }
        #expect(count == 0)
    }

    @Test func filterOptionsReturnsEmptyForScopeSelectingNothing() async throws {
        let dbQueue = try DatabaseQueue()
        try CatalogStore.migrator.migrate(dbQueue)
        let options = try await dbQueue.read { db in
            try CatalogQueryGateway.filterOptions(scope: .nothing, db: db)
        }
        #expect(options == .empty)
    }

    /// Counting and filter options are scope-scoped reads exactly like ordering is:
    /// a batch stamp has to reach all three, or they disagree about what the scope
    /// holds and the window reports the wrong kind of emptiness.
    @Test func batchScopeNarrowsCountsAndFilterOptionsToThatBatch() async throws {
        let dbQueue = try DatabaseQueue()
        try CatalogStore.migrator.migrate(dbQueue)
        try await dbQueue.write { db in
            try insertScopeRoot(id: 1, path: "/Library", db: db)
            try insertScopeAsset(rootID: 1, path: "clip.mp4", kind: "video", format: "MP4", batchMs: 100, db: db)
            try insertScopeAsset(rootID: 1, path: "old.heic", kind: "image", format: "HEIC", batchMs: 50, db: db)
            try insertScopeAsset(rootID: 1, path: "scanned.jpg", kind: "image", format: "JPEG", batchMs: nil, db: db)
        }
        let batchScope = CatalogScopePredicate(rootIDs: [1], importBatchUnixMs: 100)

        let wholeRootCount = try await dbQueue.read { db in
            try CatalogQueryGateway.countAssets(scope: CatalogScopePredicate(rootIDs: [1]), db: db)
        }
        let batchCount = try await dbQueue.read { db in
            try CatalogQueryGateway.countAssets(scope: batchScope, db: db)
        }
        let batchOptions = try await dbQueue.read { db in
            try CatalogQueryGateway.filterOptions(scope: batchScope, db: db)
        }

        #expect(wholeRootCount == 3)
        #expect(batchCount == 1)
        #expect(batchOptions.availableKinds == [.video])
        #expect(batchOptions.formatsByKind[.video] == [MediaFormatToken(rawValue: "MP4")])
        #expect(batchOptions.formatsByKind[.image] == nil)
    }

    /// The ordering query keeps the root-local index and `=` predicate for a
    /// single-root scope; the batch dimension is an added clause, not a replacement.
    @Test func singleRootBatchScopeKeepsRootLocalIndexAndAddsBatchClause() throws {
        let query = try #require(CatalogQueryGateway.orderedAssetIDQuery(
            descriptor: .default,
            scope: CatalogScopePredicate(rootIDs: [7], importBatchUnixMs: 100)
        ))

        #expect(query.sql.contains("library_root_id = ?"))
        #expect(query.sql.contains("AND import_batch_unix_ms = ?"))
        #expect(query.sql.contains("INDEXED BY idx_media_asset_best_capture_root_"))
    }

    @Test func fetchStoredAssetsReturnsEmptyForEmptyIDs() async throws {
        let dbQueue = try DatabaseQueue()
        try CatalogStore.migrator.migrate(dbQueue)
        let assets = try await dbQueue.read { db in
            try CatalogQueryGateway.fetchStoredAssets(ids: [], rootIDsByPath: [:], db: db)
        }
        #expect(assets.isEmpty)
    }

    @Test func fetchStoredTileDetailsReturnsEmptyForEmptyIDs() async throws {
        let dbQueue = try DatabaseQueue()
        try CatalogStore.migrator.migrate(dbQueue)
        let details = try await dbQueue.read { db in
            try CatalogQueryGateway.fetchStoredTileDetails(ids: [], rootIDsByPath: [:], db: db)
        }
        #expect(details.isEmpty)
    }

    @Test func metadataExtraReturnsNilWhenRowMissing() async throws {
        let dbQueue = try DatabaseQueue()
        try CatalogStore.migrator.migrate(dbQueue)
        let metadata = try await dbQueue.read { db in
            try CatalogQueryGateway.metadataExtra(
                libraryRootID: 1,
                relativePath: MediaRelativePath(rawValue: "missing.jpg"),
                db: db
            )
        }
        #expect(metadata == nil)
    }
}

private func insertScopeRoot(id: Int64, path: String, db: Database) throws {
    try db.execute(
        sql: "INSERT INTO library_root (id, path, kind) VALUES (?, ?, 'library')",
        arguments: [id, path]
    )
}

private func insertScopeAsset(
    rootID: Int64,
    path: String,
    kind: String,
    format: String,
    batchMs: Int64?,
    db: Database
) throws {
    try db.execute(
        sql: """
        INSERT INTO media_asset (
            library_root_id, relative_path, sort_key, name_sort_key, name,
            kind, format, import_batch_unix_ms
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
        arguments: [rootID, path, path, path, path, kind, format, batchMs]
    )
}
