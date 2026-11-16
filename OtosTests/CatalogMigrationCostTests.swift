import Foundation
import GRDB
@testable import OtosKit
import SQLite3
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
    /// schema before it: v72's derived folder tables dropped and its record removed.
    static let newest = CatalogSchema.derivedFolderMigrationIdentifier

    static func schemaBeforeNewest() throws -> [String] {
        [
            "DROP TABLE derived_folder",
            "DROP TABLE derived_rename",
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
            // One photo in a hundred Liked, as a choices filter finds them.
            try db.execute(sql: "UPDATE media_asset SET media_choice = 'liked' WHERE byte_size % 100 = 0")
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.inTransaction {
                for statement in try Self.schemaBeforeNewest() {
                    try db.execute(sql: statement)
                }
                return .commit
            }
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.checkpoint(.truncate)
        }
        try queue.close()
        let readsBefore = try WindowReadPages.measure(path: path)
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
        // The open's compaction, which the rebuild's free pages make owed.
        let compaction = try CatalogStore.compactIfOwed(pool, fileURL: URL(filePath: path)) {}
        try pool.close()
        #expect(run.applied == 1)
        let readsAfter = try WindowReadPages.measure(path: path)
        let variants = try WindowReadPages.indexVariants(path: path)
        // The layout v71 does not take, measured on the same rows: the table without a row id.
        try WindowReadPages.rebuildWithoutRowID(path: path)
        let readsWithoutRowID = try WindowReadPages.measure(path: path)
        let line = """
        op=migrationCost id=\(Self.newest) ms=\(DiagnosticsTiming.milliseconds(elapsed)) \
        walBytes=\(walBytes) fileBytesBefore=\(bytesBefore) fileBytesAfter=\(bytesAfter)
        op=compaction outcome=\(compaction)

        """ + WindowReadPages.report(before: readsBefore, after: readsAfter, withoutRowID: readsWithoutRowID)
            + "\n" + variants.joined(separator: "\n")
        let url = SourceTree.root.appending(path: "build/migration-cost/owner.txt")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(line.utf8).write(to: url)
    }

    private static func size(_ path: String) throws -> Int64 {
        try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64 ?? 0
    }
}

/// The pages each read that tests rows outside a covering index reads, and the rows it
/// returns, on one cold connection (no memory map, a cache that holds every page it reads:
/// each page is read from the file once), and what `media_asset`'s trees and the gray table
/// take (`dbstat`). A measurement of one catalog before and after the newest migration.
enum WindowReadPages {
    struct Read: Sendable {
        let name: String
        let pages: Int64
        let rows: Int
        let milliseconds: Int
    }

    struct Tree: Sendable {
        let name: String
        let pages: Int
        let bytes: Int
        let rows: Int
    }

    struct Measure: Sendable {
        let reads: [Read]
        let trees: [Tree]
    }

    /// One read's pages, rows and time on a fresh cold connection. A read the schema cannot
    /// prepare — one over a column or index the other schema lacks — is reported as not measured.
    static func read(_ name: String, path: String, _ query: (Database) throws -> SQLQuery?) throws -> Read? {
        var configuration = Configuration()
        configuration.readonly = true
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA mmap_size = 0")
            try db.execute(sql: "PRAGMA cache_size = -4000000")
        }
        let queue = try DatabaseQueue(path: path, configuration: configuration)
        defer { try? queue.close() }
        return try queue.read { db -> Read? in
            guard let query = try query(db) else { return nil }
            let rows: Int
            let start = ContinuousClock.now
            do {
                rows = try Row.fetchAll(db, sql: query.sql, arguments: query.arguments).count
            } catch {
                return Read(name: name, pages: -1, rows: -1, milliseconds: -1)
            }
            let milliseconds = DiagnosticsTiming.milliseconds(since: start)
            var current: Int32 = 0
            var highest: Int32 = 0
            sqlite3_db_status(db.sqliteConnection, SQLITE_DBSTATUS_CACHE_MISS, &current, &highest, 0)
            return Read(name: name, pages: Int64(current), rows: rows, milliseconds: milliseconds)
        }
    }

    /// Whether each index v71 makes is the cheaper form over the narrow table: the reads it
    /// serves, measured as v71 makes it and again in the other form — plain (its leading
    /// columns alone) for one v71 keeps covering, covering (v70's definition) for On This Day's,
    /// which v71 makes plain — or,
    /// for the product stamps, with the walks taking the date order instead. Each variant is
    /// put back before the next.
    static func indexVariants(path: String) throws -> [String] {
        let roots: [Int64] = [6, 7, 15]
        let rootArguments = StatementArguments(roots)
        let day = CalendarDay(year: 2026, month: 11, day: 16)
        let onThisDay = CatalogScopePredicate(rootIDs: roots, date: .anniversary(day))
        let batch = CatalogScopePredicate(rootIDs: roots, importBatchUnixMs: 1_600_000_000_000)
        let dateIndex = "idx_media_asset_best_capture_global_desc"
        func swapped(_ sql: String) -> String {
            sql.replacingOccurrences(of: "INDEXED BY \(ProductStampSQL.indexName)", with: "INDEXED BY \(dateIndex)")
        }
        struct Variant {
            let index: String
            /// The other form's columns, or nil for the product stamps' walks.
            let other: String?
            let reads: [VariantRead]
        }
        let walks: [(String, String)] = [
            ("searchEmbeddingOwed", "SELECT a.relative_path \(SearchEmbeddingStorage.owedFrom(rootCount: roots.count))"),
            ("searchTextOwed", "SELECT a.relative_path \(SearchTextStorage.owedFrom(rootCount: roots.count))"),
            ("searchEmbeddingReconcile", SearchEmbeddingStorage.currentEmbeddingIDsSQL(rootCount: roots.count)),
        ]
        let variants = [
            Variant(index: ProductStampSQL.indexName, other: nil, reads: walks.flatMap { name, sql in
                [
                    VariantRead(name: name) { _ in SQLQuery(sql: sql, arguments: rootArguments) },
                    VariantRead(name: name) { _ in SQLQuery(sql: swapped(sql), arguments: rootArguments) },
                ]
            }),
            Variant(
                index: "idx_media_asset_stack_candidate",
                other: "(library_root_id, best_kind, parent_path, best_format, relative_path)",
                reads: [
                    VariantRead(name: "stackCandidates") { _ in PhotoStackSQL.candidateQuery(rootIDs: roots) },
                    VariantRead(name: "filterOptions") { db in
                        try CatalogQueryGateway.distinctFilterableTypesQuery(scope: CatalogScopePredicate(rootIDs: roots), db: db)
                    },
                ]
            ),
            Variant(
                index: AnniversaryMatch.indexName,
                other: """
                (capture_day, capture_month, best_capture_local DESC, library_root_id, relative_path, \
                pending_trash_batch_unix_ms, awaiting_presence, hidden_by_source, best_kind, content_identifier, \
                shown_copy_root_id, has_copies)
                """,
                reads: [VariantRead(name: "onThisDay") { db in
                    try CatalogQueryGateway.orderedAssetIDQuery(descriptor: .default, scope: onThisDay, db: db)
                }]
            ),
            Variant(
                index: "idx_media_asset_import_batch",
                other: "(import_batch_unix_ms, library_root_id, relative_path) WHERE import_batch_unix_ms IS NOT NULL",
                reads: [VariantRead(name: "importBatch") { db in
                    try CatalogQueryGateway.orderedAssetIDQuery(descriptor: .default, scope: batch, db: db)
                }]
            ),
        ]
        var lines: [String] = []
        for variant in variants {
            if let other = variant.other {
                let kept = try reads(variant.reads, path: path)
                let queue = try DatabaseQueue(path: path)
                let original = try queue.read { db in
                    try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE name = ?", arguments: [variant.index]) ?? ""
                }
                try queue.write { db in
                    try db.execute(sql: "DROP INDEX \(variant.index)")
                    try db.execute(sql: "CREATE INDEX \(variant.index) ON media_asset\(other)")
                }
                try queue.close()
                let otherReads = try reads(variant.reads, path: path)
                let restore = try DatabaseQueue(path: path)
                try restore.write { db in
                    try db.execute(sql: "DROP INDEX \(variant.index)")
                    try db.execute(sql: original)
                }
                try restore.close()
                for (with, without) in zip(kept, otherReads) {
                    lines.append(
                        "op=indexVariant index=\(variant.index) read=\(with.name) pagesV71=\(with.pages) "
                            + "pagesOther=\(without.pages) msV71=\(with.milliseconds) msOther=\(without.milliseconds) "
                            + "rows=\(with.rows)"
                    )
                }
            } else {
                let measured = try reads(variant.reads, path: path)
                for pair in stride(from: 0, to: measured.count - 1, by: 2) {
                    let with = measured[pair], without = measured[pair + 1]
                    lines.append(
                        "op=indexVariant index=\(variant.index) read=\(with.name) pagesWithIndex=\(with.pages) "
                            + "pagesDateOrder=\(without.pages) msWithIndex=\(with.milliseconds) "
                            + "msDateOrder=\(without.milliseconds) rows=\(with.rows)"
                    )
                }
            }
        }
        return lines
    }

    /// One read a variant measures.
    struct VariantRead {
        let name: String
        let query: (Database) throws -> SQLQuery?
    }

    private static func reads(_ list: [VariantRead], path: String) throws -> [Read] {
        try list.compactMap { try read($0.name, path: path, $0.query) }
    }

    static func measure(path: String) throws -> Measure {
        let roots: [Int64] = [6, 7, 15]
        let scope = CatalogScopePredicate(rootIDs: roots)
        let liked = CatalogQueryDescriptor(scope: .allMedia, filter: MediaFilter(choices: [.liked]))
        let byName = CatalogQueryDescriptor(scope: .allMedia, sort: MediaSortOrder(field: .name, direction: .ascending))
        var reads: [Read] = []
        func read(_ name: String, _ query: (Database) throws -> SQLQuery?) throws {
            if let measured = try Self.read(name, path: path, query) {
                reads.append(measured)
            }
        }
        try read("defaultOrder") { db in
            try CatalogQueryGateway.orderedAssetIDQuery(descriptor: .default, scope: scope, db: db)
        }
        try read("nameOrder") { db in
            try CatalogQueryGateway.orderedAssetIDQuery(descriptor: byName, scope: scope, db: db)
        }
        try read("likedFilter") { db in
            try CatalogQueryGateway.orderedAssetIDQuery(descriptor: liked, scope: scope, db: db)
        }
        try read("filterOptions") { db in
            try CatalogQueryGateway.distinctFilterableTypesQuery(scope: scope, db: db)
        }
        try read("peopleFaceAssetJoin") { _ in
            SQLQuery(sql: """
            SELECT f.library_root_id, f.relative_path, f.face_index, m.best_capture_local, m.has_copies
            FROM face f
            JOIN media_asset m ON m.library_root_id = f.library_root_id AND m.relative_path = f.relative_path
            WHERE m.trash_path IS NULL AND f.is_not_face = 0 AND NOT \(LivePhotoSQL.isPairedMotion("m"))
            ORDER BY f.library_root_id, f.relative_path, f.face_index
            """, arguments: [])
        }
        try read("stackCandidates") { _ in
            PhotoStackSQL.candidateQuery(rootIDs: roots)
        }
        try read("searchEmbeddingReconcile") { _ in
            SQLQuery(sql: SearchEmbeddingStorage.currentEmbeddingIDsSQL(rootCount: roots.count), arguments: StatementArguments(roots))
        }
        try read("searchEmbeddingOwed") { _ in
            SQLQuery(sql: "SELECT a.relative_path \(SearchEmbeddingStorage.owedFrom(rootCount: roots.count))", arguments: StatementArguments(roots))
        }
        try read("searchTextOwed") { _ in
            SQLQuery(sql: "SELECT a.relative_path \(SearchTextStorage.owedFrom(rootCount: roots.count))", arguments: StatementArguments(roots))
        }
        try read("renderSignatureOwed") { _ in
            SQLQuery(sql: RenderSignatureSQL.candidatesSQL, arguments: [7, "", 100_000])
        }
        try read("samePhotoCandidates") { _ in
            SQLQuery(sql: SamePhotoSQL.candidatesSQL(rootCount: roots.count), arguments: StatementArguments(roots))
        }
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: path, configuration: configuration)
        defer { try? queue.close() }
        let trees = try queue.read { db in
            try Row.fetchAll(db, sql: """
            SELECT s.name, count(*) AS pages, sum(s.payload) AS bytes, sum(s.ncell) AS cells
            FROM dbstat AS s JOIN sqlite_master AS m ON m.name = s.name
            WHERE m.tbl_name IN ('media_asset', 'render_signature') AND s.pagetype = 'leaf'
            GROUP BY s.name ORDER BY count(*) DESC
            """).map { Tree(name: $0[0], pages: $0[1], bytes: $0[2], rows: $0[3]) }
        }
        return Measure(reads: reads, trees: trees)
    }

    /// `media_asset` made again without a row id, its indexes as they are: the layout v71
    /// compares itself with. Its triggers name the row id and are left out; only reads run.
    static func rebuildWithoutRowID(path: String) throws {
        let queue = try DatabaseQueue(path: path)
        defer { try? queue.close() }
        try queue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.inTransaction {
                let indexes = try String.fetchAll(db, sql: """
                SELECT sql FROM sqlite_master WHERE type = 'index' AND tbl_name = 'media_asset' AND sql IS NOT NULL
                """)
                let table = CatalogSchema.hotAssetTable.replacingOccurrences(
                    of: "PRIMARY KEY (library_root_id, relative_path)\n)", with: "PRIMARY KEY (library_root_id, relative_path)\n) WITHOUT ROWID"
                )
                precondition(table.contains("WITHOUT ROWID"))
                try db.execute(sql: table)
                try db.execute(sql: """
                INSERT INTO media_asset_hot (\(CatalogSchema.hotAssetCopiedColumns), render_dhash, render_signature_read)
                SELECT \(CatalogSchema.hotAssetCopiedColumns), render_dhash, render_signature_read FROM media_asset
                ORDER BY library_root_id, relative_path
                """)
                try db.execute(sql: "DROP TABLE media_asset")
                try db.execute(sql: "ALTER TABLE media_asset_hot RENAME TO media_asset")
                for index in indexes {
                    try db.execute(sql: index)
                }
                return .commit
            }
            try db.checkpoint(.truncate)
        }
    }

    static func report(before: Measure, after: Measure, withoutRowID: Measure) -> String {
        var lines: [String] = []
        for read in after.reads {
            let old = before.reads.first { $0.name == read.name }
            let other = withoutRowID.reads.first { $0.name == read.name }
            lines.append(
                "op=windowReadPages read=\(read.name) pagesBefore=\(old?.pages ?? -1) pagesAfter=\(read.pages) "
                    + "pagesWithoutRowID=\(other?.pages ?? -1) rowsBefore=\(old?.rows ?? -1) rowsAfter=\(read.rows) "
                    + "msBefore=\(old?.milliseconds ?? -1) msAfter=\(read.milliseconds) msWithoutRowID=\(other?.milliseconds ?? -1)"
            )
        }
        for (label, measure) in [("before", before), ("after", after), ("withoutRowID", withoutRowID)] {
            for tree in measure.trees {
                lines.append("op=tree when=\(label) name=\(tree.name) leafPages=\(tree.pages) payloadBytes=\(tree.bytes) cells=\(tree.rows)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
