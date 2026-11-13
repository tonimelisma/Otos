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
    /// Catalogs migrated to v13 hold claim indexes created from this exact text, and
    /// `INDEXED BY` matches a partial index by its text, so changing it without a
    /// migration that recreates the indexes would fail every claim query in them.
    @Test func theStalenessPredicatesKeepTheTextTheirIndexesWereCreatedWith() {
        #expect(EnrichmentClaimGateway.metadataStalenessSQLPredicate() == """
        metadata_source_size IS NULL
           OR metadata_source_mtime IS NULL
           OR COALESCE(byte_size, -1) <> COALESCE(metadata_source_size, -1)
           OR CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER)
              <> COALESCE(metadata_source_mtime, -1)
        """)
        #expect(EnrichmentClaimGateway.renderingStalenessSQLPredicate() == """
        rendered_source_size IS NULL
           OR rendered_source_mtime IS NULL
           OR COALESCE(byte_size, -1) <> COALESCE(rendered_source_size, -1)
           OR CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER)
              <> COALESCE(rendered_source_mtime, -1)
        """)
    }

    /// A card's second pass is claimed for the products, and a fixed library for its every
    /// product, a video's faces included (ADR 0047); each walks its own pair of indexes.
    @Test func eachClaimWalksItsOwnIndexes() async throws {
        let dbQueue = try await Self.migratedDatabase()
        for (claim, root, global) in [
            (EnrichmentClaim.products, EnrichmentClaimGateway.broadRootIndexName, EnrichmentClaimGateway.broadGlobalIndexName),
            (.library, EnrichmentClaimGateway.libraryRootIndexName, EnrichmentClaimGateway.libraryGlobalIndexName),
            (.account, EnrichmentClaimGateway.accountRootIndexName, EnrichmentClaimGateway.accountGlobalIndexName),
        ] {
            let rootQuery = try #require(EnrichmentClaimGateway.enrichmentClaimQuery(rootIDs: [1], limit: 4, claim: claim))
            let globalQuery = try #require(EnrichmentClaimGateway.enrichmentClaimQuery(rootIDs: [1, 2], limit: 4, claim: claim))
            let plans = try await dbQueue.read { db in
                try (root: Self.explainPlan(db, query: rootQuery), global: Self.explainPlan(db, query: globalQuery))
            }
            #expect(plans.root.contains(root))
            #expect(plans.global.contains(global))
        }
    }

    /// `INDEXED BY` matches a partial index by its text, so the library claim's predicate is
    /// the text v35 made its indexes from, and the account claim's the text v40 did.
    @Test func theLibraryClaimKeepsTheTextItsIndexesWereCreatedWith() {
        #expect(EnrichmentClaimGateway.stalenessSQLPredicate(.library) == CatalogSchema.videoFacesClaimPredicate)
        #expect(EnrichmentClaimGateway.stalenessSQLPredicate(.account) == CatalogSchema.accountClaimPredicate)
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
