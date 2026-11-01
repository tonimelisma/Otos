import Foundation
import GRDB
@testable import OtosKit
import Testing

/// Guards the frozen claim indexes: the v12/v13 migration bodies in
/// `CatalogStorePersistence.swift` inline literal, frozen `CREATE INDEX` SQL rather
/// than calling `EnrichmentClaimGateway.stalenessSQLPredicate` at migration time, so a
/// fresh install's stored index text can never silently diverge from an existing
/// catalog's just because the predicate builder was edited. These tests assert the
/// *current* predicate still implies the frozen index (the everyday case) and that a
/// logically-equivalent but re-parenthesized predicate fails to prepare against it (the
/// hazard this freeze exists to prevent from ever reaching a migration again).
@Suite(.testDirectory)
struct EnrichmentClaimIndexContractTests {
    @Test func broadIndexesImplyCurrentHashRequiredPredicate() async throws {
        let dbQueue = try await Self.migratedDatabase()
        let rootQuery = try #require(EnrichmentClaimGateway.enrichmentClaimQuery(
            rootIDs: [1],
            limit: 4,
            everyProduct: true
        ))
        let globalQuery = try #require(EnrichmentClaimGateway.enrichmentClaimQuery(
            rootIDs: [1, 2],
            limit: 4,
            everyProduct: true
        ))
        let plans = try await dbQueue.read { db in
            try (
                root: Self.explainPlan(db, query: rootQuery),
                global: Self.explainPlan(db, query: globalQuery)
            )
        }
        #expect(plans.root.contains(EnrichmentClaimGateway.broadRootIndexName))
        #expect(plans.global.contains(EnrichmentClaimGateway.broadGlobalIndexName))
    }

    @Test func metadataOnlyIndexesImplyCurrentMetadataOnlyPredicate() async throws {
        let dbQueue = try await Self.migratedDatabase()
        let rootQuery = try #require(EnrichmentClaimGateway.enrichmentClaimQuery(
            rootIDs: [1],
            limit: 4,
            everyProduct: false
        ))
        let globalQuery = try #require(EnrichmentClaimGateway.enrichmentClaimQuery(
            rootIDs: [1, 2],
            limit: 4,
            everyProduct: false
        ))
        let plans = try await dbQueue.read { db in
            try (
                root: Self.explainPlan(db, query: rootQuery),
                global: Self.explainPlan(db, query: globalQuery)
            )
        }
        #expect(plans.root.contains(EnrichmentClaimGateway.metadataOnlyRootIndexName))
        #expect(plans.global.contains(EnrichmentClaimGateway.metadataOnlyGlobalIndexName))
    }

    /// The negative twin. Without this, the frozen strings above look like redundant
    /// coverage of `CatalogStoreQueryPlanTests` and invite deletion. A predicate that is
    /// logically identical but re-parenthesized as `(A) OR (B)` instead of `A OR B` is
    /// rejected by SQLite's partial-index implication check at *prepare* time — confirmed
    /// against SQLite 3.54.0 directly with the production index text before writing this
    /// test (`docs/research/2026-08-03-post-increment-review-experiments.md` §1a). Run
    /// this against the pre-freeze code path (a builder that could re-parenthesize) and
    /// confirm the failure is real, not an artifact of this test's own construction.
    @Test func reparenthesizedPredicateFailsToPrepareAgainstFrozenBroadIndex() async throws {
        let dbQueue = try await Self.migratedDatabase()
        let reparenthesized = """
        (
            metadata_source_size IS NULL
               OR metadata_source_mtime IS NULL
               OR COALESCE(byte_size, -1) <> COALESCE(metadata_source_size, -1)
               OR CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER)
                  <> COALESCE(metadata_source_mtime, -1)
        )
           OR (
            content_hash_xxh3_128 IS NULL
               OR length(content_hash_xxh3_128) <> 16
               OR content_hash_source_size IS NULL
               OR content_hash_source_mtime IS NULL
               OR COALESCE(byte_size, -1) <> COALESCE(content_hash_source_size, -1)
               OR CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER)
                  <> COALESCE(content_hash_source_mtime, -1)
        )
        """
        let sql = """
        SELECT library_root_id, relative_path
        FROM media_asset INDEXED BY \(EnrichmentClaimGateway.broadRootIndexName)
        WHERE library_root_id = ?
          AND (\(reparenthesized))
          AND enrichment_claimed IS NULL
        ORDER BY best_capture_unix DESC, relative_path
        LIMIT ?
        """
        await #expect(throws: (any Error).self) {
            try await dbQueue.read { db in
                _ = try Row.fetchAll(db, sql: sql, arguments: [1, 4])
            }
        }
    }

    private static func migratedDatabase() async throws -> DatabaseQueue {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let dbQueue = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
        try CatalogStore.migrator.migrate(dbQueue)
        return dbQueue
    }

    private static func explainPlan(_ db: Database, query: SQLQuery) throws -> String {
        try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN \(query.sql)", arguments: query.arguments)
            .map { row in row["detail"] as String }
            .joined(separator: "\n")
    }
}
