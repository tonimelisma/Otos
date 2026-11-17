import Foundation
import GRDB
@testable import OtosKit

/// A generated catalog file shaped like the owner's on 2026-11-16, for the tests that
/// measure what his catalog's size and backlog make the Store do
/// (`docs/research/2026-11-16-stall-reproduction-baseline.md`).
///
/// Every number below is a read-only count of his catalog (`sqlite3 -readonly` on
/// `net.melisma.Otos/Catalog/catalog.sqlite`, 2.56 GB), multiplied by `scale`. At scale 1 the
/// file holds what his does: the same roots and their kinds, the same rows per root and
/// kind, the same derived rows per root with the same widths, and the same kinds of
/// backlog — most derived rows current for the row they were read from, a small or large
/// owed remainder for each product, metadata records read by an older parser, rows that
/// can never be hashed (dataless stand-ins), and a library no account mirrors. Nothing is
/// on disk but the file and two empty library folders: every thumbnail, preview and
/// original the rows name is missing, so a background owner can find its work and never
/// finish it.
///
/// Whether a derived row is current is decided by the product's own SQL
/// (`StoredThumbnailSQL`, `SearchEmbeddingStorage`, `SearchTextStorage`,
/// `PhotoDescriptionStorage`, `CatalogStore.currentExtractionRevisionSQL`), so the generated
/// backlog is what the candidate reads find, as they evolve. The earlier owner-shaped
/// catalogs (#779, #793, #795) were temporary probes never committed; this is the one the
/// tests keep. Generation is SQL inside one transaction; its time and size at each scale are
/// in the research note.
struct OwnerShapedCatalog {
    /// What the generator wrote, at the scale asked for.
    struct Shape: Equatable {
        var assets = 0
        var embeddingsOwed = 0
        var renderSignaturesOwed = 0
        var textsOwed = 0
        var stillsAwaitingPreview = 0
        var noThumbnailComing = 0
        var videosOwingFaces = 0
        var metadataStaleInLibraries = 0
        var unhashable = 0
        var embeddings = 0
        var texts = 0
        var faces = 0
        var descriptions = 0
        var metadataRecords = 0
    }

    let databaseURL: URL
    let pictures: LibraryRootPath
    let archive: LibraryRootPath
    let account: LibraryRootPath
    let shape: Shape
    let fileBytes: Int64
    let generation: Duration

    /// His roots: two OneDrive libraries (6 and 7), one Immich account (15) whose server
    /// also holds library 7, and the cards and cameras he imported from. Row counts per kind
    /// are his `media_asset` rows per root and kind; `hashedPermille` his share of rows with
    /// a content hash (an account's are never hashed, most of a OneDrive library's are
    /// dataless).
    private struct RootSpec {
        let id: Int64
        let kind: LibraryRootKind
        let images: Int
        let raws: Int
        /// His RAWs that pair with a processed still of their folder (ADR 0052): the first
        /// ones written take the names of the root's first images.
        var pairedRaws = 0
        let videos: Int
        let hashedPermille: Int
    }

    private static let roots: [RootSpec] = [
        RootSpec(id: 5, kind: .deviceMTP, images: 35, raws: 0, videos: 37, hashedPermille: 0),
        RootSpec(id: 6, kind: .library, images: 714, raws: 0, videos: 74, hashedPermille: 1000),
        RootSpec(id: 7, kind: .library, images: 8954, raws: 6074, pairedRaws: 5384, videos: 1886, hashedPermille: 231),
        RootSpec(id: 10, kind: .removableVolume, images: 71, raws: 0, videos: 2, hashedPermille: 0),
        RootSpec(id: 13, kind: .deviceMTP, images: 464, raws: 464, pairedRaws: 464, videos: 63, hashedPermille: 0),
        RootSpec(id: 14, kind: .deviceMTP, images: 903, raws: 0, videos: 185, hashedPermille: 0),
        RootSpec(id: 15, kind: .immichAccount, images: 117_810, raws: 10906, videos: 18348, hashedPermille: 0),
    ]

    /// His counts of the derived tables and the backlog, before `scale`.
    private enum Owner {
        /// Owed embeddings and render signatures: his were all current on 2026-11-16; a few
        /// dozen stand for the photos an import or an edit leaves owed, which a candidate read
        /// must walk the whole table to find.
        static let embeddingsOwed = 24
        static let renderSignaturesOwed = 24
        /// Libraries' previews with no current text reading (his 21 in library 7).
        static let libraryTextsOwed = 21
        /// The account's previews read for text: 60,074 of 128,889 on 2026-11-16, 10,724 of
        /// them holding text; the rest is owed.
        static let accountTexts = 60074
        static let descriptions = 5521
        /// Face rows: 102,979, of which 15,653 are video frames.
        static let stillFaces = 87326
        static let frameFaces = 15653
        static let people = 748
        static let namedPeople = 6
        static let placeCells = 1435
        /// The account's `asset_metadata` rows: 120,108 of 147,064.
        static let accountMetadataRecords = 120_108
        /// Records read by an older parser: 27,595 of 140,034.
        static let staleMetadataPermille = 197
        static let videosOwingFaces = 896
        static let stillsAwaitingPreview = 43
        /// Rows that will get no thumbnail (v77's index), his on 2026-11-17: 26 stills rendering
        /// found none in, and 152 account videos whose server holds none.
        static let stillsWithNoThumbnail = 26
        static let accountVideosWithNoThumbnail = 152
        /// Import batches in the libraries: 11,401 rows in 45 batches.
        static let importedRows = 11401
        static let importBatches = 45
    }

    static let baseCaptureUnix: Int64 = 1_262_304_000

    /// His `name_sort_key` width: 11.1 MB over 167,215 rows.
    private static let nameSortKeyLength = 66

    /// Writes the catalog under `directory`: the file in `db/`, the libraries' empty folders
    /// in `Libraries/`. `scale` 1 is the owner's catalog; every count is rounded, and an owed
    /// remainder is never rounded to nothing.
    static func make(in directory: URL, scale: Double) throws -> OwnerShapedCatalog {
        let clock = ContinuousClock()
        let start = clock.now
        let databaseURL = directory.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let picturesURL = directory.appending(path: "Libraries/Pictures", directoryHint: .isDirectory)
        let archiveURL = directory.appending(path: "Libraries/Archive", directoryHint: .isDirectory)
        for url in [picturesURL, archiveURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let staging = CatalogStore.stagingContainers(for: .databaseFile(databaseURL))
        let accountIdentity = DeviceIdentity(rawValue: "immich:generated.invalid:owner")
        let paths: [Int64: LibraryRootPath] = try [
            5: CatalogPath.normalizedDirectoryPath(for: staging.sessionRoot(in: .device, identity: DeviceIdentity(rawValue: "camera:generated-5"))),
            6: CatalogPath.normalizedExistingDirectoryPath(for: archiveURL),
            7: CatalogPath.normalizedExistingDirectoryPath(for: picturesURL),
            10: LibraryRootPath(rawValue: "/Volumes/OTOS-GENERATED-CARD/"),
            13: CatalogPath.normalizedDirectoryPath(for: staging.sessionRoot(in: .device, identity: DeviceIdentity(rawValue: "camera:generated-13"))),
            14: CatalogPath.normalizedDirectoryPath(for: staging.sessionRoot(in: .device, identity: DeviceIdentity(rawValue: "camera:generated-14"))),
            15: CatalogPath.normalizedDirectoryPath(for: staging.sessionRoot(in: .remote, identity: accountIdentity)),
        ]
        let identities: [Int64: String] = [
            5: "camera:generated-5", 10: "volume:generated-10", 13: "camera:generated-13",
            14: "camera:generated-14", 15: accountIdentity.rawValue,
        ]

        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = OFF")
        }
        let queue = try makeTestDatabaseQueue(path: databaseURL.path(percentEncoded: false), configuration: configuration)
        try CatalogStore.migrator.migrate(queue)
        var shape = Shape()
        try queue.write { db in
            for root in roots {
                try db.execute(
                    sql: """
                    INSERT INTO library_root (id, path, kind, device_identity, display_name, sort_index, remote_base_url,
                                              last_seen_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        root.id, paths[root.id]?.rawValue, root.kind.rawValue, identities[root.id],
                        "Generated \(root.id)", root.id, root.kind == .immichAccount ? "https://generated.invalid" : nil,
                        // Seen now: a card or camera unseen for 90 days is forgotten at the open.
                        identities[root.id] == nil ? nil : Date().timeIntervalSince1970,
                    ]
                )
            }
            var offset = 0
            for root in roots {
                let imagesOffset = offset
                let images = scaled(root.images, scale)
                for (kind, count) in [("image", root.images), ("raw", root.raws), ("video", root.videos)] where count > 0 {
                    let rows = scaled(count, scale)
                    let pairing = kind == "raw" && root.pairedRaws > 0
                        ? Pairing(imagesOffset: imagesOffset, count: min(scaled(root.pairedRaws, scale), rows, images)) : nil
                    try insertAssets(
                        db, root: root, kind: kind, count: rows, offset: offset,
                        pairing: pairing
                    )
                    offset += rows
                }
            }
            shape.assets = offset
            try writeBursts(db)
            shape.unhashable = try Int.fetchOne(db, sql: "SELECT count(*) FROM media_asset WHERE content_sha1 IS NULL") ?? 0
            try writeBacklog(db, scale: scale, shape: &shape)
            try writeDerivedRows(db, scale: scale, shape: &shape)
        }
        try queue.close()
        let bytes = try FileManager.default.attributesOfItem(atPath: databaseURL.path(percentEncoded: false))[.size] as? Int64 ?? 0
        guard let pictures = paths[7], let archive = paths[6], let account = paths[15] else {
            throw CocoaError(.fileNoSuchFile)
        }
        return OwnerShapedCatalog(
            databaseURL: databaseURL,
            pictures: pictures,
            archive: archive,
            account: account,
            shape: shape,
            fileBytes: bytes,
            generation: start.duration(to: clock.now)
        )
    }

    static func scaled(_ count: Int, _ scale: Double) -> Int {
        max(1, Int((Double(count) * scale).rounded()))
    }

    /// Which of a root's RAWs pair: the first `count` take the names, and so the folders, of
    /// the root's first images, written from `imagesOffset`.
    private struct Pairing {
        let imagesOffset: Int
        let count: Int
    }

    /// His bursts: 33 identifiers on 39 stills, of which one is a burst of seven frames (root
    /// 14) and 32 are carried by one still each, so they stack nothing — two in library 7, the
    /// first on a paired image, so a burst's still sits in a folder that can hold a pair; one
    /// on a camera; 29 on the account's stills, each alone in its asset's folder. Never
    /// scaled: a burst's frames are its own count, placed only where its root has the stills.
    private static func writeBursts(_ db: Database) throws {
        struct Burst {
            let root: Int64
            let identifier: String
            let frames: Int
            let skip: Int
        }
        let bursts = [
            Burst(root: 14, identifier: "generated-burst-14", frames: 7, skip: 0),
            Burst(root: 14, identifier: "generated-single-14", frames: 1, skip: 7),
            Burst(root: 7, identifier: "generated-single-7-a", frames: 1, skip: 0),
            Burst(root: 7, identifier: "generated-single-7-b", frames: 1, skip: 1),
        ] + (0 ..< 29).map { Burst(root: 15, identifier: "generated-single-15-\($0)", frames: 1, skip: $0) }
        for burst in bursts {
            try db.execute(
                sql: """
                UPDATE media_asset SET burst_identifier = ?
                WHERE rowid IN (SELECT rowid FROM media_asset WHERE library_root_id = ? AND kind = 'image'
                                ORDER BY rowid LIMIT ? OFFSET ?)
                """,
                arguments: [burst.identifier, burst.root, burst.frames, burst.skip]
            )
        }
    }

    /// One root's rows of one kind. Each row is current for every product its kind has: its
    /// metadata, rendering and faces were read from its present size and date. An account's
    /// rows carry their server item, are drawn by the server (`source_products_*`, no
    /// rendering of Otos's own) and are never hashed; a library's are hashed at its share. A
    /// paired RAW (`pairing`) is named as the image it pairs with, in that image's folder.
    private static func insertAssets(
        _ db: Database, root: RootSpec, kind: String, count: Int, offset: Int, pairing: Pairing?
    ) throws {
        let isStill = kind != "video"
        let (type, format, ext) = switch kind {
        case "raw": ("com.sony.arw-raw-image", "ARW", "ARW")
        case "video": ("com.apple.quicktime-movie", "MOV", "MOV")
        default: ("public.heic", "HEIF", "HEIC")
        }
        let isAccount = root.kind == .immichAccount
        // Rows of a library are dated folders of files; an account's are named by the
        // server's asset ID.
        let relativePath = isAccount
            ? "printf('%08x-0000-4000-8000-%012x/IMG_%06d.\(ext)', i, i, i)"
            : pairing.map { pairing in
                let image = "(\(pairing.imagesOffset) + i - \(offset))"
                return """
                CASE WHEN i - \(offset) < \(pairing.count)
                    THEN printf('%04d/%02d/image_%06d.\(ext)', 2010 + \(image) / 20000, 1 + (\(image) / 1700) % 12, \(image))
                    ELSE printf('%04d/%02d/\(kind)_%06d.\(ext)', 2010 + i / 20000, 1 + (i / 1700) % 12, i)
                END
                """
            } ?? "printf('%04d/%02d/\(kind)_%06d.\(ext)', 2010 + i / 20000, 1 + (i / 1700) % 12, i)"
        try db.execute(
            sql: """
            WITH RECURSIVE n(j) AS (SELECT 0 UNION ALL SELECT j + 1 FROM n WHERE j + 1 < ?),
            numbered AS (SELECT j + ? AS i FROM n),
            g AS (
                SELECT i, \(relativePath) AS path, ? + i * 1800 AS created, 1500000 + (i * 7919) % 6000000 AS size
                FROM numbered
            )
            INSERT INTO media_asset (
                library_root_id, relative_path, name_sort_key, name, content_type_identifier,
                kind, format, byte_size, created_at_unix, content_modified_at_unix, enriched_kind, enriched_format,
                metadata_source_size, metadata_source_mtime, thumbnail_path, preview_path, duration_seconds,
                capture_wall_compact, capture_instant_unix, content_sha1, content_hash_source_size,
                content_hash_source_mtime, relative_path_key, rendered_source_size, rendered_source_mtime,
                source_products_size, source_products_mtime, faces_source_size, faces_source_mtime, source_item_id
            )
            SELECT ?, path,
                   substr(lower(substr(path, length(rtrim(path, replace(path, '/', ''))) + 1)) || ?, 1, ?),
                   substr(path, length(rtrim(path, replace(path, '/', ''))) + 1),
                   ?, ?, ?, size, created, created + 60, ?, ?,
                   size, created + 60,
                   printf('%056x%08x.jpg', ?, i),
                   CASE WHEN ? THEN printf('%056x%08x.heic', ?, i) END,
                   CASE WHEN ? THEN 4.0 + i % 90 END,
                   CAST(strftime('%Y%m%d%H%M%S', created, 'unixepoch') AS INTEGER), created,
                   CASE WHEN i % 1000 < ? THEN randomblob(20) END,
                   CASE WHEN i % 1000 < ? THEN size END,
                   CASE WHEN i % 1000 < ? THEN created + 60 END,
                   lower(path),
                   CASE WHEN NOT ? THEN size END, CASE WHEN NOT ? THEN created + 60 END,
                   CASE WHEN ? THEN size END, CASE WHEN ? THEN created + 60 END,
                   size, created + 60,
                   CASE WHEN ? THEN printf('%08x-0000-4000-8000-%012x', i, i) END
            FROM g
            """,
            arguments: [
                count, offset, baseCaptureUnix,
                root.id, String(repeating: "0", count: nameSortKeyLength), nameSortKeyLength,
                type, kind, format, kind, format,
                root.id, isStill, root.id, !isStill,
                root.hashedPermille, root.hashedPermille, root.hashedPermille,
                isAccount, isAccount, isAccount, isAccount,
                isAccount,
            ]
        )
    }

    /// The backlog that is not a missing derived row: the account's stills whose preview is
    /// still to come, its videos whose faces are owed, the libraries' imports.
    private static func writeBacklog(_ db: Database, scale: Double, shape: inout Shape) throws {
        shape.stillsAwaitingPreview = scaled(Owner.stillsAwaitingPreview, scale)
        try db.execute(
            sql: """
            UPDATE media_asset SET thumbnail_path = NULL, preview_path = NULL,
                rendered_source_size = NULL, rendered_source_mtime = NULL,
                source_products_size = NULL, source_products_mtime = NULL,
                faces_source_size = NULL, faces_source_mtime = NULL
            WHERE rowid IN (SELECT rowid FROM media_asset WHERE library_root_id = 15 AND kind = 'image'
                            ORDER BY (rowid * 7919) % 100003 LIMIT ?)
            """,
            arguments: [shape.stillsAwaitingPreview]
        )
        // The rows that will get no thumbnail: library stills rendering found none in, and
        // account videos whose server holds none.
        let unrendered = scaled(Owner.stillsWithNoThumbnail, scale)
        try db.execute(
            sql: """
            UPDATE media_asset SET thumbnail_path = NULL, preview_path = NULL
            WHERE rowid IN (SELECT rowid FROM media_asset WHERE library_root_id = 7 AND kind = 'image'
                            ORDER BY rowid DESC LIMIT ?)
            """,
            arguments: [unrendered]
        )
        let sourceless = scaled(Owner.accountVideosWithNoThumbnail, scale)
        try db.execute(
            sql: """
            UPDATE media_asset SET thumbnail_path = NULL, preview_path = NULL,
                source_products_size = NULL, source_products_mtime = NULL, source_products_absent = 1
            WHERE rowid IN (SELECT rowid FROM media_asset WHERE library_root_id = 15 AND kind = 'video'
                            ORDER BY rowid DESC LIMIT ?)
            """,
            arguments: [sourceless]
        )
        shape.noThumbnailComing = unrendered + sourceless
        shape.videosOwingFaces = scaled(Owner.videosOwingFaces, scale)
        try db.execute(
            sql: """
            UPDATE media_asset SET faces_source_size = NULL, faces_source_mtime = NULL
            WHERE rowid IN (SELECT rowid FROM media_asset WHERE library_root_id = 15 AND kind = 'video'
                            ORDER BY (rowid * 7919) % 100003 LIMIT ?)
            """,
            arguments: [shape.videosOwingFaces]
        )
        try db.execute(
            sql: """
            UPDATE media_asset SET import_batch_unix_ms = 1600000000000 + (rowid % ?) * 86400000
            WHERE rowid IN (SELECT rowid FROM media_asset WHERE library_root_id IN (6, 7) ORDER BY rowid DESC LIMIT ?)
            """,
            arguments: [max(2, scaled(Owner.importBatches, scale)), scaled(Owner.importedRows, scale)]
        )
    }

    /// The derived tables, each current for its row by the product's own source SQL, but for
    /// the owed remainders, which are spread through the table so a read that walks it finds
    /// them late.
    private static func writeDerivedRows(_ db: Database, scale: Double, shape: inout Shape) throws {
        let spread = "ORDER BY (rowid * 7919) % 100003"
        try db.execute(sql: "CREATE TEMP TABLE owed (product TEXT NOT NULL, row INTEGER NOT NULL)")
        shape.renderSignaturesOwed = Owner.renderSignaturesOwed
        try db.execute(
            sql: """
            INSERT INTO owed SELECT 'render', rowid FROM media_asset
            WHERE library_root_id IN (6, 7) AND kind IN ('image', 'raw') AND thumbnail_path IS NOT NULL \(spread) LIMIT ?
            """,
            arguments: [shape.renderSignaturesOwed]
        )
        shape.embeddingsOwed = Owner.embeddingsOwed
        try db.execute(
            sql: """
            INSERT INTO owed SELECT 'embedding', rowid FROM media_asset
            WHERE library_root_id IN (6, 7, 15) AND thumbnail_path IS NOT NULL \(spread) LIMIT ?
            """,
            arguments: [shape.embeddingsOwed]
        )
        // Render signatures: every still of the libraries and the account, a 1 KB gray render each.
        try db.execute(sql: """
        UPDATE media_asset SET render_dhash = (rowid * 2654435761) % 9007199254740991, render_signature_read = 1
        WHERE library_root_id IN (6, 7, 15) AND kind IN ('image', 'raw') AND thumbnail_path IS NOT NULL
          AND rowid NOT IN (SELECT row FROM owed WHERE product = 'render')
        """)
        try db.execute(sql: """
        INSERT INTO \(RenderSignatureSQL.grayTable) (library_root_id, relative_path, gray)
        SELECT library_root_id, relative_path, randomblob(1024) FROM media_asset WHERE render_dhash IS NOT NULL
        """)
        // Search embeddings: 3,072-byte vectors for every thumbnail of every root but the
        // cards (his roots 6, 7, 14 and 15).
        try db.execute(sql: """
        INSERT INTO search_embedding (library_root_id, relative_path, source, embedding, labels, confident_labels)
        SELECT a.library_root_id, a.relative_path, \(SearchEmbeddingStorage.currentSource("a")), zeroblob(3072),
               substr('beach:0.412,city:0.301,dog:0.118,food:0.207,forest:0.122,mountain:0.155,night:0.098,people:0.511,'
                   || 'portrait:0.233,sky:0.442,snow:0.071,sport:0.064,street:0.199,sunset:0.177,text:0.050,water:0.388,'
                   || 'animal:0.091,building:0.270,car:0.081,child:0.140,flower:0.066,indoor:0.300,', 1, 250),
               'people,sky,water,beach,cit'
        FROM media_asset AS a
        WHERE a.library_root_id IN (6, 7, 14, 15) AND a.thumbnail_path IS NOT NULL
          AND a.rowid NOT IN (SELECT row FROM owed WHERE product = 'embedding')
        """)
        shape.embeddings = db.changesCount
        // Text readings: every library preview but a few, under half of the account's; most
        // read no text. One in six holds text, as his 13,545 of 75,823 do: eleven lines of
        // about 14 characters (his 10.9 lines and 478 bytes of stored JSON a reading), words
        // that vary from row to row, numbers, and a line of Japanese in one reading of 18 (his
        // 757 readings with Chinese or Japanese).
        let textRow = """
        SELECT a.library_root_id, a.relative_path, \(SearchTextStorage.currentSource("a")),
               CASE WHEN a.rowid % 6 = 0 THEN (
                   SELECT json_group_array(json_object('confidence', 0.93, 'text',
                       CASE WHEN n.k = 1 AND a.rowid % 18 = 0 THEN '営業時間 ' || (a.rowid % 24) || '時'
                       ELSE substr('OPEN EXIT CAFE MENU SALE STOP Straße café niño ÉCOLE Rua Praça Gare Platz',
                                   1 + ((a.rowid * n.k * 7) % 60), 9)
                            || ' ' || printf('%x', (a.rowid * 2654435761 + n.k) % 1048573)
                            || ' ' || ((a.rowid + n.k) % 1000) END))
                   FROM (SELECT 1 AS k UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5
                         UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9
                         UNION ALL SELECT 10 UNION ALL SELECT 11) AS n
               ) ELSE '[]' END
        FROM media_asset AS a
        """
        try db.execute(
            sql: """
            INSERT INTO search_text (library_root_id, relative_path, source, lines)
            \(textRow) WHERE a.library_root_id IN (6, 7) AND a.preview_path IS NOT NULL
              AND a.rowid NOT IN (SELECT rowid FROM media_asset WHERE library_root_id = 7 AND preview_path IS NOT NULL \(spread) LIMIT ?)
            """,
            arguments: [scaled(Owner.libraryTextsOwed, scale)]
        )
        shape.texts = db.changesCount
        try db.execute(
            sql: """
            INSERT INTO search_text (library_root_id, relative_path, source, lines)
            \(textRow) WHERE a.library_root_id = 15 AND a.preview_path IS NOT NULL ORDER BY a.rowid LIMIT ?
            """,
            arguments: [scaled(Owner.accountTexts, scale)]
        )
        shape.texts += db.changesCount
        // Their words in the text index, as the Store writes them with each reading.
        try CatalogSchema.indexStoredSearchTexts(db)
        shape.textsOwed = try Int.fetchOne(db, sql: """
        SELECT count(*) FROM media_asset AS a WHERE a.library_root_id IN (6, 7, 15) AND a.preview_path IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM search_text AS t WHERE t.library_root_id = a.library_root_id AND t.relative_path = a.relative_path)
        """) ?? 0
        // People and faces: 2 KB embeddings, most assigned to one of his 748 people.
        try db.execute(
            sql: """
            WITH RECURSIVE n(k) AS (SELECT 1 UNION ALL SELECT k + 1 FROM n WHERE k < ?)
            INSERT INTO person (id, name) SELECT k, CASE WHEN k <= ? THEN 'Person ' || k END FROM n
            """,
            arguments: [scaled(Owner.people, scale), scaled(Owner.namedPeople, scale)]
        )
        let people = scaled(Owner.people, scale)
        let face = """
        SELECT library_root_id, relative_path, 0, 0.3, 0.3, 0.2, 0.2, zeroblob(40), 0.47, \(FaceAnalyzer.revision),
               CASE WHEN rowid % 33 = 0 THEN NULL ELSE 1 + rowid % \(people) END, 1
        """
        try db.execute(
            sql: """
            INSERT INTO face (library_root_id, relative_path, face_index, box_x, box_y, box_width, box_height,
                              landmarks, quality, analysis_revision, person_id, assignment)
            \(face) FROM media_asset WHERE library_root_id IN (6, 7, 15) AND kind IN ('image', 'raw')
              AND preview_path IS NOT NULL \(spread) LIMIT ?
            """,
            arguments: [scaled(Owner.stillFaces, scale)]
        )
        shape.faces = db.changesCount
        try db.execute(
            sql: """
            INSERT INTO face (library_root_id, relative_path, face_index, box_x, box_y, box_width, box_height,
                              landmarks, quality, analysis_revision, person_id, assignment, frame_index)
            \(face), 0 FROM media_asset WHERE library_root_id IN (7, 15) AND kind = 'video'
              AND faces_source_size IS NOT NULL \(spread) LIMIT ?
            """,
            arguments: [scaled(Owner.frameFaces, scale)]
        )
        shape.faces += db.changesCount
        try db.execute(sql: """
        INSERT INTO face_embedding (library_root_id, relative_path, face_index, embedding)
        SELECT library_root_id, relative_path, face_index, zeroblob(2048) FROM face
        ORDER BY library_root_id, relative_path, face_index
        """)
        // Metadata records of about 1.1 KB, three in four located in one of his 1,435 named
        // cells; a fifth read by an older parser.
        let cells = scaled(Owner.placeCells, scale)
        let language = PlaceNameLanguage(Locale.current).identifier
        try db.execute(
            sql: """
            WITH RECURSIVE n(k) AS (SELECT 0 UNION ALL SELECT k + 1 FROM n WHERE k + 1 < ?)
            INSERT INTO place_cell (cell_latitude, cell_longitude, country, town, language)
            SELECT 2000 + k / 40, 1000 + k % 40, 'Generated Country', 'Town ' || k, ? FROM n
            """,
            arguments: [cells, language]
        )
        let record = """
        SELECT a.library_root_id, a.relative_path,
               CASE a.kind WHEN 'video' THEN 'isoBMFF' WHEN 'raw' THEN 'tiff' ELSE 'heif' END,
               lower(substr(a.relative_path, -3)), 'Apple', 'iPhone 15 Pro', 4032, 3024,
               CASE WHEN a.rowid % 4 <> 0 THEN (2000 + (a.rowid % ?) / 40 + 0.5) / 50.0 END,
               CASE WHEN a.rowid % 4 <> 0 THEN (1000 + (a.rowid % ?) % 40 + 0.5) / 50.0 END,
               '{"generated":"' || substr(hex(zeroblob(520)), 1, 1000) || '"}'
        FROM media_asset AS a
        """
        try db.execute(
            sql: """
            INSERT INTO asset_metadata (library_root_id, relative_path, family, file_extension, camera_make,
                                        camera_model, pixel_width, pixel_height, primary_latitude, primary_longitude,
                                        metadata_extra_json)
            \(record) WHERE a.library_root_id <> 15
            """,
            arguments: [cells, cells]
        )
        shape.metadataRecords = db.changesCount
        try db.execute(
            sql: """
            INSERT INTO asset_metadata (library_root_id, relative_path, family, file_extension, camera_make,
                                        camera_model, pixel_width, pixel_height, primary_latitude, primary_longitude,
                                        metadata_extra_json)
            \(record) WHERE a.library_root_id = 15 ORDER BY a.rowid LIMIT ?
            """,
            arguments: [cells, cells, scaled(Owner.accountMetadataRecords, scale)]
        )
        shape.metadataRecords += db.changesCount
        try db.execute(sql: """
        UPDATE asset_metadata AS m SET extraction_revision = \(CatalogStore.currentExtractionRevisionSQL)
        WHERE m.rowid % 1000 >= \(Owner.staleMetadataPermille)
        """)
        shape.metadataStaleInLibraries = try Int.fetchOne(
            db, sql: """
            SELECT count(*) FROM asset_metadata AS m WHERE m.library_root_id IN (6, 7)
              AND COALESCE(m.extraction_revision, 0) < \(CatalogStore.currentExtractionRevisionSQL)
            """
        ) ?? 0
        // Descriptions: the first stills of the libraries and the account that can be
        // described; the rest of them are owed.
        try db.execute(
            sql: """
            INSERT INTO photo_description (library_root_id, relative_path, source, text)
            SELECT a.library_root_id, a.relative_path, \(PhotoDescriptionStorage.currentSource("a")),
                   'Two or three generated sentences about the photo, about as long as the ones the model writes for it.'
                       || ' A second sentence keeps the text near its measured length of two hundred bytes.'
            FROM media_asset AS a WHERE a.library_root_id IN (7, 15) AND \(PhotoDescriptionStorage.describableStill)
            ORDER BY a.rowid LIMIT ?
            """,
            arguments: [scaled(Owner.descriptions, scale)]
        )
        shape.descriptions = db.changesCount
        // The account's server holds library 7, not library 6.
        try db.execute(sql: "INSERT INTO immich_mirror (account_root_id, library_root_id, server_prefix) VALUES (15, 7, '/mnt/onedrive/Pictures')")
    }
}
