import Foundation
import GRDB
@testable import Otos
import Testing

struct CatalogStoreQueryPlanTests {
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

        let plans = try await dbQueue.read { db in
            try QueryPlans(
                rootOrder: explainPlan(db, sql: rootOrderSQL, arguments: [rootID1]),
                globalOrder: explainPlan(db, sql: globalOrderSQL, arguments: [rootID1, rootID2]),
                rootEnrichment: explainPlan(db, sql: rootEnrichmentSQL, arguments: [rootID1, 4]),
                globalEnrichment: explainPlan(db, sql: globalEnrichmentSQL, arguments: [rootID1, rootID2, 4])
            )
        }

        #expect(plans.rootOrder.contains("idx_media_asset_order_root"))
        #expect(plans.globalOrder.contains("idx_media_asset_order_global"))
        #expect(plans.rootEnrichment.contains("idx_media_asset_needs_enrichment_root"))
        #expect(plans.globalEnrichment.contains("idx_media_asset_needs_enrichment_global"))
        #expect(!usesTemporarySort(plans.rootOrder))
        #expect(!usesTemporarySort(plans.globalOrder))
        #expect(!usesTemporarySort(plans.rootEnrichment))
        #expect(!usesTemporarySort(plans.globalEnrichment))
    }
}

private struct QueryPlans {
    let rootOrder: String
    let globalOrder: String
    let rootEnrichment: String
    let globalEnrichment: String
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
                    name,
                    content_type_identifier,
                    byte_size,
                    content_modified_at_unix
                )
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [rootID, relativePath, sortKey, relativePath, "public.jpeg", 1, 1000]
            )
        }
        return (rootID1, rootID2)
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

private func usesTemporarySort(_ plan: String) -> Bool {
    plan.localizedCaseInsensitiveContains("TEMP B-TREE")
}

private let rootOrderSQL = """
SELECT library_root_id, relative_path
FROM media_asset INDEXED BY idx_media_asset_order_root
WHERE library_root_id = ?
ORDER BY sort_key, relative_path
"""

private let globalOrderSQL = """
SELECT library_root_id, relative_path
FROM media_asset INDEXED BY idx_media_asset_order_global
WHERE library_root_id IN (?, ?)
ORDER BY sort_key, library_root_id, relative_path
"""

private let rootEnrichmentSQL = """
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
ORDER BY sort_key, relative_path
LIMIT ?
"""

private let globalEnrichmentSQL = """
SELECT library_root_id, relative_path
FROM media_asset INDEXED BY idx_media_asset_needs_enrichment_global
WHERE library_root_id IN (?, ?)
  AND (
    enriched_source_size IS NULL
    OR enriched_source_mtime IS NULL
    OR COALESCE(byte_size, -1) <> COALESCE(enriched_source_size, -1)
    OR CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER)
       <> COALESCE(enriched_source_mtime, -1)
  )
ORDER BY sort_key, library_root_id, relative_path
LIMIT ?
"""
