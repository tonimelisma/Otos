import Foundation
import GRDB
@testable import OtosKit
import Testing

/// v71 rebuilds `media_asset` narrow and moves the render signature's gray out of
/// it (ADR 0002). A rebuild drops the table every overlay table refers to, so this
/// asserts what must survive it: every asset row with every column but the three removed,
/// every row of every table that refers to an asset, byte for byte, and the signatures that
/// were current for their thumbnail. It runs on a catalog made at v70 with the rows a
/// catalog holds: renamed and moved assets, trashed and pending-Trash rows, an account's
/// listed rows, copies, a row with nothing but its key, and every product the rows carry.
@Suite(.testScope)
struct HotAssetTableMigrationTests {
    private static let before = CatalogSchema.searchVectorFileMigrationIdentifier

    /// The removed columns, which no read after v71 names.
    private static let removedColumns: Set = ["sort_key", "render_gray", "render_signature_source"]

    @Test func theRebuildKeepsEveryAssetAndEveryRowThatRefersToOne() async throws {
        let queue = try DatabaseQueue()
        try CatalogStore.migrator.migrate(queue, upTo: Self.before)
        try await queue.write { db in
            try Self.writeV69Catalog(db)
        }
        let children = try await queue.read { db in try Self.tablesReferringToAssets(db) }
        // Every table that refers to an asset holds rows here, so a table added later is
        // covered or this fails.
        #expect(children.isSuperset(of: [
            "asset_metadata", "duplicate_kept_pair", "face", "photo_description", "search_embedding", "search_text",
        ]))
        let snapshotBefore = try await queue.read { db in try Self.snapshot(db, children: children) }
        for (table, rows) in snapshotBefore.children {
            #expect(!rows.isEmpty, "\(table) holds no row to carry")
        }
        let indexesBefore = try await queue.read { db in try Self.indexNames(db) }
        let signaturesBefore = try await queue.read { db in
            try Row.fetchAll(db, sql: """
            SELECT relative_path, render_dhash, render_gray,
                   COALESCE(render_signature_source = \(StoredThumbnailSQL.identity("media_asset")), 0) AS current
            FROM media_asset ORDER BY library_root_id, relative_path
            """).map { SignatureBefore(path: $0[0], hash: $0[1], gray: $0[2], current: $0[3]) }
        }

        try CatalogStore.migrator.migrate(queue)

        try await queue.read { db in
            let after = try Self.snapshot(db, children: children)
            #expect(after.assets == snapshotBefore.assets)
            for (table, rows) in snapshotBefore.children {
                #expect(after.children[table] == rows, "\(table)")
            }
            #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            #expect(try String.fetchOne(db, sql: "PRAGMA integrity_check") == "ok")
            let columns = try Set(String.fetchAll(db, sql: "SELECT name FROM pragma_table_xinfo('media_asset')"))
            #expect(columns.isDisjoint(with: Self.removedColumns))
            #expect(columns.contains("render_signature_read"))
            // Every index is carried over; the later migrations add three.
            #expect(try Self.indexNames(db) == indexesBefore.union([
                ChosenRowsSQL.indexName, SearchEmbeddingStorage.noThumbnailComingIndexName, PhotoCopySQL.indexName,
            ]))
            // A signature current for its thumbnail keeps its hash and its gray; a stale one is
            // owed again; a thumbnail that did not decode stays read.
            for signature in signaturesBefore {
                let path = signature.path
                let current = signature.current
                let stored = try #require(try Row.fetchOne(db, sql: """
                SELECT a.render_dhash, a.render_signature_read, g.gray
                FROM media_asset a LEFT JOIN render_signature g USING (library_root_id, relative_path)
                WHERE a.relative_path = ?
                """, arguments: [path]))
                #expect((stored["render_signature_read"] as Int) == (current ? 1 : 0), "\(path)")
                #expect(stored["render_dhash"] as Int64? == (current ? signature.hash : nil), "\(path)")
                let gray: Data? = current && signature.hash != nil ? signature.gray : nil
                #expect(stored["gray"] as Data? == gray, "\(path)")
            }
        }
    }

    /// After the rebuild the triggers work as before: a choice on a copy is every copy's, a
    /// removed copy leaves its photo alone, a new thumbnail makes its signature owed, and a
    /// move and a deletion carry the gray with the row.
    @Test func theRebuiltTableKeepsItsCopiesAndItsSignatures() async throws {
        let queue = try DatabaseQueue()
        try CatalogStore.migrator.migrate(queue, upTo: Self.before)
        try await queue.write { db in try Self.writeV69Catalog(db) }
        try CatalogStore.migrator.migrate(queue)
        try await queue.write { db in
            try db.execute(sql: "UPDATE media_asset SET media_choice = 'liked' WHERE relative_path = 'copy-a.jpg'")
            let choices = try String.fetchAll(db, sql: """
            SELECT media_choice FROM media_asset WHERE relative_path IN ('copy-a.jpg', 'asset/copy-b.jpg')
            ORDER BY relative_path
            """)
            #expect(choices == ["liked", "liked"])
            #expect(try Int.fetchAll(db, sql: """
            SELECT has_copies FROM media_asset WHERE relative_path IN ('copy-a.jpg', 'asset/copy-b.jpg')
            """) == [1, 1])
            try db.execute(sql: "DELETE FROM media_asset WHERE relative_path = 'asset/copy-b.jpg'")
            #expect(try Int.fetchOne(db, sql: "SELECT has_copies FROM media_asset WHERE relative_path = 'copy-a.jpg'") == 0)

            try db.execute(sql: "UPDATE media_asset SET relative_path = 'moved/signed.jpg' WHERE relative_path = 'signed.jpg'")
            #expect(try String.fetchAll(db, sql: "SELECT relative_path FROM render_signature") == ["moved/signed.jpg"])
            try db.execute(sql: "UPDATE media_asset SET rendered_revision = rendered_revision + 1 WHERE relative_path = 'moved/signed.jpg'")
            let stale = try #require(try Row.fetchOne(db, sql: """
            SELECT render_dhash, render_signature_read FROM media_asset WHERE relative_path = 'moved/signed.jpg'
            """))
            #expect(stale["render_dhash"] as Int64? == nil)
            #expect(stale["render_signature_read"] as Int == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM render_signature") == 0)
            #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    // MARK: - The v70 catalog

    /// The asset rows of a v70 catalog, one of each kind a catalog holds, and a row of every
    /// table that refers to an asset.
    private static func writeV69Catalog(_ db: Database) throws {
        try db.execute(sql: """
        INSERT INTO library_root (id, path, kind) VALUES
            (1, '/Pictures/', 'library'), (2, '/Account/', 'immichAccount'), (3, '/Volumes/CARD/', 'removableVolume')
        """)
        // Nothing but the key and the columns no row can lack.
        try insertAsset(db, root: 1, path: "bare.jpg", extra: [:])
        // Every column a row can hold, each with its own value.
        try insertAsset(db, root: 1, path: "2020/full.heic", extra: [
            "name": "full.heic", "content_type_identifier": "public.heic", "kind": "image", "format": "HEIF",
            "byte_size": 1234, "created_at_unix": 1_600_000_000.5, "content_modified_at_unix": 1_600_000_100.25,
            "file_identifier": 77, "enriched_kind": "raw", "enriched_format": "DNG", "metadata_source_size": 1234,
            "metadata_source_mtime": 1_600_000_100, "thumbnail_path": "t.jpg", "preview_path": "p.heic",
            "face_frames_path": "f.faces.heic", "duration_seconds": 3.5, "enrichment_claimed": 9.0,
            "undecodable_by": "otos", "import_batch_unix_ms": 1_700_000_000_000, "import_source_root_path": "/Volumes/CARD/",
            "import_source_relative_path": "DCIM/full.heic", "import_source_byte_size": 1234,
            "import_source_modified_at_epoch": 1_600_000_100.0, "import_destination_byte_size": 1234,
            "import_destination_modified_at_epoch": 1_600_000_100.0, "capture_wall_compact": 20_200_101_120_000,
            "capture_wall_precision": "seconds", "capture_instant_unix": 1_577_880_000.0, "assumed_utc_offset_seconds": 7200,
            "media_choice": "disliked", "media_choice_sequence": -2, "stack_key_chosen_at_unix_ms": 5,
            "burst_key_chosen_at_unix_ms": 6, "edit_recipe_json": #"{"quarterTurns":1}"#, "edit_revision": 3,
            "rendered_revision": 2, "rendered_source_size": 1234, "rendered_source_mtime": 1_600_000_100,
            "faces_source_size": 1234, "faces_source_mtime": 1_600_000_100, "faces_read_source_size": 1234,
            "faces_read_source_mtime": 1_600_000_100, "content_identifier": "live-1", "burst_identifier": "burst-1",
            "render_dhash": 99, "render_gray": Data(repeating: 3, count: 1024), "render_signature_source": "a stale stamp",
        ])
        // Out of sight: in the Trash, waiting for the Trash, unseen by its attachment, hidden.
        try insertAsset(db, root: 1, path: "trashed.jpg", extra: ["trash_path": "/Users/x/.Trash/trashed.jpg"])
        try insertAsset(db, root: 1, path: "pending.jpg", extra: ["pending_trash_batch_unix_ms": 42])
        try insertAsset(db, root: 3, path: "DCIM/unseen.jpg", extra: ["awaiting_presence": 1])
        // An account's listed rows: an uploaded asset and an external library's.
        try insertAsset(db, root: 2, path: "asset/uploaded.jpg", extra: [
            "source_item_id": "asset", "source_products_size": 10, "source_products_mtime": 20, "thumbnail_path": "u.jpg",
        ])
        try insertAsset(db, root: 2, path: "external/ext.jpg", extra: [
            "source_item_id": "external", "source_path_sha1": Data(repeating: 9, count: 20), "hidden_by_source": 1,
            "source_products_absent": 1,
        ])
        // Two copies of one photo, in the library and the account.
        let digest = Data(repeating: 5, count: 20)
        for (root, path) in [(Int64(1), "copy-a.jpg"), (2, "asset/copy-b.jpg")] {
            try insertAsset(db, root: root, path: path, extra: [
                "byte_size": 50, "content_modified_at_unix": 100.0, "content_sha1": digest,
                "content_hash_source_size": 50, "content_hash_source_mtime": 100, "kind": "image",
            ])
        }
        // Signatures: one current for its thumbnail, one whose thumbnail decoded to nothing.
        try insertAsset(db, root: 1, path: "signed.jpg", extra: [
            "kind": "image", "thumbnail_path": "s.jpg", "rendered_source_size": 1, "rendered_source_mtime": 2,
            "render_dhash": 12345, "render_gray": Data(repeating: 1, count: 1024),
        ])
        try db.execute(sql: """
        UPDATE media_asset SET render_signature_source = \(StoredThumbnailSQL.identity("media_asset"))
        WHERE relative_path = 'signed.jpg'
        """)
        try insertAsset(db, root: 1, path: "undecodable.jpg", extra: ["kind": "image", "thumbnail_path": "x.jpg"])
        try db.execute(sql: """
        UPDATE media_asset SET render_signature_source = \(StoredThumbnailSQL.identity("media_asset"))
        WHERE relative_path = 'undecodable.jpg'
        """)
        // A move outside Otos and a rename: the row and every child take the new key.
        try insertAsset(db, root: 1, path: "old/renamed.jpg", extra: ["kind": "image"])
        try writeChildren(db, root: 1, path: "old/renamed.jpg")
        try db.execute(sql: "UPDATE media_asset SET relative_path = 'new/renamed.jpg' WHERE relative_path = 'old/renamed.jpg'")
        try db.execute(sql: "UPDATE media_asset SET library_root_id = 3, relative_path = 'moved.jpg' WHERE relative_path = 'bare.jpg'")
        for (root, path) in [(Int64(1), "2020/full.heic"), (2, "asset/uploaded.jpg"), (1, "trashed.jpg")] {
            try writeChildren(db, root: root, path: path)
        }
        try db.execute(sql: """
        INSERT INTO duplicate_kept_pair (first_root_id, first_path, second_root_id, second_path)
        VALUES (1, 'copy-a.jpg', 2, 'asset/copy-b.jpg')
        """)
    }

    private static func insertAsset(_ db: Database, root: Int64, path: String, extra: [String: (any DatabaseValueConvertible)?]) throws {
        let columns = ["library_root_id", "relative_path", "relative_path_key", "sort_key", "name_sort_key"] + extra.keys.sorted()
        let values: [(any DatabaseValueConvertible)?] = [root, path, path.lowercased(), "sort " + path, path.lowercased()]
            + extra.keys.sorted().map { extra[$0] ?? nil }
        try db.execute(
            sql: "INSERT INTO media_asset (\(columns.joined(separator: ", "))) VALUES (\(columns.map { _ in "?" }.joined(separator: ", ")))",
            arguments: StatementArguments(values)
        )
    }

    /// A row of each table that refers to an asset, for one asset.
    private static func writeChildren(_ db: Database, root: Int64, path: String) throws {
        let person = try (Int64.fetchOne(db, sql: "SELECT max(id) FROM person") ?? 0) + 1
        try db.execute(sql: "INSERT INTO person (id, name) VALUES (?, ?)", arguments: [person, "Person \(person)"])
        try db.execute(
            sql: """
            INSERT INTO asset_metadata (library_root_id, relative_path, family, camera_model, pixel_width,
                                        metadata_extra_json, extraction_revision)
            VALUES (?, ?, 'heif', 'Camera', 4032, '{"k":1}', 3)
            """,
            arguments: [root, path]
        )
        for index in 0 ..< 2 {
            try db.execute(
                sql: """
                INSERT INTO face (library_root_id, relative_path, face_index, box_x, box_y, box_width, box_height,
                                  landmarks, quality, analysis_revision, person_id, assignment, likeness)
                VALUES (?, ?, ?, 0.1, 0.2, 0.3, 0.4, x'0102', 0.5, 7, ?, 1, 0.75)
                """,
                arguments: [root, path, index, person]
            )
            try db.execute(sql: FaceEmbeddingSQL.insertSQL, arguments: [root, path, index, Data(repeating: UInt8(index), count: 16)])
        }
        try db.execute(sql: "INSERT INTO face_rejection VALUES (?, ?, 1, ?)", arguments: [root, path, person])
        try db.execute(
            sql: """
            INSERT INTO search_embedding (library_root_id, relative_path, source, embedding, labels, confident_labels)
            VALUES (?, ?, 'embedding source', x'00ff', 'sky:0.5', 'sky')
            """,
            arguments: [root, path]
        )
        try db.execute(
            sql: "INSERT INTO search_text (library_root_id, relative_path, source, lines) VALUES (?, ?, 'text source', '[]')",
            arguments: [root, path]
        )
        try db.execute(
            sql: "INSERT INTO photo_description (library_root_id, relative_path, source, text) VALUES (?, ?, 'd', 'A photo.')",
            arguments: [root, path]
        )
    }

    // MARK: - Reading back

    private struct SignatureBefore: Sendable {
        let path: String
        let hash: Int64?
        let gray: Data?
        let current: Bool
    }

    /// Rows as their values, which cross into a test's checks.
    private typealias Values = [[DatabaseValue]]

    private struct Snapshot: Sendable {
        let assets: Values
        let children: [String: Values]
    }

    /// The tables whose foreign keys name `media_asset`, and the tables whose foreign keys name
    /// those.
    private static func tablesReferringToAssets(_ db: Database) throws -> Set<String> {
        let direct = try Set(String.fetchAll(db, sql: """
        SELECT DISTINCT m.name FROM sqlite_master AS m, pragma_foreign_key_list(m.name) AS f
        WHERE m.type = 'table' AND f."table" = 'media_asset'
        """))
        let indirect = try Set(String.fetchAll(db, sql: """
        SELECT DISTINCT m.name FROM sqlite_master AS m, pragma_foreign_key_list(m.name) AS f
        WHERE m.type = 'table' AND f."table" IN (\(direct.map { "'\($0)'" }.joined(separator: ", ")))
        """))
        return direct.union(indirect)
    }

    /// Every asset row's kept columns, and every row of every table in `children`, in a fixed
    /// order.
    private static func snapshot(_ db: Database, children: Set<String>) throws -> Snapshot {
        let assets = try Row.fetchAll(db, sql: """
        SELECT \(CatalogSchema.hotAssetCopiedColumns) FROM media_asset ORDER BY library_root_id, relative_path
        """).map { Array($0.databaseValues) }
        var rows: [String: Values] = [:]
        for table in children {
            let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM pragma_table_info('\(table)')") ?? 1
            let order = (1 ... count).map(String.init).joined(separator: ", ")
            rows[table] = try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY \(order)").map { Array($0.databaseValues) }
        }
        return Snapshot(assets: assets, children: rows)
    }

    private static func indexNames(_ db: Database) throws -> Set<String> {
        try Set(String.fetchAll(db, sql: """
        SELECT name FROM sqlite_master
        WHERE type = 'index' AND tbl_name = 'media_asset' AND name NOT LIKE 'sqlite_autoindex_%'
        """))
    }
}

/// The open's compaction (`CatalogStore.compactIfOwed`): a catalog a tenth or more free, and at least
/// 256 MB of it, is rewritten without its free pages, keeping every row, once; one without room above the
/// free-space floor is left as it is and asked again at the next open.
@Suite(.testScope)
struct CatalogCompactionTests {
    private static func catalogWithFreePages() throws -> (DatabasePool, URL) {
        let url = try makeTestDirectory().appending(path: "catalog.sqlite")
        let pool = try DatabasePool(path: url.path(percentEncoded: false))
        try CatalogStore.migrator.migrate(pool)
        try pool.write { db in
            try db.execute(sql: "INSERT INTO library_root (id, path, kind) VALUES (1, '/Pictures/', 'library')")
            try db.execute(sql: """
            WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 400)
            INSERT INTO media_asset (library_root_id, relative_path, relative_path_key, name_sort_key, edit_recipe_json)
            SELECT 1, printf('%04d.jpg', i), printf('%04d.jpg', i), printf('%04d.jpg', i), hex(randomblob(4000)) FROM n
            """)
            try db.execute(sql: "DELETE FROM media_asset WHERE relative_path > '0040.jpg'")
        }
        try pool.writeWithoutTransaction { db in try db.checkpoint(.truncate) }
        return (pool, url)
    }

    @Test func aCatalogWithFreePagesIsRewrittenOnceAndKeepsItsRows() throws {
        let (pool, url) = try Self.catalogWithFreePages()
        var told = 0
        let outcome = try CatalogStore.compactIfOwed(pool, fileURL: url, minimumFreeBytes: 0) { told += 1 }
        guard case let .compacted(_, before, after) = outcome else {
            Issue.record("not compacted: \(outcome)")
            return
        }
        #expect(told == 1)
        #expect(after < before / 2)
        let state = try pool.read { db in
            try [
                String(Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? -1),
                String(Int.fetchOne(db, sql: "SELECT count(*) FROM media_asset") ?? -1),
                String.fetchOne(db, sql: "PRAGMA integrity_check") ?? "",
            ]
        }
        #expect(state == ["0", "40", "ok"])
        let again = try CatalogStore.compactIfOwed(pool, fileURL: url, minimumFreeBytes: 0) { told += 1 }
        guard case .notOwed = again else {
            Issue.record("compacted twice: \(again)")
            return
        }
        #expect(told == 1)
    }

    /// The owner's catalog after v71: 162,334 of 687,016 pages free (23.6 %, 634 MB of 2.8 GB),
    /// which a quarter's rule left in place. A tenth and 256 MB owe it; a smaller share, or
    /// fewer bytes, do not.
    @Test func theOwnersFileAfterV71IsOwedItsCompaction() {
        let minimum = CatalogStore.compactionMinimumFreeBytes
        #expect(CatalogStore.compactionOwed(pages: 687_016, freePages: 162_334, pageSize: 4096, minimumFreeBytes: minimum))
        #expect(!CatalogStore.compactionOwed(pages: 687_016, freePages: 68000, pageSize: 4096, minimumFreeBytes: minimum))
        #expect(!CatalogStore.compactionOwed(pages: 200_000, freePages: 60000, pageSize: 4096, minimumFreeBytes: minimum))
    }

    @Test func aCatalogWithoutRoomAboveTheFloorIsLeftForTheNextOpen() throws {
        let (pool, url) = try Self.catalogWithFreePages()
        let pages = try pool.read { db in try Int.fetchOne(db, sql: "PRAGMA page_count") ?? 0 }
        let outcome = try CatalogStore.compactIfOwed(
            pool, fileURL: url, minimumFreeBytes: 0, availableBytes: { _ in FreeSpaceFloor.bytes }
        ) {
            Issue.record("told of a compaction that was skipped")
        }
        guard case .skippedForSpace = outcome else {
            Issue.record("not skipped: \(outcome)")
            return
        }
        #expect(try pool.read { db in try Int.fetchOne(db, sql: "PRAGMA page_count") } == pages)
    }
}
