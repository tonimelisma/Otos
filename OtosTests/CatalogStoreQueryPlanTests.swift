import Foundation
import GRDB
@testable import Otos
import Testing

struct CatalogStoreQueryPlanTests {
    @Test func descriptorQueryFiltersAndSortsBySQLiteBestValues() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
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
                formats: [MediaFormatToken(rawValue: "DNG")]
            ),
            sort: MediaSortOrder(field: .name, direction: .ascending)
        )

        let ids = try await dbQueue.read { db in
            try CatalogStore.fetchOrderedAssetIDRows(descriptor: descriptor, rootIDs: [rootID], db: db)
        }

        #expect(ids.map(\.1.rawValue) == ["alpha.jpg", "raw-original.nef", "retagged.mov"])
    }

    @Test func querySchemaStreamsCatalogOrderAndEnrichmentCandidatesFromIndexes() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let dbQueue = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
        try CatalogStore.migrator.migrate(dbQueue)
        let (rootID1, rootID2) = try await insertPlanFixture(dbQueue)
        let now = Date().timeIntervalSince1970
        let rootOrderQuery = try #require(CatalogStore.orderedAssetIDQuery(descriptor: .default, rootIDs: [rootID1]))
        let globalOrderQuery = try #require(CatalogStore.orderedAssetIDQuery(
            descriptor: .default,
            rootIDs: [rootID1, rootID2]
        ))
        let rootEnrichmentQuery = try #require(EnrichmentLeaseGateway.enrichmentClaimQuery(
            rootIDs: [rootID1],
            now: now,
            claimNotAfter: now + 300,
            limit: 4
        ))
        let globalEnrichmentQuery = try #require(EnrichmentLeaseGateway.enrichmentClaimQuery(
            rootIDs: [rootID1, rootID2],
            now: now,
            claimNotAfter: now + 300,
            limit: 4
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

    @Test func enrichmentClaimQueryUsesPartialIndexWithoutNotInExclusion() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let dbQueue = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
        try CatalogStore.migrator.migrate(dbQueue)
        let rootID = try await insertEnrichmentClaimFixture(dbQueue, assetCount: 200, claimedCount: 50)
        let now = Date().timeIntervalSince1970
        let claimQuery = try #require(EnrichmentLeaseGateway.enrichmentClaimQuery(
            rootIDs: [rootID],
            now: now,
            claimNotAfter: now + 300,
            limit: 4
        ))

        let legacyQuery = legacyNotInEnrichmentQuery(rootID: rootID, excludedCount: 50)
        let exclusionPlan = try await dbQueue.read { db in
            try explainPlan(
                db,
                sql: legacyQuery.sql,
                arguments: legacyQuery.arguments
            )
        }
        let claimPlan = try await dbQueue.read { db in
            try explainPlan(
                db,
                query: claimQuery
            )
        }

        #expect(legacyQuery.sql.localizedCaseInsensitiveContains("NOT IN"))
        #expect(!exclusionPlan.isEmpty)
        #expect(claimPlan.contains("idx_media_asset_needs_enrichment_root"))
        #expect(!claimQuery.sql.localizedCaseInsensitiveContains("NOT IN"))
    }

    @Test func enrichmentClaimUpdateReturningClaimsRows() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let dbQueue = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
        try CatalogStore.migrator.migrate(dbQueue)
        let rootID = try await insertEnrichmentClaimFixture(dbQueue, assetCount: 3, claimedCount: 0)
        let claimedUntil = Date().timeIntervalSince1970 + 300

        let claimed = try await dbQueue.write { db in
            try EnrichmentLeaseGateway.fetchStoredAssetsNeedingEnrichment(
                rootIDs: [rootID],
                claimNotAfter: claimedUntil,
                limit: 2,
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
                  AND enrichment_claimed_until IS NOT NULL
                """,
                arguments: [rootID]
            ) ?? 0
        }
        #expect(stillClaimed == 2)
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
            ts_original_unix,
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
        let claimedUntil = Date().timeIntervalSince1970 + 300
        for index in 0 ..< assetCount {
            let relativePath = String(format: "asset-%04d.jpg", index)
            let claimed: Double? = index < claimedCount ? claimedUntil : nil
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
                    enrichment_claimed_until
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

private func legacyExclusionArguments(rootID: Int64, excludedCount: Int) -> [any DatabaseValueConvertible] {
    (0 ..< excludedCount).flatMap { index -> [any DatabaseValueConvertible] in
        [rootID, String(format: "asset-%04d.jpg", index)]
    }
}

private func legacyNotInEnrichmentQuery(rootID: Int64, excludedCount: Int) -> CatalogStore.SQLQuery {
    let exclusionPlaceholders = Array(repeating: "(?, ?)", count: excludedCount).joined(separator: ", ")
    return CatalogStore.SQLQuery(
        sql: """
        SELECT library_root_id, relative_path
        FROM media_asset INDEXED BY idx_media_asset_needs_enrichment_root
        WHERE library_root_id = ?
          AND (
            enriched_source_size IS NULL
            OR enriched_source_mtime IS NULL
            OR COALESCE(byte_size, -1) <> COALESCE(enriched_source_size, -1)
            OR CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER)
               <> COALESCE(enriched_source_mtime, -1)
          )
          AND (library_root_id, relative_path) NOT IN (\(exclusionPlaceholders))
        ORDER BY sort_key, relative_path
        LIMIT ?
        """,
        arguments: legacyNotInEnrichmentArguments(rootID: rootID, excludedCount: excludedCount)
    )
}

private func legacyNotInEnrichmentArguments(rootID: Int64, excludedCount: Int) -> StatementArguments {
    var values: [any DatabaseValueConvertible] = [rootID]
    values.append(contentsOf: legacyExclusionArguments(rootID: rootID, excludedCount: excludedCount))
    values.append(4)
    return StatementArguments(values)
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

private func explainPlan(_ db: Database, query: CatalogStore.SQLQuery) throws -> String {
    try explainPlan(db, sql: query.sql, arguments: query.arguments)
}

private func usesTemporarySort(_ plan: String) -> Bool {
    plan.localizedCaseInsensitiveContains("TEMP B-TREE")
}
