import Foundation
import GRDB
@testable import OtosKit
import Testing

@Suite(.testDirectory)
struct CatalogStoreQueryPlanTests {
    @Test func descriptorQueryFiltersAndSortsBySQLiteBestValues() async throws {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let dbQueue = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
        try CatalogStore.migrator.migrate(dbQueue)
        let rootID = try await insertDescriptorFixture(dbQueue)
        let descriptor = CatalogQueryDescriptor(
            scope: .allMedia,
            filter: MediaFilter(
                kinds: [.image],
                fileTypes: [FilterFileType(kind: .raw, format: MediaFormatToken(rawValue: "DNG"))]
            ),
            sort: MediaSortOrder(field: .name, direction: .ascending)
        )

        let ids = try await dbQueue.read { db in
            try CatalogQueryGateway.fetchOrderedAssetIDRows(
                descriptor: descriptor,
                scope: CatalogScopePredicate(rootIDs: [rootID]),
                db: db
            )
        }

        #expect(ids.map(\.relativePath.rawValue) == ["alpha.jpg", "raw-original.nef", "retagged.mov"])

        // A file type matches only under the kind it was chosen in.
        let wrongKind = try await dbQueue.read { db in
            try CatalogQueryGateway.fetchOrderedAssetIDRows(
                descriptor: CatalogQueryDescriptor(
                    scope: .allMedia,
                    filter: MediaFilter(fileTypes: [FilterFileType(kind: .image, format: MediaFormatToken(rawValue: "DNG"))])
                ),
                scope: CatalogScopePredicate(rootIDs: [rootID]),
                db: db
            )
        }
        #expect(wrongKind.isEmpty)
    }

    @Test func querySchemaStreamsCatalogOrderAndEnrichmentCandidatesFromIndexes() async throws {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let dbQueue = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
        try CatalogStore.migrator.migrate(dbQueue)
        let (rootID1, rootID2) = try await insertPlanFixture(dbQueue)
        let rootOrderQuery = try #require(try CatalogQueryGateway.orderedAssetIDQuery(
            descriptor: .default,
            scope: CatalogScopePredicate(rootIDs: [rootID1])
        ))
        let globalOrderQuery = try #require(try CatalogQueryGateway.orderedAssetIDQuery(
            descriptor: .default,
            scope: CatalogScopePredicate(rootIDs: [rootID1, rootID2])
        ))
        let rootEnrichmentQuery = try #require(EnrichmentClaimGateway.enrichmentClaimQuery(
            rootIDs: [rootID1],
            limit: 4,
            claim: .products
        ))
        let globalEnrichmentQuery = try #require(EnrichmentClaimGateway.enrichmentClaimQuery(
            rootIDs: [rootID1, rootID2],
            limit: 4,
            claim: .products
        ))

        let plans = try await dbQueue.read { db in
            try QueryPlans(
                rootOrder: explainPlan(db, query: rootOrderQuery),
                globalOrder: explainPlan(db, query: globalOrderQuery),
                rootEnrichment: explainPlan(db, query: rootEnrichmentQuery),
                globalEnrichment: explainPlan(db, query: globalEnrichmentQuery)
            )
        }

        #expect(plans.rootOrder.contains("idx_media_asset_best_capture_root_desc"))
        #expect(plans.globalOrder.contains("idx_media_asset_best_capture_global_desc"))
        #expect(plans.rootEnrichment.contains("idx_media_asset_needs_enrichment_root"))
        #expect(plans.globalEnrichment.contains("idx_media_asset_needs_enrichment_global"))
        #expect(!usesTemporarySort(plans.rootOrder))
        #expect(!usesTemporarySort(plans.globalOrder))
        #expect(!usesTemporarySort(plans.rootEnrichment))
        #expect(!usesTemporarySort(plans.globalEnrichment))
    }

    /// The Places scopes join `asset_metadata` for the coordinate (ADR 0040). The order
    /// must still come from the capture index — a walk, never a temporary sort — and the
    /// join must be a primary-key lookup per row, which is what makes the deferred
    /// partial index on `primary_latitude` unnecessary (measured 2026-10-31,
    /// `docs/research/2026-10-31-map-views-in-photo-managers.md`).
    @Test func locatedOrderQueryKeepsTheCaptureIndexAndLooksUpMetadataByKey() async throws {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let dbQueue = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
        try CatalogStore.migrator.migrate(dbQueue)
        let (rootID1, rootID2) = try await insertPlanFixture(dbQueue)
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO asset_metadata (library_root_id, relative_path, primary_latitude, primary_longitude)
                VALUES (?, ?, ?, ?)
                """,
                arguments: [rootID1, "a.jpg", 60.17, 24.94]
            )
        }
        let rootLocated = try #require(try CatalogQueryGateway.orderedAssetIDQuery(
            descriptor: .default,
            scope: CatalogScopePredicate(rootIDs: [rootID1], location: .located)
        ))
        let globalLocated = try #require(try CatalogQueryGateway.orderedAssetIDQuery(
            descriptor: .default,
            scope: CatalogScopePredicate(rootIDs: [rootID1, rootID2], location: .located)
        ))
        let onePlace = try #require(try CatalogQueryGateway.orderedAssetIDQuery(
            descriptor: .default,
            scope: CatalogScopePredicate(
                rootIDs: [rootID1, rootID2],
                location: .within(MapArea(south: 60, north: 61, west: 24, east: 25))
            )
        ))

        let (rootPlan, globalPlan, placePlan, rows) = try await dbQueue.read { db in
            try (
                explainPlan(db, query: rootLocated),
                explainPlan(db, query: globalLocated),
                explainPlan(db, query: onePlace),
                CatalogQueryGateway.fetchOrderedAssetIDRows(
                    descriptor: .default,
                    scope: CatalogScopePredicate(rootIDs: [rootID1, rootID2], location: .located),
                    db: db
                )
            )
        }

        for plan in [rootPlan, globalPlan, placePlan] {
            #expect(plan.contains("idx_media_asset_best_capture_"))
            #expect(plan.contains("SEARCH asset_metadata USING INDEX sqlite_autoindex_asset_metadata_1"))
            #expect(!usesTemporarySort(plan))
        }
        #expect(rootPlan.contains("idx_media_asset_best_capture_root_desc"))
        #expect(globalPlan.contains("idx_media_asset_best_capture_global_desc"))
        #expect(rows.map(\.relativePath.rawValue) == ["a.jpg"])
        #expect(rows.first?.coordinate == PlaceCoordinate(latitude: 60.17, longitude: 24.94))
    }

    @Test func enrichmentClaimUpdateReturningClaimsRows() async throws {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let dbQueue = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
        try CatalogStore.migrator.migrate(dbQueue)
        let rootID = try await insertEnrichmentClaimFixture(dbQueue, assetCount: 3, claimedCount: 0)

        let claimed = try await dbQueue.write { db in
            try EnrichmentClaimGateway.fetchStoredAssetsNeedingEnrichment(
                rootIDs: [rootID],
                limit: 2,
                claim: .products,
                db: db
            )
        }
        #expect(claimed.count == 2)

        let stillClaimed = try await dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM media_asset
                WHERE library_root_id = ?
                  AND enrichment_claimed IS NOT NULL
                """,
                arguments: [rootID]
            ) ?? 0
        }
        #expect(stillClaimed == 2)
    }

    /// ARC-037: `.removableVolume` roots claim with the metadata-only predicate and
    /// index. Assert the index choice on EXPLAIN QUERY PLAN — a correctness-only
    /// assertion would not catch a narrow query silently planning against the broad
    /// index.
    /// ADR 0052: the stack candidates' read seeks the RAW folders and each folder's stills
    /// through the candidate index. Without it each folder scanned its whole root, and on the
    /// owner's 10,917 RAW folders the window's first publication took minutes.
    @Test func stackCandidatesSeekTheirFoldersThroughTheCandidateIndex() async throws {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let dbQueue = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
        try CatalogStore.migrator.migrate(dbQueue)
        let (rootID1, rootID2) = try await insertPlanFixture(dbQueue)
        let query = try #require(PhotoStackSQL.candidateQuery(rootIDs: [rootID1, rootID2]))
        let plan = try await dbQueue.read { db in try explainPlan(db, query: query) }
        #expect(plan.contains("SEARCH still USING INDEX idx_media_asset_stack_candidate"))
        // The burst stills are found through their own partial index, never a scan.
        #expect(plan.contains("idx_media_asset_burst"))
        #expect(!plan.contains("SCAN still"))
    }

    @Test func metadataOnlyClaimQueriesUseMetadataOnlyIndexes() async throws {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let dbQueue = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
        try CatalogStore.migrator.migrate(dbQueue)
        let (rootID1, rootID2) = try await insertPlanFixture(dbQueue)
        let rootMetadataOnlyQuery = try #require(EnrichmentClaimGateway.enrichmentClaimQuery(
            rootIDs: [rootID1],
            limit: 4,
            claim: .metadata
        ))
        let globalMetadataOnlyQuery = try #require(EnrichmentClaimGateway.enrichmentClaimQuery(
            rootIDs: [rootID1, rootID2],
            limit: 4,
            claim: .metadata
        ))

        let plans = try await dbQueue.read { db in
            let root = try explainPlan(db, query: rootMetadataOnlyQuery)
            let global = try explainPlan(db, query: globalMetadataOnlyQuery)
            return (root: root, global: global)
        }
        #expect(plans.root.contains(EnrichmentClaimGateway.metadataOnlyRootIndexName))
        #expect(plans.global.contains(EnrichmentClaimGateway.metadataOnlyGlobalIndexName))
    }

    /// Regression guard: a metadata-current asset with no digest is claimed by
    /// the metadata-only claim (a `.removableVolume` root) never, and by the broad claim
    /// (a library root) still — the wiring that must hold or removable enrichment spins
    /// forever.
    @Test func metadataCurrentNoHashIsClaimedOnlyWhenHashRequired() async throws {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let dbQueue = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
        try CatalogStore.migrator.migrate(dbQueue)
        let rootID = try await dbQueue.write { db in
            try db.execute(sql: "INSERT INTO library_root (path) VALUES (?)", arguments: ["/tmp/otos-nohash"])
            let rootID = db.lastInsertedRowID
            try db.execute(
                sql: """
                INSERT INTO media_asset (
                    library_root_id, relative_path, sort_key, name_sort_key, name,
                    content_type_identifier, byte_size, content_modified_at_unix,
                    metadata_source_size, metadata_source_mtime
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [rootID, "a.jpg", "a.jpg", "a.jpg", "a.jpg", "public.jpeg", 1, 1000, 1, 1000]
            )
            return rootID
        }

        let metadataOnlyClaimed = try await dbQueue.write { db in
            try EnrichmentClaimGateway.fetchStoredAssetsNeedingEnrichment(
                rootIDs: [rootID],
                limit: 4,
                claim: .metadata,
                db: db
            )
        }
        #expect(metadataOnlyClaimed.isEmpty)

        let broadClaimed = try await dbQueue.write { db in
            try EnrichmentClaimGateway.fetchStoredAssetsNeedingEnrichment(
                rootIDs: [rootID],
                limit: 4,
                claim: .products,
                db: db
            )
        }
        #expect(broadClaimed.map(\.relativePath.rawValue) == ["a.jpg"])
    }
}

private struct QueryPlans {
    let rootOrder: String
    let globalOrder: String
    let rootEnrichment: String
    let globalEnrichment: String
}

private func insertDescriptorFixture(_ dbQueue: DatabaseQueue) async throws -> Int64 {
    try await dbQueue.write { db in
        try db.execute(sql: "INSERT INTO library_root (path) VALUES (?)", arguments: ["/tmp/otos-descriptor"])
        let rootID = db.lastInsertedRowID
        for fixture in descriptorFixtures() {
            try insertDescriptorFixtureRow(fixture, rootID: rootID, db: db)
        }
        return rootID
    }
}

private func descriptorFixtures() -> [DescriptorFixture] {
    [
        DescriptorFixture(
            relativePath: "video.mov",
            nameSortKey: "video.mov",
            kind: "video",
            format: "MOV",
            enrichedKind: nil,
            enrichedFormat: nil,
            originalDate: 400,
            byteSize: 40
        ),
        DescriptorFixture(
            relativePath: "raw-original.nef",
            nameSortKey: "raw-original.nef",
            kind: "raw",
            format: "NEF",
            enrichedKind: nil,
            enrichedFormat: "DNG",
            originalDate: 300,
            byteSize: 30
        ),
        DescriptorFixture(
            relativePath: "alpha.jpg",
            nameSortKey: "alpha.jpg",
            kind: "image",
            format: "JPEG",
            enrichedKind: nil,
            enrichedFormat: nil,
            originalDate: 200,
            byteSize: 20
        ),
        DescriptorFixture(
            relativePath: "retagged.mov",
            nameSortKey: "retagged.mov",
            kind: "video",
            format: "MOV",
            enrichedKind: "image",
            enrichedFormat: "JPEG",
            originalDate: 100,
            byteSize: 10
        ),
    ]
}

private func insertDescriptorFixtureRow(_ fixture: DescriptorFixture, rootID: Int64, db: Database) throws {
    try db.execute(
        sql: """
        INSERT INTO media_asset (
            library_root_id,
            relative_path,
            sort_key,
            name_sort_key,
            name,
            content_type_identifier,
            kind,
            format,
            byte_size,
            content_modified_at_unix,
            capture_instant_unix,
            enriched_kind,
            enriched_format
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        arguments: [
            rootID,
            fixture.relativePath,
            fixture.relativePath,
            fixture.nameSortKey,
            fixture.relativePath,
            "public.item",
            fixture.kind,
            fixture.format,
            fixture.byteSize,
            10,
            fixture.originalDate,
            fixture.enrichedKind,
            fixture.enrichedFormat,
        ]
    )
}

private struct DescriptorFixture {
    let relativePath: String
    let nameSortKey: String
    let kind: String
    let format: String
    let enrichedKind: String?
    let enrichedFormat: String?
    let originalDate: Double
    let byteSize: Int
}

private func insertPlanFixture(_ dbQueue: DatabaseQueue) async throws -> (Int64, Int64) {
    try await dbQueue.write { db in
        try db.execute(sql: "INSERT INTO library_root (path) VALUES (?)", arguments: ["/tmp/otos-a"])
        let rootID1 = db.lastInsertedRowID
        try db.execute(sql: "INSERT INTO library_root (path) VALUES (?)", arguments: ["/tmp/otos-b"])
        let rootID2 = db.lastInsertedRowID
        for (rootID, relativePath, sortKey) in [
            (rootID1, "b.jpg", "b.jpg"),
            (rootID1, "a.jpg", "a.jpg"),
            (rootID2, "c.jpg", "c.jpg"),
        ] {
            try db.execute(
                sql: """
                INSERT INTO media_asset (
                    library_root_id,
                    relative_path,
                    sort_key,
                    name_sort_key,
                    name,
                    content_type_identifier,
                    byte_size,
                    content_modified_at_unix
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [rootID, relativePath, sortKey, sortKey, relativePath, "public.jpeg", 1, 1000]
            )
        }
        return (rootID1, rootID2)
    }
}

private func insertEnrichmentClaimFixture(
    _ dbQueue: DatabaseQueue,
    assetCount: Int,
    claimedCount: Int
) async throws -> Int64 {
    try await dbQueue.write { db in
        try db.execute(sql: "INSERT INTO library_root (path) VALUES (?)", arguments: ["/tmp/otos-claim"])
        let rootID = db.lastInsertedRowID
        for index in 0 ..< assetCount {
            let relativePath = String(format: "asset-%04d.jpg", index)
            let claimed: Int? = index < claimedCount ? 1 : nil
            try db.execute(
                sql: """
                INSERT INTO media_asset (
                    library_root_id,
                    relative_path,
                    sort_key,
                    name_sort_key,
                    name,
                    content_type_identifier,
                    byte_size,
                    content_modified_at_unix,
                    enrichment_claimed
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    rootID,
                    relativePath,
                    relativePath,
                    relativePath,
                    relativePath,
                    "public.jpeg",
                    1,
                    1000,
                    claimed,
                ]
            )
        }
        return rootID
    }
}

private func explainPlan(
    _ db: Database,
    sql: String,
    arguments: StatementArguments = StatementArguments()
) throws -> String {
    try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN \(sql)", arguments: arguments)
        .map { row in row["detail"] as String }
        .joined(separator: "\n")
}

private func explainPlan(_ db: Database, query: SQLQuery) throws -> String {
    try explainPlan(db, sql: query.sql, arguments: query.arguments)
}

private func usesTemporarySort(_ plan: String) -> Bool {
    plan.localizedCaseInsensitiveContains("TEMP B-TREE")
}
