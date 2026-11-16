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
    /// schema before it: v66's vector table folded back into a face table that carries the
    /// embedding, in the column order v65 left, its indexes made as v65 left them, and its
    /// record removed. They run with foreign keys off: dropping a referenced table cascades.
    static let newest = CatalogSchema.faceEmbeddingTableMigrationIdentifier

    static var schemaBeforeNewest: [String] {
        let columns = """
        library_root_id, relative_path, face_index, box_x, box_y, box_width, box_height, landmarks, quality,
        analysis_revision, embedding, person_id, is_not_face, assignment, likeness, is_key_photo, frame_index
        """
        return [
            """
            CREATE TABLE face_wide (
                library_root_id INTEGER NOT NULL,
                relative_path TEXT NOT NULL,
                face_index INTEGER NOT NULL,
                box_x REAL NOT NULL,
                box_y REAL NOT NULL,
                box_width REAL NOT NULL,
                box_height REAL NOT NULL,
                landmarks BLOB NOT NULL,
                quality REAL NOT NULL,
                analysis_revision INTEGER NOT NULL,
                embedding BLOB NOT NULL, person_id INTEGER REFERENCES person(id) ON DELETE SET NULL,
                is_not_face INTEGER NOT NULL DEFAULT 0, assignment INTEGER NOT NULL DEFAULT 0, likeness REAL,
                is_key_photo INTEGER NOT NULL DEFAULT 0, frame_index INTEGER,
                PRIMARY KEY (library_root_id, relative_path, face_index),
                FOREIGN KEY (library_root_id, relative_path)
                    REFERENCES media_asset(library_root_id, relative_path)
                    ON UPDATE CASCADE ON DELETE CASCADE
            )
            """,
            """
            INSERT INTO face_wide (\(columns))
            SELECT f.library_root_id, f.relative_path, f.face_index, f.box_x, f.box_y, f.box_width, f.box_height,
                   f.landmarks, f.quality, f.analysis_revision, e.embedding, f.person_id, f.is_not_face, f.assignment,
                   f.likeness, f.is_key_photo, f.frame_index
            FROM face AS f JOIN face_embedding AS e
              ON e.library_root_id = f.library_root_id AND e.relative_path = f.relative_path AND e.face_index = f.face_index
            ORDER BY f.library_root_id, f.relative_path, f.face_index
            """,
            "DROP TABLE face_embedding",
            "DELETE FROM sqlite_sequence WHERE name = 'face_embedding'",
            "DROP TABLE face",
            "ALTER TABLE face_wide RENAME TO face",
            "CREATE UNIQUE INDEX idx_face_key_photo ON face(person_id) WHERE is_key_photo = 1",
            """
            CREATE INDEX idx_face_person_photo
            ON face(person_id, library_root_id, relative_path, is_not_face) WHERE person_id IS NOT NULL
            """,
            """
            CREATE INDEX idx_face_assigned_photo
            ON face(library_root_id, relative_path) WHERE person_id IS NOT NULL AND is_not_face = 0
            """,
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
