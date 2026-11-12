import Foundation
import GRDB
@testable import OtosKit
import Testing

struct CatalogQueryGatewayTests {
    @Test func orderedAssetIDQueryReturnsNilForScopeSelectingNothing() throws {
        #expect(try CatalogQueryGateway.orderedAssetIDQuery(descriptor: .default, scope: .nothing) == nil)
    }

    /// Counting is a scope-scoped read exactly like ordering is: a batch stamp has to
    /// reach both, or they disagree about what the scope holds and the window reports
    /// the wrong kind of emptiness.
    @Test func batchScopeNarrowsCountsToThatBatch() async throws {
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

        #expect(wholeRootCount == 3)
        #expect(batchCount == 1)
    }

    @Test func choiceFilterQueryReturnsOnlySelectedChoices() async throws {
        let dbQueue = try DatabaseQueue()
        try CatalogStore.migrator.migrate(dbQueue)
        try await dbQueue.write { db in
            try insertScopeRoot(id: 1, path: "/Library", db: db)
            try insertScopeAsset(
                rootID: 1,
                path: "liked.jpg",
                kind: "image",
                format: "JPEG",
                batchMs: nil,
                choice: "liked",
                db: db
            )
            try insertScopeAsset(
                rootID: 1,
                path: "unrated.jpg",
                kind: "image",
                format: "JPEG",
                batchMs: nil,
                choice: "notRated",
                db: db
            )
            try insertScopeAsset(
                rootID: 1,
                path: "disliked.jpg",
                kind: "image",
                format: "JPEG",
                batchMs: nil,
                choice: "disliked",
                db: db
            )
        }
        let descriptor = CatalogQueryDescriptor(
            scope: .allMedia,
            filter: MediaFilter(choices: [.liked, .disliked]),
            sort: .filenameAscending
        )
        let query = try #require(try CatalogQueryGateway.orderedAssetIDQuery(
            descriptor: descriptor,
            scope: CatalogScopePredicate(rootIDs: [1])
        ))
        #expect(query.sql.contains("media_choice IN"))
        let paths = try await dbQueue.read { db in
            try CatalogQueryGateway.fetchOrderedAssetIDRows(
                descriptor: descriptor,
                scope: CatalogScopePredicate(rootIDs: [1]),
                db: db
            ).map(\.relativePath.rawValue)
        }
        #expect(paths == ["disliked.jpg", "liked.jpg"])
    }

    /// DES-069's day bucket comes from this column — the ordering query already reads
    /// it for `ORDER BY`; this checks it is also carried through to the fetched rows,
    /// nil included, rather than silently dropped.
    @Test func fetchOrderedAssetIDRowsCarriesCaptureLocalTimePerRow() async throws {
        let dbQueue = try DatabaseQueue()
        try CatalogStore.migrator.migrate(dbQueue)
        try await dbQueue.write { db in
            try insertScopeRoot(id: 1, path: "/Library", db: db)
            try insertScopeAsset(rootID: 1, path: "dated.jpg", kind: "image", format: "JPEG", batchMs: nil, db: db)
            try insertScopeAsset(rootID: 1, path: "undated.jpg", kind: "image", format: "JPEG", batchMs: nil, db: db)
            // best_capture_local is a GENERATED column over the stored wall clock (else the
            // absolute dates and their assumed offset) — write its source, not the column.
            try db.execute(
                sql: "UPDATE media_asset SET capture_wall_compact = ? WHERE relative_path = ?",
                arguments: [20_231_114_221_320, "dated.jpg"]
            )
        }
        let rows = try await dbQueue.read { db in
            try CatalogQueryGateway.fetchOrderedAssetIDRows(
                descriptor: CatalogQueryDescriptor(scope: .allMedia, sort: .dateNewest),
                scope: CatalogScopePredicate(rootIDs: [1]),
                db: db
            )
        }
        let byPath = Dictionary(uniqueKeysWithValues: rows.map { ($0.relativePath.rawValue, $0.captureLocalTime) })
        // 2023-11-14 22:13:20 read as UTC.
        #expect((byPath["dated.jpg"] ?? nil) == CaptureLocalTime(seconds: 1_700_000_000))
        #expect((byPath["undated.jpg"] ?? nil) == nil)
        #expect(byPath.keys.contains("undated.jpg"))
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
    choice: String = "notRated",
    db: Database
) throws {
    try db.execute(
        sql: """
        INSERT INTO media_asset (
            library_root_id, relative_path, sort_key, name_sort_key, name,
            kind, format, media_choice, import_batch_unix_ms
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        arguments: [rootID, path, path, path, path, kind, format, choice, batchMs]
    )
}
