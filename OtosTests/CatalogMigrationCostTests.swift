import Foundation
import GRDB
@testable import OtosKit
import Testing

/// What the newest migration costs at launch on a catalog of the owner's shape (ADR 0002,
/// "Schema Migrations At Launch"): its milliseconds through the Store's own migration pass,
/// the write-ahead log it leaves, and the file's size before and after. A migration's PR
/// states these; the test writes them to `build/migration-cost/owner.txt`. At the owner's size
/// only on demand (`OTOS_SCALE_TEST=1 script/check.sh --only CatalogMigrationCostTests`), since
/// it writes a 2.3 GB file; it is a measurement, not a benchmark.
///
/// The generator writes its rows through the products' own current SQL, which names the
/// newest schema's indexes, so the catalog is generated whole and then put back to the schema
/// before the newest migration (`schemaBeforeNewest`), which the pass then applies.
@Suite(.testDirectory, .serialized)
struct CatalogMigrationCostTests {
    /// The newest migration, and the statements that put a catalog it migrated back to the
    /// schema before it: v65's new indexes dropped, the indexes it dropped or remade made as
    /// v64 left them, and its record removed.
    static let newest = CatalogSchema.owedWorkIndexesMigrationIdentifier

    static var schemaBeforeNewest: [String] {
        let claims: [(name: String, global: Bool, claim: EnrichmentClaim)] = [
            (EnrichmentClaimGateway.broadGlobalIndexName, true, .products),
            (EnrichmentClaimGateway.broadRootIndexName, false, .products),
            (EnrichmentClaimGateway.libraryGlobalIndexName, true, .library),
            (EnrichmentClaimGateway.libraryRootIndexName, false, .library),
        ]
        return [
            SearchEmbeddingStorage.sourceIndexName, SearchTextStorage.sourceIndexName, PhotoDescriptionStorage.sourceIndexName,
            ProductStampSQL.indexName, RenderSignatureSQL.owedIndexName, SourceProductsSQL.owedIndexName,
        ].map { "DROP INDEX \($0)" } + [
            "CREATE INDEX idx_media_asset_order_global ON media_asset(sort_key, library_root_id, relative_path)",
            "CREATE INDEX idx_media_asset_order_root ON media_asset(library_root_id, sort_key, relative_path)",
        ] + claims.flatMap { index in
            [
                "DROP INDEX \(index.name)",
                CatalogSchema.claimIndex(index.name, global: index.global, claim: index.claim, orderColumn: "best_capture_local"),
            ]
        } + [
            "DELETE FROM grdb_migrations WHERE identifier = '\(newest)'",
        ]
    }

    @Test(.enabled(if: StallReproductionTests.ownerSize))
    func theNewestMigrationCostsOnTheOwnersShape() throws {
        #expect(CatalogStore.knownMigrationIdentifiers.last == Self.newest)
        let directory = try makeTestDirectory()
        let catalog = try OwnerShapedCatalog.make(in: directory, scale: 1)
        let path = catalog.databaseURL.path(percentEncoded: false)
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            for statement in Self.schemaBeforeNewest {
                try db.execute(sql: statement)
            }
        }
        try queue.close()
        let bytesBefore = try Self.size(path)
        let pool = try DatabasePool(path: path)
        let start = ContinuousClock.now
        let run = try CatalogStore.applyPendingMigrations(pool) { _, _ in }
        let elapsed = start.duration(to: .now)
        let walBytes = try Self.size(path + "-wal")
        try pool.writeWithoutTransaction { db in
            try db.checkpoint(.truncate)
        }
        let bytesAfter = try Self.size(path)
        try pool.close()
        #expect(run.applied == 1)
        let line = """
        op=migrationCost id=\(Self.newest) ms=\(DiagnosticsTiming.milliseconds(elapsed)) \
        walBytes=\(walBytes) fileBytesBefore=\(bytesBefore) fileBytesAfter=\(bytesAfter)
        """
        let url = SourceTree.root.appending(path: "build/migration-cost/owner.txt")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(line.utf8).write(to: url)
    }

    private static func size(_ path: String) throws -> Int64 {
        try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64 ?? 0
    }
}
