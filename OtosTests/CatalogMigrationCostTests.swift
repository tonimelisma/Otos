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
@Suite(.testScope, .serialized)
struct CatalogMigrationCostTests {
    /// The newest migration, and the statements that put a catalog it migrated back to the
    /// schema before it: v69's name and size order indexes made as v68 left them, with their
    /// leading columns alone, and its record removed.
    static let newest = CatalogSchema.sortOrderTestedColumnsMigrationIdentifier

    static var schemaBeforeNewest: [String] {
        CatalogSchema.sortOrderIndexes.flatMap { index in
            [
                "DROP INDEX \(index.name)",
                "CREATE INDEX \(index.name) ON media_asset(\(index.columns))",
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
        try queue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.inTransaction {
                for statement in Self.schemaBeforeNewest {
                    try db.execute(sql: statement)
                }
                return .commit
            }
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.checkpoint(.truncate)
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
