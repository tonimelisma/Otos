import Foundation
import GRDB
import OSLog

/// The catalog's schema, as the one baseline migration creates it.
///
/// Otos had no users when the incremental history (v3–v23) was replaced by this
/// baseline (ADR 0010), so there is no older catalog to upgrade: a catalog whose
/// migration history this build does not know is refused unopened, like any other.
/// Changes from here on are additive migrations registered after the baseline.
///
/// Statements run in order inside the baseline migration's transaction. Column order
/// within a table is the order a row reads in; nothing depends on it, but it is kept
/// stable so a schema dump stays comparable across builds.
nonisolated enum CatalogSchema {
    static let baselineMigrationIdentifier = "v1_catalog_baseline"

    /// The move witness's scan fact (ADR 0008): each file's identifier on its volume,
    /// written by every scan upsert. Rows from before the column read `NULL` until their
    /// next scan, and a `NULL` never witnesses a move.
    static let fileIdentifierMigrationIdentifier = "v2_media_asset_file_identifier"

    static let fileIdentifierStatements: [String] = [
        "ALTER TABLE media_asset ADD COLUMN file_identifier INTEGER",
        """
        CREATE INDEX idx_media_asset_file_identifier
        ON media_asset(file_identifier) WHERE file_identifier IS NOT NULL
        """,
    ]

    /// The stored loupe preview (ADR 0035): its relative path beside the thumbnail's.
    /// Library stills enriched before previews existed have neither a preview nor a
    /// rendered thumbnail, so their enrichment stamps are cleared here: the existing
    /// staleness predicate then claims them again, and re-enrichment renders both from
    /// the original — downloading it first when it is cloud-only, under the free-space
    /// floor (ENR-008). Card and camera rows are left alone; they re-enrich when next
    /// attached and changed, and are forgotten after 90 days unseen.
    static let previewPathMigrationIdentifier = "v3_media_asset_preview_path"

    static let previewPathStatements: [String] = [
        "ALTER TABLE media_asset ADD COLUMN preview_path TEXT",
        """
        UPDATE media_asset SET enriched_source_size = NULL, enriched_source_mtime = NULL
        WHERE kind = 'image'
          AND library_root_id IN (SELECT id FROM library_root WHERE kind = 'library')
        """,
    ]

    /// One current edit per photo (ADR 0036): the recipe's JSON, the revision it was saved
    /// as, and the revision the stored thumbnail and preview were rendered from. Columns
    /// on the asset row, as `media_choice` is, so every re-key, move and deletion carries
    /// the edit with the row; Move to Trash and import carry it explicitly.
    static let editRecipeMigrationIdentifier = "v4_media_asset_edit_recipe"

    static let editRecipeStatements: [String] = [
        "ALTER TABLE media_asset ADD COLUMN edit_recipe_json TEXT",
        "ALTER TABLE media_asset ADD COLUMN edit_revision INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE media_asset ADD COLUMN rendered_revision INTEGER NOT NULL DEFAULT 0",
    ]

    /// HEIF orientation from its transform properties (MediaMetadata 0.6.1). Earlier
    /// versions read orientation only from Exif, and a HEIF that records its rotation in an
    /// `irot` or `imir` property instead (Sony cameras, for one) was cataloged with no
    /// orientation, so its upright size read as its stored, unrotated one. Every library
    /// HEIF row with no orientation has its enrichment stamps cleared: the staleness
    /// predicate claims it again and re-enrichment reads its metadata anew, downloading a
    /// cloud-only original first under the free-space floor (ENR-008). An upright HEIF with
    /// no orientation tag is read again too; nothing short of its bytes tells them apart.
    /// Card and camera rows are left alone, as for v3.
    static let heifOrientationMigrationIdentifier = "v5_heif_orientation_reread"

    static let heifOrientationStatements: [String] = [
        """
        UPDATE media_asset SET enriched_source_size = NULL, enriched_source_mtime = NULL
        WHERE library_root_id IN (SELECT id FROM library_root WHERE kind = 'library')
          AND (library_root_id, relative_path) IN (
            SELECT library_root_id, relative_path FROM asset_metadata
            WHERE family = 'heif' AND orientation IS NULL
          )
        """,
    ]

    /// The MediaMetadata extraction revision each metadata record was read with (ADR 0039).
    /// Records from before the column read `NULL`: unknown, so older than any revision.
    /// `MetadataRefresher` re-reads a library row whose revision is lower than the
    /// reader's when its original is already local, and nothing is downloaded for it.
    static let extractionRevisionMigrationIdentifier = "v6_asset_metadata_extraction_revision"

    static let extractionRevisionStatements: [String] = [
        "ALTER TABLE asset_metadata ADD COLUMN extraction_revision INTEGER",
    ]

    /// MediaMetadata 0.7.1 (ADR 0039):
    /// - Revisions are per format family. The numbers v6 stored were one global
    ///   revision, so they no longer mean anything and become `NULL`, which the library
    ///   defines as 0 (read before revisions). A family the library has not changed since
    ///   then is current at 0, so only the families it fixed are re-read, from local bytes
    ///   (`MetadataRefresher`).
    /// - Format tokens take the library's file-type names (`HEIC` and `HIF` become `HEIF`,
    ///   `JPG` and `JPE` become `JPEG`, `TIF` becomes `TIFF`).
    static let familyRevisionMigrationIdentifier = "v7_family_revisions_and_file_type_names"

    static func migrateToFamilyRevisionsAndFileTypeNames(_ db: Database) throws {
        try db.execute(sql: "UPDATE asset_metadata SET extraction_revision = NULL")
        for column in ["format", "enriched_format"] {
            let tokens = try String.fetchAll(db, sql: "SELECT DISTINCT \(column) FROM media_asset WHERE \(column) IS NOT NULL")
            for token in tokens {
                guard let named = MediaFormatToken.normalize(extension: token)?.rawValue, named != token else { continue }
                try db.execute(
                    sql: "UPDATE media_asset SET \(column) = ? WHERE \(column) = ?",
                    arguments: [named, token]
                )
            }
        }
    }

    /// MediaMetadata 0.8.0 (ADR 0039): the catalog sorts by the library's capture instant.
    /// The four `ts_*_unix` columns, which `best_capture_unix` coalesced in Otos's own
    /// order (original, QuickTime creation, digitized, GPS), become one
    /// `capture_instant_unix` chosen by `CaptureTimestamps.instantPrecedence` (original,
    /// digitized, QuickTime creation and content-create, GPS). `best_capture_unix` falls
    /// back from it to the file's creation and modification dates, as before, and becomes
    /// a virtual column: SQLite cannot add a stored one, and the indexes over it hold the
    /// value either way.
    ///
    /// The instant is filled first from the old columns in the library's order, then from
    /// each row's stored timestamp records, which also hold the roles the old columns
    /// never did. A record that cannot be decoded keeps the first value and is logged:
    /// the catalog still opens, and the row is as well ordered as before.
    static let captureInstantMigrationIdentifier = "v8_media_asset_capture_instant"

    static func migrateToCaptureInstant(_ db: Database) throws {
        try db.execute(sql: "ALTER TABLE media_asset ADD COLUMN capture_instant_unix DOUBLE")
        try db.execute(sql: """
        UPDATE media_asset SET capture_instant_unix = COALESCE(
            ts_original_unix, ts_digitized_unix, ts_quicktime_creation_unix, ts_gps_unix
        )
        """)
        let rows = try Row.fetchAll(db, sql: """
        SELECT library_root_id, relative_path, metadata_extra_json FROM asset_metadata
        WHERE metadata_extra_json IS NOT NULL
        """)
        var undecodable = 0
        for row in rows {
            let json: String = row["metadata_extra_json"]
            let metadata: AssetMetadata
            do {
                metadata = try CatalogStore.decodeMetadataExtraJSON(json)
            } catch {
                undecodable += 1
                continue
            }
            try db.execute(
                sql: "UPDATE media_asset SET capture_instant_unix = ? WHERE library_root_id = ? AND relative_path = ?",
                arguments: [
                    metadata.captureInstant?.timeIntervalSince1970,
                    row["library_root_id"] as Int64,
                    row["relative_path"] as String,
                ]
            )
        }
        if undecodable > 0 {
            OtosLog.persistence.errorOperation("catalog.migration.captureInstant", phase: "undecodable", fields: [
                "count": "\(undecodable)",
            ])
        }
        // Every index over the date column — the sort orders and enrichment's priority —
        // goes while the column is rebuilt and comes back from its own definition.
        let indexes = try Row.fetchAll(db, sql: """
        SELECT name, sql FROM sqlite_master
        WHERE type = 'index' AND tbl_name = 'media_asset' AND sql LIKE '%best_capture_unix%'
        """)
        for index in indexes {
            try db.execute(sql: "DROP INDEX \(index["name"] as String)")
        }
        try db.execute(sql: "ALTER TABLE media_asset DROP COLUMN best_capture_unix")
        for column in ["ts_original_unix", "ts_quicktime_creation_unix", "ts_digitized_unix", "ts_gps_unix"] {
            try db.execute(sql: "ALTER TABLE media_asset DROP COLUMN \(column)")
        }
        try db.execute(sql: """
        ALTER TABLE media_asset ADD COLUMN best_capture_unix DOUBLE GENERATED ALWAYS AS (
            COALESCE(capture_instant_unix, created_at_unix, content_modified_at_unix)
        ) VIRTUAL
        """)
        for index in indexes {
            try db.execute(sql: index["sql"] as String)
        }
    }

    /// MediaMetadata 0.8.2 (ADR 0041): Apple's content identifier, which a Live Photo's
    /// still and motion movie share, stored as the library reports it. `parent_path` is the
    /// folder part of `relative_path` (`a/b/` for `a/b/c.heic`, empty at the root), so the
    /// pair rule (`LivePhotoSQL`) can ask for one folder through one index.
    ///
    /// Records read before 0.8.2 lack the field, which raises no extraction revision. Their
    /// families' revisions are cleared, as v7 did, so `MetadataRefresher` re-reads them from
    /// local bytes; a cloud-only original is not downloaded for it (ADR 0039).
    static let contentIdentifierMigrationIdentifier = "v9_media_asset_content_identifier"

    static let contentIdentifierStatements: [String] = [
        "ALTER TABLE media_asset ADD COLUMN content_identifier TEXT",
        """
        ALTER TABLE media_asset ADD COLUMN parent_path TEXT GENERATED ALWAYS AS (
            rtrim(relative_path, replace(relative_path, '/', ''))
        ) VIRTUAL
        """,
        """
        CREATE INDEX idx_media_asset_content_identifier
        ON media_asset(library_root_id, content_identifier, parent_path)
        WHERE content_identifier IS NOT NULL
        """,
        "UPDATE asset_metadata SET extraction_revision = NULL WHERE family IN ('heif', 'jpeg', 'isoBMFF')",
    ]

    /// The file path where the system Trash put a moved item's file (ADR 0022). A row whose file the queue
    /// moved to the Trash stays in the catalog, hidden by its pending mark, until the file is
    /// proven gone from the Trash: an item in the Trash is not proven deleted (ADR 0008), so
    /// everything Otos holds for it is kept, and Finder's Put Back — or undo — returns the
    /// file to the row's own path, where the next scan of that path shows it again.
    static let trashPathMigrationIdentifier = "v10_media_asset_trash_path"

    static let trashPathStatements: [String] = [
        "ALTER TABLE media_asset ADD COLUMN trash_path TEXT",
    ]

    /// Duplicates (ADR 0042). "Keep All Copies" is remembered per pair of paths, as overlay
    /// on both copies: an Otos move carries it (`ON UPDATE CASCADE`), and a copy's proven
    /// deletion or its library's removal ends it (`ON DELETE CASCADE`). The digest index
    /// lets the duplicates read group by content without a full scan per pass.
    static let duplicatesMigrationIdentifier = "v11_duplicate_kept_pair"

    static let duplicatesStatements: [String] = [
        """
        CREATE TABLE duplicate_kept_pair (
            first_root_id INTEGER NOT NULL,
            first_path TEXT NOT NULL,
            second_root_id INTEGER NOT NULL,
            second_path TEXT NOT NULL,
            PRIMARY KEY (first_root_id, first_path, second_root_id, second_path),
            FOREIGN KEY (first_root_id, first_path)
                REFERENCES media_asset(library_root_id, relative_path)
                ON UPDATE CASCADE ON DELETE CASCADE,
            FOREIGN KEY (second_root_id, second_path)
                REFERENCES media_asset(library_root_id, relative_path)
                ON UPDATE CASCADE ON DELETE CASCADE
        )
        """,
        """
        CREATE INDEX idx_duplicate_kept_pair_second
        ON duplicate_kept_pair(second_root_id, second_path)
        """,
        """
        CREATE INDEX idx_media_asset_content_hash
        ON media_asset(content_hash_xxh3_128) WHERE content_hash_xxh3_128 IS NOT NULL
        """,
    ]

    /// Same photo (ADR 0042). A still's render signature — a 64-bit difference hash and a
    /// 32 × 32 grayscale render of its stored thumbnail — with the thumbnail it was read
    /// from (`render_signature_source`), so a re-rendered thumbnail makes it stale without
    /// any write site having to know. MediaMetadata 0.9 adds capture sub-seconds and Apple's
    /// burst identifier, new fields its families' revisions do not announce; the families
    /// that carry EXIF are cleared, as v9 did, so `MetadataRefresher` re-reads them from
    /// local bytes and a cloud-only original is not downloaded for it (ADR 0039).
    static let renderSignatureMigrationIdentifier = "v12_render_signature"

    static let renderSignatureStatements: [String] = [
        "ALTER TABLE media_asset ADD COLUMN render_dhash INTEGER",
        "ALTER TABLE media_asset ADD COLUMN render_gray BLOB",
        "ALTER TABLE media_asset ADD COLUMN render_signature_source TEXT",
        "UPDATE asset_metadata SET extraction_revision = NULL WHERE family IN ('heif', 'jpeg', 'tiff')",
    ]

    /// One freshness stamp per product (ADR 0009): metadata, the rendering (thumbnail and
    /// preview, made from one development, ADR 0035), and the digest each name the
    /// `(size, mtime)` they were made from, so each is stale on its own. The old
    /// enrichment stamp certified metadata and rendering together; it becomes the metadata
    /// stamp, and the rendering stamp starts as its copy. A card's or camera's still or RAW
    /// without a preview was given QuickLook's or the camera's embedded thumbnail, not a
    /// rendering, so it starts with none and is rendered again. The claim indexes are
    /// created again from the current predicates.
    static let productStampsMigrationIdentifier = "v13_product_stamps"

    static var productStampsStatements: [String] {
        [
            "DROP INDEX \(EnrichmentClaimGateway.broadGlobalIndexName)",
            "DROP INDEX \(EnrichmentClaimGateway.broadRootIndexName)",
            "DROP INDEX \(EnrichmentClaimGateway.metadataOnlyGlobalIndexName)",
            "DROP INDEX \(EnrichmentClaimGateway.metadataOnlyRootIndexName)",
            "ALTER TABLE media_asset RENAME COLUMN enriched_source_size TO metadata_source_size",
            "ALTER TABLE media_asset RENAME COLUMN enriched_source_mtime TO metadata_source_mtime",
            "ALTER TABLE media_asset ADD COLUMN rendered_source_size INTEGER",
            "ALTER TABLE media_asset ADD COLUMN rendered_source_mtime INTEGER",
            """
            UPDATE media_asset
            SET rendered_source_size = metadata_source_size, rendered_source_mtime = metadata_source_mtime
            WHERE NOT (
                library_root_id IN (SELECT id FROM library_root WHERE kind <> 'library')
                AND enriched_kind IN ('image', 'raw')
                AND preview_path IS NULL
            )
            """,
            claimIndex(EnrichmentClaimGateway.broadGlobalIndexName, global: true, predicate: xxh3ProductsClaimPredicate, orderColumn: "best_capture_unix"),
            claimIndex(EnrichmentClaimGateway.broadRootIndexName, global: false, predicate: xxh3ProductsClaimPredicate, orderColumn: "best_capture_unix"),
            claimIndex(EnrichmentClaimGateway.metadataOnlyGlobalIndexName, global: true, claim: .metadata, orderColumn: "best_capture_unix"),
            claimIndex(EnrichmentClaimGateway.metadataOnlyRootIndexName, global: false, claim: .metadata, orderColumn: "best_capture_unix"),
        ]
    }

    /// Whether a card's or camera's retained row has been seen by the source's current
    /// attachment (ADR 0013). Attach sets it on every row the source held; each scan
    /// upsert that observes the file clears it, so the grid fills as the card is read
    /// instead of showing what the card held last time; the completed scan deletes what
    /// it never saw. Detach and launch clear it: with no attachment, nothing is awaited,
    /// and an offline card shows the rows it last held. Every user-facing read, import
    /// planning and enrichment claims exclude a row while it is set.
    static let awaitingPresenceMigrationIdentifier = "v14_media_asset_awaiting_presence"

    static let awaitingPresenceStatements: [String] = [
        "ALTER TABLE media_asset ADD COLUMN awaiting_presence INTEGER NOT NULL DEFAULT 0",
        // Few rows are ever set, and every write that clears them in bulk — detach, launch
        // — reads only those through this index rather than the whole table.
        """
        CREATE INDEX idx_media_asset_awaiting_presence
        ON media_asset(library_root_id) WHERE awaiting_presence <> 0
        """,
    ]

    /// The server an Immich account's root reads from, as Settings shows it (ADR 0046 §2).
    /// Null for every other kind; the session token is never stored here.
    static let remoteBaseURLMigrationIdentifier = "v15_library_root_remote_base_url"

    static let remoteBaseURLStatements: [String] = [
        "ALTER TABLE library_root ADD COLUMN remote_base_url TEXT",
    ]

    /// An item its source holds but hides: an Immich asset in Immich's trash (ADR 0046 §5).
    /// The row and its overlay stay, as they do for Otos's own Trash (ADR 0022), and every
    /// user-facing read leaves it out; the source showing it again shows it again.
    static let hiddenBySourceMigrationIdentifier = "v16_media_asset_hidden_by_source"

    static let hiddenBySourceStatements: [String] = [
        "ALTER TABLE media_asset ADD COLUMN hidden_by_source INTEGER NOT NULL DEFAULT 0",
    ]

    /// The `(size, mtime)` a source's own thumbnail and preview were made for (ADR 0035's
    /// source-provisional products, ADR 0046 §7): a row whose file has changed since is
    /// owed newer ones. Separate from the rendering stamp, which only Otos's rendering
    /// writes.
    static let sourceProductsMigrationIdentifier = "v17_media_asset_source_products"

    static let sourceProductsStatements: [String] = [
        "ALTER TABLE media_asset ADD COLUMN source_products_size INTEGER",
        "ALTER TABLE media_asset ADD COLUMN source_products_mtime INTEGER",
    ]

    /// Faces (ADR 0047). Each face `FaceAnalyzer` reads is a row of `face`, overlay on its
    /// asset, so a move carries it (`ON UPDATE CASCADE`, the move witness of ADR 0034
    /// included) and the asset's proven deletion or its library's removal ends it
    /// (`ON DELETE CASCADE`). The faces stamp names the `(size, mtime)` they were read for
    /// (ADR 0009); a new reading replaces every face of the asset. This migration also made a
    /// claim index pair for a library's rows that owed faces, which `v30_faces_from_preview`
    /// drops.
    ///
    /// A face row holds the box and the five alignment points as fractions of the upright
    /// photo (top-left origin), Vision's capture quality, the analysis revision that read it
    /// (`FaceAnalyzer.revision`), and the embedding as 512 little-endian Float32 values.
    static let facesMigrationIdentifier = "v18_faces"

    static var facesStatements: [String] {
        [
            "ALTER TABLE media_asset ADD COLUMN faces_source_size INTEGER",
            "ALTER TABLE media_asset ADD COLUMN faces_source_mtime INTEGER",
            """
            CREATE TABLE face (
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
                embedding BLOB NOT NULL,
                PRIMARY KEY (library_root_id, relative_path, face_index),
                FOREIGN KEY (library_root_id, relative_path)
                    REFERENCES media_asset(library_root_id, relative_path)
                    ON UPDATE CASCADE ON DELETE CASCADE
            )
            """,
            claimIndex(libraryGlobalIndexName, global: true, predicate: libraryClaimPredicate, orderColumn: "best_capture_unix"),
            claimIndex(libraryRootIndexName, global: false, predicate: libraryClaimPredicate, orderColumn: "best_capture_unix"),
        ]
    }

    /// The products claim's text from v13 until v60 made the digest SHA-1: every claim
    /// index a migration before v60 makes names the XXH3 column, so it is frozen here.
    static var xxh3ProductsClaimPredicate: String {
        """
        \(EnrichmentClaimGateway.metadataStalenessSQLPredicate())
           OR \(EnrichmentClaimGateway.renderingStalenessSQLPredicate())
           OR content_hash_xxh3_128 IS NULL
           OR length(content_hash_xxh3_128) <> 16
           OR content_hash_source_size IS NULL
           OR content_hash_source_mtime IS NULL
           OR COALESCE(byte_size, -1) <> COALESCE(content_hash_source_size, -1)
           OR CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER)
              <> COALESCE(content_hash_source_mtime, -1)
        """
    }

    /// The claim index pair `v18_faces` made for a library's rows, and the products they
    /// owed: every product, faces included. `v30_faces_from_preview` drops them.
    private static let libraryGlobalIndexName = "idx_media_asset_needs_enrichment_global_library"
    private static let libraryRootIndexName = "idx_media_asset_needs_enrichment_root_library"
    private static var libraryClaimPredicate: String {
        """
        \(xxh3ProductsClaimPredicate)
           OR faces_source_size IS NULL
           OR faces_source_mtime IS NULL
           OR COALESCE(byte_size, -1) <> COALESCE(faces_source_size, -1)
           OR CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER)
              <> COALESCE(faces_source_mtime, -1)
        """
    }

    /// People (ADR 0047). What the user decides about faces is overlay, and it outlives a
    /// new reading of the same photo: `writeFaces` carries each act to the new face it
    /// overlaps.
    /// - `person`: a name (optional until the user gives one) and an optional birthday, as
    ///   `YYYY-MM-DD`.
    /// - `face.person_id`: the person the user confirmed the face as; removing the person
    ///   returns the face to unnamed (`ON DELETE SET NULL`).
    /// - `face.is_not_face`: the user said this detection is not a face. Carried to a new
    ///   reading of the same source; a changed file is read afresh.
    /// - `face.is_ignored`: the face belongs to a group the user ignored.
    /// - `face_rejection`: "not this person", so the suggestion never returns; removing the
    ///   person forgets them.
    static let peopleMigrationIdentifier = "v19_people"

    static let peopleStatements: [String] = [
        """
        CREATE TABLE person (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT,
            birthday TEXT
        )
        """,
        "ALTER TABLE face ADD COLUMN person_id INTEGER REFERENCES person(id) ON DELETE SET NULL",
        "ALTER TABLE face ADD COLUMN is_not_face INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE face ADD COLUMN is_ignored INTEGER NOT NULL DEFAULT 0",
        "CREATE INDEX idx_face_person ON face(person_id) WHERE person_id IS NOT NULL",
        """
        CREATE TABLE face_rejection (
            library_root_id INTEGER NOT NULL,
            relative_path TEXT NOT NULL,
            face_index INTEGER NOT NULL,
            person_id INTEGER NOT NULL REFERENCES person(id) ON DELETE CASCADE,
            PRIMARY KEY (library_root_id, relative_path, face_index, person_id),
            FOREIGN KEY (library_root_id, relative_path, face_index)
                REFERENCES face(library_root_id, relative_path, face_index)
                ON UPDATE CASCADE ON DELETE CASCADE
        )
        """,
        "CREATE INDEX idx_face_rejection_person ON face_rejection(person_id)",
    ]

    /// The source's own ID for the item a row is: an Immich asset's ID (ADR 0046 §2). A Live
    /// Photo's motion part lives in its still's folder, so a folder names only its still;
    /// every request Otos makes for an item, and every size and deletion the source reports
    /// for one, finds its row by this. Null for every kind that reads its files in place
    /// or names them by path. Existing account rows are all stills, named by their folder.
    static let sourceItemIDMigrationIdentifier = "v20_media_asset_source_item_id"

    static let sourceItemIDStatements: [String] = [
        "ALTER TABLE media_asset ADD COLUMN source_item_id TEXT",
        """
        UPDATE media_asset SET source_item_id = substr(relative_path, 1, instr(relative_path, '/') - 1)
        WHERE instr(relative_path, '/') > 1
          AND library_root_id IN (
              SELECT id FROM library_root WHERE kind = '\(LibraryRootKind.immichAccount.rawValue)'
          )
        """,
        """
        CREATE INDEX idx_media_asset_source_item ON media_asset(library_root_id, source_item_id)
        WHERE source_item_id IS NOT NULL
        """,
    ]

    /// Search embeddings (ADR 0048): one per asset, read from its stored thumbnail by
    /// `PhotoSearchIndex`, overlay on the asset — a move carries it (`ON UPDATE CASCADE`, the
    /// move witness of ADR 0034 included) and the asset's proven deletion or its root's
    /// removal ends it (`ON DELETE CASCADE`). `source` names the thumbnail and model revision
    /// it was read from (`SearchEmbeddingStorage.currentSource`); `embedding` is 768
    /// little-endian Float32 values, or NULL for a thumbnail that did not decode.
    static let searchEmbeddingsMigrationIdentifier = "v21_search_embeddings"

    static let searchEmbeddingsStatements: [String] = [
        """
        CREATE TABLE search_embedding (
            library_root_id INTEGER NOT NULL,
            relative_path TEXT NOT NULL,
            source TEXT NOT NULL,
            embedding BLOB,
            PRIMARY KEY (library_root_id, relative_path),
            FOREIGN KEY (library_root_id, relative_path)
                REFERENCES media_asset(library_root_id, relative_path)
                ON UPDATE CASCADE ON DELETE CASCADE
        )
        """,
    ]

    /// Search reads more of each picture (ADR 0048):
    /// - `search_embedding.labels`: the thumbnail's scene labels, read with its embedding
    ///   (`SearchEmbeddingStorage`); `SearchEmbedding.revision` 2 makes every row owed again.
    /// - `search_text`: the text Vision recognised in the asset's stored preview, overlay on
    ///   the asset like an embedding (cascade on move and deletion). `source` names the preview
    ///   and the recognition revision it was read from (`SearchTextStorage.currentSource`);
    ///   `text` is the recognised lines, empty when the preview holds none.
    static let searchTextMigrationIdentifier = "v22_search_labels_and_text"

    static let searchTextStatements: [String] = [
        "ALTER TABLE search_embedding ADD COLUMN labels TEXT",
        """
        CREATE TABLE search_text (
            library_root_id INTEGER NOT NULL,
            relative_path TEXT NOT NULL,
            source TEXT NOT NULL,
            text TEXT NOT NULL,
            PRIMARY KEY (library_root_id, relative_path),
            FOREIGN KEY (library_root_id, relative_path)
                REFERENCES media_asset(library_root_id, relative_path)
                ON UPDATE CASCADE ON DELETE CASCADE
        )
        """,
    ]

    /// The timeline runs on local capture time (ADR 0039): `best_capture_local` replaces
    /// `best_capture_unix`. It is the library's capture wall clock read as if it were UTC
    /// (`CaptureLocalTime`), so an item is ordered by, and sits on, the day it was taken on
    /// the clock where it was taken, whatever zone the Mac is in. An item whose file records
    /// no wall clock is placed by its absolute time — capture instant, else creation, else
    /// modification date — read with `assumed_utc_offset_seconds`, the offset of the Mac's
    /// zone when Otos recorded that time (`CaptureLocalTime.assumedUTCOffset`). This
    /// migration makes that assumption for every existing row in the zone it runs in.
    ///
    /// Every index over the old column is rebuilt, under its own name, over the new one.
    static let captureLocalTimeMigrationIdentifier = "v23_media_asset_capture_local_time"

    /// Re-reads the faces of every RAW stamped as read with none. Before the renderer told
    /// Image I/O a still's type, a Sony ARW's bytes read as a TIFF with no image, the upright
    /// original was unreadable, and the row was stamped with no faces (ENR-022), so no ARW
    /// in a library was ever read for faces. Clearing the stamp of a RAW that has no face
    /// row makes it owe faces again; a RAW with faces was read and keeps them.
    static let rawFacesMigrationIdentifier = "v24_raw_faces_reread"

    static var rawFacesStatements: [String] {
        [
            """
            UPDATE media_asset SET faces_source_size = NULL, faces_source_mtime = NULL
            WHERE best_kind = 'raw'
              AND faces_source_size IS NOT NULL
              AND NOT EXISTS (
                  SELECT 1 FROM face
                  WHERE face.library_root_id = media_asset.library_root_id
                    AND face.relative_path = media_asset.relative_path
              )
            """,
        ]
    }

    /// The decoder a still could not be decoded by (ENR-029). When the renderer cannot
    /// decode a still, its rendering falls back to QuickLook's thumbnail and it is stamped
    /// with no faces; `undecodable_by` names the decoder that said so
    /// (`ImageRenderer.decoderIdentity`), and is NULL once a decoder read it. A row
    /// rendered before this column with a stamp and no preview is such a fallback, so it
    /// is marked as undecodable by Otos's first decoder and tried again once.
    static let decodeVerdictMigrationIdentifier = "v25_media_asset_undecodable_by"

    static var decodeVerdictStatements: [String] {
        [
            "ALTER TABLE media_asset ADD COLUMN undecodable_by TEXT",
            """
            UPDATE media_asset SET undecodable_by = 'otos1'
            WHERE best_kind IN ('image', 'raw')
              AND rendered_source_size IS NOT NULL
              AND preview_path IS NULL
            """,
        ]
    }

    /// Faces auto-tagged (ADR 0047): every face has a person Otos guessed or the user gave,
    /// and named and unnamed people are one kind.
    /// - `face.assignment`: whose word `person_id` is (`FaceAssignmentColumn`): none, Otos's
    ///   guess, a seed (a face a person was first found from), the user's, or held (the user
    ///   removed the name, so only the user gives it a person again). A confirmed face is the
    ///   user's; a face of an ignored group is held.
    /// - `face.likeness`: how like its person the face is, which the likeness sort orders by.
    /// - `face.is_feature`: the person's feature photo, at most one face per person; it moves
    ///   and goes with its face.
    /// - `person.is_hidden`, `person.is_favorite`: shown only in the People gallery, and first.
    static let autoTaggedPeopleMigrationIdentifier = "v26_people_auto_tagged"

    static var autoTaggedPeopleStatements: [String] {
        [
            "ALTER TABLE face ADD COLUMN assignment INTEGER NOT NULL DEFAULT 0",
            "ALTER TABLE face ADD COLUMN likeness REAL",
            "ALTER TABLE face ADD COLUMN is_feature INTEGER NOT NULL DEFAULT 0",
            "UPDATE face SET assignment = \(FaceAssignmentColumn.user.rawValue) WHERE person_id IS NOT NULL",
            "UPDATE face SET assignment = \(FaceAssignmentColumn.held.rawValue) WHERE person_id IS NULL AND is_ignored = 1",
            "ALTER TABLE face DROP COLUMN is_ignored",
            "CREATE UNIQUE INDEX idx_face_feature ON face(person_id) WHERE is_feature = 1",
            "ALTER TABLE person ADD COLUMN is_hidden INTEGER NOT NULL DEFAULT 0",
            "ALTER TABLE person ADD COLUMN is_favorite INTEGER NOT NULL DEFAULT 0",
        ]
    }

    /// Place names (ADR 0040): the country and town Apple Maps names for each cell of the map
    /// a located photo falls in (`PlaceCell`), read once per cell by `PlaceNameReader` and
    /// shared by every photo in it. A cell Maps names nothing for (open sea) is stored with no
    /// names, so it is not asked again; `locale` is the language the names are in, and a cell
    /// named in another language than the Mac's is asked again.
    static let placeNamesMigrationIdentifier = "v27_place_names"

    static var placeNamesStatements: [String] {
        [
            """
            CREATE TABLE place_cell (
                cell_latitude INTEGER NOT NULL,
                cell_longitude INTEGER NOT NULL,
                country TEXT,
                town TEXT,
                locale TEXT NOT NULL,
                PRIMARY KEY (cell_latitude, cell_longitude)
            )
            """,
            "CREATE INDEX idx_place_cell_names ON place_cell(country, town)",
        ]
    }

    /// The face a person is shown by is their key photo, as Photos calls it (ADR 0047):
    /// v26's `face.is_feature` and its index take that name. Nothing else changes.
    static let keyPhotoMigrationIdentifier = "v28_face_key_photo"

    static var keyPhotoStatements: [String] {
        [
            "DROP INDEX idx_face_feature",
            "ALTER TABLE face RENAME COLUMN is_feature TO is_key_photo",
            "CREATE UNIQUE INDEX idx_face_key_photo ON face(person_id) WHERE is_key_photo = 1",
        ]
    }

    /// Faces analysis revision 2 (ADR 0047) admits a face only when Vision's classifier sees
    /// a person around it. It reads the same detections with the same model and only turns
    /// more of them away, so a photo stamped with no face has none under it either. A photo
    /// with faces read under an earlier revision owes faces again: its stamp is cleared, and
    /// its re-reading carries each kept face's person over by its box.
    static let personAdmissionMigrationIdentifier = "v29_faces_person_admission"

    static var personAdmissionStatements: [String] {
        [
            """
            UPDATE media_asset SET faces_source_size = NULL, faces_source_mtime = NULL
            WHERE faces_source_size IS NOT NULL
              AND EXISTS (
                  SELECT 1 FROM face
                  WHERE face.library_root_id = media_asset.library_root_id
                    AND face.relative_path = media_asset.relative_path
                    AND face.analysis_revision < 2
              )
            """,
        ]
    }

    /// Faces are read from each still's stored preview, never from its original (ADR 0047,
    /// analysis revision 3): enrichment no longer owes them, so the library claim's index
    /// pair goes, and the faces stamp now names the source the preview was made from. Every
    /// stamp is cleared, so every still with a preview is read again from it, and each
    /// re-reading carries what the user said about a face over by its box.
    static let facesFromPreviewMigrationIdentifier = "v30_faces_from_preview"

    static var facesFromPreviewStatements: [String] {
        [
            "DROP INDEX \(libraryGlobalIndexName)",
            "DROP INDEX \(libraryRootIndexName)",
            "UPDATE media_asset SET faces_source_size = NULL, faces_source_mtime = NULL",
        ]
    }

    /// The Info pane shows what Otos recognised in a photo (ADR 0048, ADR 0050):
    /// - `search_embedding.confident_labels`: the scene labels that pass Vision's
    ///   high-precision test, most confident first; `SearchEmbedding.revision` 3 makes every
    ///   embedding owed again, so the column fills as they are read.
    /// - `search_text` is rebuilt with `lines`, each recognised line with its confidence as
    ///   JSON (`SearchTextStorage`), in place of the joined `text`: the accurate level's
    ///   readings (`SearchTextReading.revision` 2) replace every fast-level one, so no old row
    ///   would be current.
    static let inThisPhotoMigrationIdentifier = "v31_in_this_photo"

    static var inThisPhotoStatements: [String] {
        [
            "ALTER TABLE search_embedding ADD COLUMN confident_labels TEXT",
            "DROP TABLE search_text",
            """
            CREATE TABLE search_text (
                library_root_id INTEGER NOT NULL,
                relative_path TEXT NOT NULL,
                source TEXT NOT NULL,
                lines TEXT NOT NULL,
                PRIMARY KEY (library_root_id, relative_path),
                FOREIGN KEY (library_root_id, relative_path)
                    REFERENCES media_asset(library_root_id, relative_path)
                    ON UPDATE CASCADE ON DELETE CASCADE
            )
            """,
        ]
    }

    /// When the user made a file its stack's key (Make Key Photo, ADR 0052), as Unix
    /// milliseconds; NULL when never. The stack itself is derived from names and kinds and
    /// stored nowhere; this is the one fact about it the user authors, kept on the member it
    /// names so a move carries it and a deletion purges it (ADR 0008). The latest choice among
    /// a stack's members wins.
    static let stackKeyMigrationIdentifier = "v32_stack_key_chosen"

    static let stackKeyStatements: [String] = [
        "ALTER TABLE media_asset ADD COLUMN stack_key_chosen_at_unix_ms INTEGER",
    ]

    /// The stack candidates' read (`PhotoStackSQL`, ADR 0052) finds the folders holding a RAW
    /// and then each one's stills by kind and folder. Without this index each folder was a scan
    /// of its whole root: on the owner's library, 10,917 RAW folders over 166,528 rows held the
    /// window's first publication for minutes. With it the read measured 65 ms there.
    static let stackCandidateIndexMigrationIdentifier = "v33_stack_candidate_index"

    static let stackCandidateIndexStatements: [String] = [
        """
        CREATE INDEX idx_media_asset_stack_candidate
        ON media_asset(library_root_id, best_kind, parent_path)
        """,
    ]

    /// When an Immich account's sync last applied its server's stream to its end (ADR 0046
    /// §6), as Unix seconds; NULL until its first complete pass. What Settings and the
    /// sidebar say about the account when its server does not answer.
    static let lastSyncedMigrationIdentifier = "v34_library_root_last_synced"

    static let lastSyncedStatements: [String] = [
        "ALTER TABLE library_root ADD COLUMN last_synced_at DOUBLE",
    ]

    /// A library's videos are read for faces from six of their frames (ADR 0047,
    /// `VideoFaceReader`), by enrichment, in the same read as their other products:
    /// - `media_asset.face_frames_path`: a video's stored face frames, the sampled frames its
    ///   faces were kept from, as the images of one HEIC in the derived-image directory
    ///   (`ThumbnailStore.faceFramesRelativeName`); a derived image like the preview, deleted
    ///   and moved with it. NULL for a still and for a video with no face.
    /// - `face.frame_index`: which image of that file a video's face was read in, and so the
    ///   one its tile is cut from; NULL for a still's face, read from its preview.
    /// - The library claim's index pair, over every product a library's row owes, a video's
    ///   faces included. Its text is frozen here, since `INDEXED BY` matches by text; a
    ///   contract test holds `EnrichmentClaimGateway.stalenessSQLPredicate(.library)` to it.
    ///
    /// Every video's faces stamp is NULL (the preview reader never reads a video), so every
    /// library video owes its faces once.
    static let videoFacesMigrationIdentifier = "v35_video_faces"

    static let videoFacesClaimPredicate = """
    metadata_source_size IS NULL
       OR metadata_source_mtime IS NULL
       OR COALESCE(byte_size, -1) <> COALESCE(metadata_source_size, -1)
       OR CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER)
          <> COALESCE(metadata_source_mtime, -1)
       OR rendered_source_size IS NULL
       OR rendered_source_mtime IS NULL
       OR COALESCE(byte_size, -1) <> COALESCE(rendered_source_size, -1)
       OR CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER)
          <> COALESCE(rendered_source_mtime, -1)
       OR content_hash_xxh3_128 IS NULL
       OR length(content_hash_xxh3_128) <> 16
       OR content_hash_source_size IS NULL
       OR content_hash_source_mtime IS NULL
       OR COALESCE(byte_size, -1) <> COALESCE(content_hash_source_size, -1)
       OR CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER)
          <> COALESCE(content_hash_source_mtime, -1)
       OR (best_kind = 'video' AND (faces_source_size IS NULL
       OR faces_source_mtime IS NULL
       OR COALESCE(byte_size, -1) <> COALESCE(faces_source_size, -1)
       OR CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER)
          <> COALESCE(faces_source_mtime, -1)))
    """

    static var videoFacesStatements: [String] {
        [
            "ALTER TABLE media_asset ADD COLUMN face_frames_path TEXT",
            "ALTER TABLE face ADD COLUMN frame_index INTEGER",
            claimIndex(
                EnrichmentClaimGateway.libraryGlobalIndexName, global: true,
                predicate: videoFacesClaimPredicate, orderColumn: "best_capture_local"
            ),
            claimIndex(
                EnrichmentClaimGateway.libraryRootIndexName, global: false,
                predicate: videoFacesClaimPredicate, orderColumn: "best_capture_local"
            ),
        ]
    }

    /// Every stored name key, made again from its row's path (ARC-056). A key is the path's
    /// `FilesystemNameKey` under its root's case capability; catalogs from before every path
    /// write carried its key hold rows with an empty key, or the key of a path a
    /// reorganization moved them from, which a scan would match to an unrelated file. The key
    /// needs Unicode normalization SQLite does not have, so it is made in Swift.
    static let pathKeysMigrationIdentifier = "v36_path_keys"

    static func recomputePathKeys(db: Database) throws {
        let roots = try Row.fetchAll(db, sql: "SELECT id, case_sensitive_names FROM library_root")
        for root in roots {
            let rootID: Int64 = root["id"]
            let capabilities = VolumeNamespaceCapabilities(storedCaseSensitiveColumn: root["case_sensitive_names"])
            for table in ["media_asset", "media_companion"] {
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT relative_path, relative_path_key FROM \(table) WHERE library_root_id = ?",
                    arguments: [rootID]
                )
                for row in rows {
                    let path: String = row[0]
                    let stored: String = row[1]
                    let key = FilesystemNamespaceSemantics.nameKey(
                        relativePath: MediaRelativePath(rawValue: path),
                        capabilities: capabilities
                    ).rawValue
                    guard key != stored else { continue }
                    try db.execute(
                        sql: "UPDATE \(table) SET relative_path_key = ? WHERE library_root_id = ? AND relative_path = ?",
                        arguments: [key, rootID, path]
                    )
                }
            }
        }
    }

    /// iPhone bursts (ADR 0052):
    /// - `media_asset.burst_identifier`: Apple's burst identifier as MediaMetadata reads it,
    ///   written with each metadata record like `content_identifier`, and filled here from
    ///   the records already stored.
    /// - `media_asset.burst_key_chosen_at_unix_ms`: when the user made this file its burst's
    ///   key frame (Make Key Photo), apart from a pair's choice so neither clears the other.
    /// - `idx_media_asset_burst`: the candidates' read of every root's burst stills.
    static let burstMigrationIdentifier = "v37_bursts"

    /// A stored record's burst identifier; a record that is not valid JSON has none, so one
    /// damaged record never fails the migration.
    private static func burstIdentifierSQL(_ table: String) -> String {
        """
        CASE WHEN json_valid(\(table).metadata_extra_json)
            THEN json_extract(\(table).metadata_extra_json, '$.burstIdentifier') END
        """
    }

    static let burstStatements: [String] = [
        "ALTER TABLE media_asset ADD COLUMN burst_identifier TEXT",
        "ALTER TABLE media_asset ADD COLUMN burst_key_chosen_at_unix_ms INTEGER",
        """
        UPDATE media_asset SET burst_identifier = (
            SELECT \(burstIdentifierSQL("metadata")) FROM asset_metadata AS metadata
            WHERE metadata.library_root_id = media_asset.library_root_id
              AND metadata.relative_path = media_asset.relative_path
        )
        WHERE (library_root_id, relative_path) IN (
            SELECT library_root_id, relative_path FROM asset_metadata AS metadata
            WHERE \(burstIdentifierSQL("metadata")) IS NOT NULL
        )
        """,
        """
        CREATE INDEX idx_media_asset_burst
        ON media_asset(library_root_id, burst_identifier) WHERE burst_identifier IS NOT NULL
        """,
    ]

    /// On This Day picks (ADR 0049): `idx_search_embedding_left_out` held just the rows whose
    /// confident labels leave a photo out of On This Day (`OnThisDayPicks`); v52 drops it.
    static let leftOutIndexMigrationIdentifier = "v38_on_this_day_left_out"

    static var leftOutIndexStatements: [String] {
        [
            """
            CREATE INDEX idx_search_embedding_left_out
            ON search_embedding(library_root_id, relative_path) WHERE \(OnThisDayPicks.leftOutLabelSQL)
            """,
        ]
    }

    /// `media_asset.source_products_absent`: the source has said it holds no thumbnail or
    /// preview of the row (ADR 0046 §7): an Immich asset listed without a thumbhash, which
    /// Immich writes only once it has made the asset's previews (and never for a hidden
    /// Live Photo motion part), or one whose preview request it answered with a refusal.
    /// Such a row is not asked for its source's images until a later listing says the
    /// source has them.
    static let sourceProductsAbsentMigrationIdentifier = "v39_source_products_absent"

    static let sourceProductsAbsentStatements: [String] = [
        "ALTER TABLE media_asset ADD COLUMN source_products_absent INTEGER NOT NULL DEFAULT 0",
    ]
    /// An Immich account's videos are read for faces too (ADR 0047), in byte ranges from its
    /// server (`RemoteVideoAsset`), under the account claim: metadata, and a video's faces.
    /// Its index pair's text is frozen here, as v35's is; a contract test holds
    /// `EnrichmentClaimGateway.stalenessSQLPredicate(.account)` to it. Every account video's
    /// faces stamp is NULL, so each owes its faces once.
    static let accountVideoFacesMigrationIdentifier = "v40_account_video_faces"

    static let accountClaimPredicate = """
    metadata_source_size IS NULL
       OR metadata_source_mtime IS NULL
       OR COALESCE(byte_size, -1) <> COALESCE(metadata_source_size, -1)
       OR CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER)
          <> COALESCE(metadata_source_mtime, -1)
       OR (best_kind = 'video' AND (faces_source_size IS NULL
       OR faces_source_mtime IS NULL
       OR COALESCE(byte_size, -1) <> COALESCE(faces_source_size, -1)
       OR CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER)
          <> COALESCE(faces_source_mtime, -1)))
    """

    static var accountVideoFacesStatements: [String] {
        [
            claimIndex(
                EnrichmentClaimGateway.accountGlobalIndexName, global: true,
                predicate: accountClaimPredicate, orderColumn: "best_capture_local"
            ),
            claimIndex(
                EnrichmentClaimGateway.accountRootIndexName, global: false,
                predicate: accountClaimPredicate, orderColumn: "best_capture_local"
            ),
        ]
    }

    /// `library_root.resync_owed`: an Immich account owes a full resync (ADR 0046 §5): its
    /// server reset the cursor, or a new session began. 0 when none is owed, else the
    /// revision of the newest request; each request adds one, and a pass that read the stream
    /// from zero to its end settles only the revision it started from, in the transaction
    /// that purges what it no longer lists, so a request made meanwhile stays owed.
    static let resyncOwedMigrationIdentifier = "v41_library_root_resync_owed"

    static let resyncOwedStatements: [String] = [
        "ALTER TABLE library_root ADD COLUMN resync_owed INTEGER NOT NULL DEFAULT 0",
    ]

    /// Camera bursts (ADR 0052): `media_asset.continuous_shooting_frame`, the frame's number
    /// in its camera's continuous-shooting sequence as MediaMetadata 0.9.5 reports it,
    /// written with each metadata record and filled from the records already stored (only a
    /// re-read from local bytes reports it). `idx_media_asset_burst_or_frame` replaces
    /// `idx_media_asset_burst`: one index over every still in an iPhone or a camera burst, so
    /// the candidates' read stays two arms.
    static let continuousFrameMigrationIdentifier = "v42_continuous_shooting_frame"

    static var continuousFrameStatements: [String] {
        [
            "ALTER TABLE media_asset ADD COLUMN continuous_shooting_frame INTEGER",
            """
            UPDATE media_asset SET continuous_shooting_frame = (
                SELECT CASE WHEN json_valid(metadata.metadata_extra_json)
                    THEN json_extract(metadata.metadata_extra_json, '$.continuousShootingFrame') END
                FROM asset_metadata AS metadata
                WHERE metadata.library_root_id = media_asset.library_root_id
                  AND metadata.relative_path = media_asset.relative_path
            )
            WHERE (library_root_id, relative_path) IN (
                SELECT library_root_id, relative_path FROM asset_metadata
                WHERE json_valid(metadata_extra_json)
                  AND json_extract(metadata_extra_json, '$.continuousShootingFrame') IS NOT NULL
            )
            """,
            "DROP INDEX idx_media_asset_burst",
            """
            CREATE INDEX idx_media_asset_burst_or_frame
            ON media_asset(library_root_id)
            WHERE (burst_identifier IS NOT NULL OR continuous_shooting_frame IS NOT NULL)
            """,
        ]
    }

    /// Place cells kept with each location (ADR 0051): `asset_metadata.place_cell_latitude`
    /// and `place_cell_longitude`, the cell (`PlaceCell`) a primary location falls in,
    /// generated by SQLite from the stored coordinate — the floor of 50 cells a degree,
    /// written without SQLite's math functions, which a build may lack, and held to the cells
    /// whose centers are valid coordinates — and indexed, so the reads of the unnamed cells
    /// and of the Places filter's options walk the index instead of computing every row's
    /// cell. The text is frozen here; a test holds `PlaceCell.init` to it. `place_cell.locale`
    /// becomes `language` (`PlaceNameLanguage`); v45 turns the full locale identifiers it
    /// held into language keys (`convertPlaceNameLanguages`).
    static let placeCellMigrationIdentifier = "v43_place_cell_columns"

    static var placeCellStatements: [String] {
        [
            """
            ALTER TABLE asset_metadata ADD COLUMN place_cell_latitude INTEGER
            GENERATED ALWAYS AS (\(PlaceCellSQL.cell("primary_latitude", cells: PlaceCellSQL.latitudeCells))) VIRTUAL
            """,
            """
            ALTER TABLE asset_metadata ADD COLUMN place_cell_longitude INTEGER
            GENERATED ALWAYS AS (\(PlaceCellSQL.cell("primary_longitude", cells: PlaceCellSQL.longitudeCells))) VIRTUAL
            """,
            """
            CREATE INDEX \(PlaceCellSQL.indexName)
            ON asset_metadata(place_cell_latitude, place_cell_longitude)
            WHERE place_cell_latitude IS NOT NULL AND place_cell_longitude IS NOT NULL
            """,
            "ALTER TABLE place_cell RENAME COLUMN locale TO language",
        ]
    }

    /// `idx_media_asset_undecodable`: the stills and videos a decoder could not read (ENR-029,
    /// ENR-031), so the launch's hand-back of those another decoder judged
    /// (`releaseUndecodedByAnotherDecoder`) seeks them instead of scanning every row.
    static let undecodableIndexMigrationIdentifier = "v44_media_asset_undecodable_index"

    static let undecodableIndexStatements: [String] = [
        "CREATE INDEX idx_media_asset_undecodable ON media_asset(undecodable_by) WHERE undecodable_by IS NOT NULL",
    ]

    /// Place names stored before v43 carry the full locale they were read in (`en_US`);
    /// the reader keys them by language (`PlaceNameLanguage`, `en-Latn`). Each distinct stored
    /// value is converted by the reader's own function, so an upgrade asks Maps nothing it
    /// already holds in the Mac's language. A value with no language keeps its text and its
    /// cells are named again.
    static let placeNameLanguageMigrationIdentifier = "v45_place_name_language_keys"

    static func convertPlaceNameLanguages(db: Database) throws {
        let stored = try String.fetchAll(db, sql: "SELECT DISTINCT language FROM place_cell")
        for value in stored {
            let language = PlaceNameLanguage(Locale(identifier: value)).identifier
            guard !language.isEmpty, language != value else { continue }
            try db.execute(
                sql: "UPDATE place_cell SET language = ? WHERE language = ?",
                arguments: [language, value]
            )
        }
    }

    /// Camera bursts no longer stack (ADR 0052): a camera's frame number says where a frame
    /// stands in its sequence, not which sequence, so `media_asset.continuous_shooting_frame`
    /// and the index over it go, and `idx_media_asset_burst` serves the candidates' read of
    /// iPhone bursts again. The number stays in each stored metadata record, as the library
    /// reported it.
    static let cameraBurstsRemovedMigrationIdentifier = "v46_camera_bursts_removed"

    static let cameraBurstsRemovedStatements = [
        "DROP INDEX idx_media_asset_burst_or_frame",
        "ALTER TABLE media_asset DROP COLUMN continuous_shooting_frame",
        """
        CREATE INDEX idx_media_asset_burst
        ON media_asset(library_root_id, burst_identifier) WHERE burst_identifier IS NOT NULL
        """,
    ]

    /// The source a photo's stored faces were read from (ADR 0047):
    /// `media_asset.faces_read_source_size` and `faces_read_source_mtime`, written with every
    /// reading beside the faces stamp. The stamp says whether the faces are owed, and a
    /// migration clears it to owe a re-read; this pair says what the faces came from, so a
    /// re-read of a file that changed meanwhile is read afresh rather than taken for the same
    /// source (ENR-023). Filled for every photo holding a face row: from its stamp where it
    /// has one; where a migration cleared it, the faces are taken to come from the source the
    /// stamp would name now (a still's stored preview, a video's file), as every reading
    /// before this migration took them.
    static let facesReadSourceMigrationIdentifier = "v47_faces_read_source"

    static var facesReadSourceStatements: [String] {
        let stamped = "faces_source_size IS NOT NULL AND faces_source_mtime IS NOT NULL"
        let previewSize = "CASE WHEN rendered_source_size IS NOT NULL THEN rendered_source_size ELSE source_products_size END"
        let previewMTime = "CASE WHEN rendered_source_size IS NOT NULL THEN rendered_source_mtime ELSE source_products_mtime END"
        let fileMTime = "CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER)"
        return [
            "ALTER TABLE media_asset ADD COLUMN faces_read_source_size INTEGER",
            "ALTER TABLE media_asset ADD COLUMN faces_read_source_mtime INTEGER",
            """
            UPDATE media_asset SET
                faces_read_source_size = CASE
                    WHEN \(stamped) THEN faces_source_size
                    WHEN best_kind = 'video' OR (\(previewSize)) IS NULL THEN COALESCE(byte_size, -1)
                    ELSE \(previewSize) END,
                faces_read_source_mtime = CASE
                    WHEN \(stamped) THEN faces_source_mtime
                    WHEN best_kind = 'video' OR (\(previewSize)) IS NULL THEN \(fileMTime)
                    ELSE \(previewMTime) END
            WHERE EXISTS (
                SELECT 1 FROM face
                WHERE face.library_root_id = media_asset.library_root_id
                  AND face.relative_path = media_asset.relative_path
            )
            """,
        ]
    }

    /// Every stored birthday in its one form, `YYYY` or `YYYY-MM-DD` (`PersonBirthday`). The
    /// rule before this migration let through other spellings of a valid date (`1985-6-7`, `+985`), and
    /// a year 0 (`0000`), which the People read now refuses as a malformed person row. A
    /// spelling of a valid date is rewritten in its form; one that names no date is cleared,
    /// and logged with the person it was cleared from.
    static let canonicalBirthdayMigrationIdentifier = "v48_person_birthday_canonical"

    static func canonicalizeBirthdays(_ db: Database) throws {
        var rewritten = 0
        for row in try Row.fetchAll(db, sql: "SELECT id, birthday FROM person WHERE birthday IS NOT NULL") {
            let id: Int64 = row["id"]
            let text: String = row["birthday"]
            let birthday = PersonBirthday(text) ?? legacyBirthday(text)
            guard birthday?.text != text else { continue }
            try db.execute(sql: "UPDATE person SET birthday = ? WHERE id = ?", arguments: [birthday?.text, id])
            rewritten += 1
            if birthday == nil {
                OtosLog.persistence.errorOperation("catalog.migration.birthday", phase: "cleared", fields: [
                    "person": "\(id)", "reason": "namesNoDate",
                ])
            }
        }
        OtosLog.persistence.noticeOperation("catalog.migration.birthday", phase: "finish", fields: [
            "rewritten": "\(rewritten)",
        ])
    }

    /// A birthday in a spelling the rule before v48 accepted: `-`-separated integers, one or
    /// three of them, the year written in four characters. Nil unless it names a valid date.
    static func legacyBirthday(_ text: String) -> PersonBirthday? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 1 || parts.count == 3, text.split(separator: "-").first?.count == 4 else { return nil }
        let values = parts.compactMap(\.self)
        guard values.count == parts.count else { return nil }
        let form = values.count == 1
            ? String(format: "%04d", values[0])
            : String(format: "%04d-%02d-%02d", values[0], values[1], values[2])
        return PersonBirthday(form)
    }

    /// A key photo is the user's word about its face (ADR 0047): choosing one confirms the
    /// face as the person's, so a re-read carries it and assignment never moves it. Key photos
    /// chosen before on a face Otos had guessed become the user's.
    static let keyPhotoIsUsersWordMigrationIdentifier = "v49_key_photo_users_word"

    static var keyPhotoIsUsersWordStatements: [String] {
        [
            """
            UPDATE face SET assignment = \(FaceAssignmentColumn.user.rawValue)
            WHERE is_key_photo = 1 AND person_id IS NOT NULL
              AND assignment IN (\(FaceAssignmentColumn.model.rawValue), \(FaceAssignmentColumn.seed.rawValue))
            """,
        ]
    }

    /// What is owed faces is read from three partial indexes, each over only the rows that
    /// owe them, so a catalog with nothing owed reads none (ADR 0047): stills owed faces from
    /// their stored preview (`PreviewFaceSQL.stillOwesFaces`, the preview reader's candidates
    /// and the unchecked count), stills still waiting for one (`stillAwaitsPreview`) and videos
    /// whose frames are not yet read (`videoOwesFaces`). Each one's condition is frozen here,
    /// and SQLite reads a partial index only for a query whose terms state its condition, so a
    /// plan test holds every query `PreviewFaceSQL` makes to its index.
    static let facesOwedIndexesMigrationIdentifier = "v50_faces_owed_indexes"

    static let stillOwesFacesIndexName = "idx_media_asset_still_owes_faces"
    static let stillAwaitsPreviewIndexName = "idx_media_asset_still_awaits_preview"
    static let videoOwesFacesIndexName = "idx_media_asset_video_owes_faces"

    static let stillOwesFacesPredicate = """
    kind IN ('image', 'raw') AND trash_path IS NULL AND preview_path IS NOT NULL
      AND (CASE WHEN rendered_source_size IS NOT NULL THEN rendered_source_size ELSE source_products_size END) IS NOT NULL
      AND (faces_source_size IS NOT (CASE WHEN rendered_source_size IS NOT NULL THEN rendered_source_size ELSE source_products_size END)
           OR faces_source_mtime IS NOT (CASE WHEN rendered_source_size IS NOT NULL THEN rendered_source_mtime ELSE source_products_mtime END))
    """

    static let stillAwaitsPreviewPredicate = """
    kind IN ('image', 'raw') AND trash_path IS NULL AND preview_path IS NULL
      AND source_products_size IS NULL
      AND (rendered_source_size IS NULL
       OR rendered_source_mtime IS NULL
       OR COALESCE(byte_size, -1) <> COALESCE(rendered_source_size, -1)
       OR CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER)
          <> COALESCE(rendered_source_mtime, -1))
    """

    static let videoOwesFacesPredicate = """
    trash_path IS NULL AND best_kind = 'video' AND (faces_source_size IS NULL
       OR faces_source_mtime IS NULL
       OR COALESCE(byte_size, -1) <> COALESCE(faces_source_size, -1)
       OR CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER)
          <> COALESCE(faces_source_mtime, -1))
    """

    static var facesOwedIndexesStatements: [String] {
        [
            "CREATE INDEX \(stillOwesFacesIndexName) ON media_asset(library_root_id, relative_path) WHERE \(stillOwesFacesPredicate)",
            "CREATE INDEX \(stillAwaitsPreviewIndexName) ON media_asset(library_root_id) WHERE \(stillAwaitsPreviewPredicate)",
            "CREATE INDEX \(videoOwesFacesIndexName) ON media_asset(library_root_id) WHERE \(videoOwesFacesPredicate)",
        ]
    }

    /// A thumbnail that did not decode is no reading of the picture (ADR 0048): the rows
    /// recorded for one with no embedding go, so each such asset is owed again, and the Info
    /// pane no longer reads it as recognised with nothing in it.
    static let unreadThumbnailsMigrationIdentifier = "v51_search_unread_thumbnails"

    static let unreadThumbnailsStatements: [String] = [
        "DELETE FROM search_embedding WHERE embedding IS NULL",
    ]

    /// On This Day seeks each row's search row by its key (`OnThisDayPicks.exclusionSQL`), so
    /// v38's `idx_search_embedding_left_out`, which a list of every left-out row was read
    /// from, serves no read and goes.
    static let leftOutIndexDroppedMigrationIdentifier = "v52_on_this_day_left_out_index_dropped"

    static let leftOutIndexDroppedStatements: [String] = [
        "DROP INDEX idx_search_embedding_left_out",
    ]

    /// A preview that did not decode was once recorded as a text reading with no lines, which
    /// reads the same as a preview read and found to hold no text (ADR 0048). Every empty
    /// reading of an asset with a stored preview goes, so each is owed and read once more by
    /// the index from that preview in Application Support: nothing downloads, and a preview
    /// that holds no text is recorded empty again. The statement visits each reading once and
    /// finds its asset by the asset's key (`CatalogStoreQueryPlanTests`); on the owner's
    /// catalog it removed 1,498 of 1,930 readings.
    static let unreadTextPreviewsMigrationIdentifier = "v53_search_unread_text_previews"

    static let unreadTextPreviewsStatements: [String] = [
        """
        DELETE FROM search_text WHERE lines = '[]' AND EXISTS (
            SELECT 1 FROM media_asset AS a
            WHERE a.library_root_id = search_text.library_root_id AND a.relative_path = search_text.relative_path
              AND a.preview_path IS NOT NULL
        )
        """,
    ]

    /// A person's photos are read as "this row holds a face of this person": the order of
    /// `SidebarSelection.person`, the People filter, a person named in a search and the
    /// likeness sort each ask it once per row of the scope. v19's index on `person_id` alone
    /// answered it by walking every face of the person for every row — on the owner's catalog
    /// (147,024 rows, 14,614 faces of one person) the person's photos never finished
    /// opening. The index keyed by person and photo, with `is_not_face`, answers it with one
    /// seek, and still serves every read of a person's faces by its prefix
    /// (`docs/research/2026-11-14-owner-scale-query-plans.md`).
    static let facePersonPhotoIndexMigrationIdentifier = "v54_face_person_photo_index"

    static let facePersonPhotoIndexStatements: [String] = [
        "DROP INDEX idx_face_person",
        """
        CREATE INDEX idx_face_person_photo
        ON face(person_id, library_root_id, relative_path, is_not_face) WHERE person_id IS NOT NULL
        """,
    ]

    /// The window's reads walk an index and test every row they reach for whether it is
    /// shown (`CatalogVisibilitySQL`) and whether it is a Live Photo's movie
    /// (`LivePhotoSQL`). Their indexes held the order alone, so each row reached cost a read
    /// of its table row: on the owner's catalog (166,555 rows of about 3.3 KB, a 542 MB table)
    /// the All Media order took 13–34 s cold and 2–4 s warm, the filter's types 18 s cold,
    /// one random page read per row (`docs/research/2026-11-14-window-reads-and-launch.md`).
    /// These indexes carry the columns those tests read, so a row is tested in the index
    /// and only the rows that pass are read — the order took 0.08–0.10 s and the types
    /// 0.33 s on the same copy. The date order's four indexes, the stack candidates' (whose
    /// folder walk the filter's types share) and the import batches' are recreated with them.
    ///
    /// The launch's two maintenance writes each walked the whole table for the few rows
    /// they change (8.9 s and 15.2 s cold on the copy): an enrichment claim a previous
    /// process left, and an edit not yet rendered. Each now has a partial index of exactly
    /// those rows (1.6 ms and 0.3 ms).
    static let windowReadIndexesMigrationIdentifier = "v55_window_read_indexes"

    /// The columns every window read tests a row by: whether it is shown, and whether it is
    /// a Live Photo's movie.
    static let windowReadTestedColumns =
        "pending_trash_batch_unix_ms, awaiting_presence, hidden_by_source, best_kind, content_identifier"

    static let windowReadIndexesStatements: [String] = [
        "DROP INDEX idx_media_asset_best_capture_global_desc",
        "DROP INDEX idx_media_asset_best_capture_root_desc",
        "DROP INDEX idx_media_asset_best_capture_global_asc",
        "DROP INDEX idx_media_asset_best_capture_root_asc",
        "DROP INDEX idx_media_asset_stack_candidate",
        "DROP INDEX idx_media_asset_import_batch",
        """
        CREATE INDEX idx_media_asset_best_capture_global_desc
        ON media_asset(best_capture_local DESC, library_root_id, relative_path, \(windowReadTestedColumns))
        """,
        """
        CREATE INDEX idx_media_asset_best_capture_root_desc
        ON media_asset(library_root_id, best_capture_local DESC, relative_path, \(windowReadTestedColumns))
        """,
        """
        CREATE INDEX idx_media_asset_best_capture_global_asc
        ON media_asset(best_capture_local ASC, library_root_id, relative_path, \(windowReadTestedColumns))
        """,
        """
        CREATE INDEX idx_media_asset_best_capture_root_asc
        ON media_asset(library_root_id, best_capture_local ASC, relative_path, \(windowReadTestedColumns))
        """,
        """
        CREATE INDEX idx_media_asset_stack_candidate
        ON media_asset(library_root_id, best_kind, parent_path, best_format, \(windowReadTestedColumns))
        """,
        """
        CREATE INDEX idx_media_asset_import_batch
        ON media_asset(import_batch_unix_ms, library_root_id, relative_path, \(windowReadTestedColumns))
        WHERE import_batch_unix_ms IS NOT NULL
        """,
        """
        CREATE INDEX idx_media_asset_enrichment_claimed
        ON media_asset(enrichment_claimed) WHERE enrichment_claimed IS NOT NULL
        """,
        """
        CREATE INDEX idx_media_asset_unrendered_edit
        ON media_asset(library_root_id, relative_path) WHERE edit_revision <> rendered_revision
        """,
    ]

    /// The absolute time an item without a wall clock is placed by, as SQL over `media_asset`.
    static let absoluteCaptureSQL = "COALESCE(capture_instant_unix, created_at_unix, content_modified_at_unix)"

    /// The absolute time an item without a wall clock is placed by, in whole seconds: the
    /// second it falls in (the floor, so a time before 1970 is not moved forward), as a
    /// clock's seconds hand reads it. Written without `floor()`, which SQLite provides only
    /// when built with its math functions.
    static let absoluteCaptureWholeSecondsSQL = """
    (CAST(\(absoluteCaptureSQL) AS INTEGER) - (\(absoluteCaptureSQL) < CAST(\(absoluteCaptureSQL) AS INTEGER)))
    """

    /// `best_capture_local`'s definition: the stored wall clock (`YYYYMMDDHHMMSS`) as
    /// seconds of a UTC reading, else the absolute time in whole seconds plus the assumed
    /// offset. A wall that is not a real date-time is NULL to `unixepoch` and falls through
    /// to the absolute time.
    ///
    /// Both branches are whole seconds, because a wall clock is: an Immich asset is placed
    /// by the server's date, which carries milliseconds, until its bytes are read, and the
    /// read's wall clock of the same second must not move it (v56).
    static let bestCaptureLocalSQL = """
    COALESCE(
        unixepoch(printf('%04d-%02d-%02d %02d:%02d:%02d',
            capture_wall_compact / 10000000000, (capture_wall_compact / 100000000) % 100,
            (capture_wall_compact / 1000000) % 100, (capture_wall_compact / 10000) % 100,
            (capture_wall_compact / 100) % 100, capture_wall_compact % 100)),
        \(absoluteCaptureWholeSecondsSQL) + assumed_utc_offset_seconds
    )
    """

    /// The local capture time is whole seconds in both of its branches (ADR 0039). Before
    /// v56 an item without a wall clock kept its absolute time's fraction: an unread Immich
    /// still sorted by the server's date with milliseconds, and the read's wall clock, whole
    /// seconds, moved it by under a second. On the owner's catalog 41,048 of 51,327 read
    /// Immich stills had moved that way, each read a change of the sort date and a read of
    /// the window's order for no reorder a user could see
    /// (`docs/research/2026-11-14-whole-second-capture-time.md`). The generated column is
    /// defined again (`bestCaptureLocalSQL`) and every index over it rebuilt under its own
    /// name; no stored column changes.
    static let wholeSecondCaptureLocalMigrationIdentifier = "v56_capture_local_whole_seconds"

    /// The People scope holds every photo with a face given a person: an `EXISTS` over `face`
    /// per row of the order. By the face table's key it read each face's row to test its
    /// person and whether it is a face, and those rows carry the embeddings: on the owner's
    /// catalog (98,359 faces, 147,024 rows) the check over every row took 4.8 s cold, 0.44 s
    /// warm. A partial index of exactly the faces it accepts answers it from the index:
    /// 0.13–0.15 s, cold or warm (`docs/research/2026-11-14-derived-owners-and-face-checks.md`).
    static let assignedFacePhotoIndexMigrationIdentifier = "v57_assigned_face_photo_index"

    /// The filter's types for the People row walk `idx_media_asset_stack_candidate` and test
    /// each row for an assigned face by its key (`idx_face_assigned_photo`). The index held no
    /// `relative_path`, so every row reached cost a read of its table row to find the key: on
    /// the owner's catalog the People row's options took 17–41 s on a copy (8–12 s in the
    /// installed app, rerun on every lap of the window during enrichment). With the path in
    /// the index the key is in the index and the read took 0.18–0.31 s; the index grows from
    /// about 10 MB to 19 MB (`docs/research/2026-11-14-scope-switch-and-background-laps.md`).
    static let stackCandidatePathMigrationIdentifier = "v59_stack_candidate_path"

    static let stackCandidatePathStatements: [String] = [
        "DROP INDEX idx_media_asset_stack_candidate",
        """
        CREATE INDEX idx_media_asset_stack_candidate
        ON media_asset(library_root_id, best_kind, parent_path, best_format, relative_path, \(windowReadTestedColumns))
        """,
    ]

    static let assignedFacePhotoIndexStatements: [String] = [
        """
        CREATE INDEX idx_face_assigned_photo
        ON face(library_root_id, relative_path) WHERE person_id IS NOT NULL AND is_not_face = 0
        """,
    ]

    /// v58 a still's description, written by Apple's on-device language model from its stored
    /// preview and the facts Otos holds about it (ADR 0053, `PhotoDescriptionStorage`): one
    /// row per asset naming everything it was written from, its text NULL when the model
    /// declined. A move carries it and a proven deletion ends it, by cascade.
    static let photoDescriptionMigrationIdentifier = "v58_photo_description"

    static let photoDescriptionStatements: [String] = [
        """
        CREATE TABLE photo_description (
            library_root_id INTEGER NOT NULL,
            relative_path TEXT NOT NULL,
            source TEXT NOT NULL,
            text TEXT,
            PRIMARY KEY (library_root_id, relative_path),
            FOREIGN KEY (library_root_id, relative_path)
                REFERENCES media_asset(library_root_id, relative_path)
                ON UPDATE CASCADE ON DELETE CASCADE
        )
        """,
    ]

    /// One photo, several copies (ADR 0054), and the digest that finds them (ADR 0018):
    /// - The digest is SHA-1 (`content_sha1`), the digest Immich reports for an uploaded
    ///   original, so a library's copy and an account's are compared without a download.
    ///   Every XXH3 digest is cleared, and so is the import journal's: each row owes its
    ///   digest again, and enrichment reads it as it reads any owed digest — a library's
    ///   row for its digest alone, from one read of its bytes, under the free-space floor
    ///   (ENR-008). The claim indexes whose text names the digest are made again from the
    ///   gateway's predicate, which `INDEXED BY` matches by text.
    /// - `idx_media_asset_content_sha1` holds the digest with what makes it current and what a
    ///   copy is tested by (`ContentDigestSQL`), so a scan of every digest reads no table row.
    /// - `shown_copy_root_id` is the root of the copy shown in this row's place: the first
    ///   present copy with the same current digest, in a library before an account, then by
    ///   root and path; NULL for the copy that is shown, and for a row with no current digest
    ///   or the digest of no bytes. Three triggers keep it in the transaction of every write
    ///   that can move it, so no write path can leave it stale. Deciding it inside each read
    ///   took 17–33 s on the owner's catalog (`docs/research/2026-11-14-one-photo-many-copies.md`).
    ///   Every digest is cleared here, so it starts NULL everywhere and fills as digests arrive.
    /// - The window's date indexes and the stack candidates' carry it with the other
    ///   columns a row is tested by (v55).
    /// - Every Immich account owes a full resync, so every asset is listed again with its
    ///   checksum.
    static let copiesMigrationIdentifier = "v60_sha1_digest_and_copies"

    /// The digest index's columns as v60 made it; v64 adds `source_path_sha1`
    /// (`ContentDigestSQL.indexedColumns`).
    static let copiesDigestIndexColumns = """
    content_sha1, library_root_id, relative_path, content_hash_source_size, content_hash_source_mtime, \
    byte_size, content_modified_at_unix, pending_trash_batch_unix_ms, awaiting_presence, hidden_by_source, \
    trash_path, best_kind, content_identifier
    """

    /// The columns a combined scope's reads tested a row by from v60 to v62: v55's, and
    /// whether another copy is shown in its place. v64 adds `has_copies`
    /// (`photoTestedColumns`).
    static let copyTestedColumns = "\(windowReadTestedColumns), shown_copy_root_id"

    /// The kinds of root whose rows are copies of one another: the ones All Media holds
    /// (`LibraryRootKind.isMemberOfAllMedia`).
    static let copyRootKinds = "'library', 'immichAccount'"

    /// A row's place among its copies, as an ordered row value over `row`: a library's copy
    /// before an account's, then by root and path.
    static func copyRank(_ row: String) -> String {
        """
        ((SELECT kind FROM library_root WHERE id = \(row).library_root_id) = 'immichAccount'), \
        \(row).library_root_id, \(row).relative_path
        """
    }

    /// Sets `shown_copy_root_id` for every row of `media_asset` that `rows` selects: v60's
    /// triggers, which v64 replaces (`photoCopiesRecompute`).
    static func shownCopyRecompute(rows: String) -> String {
        """
        UPDATE media_asset SET shown_copy_root_id = CASE
            WHEN \(ContentDigestSQL.isCurrent("media_asset")) AND media_asset.content_sha1 <> \(ContentDigestSQL.empty)
            THEN (
                SELECT copy.library_root_id FROM media_asset AS copy INDEXED BY \(ContentDigestSQL.indexName)
                WHERE copy.content_sha1 = media_asset.content_sha1
                  AND \(ContentDigestSQL.isCurrent("copy"))
                  AND copy.library_root_id IN (SELECT id FROM library_root WHERE kind IN (\(copyRootKinds)))
                  AND \(CatalogVisibilitySQL.isPresent("copy"))
                  AND (\(copyRank("copy"))) < (\(copyRank("media_asset")))
                ORDER BY \(copyRank("copy"))
                LIMIT 1
            )
        END
        WHERE \(rows);
        """
    }

    /// The columns a row's current digest, its presence or its rank read.
    static let copyInputColumns = """
    content_sha1, content_hash_source_size, content_hash_source_mtime, byte_size, content_modified_at_unix, \
    pending_trash_batch_unix_ms, awaiting_presence, hidden_by_source, library_root_id, relative_path
    """

    /// Whether an update changed any of `copyInputColumns`.
    static let copyInputChanged = """
    OLD.content_sha1 IS NOT NEW.content_sha1
      OR OLD.content_hash_source_size IS NOT NEW.content_hash_source_size
      OR OLD.content_hash_source_mtime IS NOT NEW.content_hash_source_mtime
      OR OLD.byte_size IS NOT NEW.byte_size
      OR OLD.content_modified_at_unix IS NOT NEW.content_modified_at_unix
      OR OLD.pending_trash_batch_unix_ms IS NOT NEW.pending_trash_batch_unix_ms
      OR OLD.awaiting_presence IS NOT NEW.awaiting_presence
      OR OLD.hidden_by_source IS NOT NEW.hidden_by_source
      OR OLD.library_root_id IS NOT NEW.library_root_id
      OR OLD.relative_path IS NOT NEW.relative_path
    """

    static var copiesStatements: [String] {
        let claimIndexes: [(name: String, global: Bool, claim: EnrichmentClaim)] = [
            (EnrichmentClaimGateway.broadGlobalIndexName, true, .products),
            (EnrichmentClaimGateway.broadRootIndexName, false, .products),
            (EnrichmentClaimGateway.libraryGlobalIndexName, true, .library),
            (EnrichmentClaimGateway.libraryRootIndexName, false, .library),
        ]
        let testedIndexes: [(name: String, columns: String)] = [
            ("idx_media_asset_best_capture_global_desc", "best_capture_local DESC, library_root_id, relative_path"),
            ("idx_media_asset_best_capture_root_desc", "library_root_id, best_capture_local DESC, relative_path"),
            ("idx_media_asset_best_capture_global_asc", "best_capture_local ASC, library_root_id, relative_path"),
            ("idx_media_asset_best_capture_root_asc", "library_root_id, best_capture_local ASC, relative_path"),
            ("idx_media_asset_stack_candidate", "library_root_id, best_kind, parent_path, best_format, relative_path"),
        ]
        var statements = ["DROP INDEX idx_media_asset_content_hash"]
        statements += claimIndexes.map { "DROP INDEX \($0.name)" }
        statements += testedIndexes.map { "DROP INDEX \($0.name)" }
        statements += [
            "ALTER TABLE media_asset RENAME COLUMN content_hash_xxh3_128 TO content_sha1",
            """
            UPDATE media_asset SET content_sha1 = NULL, content_hash_source_size = NULL, content_hash_source_mtime = NULL
            WHERE content_sha1 IS NOT NULL OR content_hash_source_size IS NOT NULL OR content_hash_source_mtime IS NOT NULL
            """,
            "ALTER TABLE active_file_operation RENAME COLUMN content_hash_xxh3_128 TO content_sha1",
            "UPDATE active_file_operation SET content_sha1 = NULL WHERE content_sha1 IS NOT NULL",
            "ALTER TABLE media_asset ADD COLUMN shown_copy_root_id INTEGER",
            """
            CREATE INDEX \(ContentDigestSQL.indexName)
            ON media_asset(\(copiesDigestIndexColumns))
            WHERE content_sha1 IS NOT NULL
            """,
            """
            CREATE TRIGGER media_asset_copy_inserted AFTER INSERT ON media_asset
            WHEN NEW.content_sha1 IS NOT NULL
            BEGIN
            \(shownCopyRecompute(rows: "content_sha1 = NEW.content_sha1"))
            END
            """,
            """
            CREATE TRIGGER media_asset_copy_deleted AFTER DELETE ON media_asset
            WHEN OLD.content_sha1 IS NOT NULL
            BEGIN
            \(shownCopyRecompute(rows: "content_sha1 = OLD.content_sha1"))
            END
            """,
            """
            CREATE TRIGGER media_asset_copy_updated AFTER UPDATE OF \(copyInputColumns) ON media_asset
            WHEN (OLD.content_sha1 IS NOT NULL OR NEW.content_sha1 IS NOT NULL) AND (\(copyInputChanged))
            BEGIN
            \(shownCopyRecompute(rows: "content_sha1 IN (OLD.content_sha1, NEW.content_sha1)"))
            UPDATE media_asset SET shown_copy_root_id = NULL
            WHERE rowid = NEW.rowid AND NEW.content_sha1 IS NULL AND shown_copy_root_id IS NOT NULL;
            END
            """,
        ]
        statements += claimIndexes.map { index in
            claimIndex(index.name, global: index.global, claim: index.claim, orderColumn: "best_capture_local")
        }
        statements += testedIndexes.map { index in
            "CREATE INDEX \(index.name) ON media_asset(\(index.columns), \(copyTestedColumns))"
        }
        statements.append("UPDATE library_root SET resync_owed = resync_owed + 1 WHERE kind = 'immichAccount'")
        return statements
    }

    /// Mirrors (ADR 0054): an Immich external library that holds a library's files.
    /// - `source_path_sha1` is an external library's asset's checksum, the SHA-1 of its path
    ///   on the server, written by its listing; its index finds the asset a library file's
    ///   path names.
    /// - `immich_mirror` is where an account's server holds one library's files: the server
    ///   path a library file's relative path follows. It is learned from the server and goes
    ///   with either root.
    /// - Every Immich account owes a full resync, so every asset is listed again with its
    ///   path checksum.
    static let mirrorsMigrationIdentifier = "v61_immich_mirrors"

    static let mirrorsStatements = [
        "ALTER TABLE media_asset ADD COLUMN source_path_sha1 BLOB",
        """
        CREATE INDEX idx_media_asset_source_path_sha1 ON media_asset(library_root_id, source_path_sha1)
        WHERE source_path_sha1 IS NOT NULL
        """,
        """
        CREATE TABLE immich_mirror (
            account_root_id INTEGER NOT NULL REFERENCES library_root(id) ON DELETE CASCADE,
            library_root_id INTEGER NOT NULL REFERENCES library_root(id) ON DELETE CASCADE,
            server_prefix TEXT NOT NULL,
            PRIMARY KEY (account_root_id, library_root_id)
        )
        """,
        "CREATE INDEX idx_immich_mirror_library ON immich_mirror(library_root_id)",
        "UPDATE library_root SET resync_owed = resync_owed + 1 WHERE kind = 'immichAccount'",
    ]

    /// v62: On This Day's day as columns (`AnniversaryMatch`). `capture_day` and
    /// `capture_month` are the date `best_capture_local` shows, generated and never written;
    /// `idx_media_asset_capture_day` is led by them, carries the order's columns and what a
    /// combined scope tests a row by, so a match seeks its day's rows and tests them in the
    /// index (`docs/research/2026-11-15-proportional-small-scopes.md`).
    static let captureDayMigrationIdentifier = "v62_capture_day_index"

    static let captureDayStatements: [String] = [
        "ALTER TABLE media_asset ADD COLUMN capture_day INTEGER GENERATED ALWAYS AS (\(AnniversaryMatch.daySQL)) VIRTUAL",
        "ALTER TABLE media_asset ADD COLUMN capture_month INTEGER GENERATED ALWAYS AS (\(AnniversaryMatch.monthSQL)) VIRTUAL",
        """
        CREATE INDEX \(AnniversaryMatch.indexName)
        ON media_asset(capture_day, capture_month, best_capture_local DESC, library_root_id, relative_path, \(copyTestedColumns))
        """,
    ]

    /// v63: the Places scope reads every located row's coordinate with its order (ADR 0040).
    /// Joined by key, each coordinate was read from its `asset_metadata` row, which also holds
    /// the metadata record, so the order read nearly the whole table: 59,151 pages for 50,000
    /// located rows of an owner-shaped catalog of 166,000. `idx_asset_metadata_location` holds
    /// the key and the coordinate of exactly the located rows, so the join is answered from
    /// the index: 2,778 pages (`docs/research/2026-11-15-places-first-paint.md`).
    static let locationIndexMigrationIdentifier = "v63_asset_metadata_location_index"

    static let locationIndexStatements: [String] = [
        """
        CREATE INDEX \(LocationIndexSQL.indexName)
        ON asset_metadata(library_root_id, relative_path, primary_latitude, primary_longitude)
        WHERE primary_latitude IS NOT NULL AND primary_longitude IS NOT NULL
        """,
    ]

    /// v64: what the user says of a photo is said of all its copies, and a mirror is never a
    /// duplicate (ADR 0054, ADR 0042; owner, 2026-11-15):
    /// - `media_asset.has_copies` is 1 when another present copy shares the row's current
    ///   digest, in a library or an account. A face on any copy is the photo's, and a read
    ///   asks for a copy's faces only of a row that has one (`PhotoFaceSQL`). The window's
    ///   date indexes, the stack candidates' and On This Day's carry it beside
    ///   `shown_copy_root_id`, so the test reads no table row.
    /// - `media_asset.media_choice_sequence` orders the act that set the row's choice among
    ///   every choice act in the catalog (`choice_sequence`): an act order rather than a
    ///   clock, because which act came last is a fact the catalog holds. A choice set before
    ///   v64 has no act, so it is ordered before every act, Liked (-1) before Disliked (-2);
    ///   NULL is Not Rated with no act. One order is one act, which wrote one choice.
    /// - A choice act on a copy is written on every copy in the same transaction
    ///   (`media_asset_choice_made`). When a copy joins a photo, every copy takes the choice of
    ///   the latest act among them (`photoChoiceUnify`), and that write carries the act's
    ///   order, so no trigger's own write is taken for an act.
    /// - The digest index carries `source_path_sha1`, so Duplicates leaves out an external
    ///   library's asset reading no table row (`DuplicatesGateway.countsAsCopy`).
    /// - The three copy triggers are made again to keep `has_copies` and the photo's choice
    ///   beside the shown copy.
    /// Every row with a digest is recomputed once, and every photo whose copies disagree takes
    /// one choice by the rule above.
    static let photoCopiesMigrationIdentifier = "v64_photo_copies"

    /// The columns a combined scope's reads test a row by: v60's, and whether the row has a
    /// present copy.
    static let photoTestedColumns = "\(copyTestedColumns), has_copies"

    /// The indexes that carry the tested columns, by name and leading columns.
    static let photoTestedIndexes: [(name: String, columns: String)] = [
        ("idx_media_asset_best_capture_global_desc", "best_capture_local DESC, library_root_id, relative_path"),
        ("idx_media_asset_best_capture_root_desc", "library_root_id, best_capture_local DESC, relative_path"),
        ("idx_media_asset_best_capture_global_asc", "best_capture_local ASC, library_root_id, relative_path"),
        ("idx_media_asset_best_capture_root_asc", "library_root_id, best_capture_local ASC, relative_path"),
        ("idx_media_asset_stack_candidate", "library_root_id, best_kind, parent_path, best_format, relative_path"),
        (AnniversaryMatch.indexName, "capture_day, capture_month, best_capture_local DESC, library_root_id, relative_path"),
    ]

    /// Whether `row` is a copy: a current digest of some bytes, in a library or an account.
    static func isCopy(_ row: String) -> String {
        """
        (\(ContentDigestSQL.isCurrent(row)) AND \(row).content_sha1 <> \(ContentDigestSQL.empty)
          AND \(row).library_root_id IN (SELECT id FROM library_root WHERE kind IN (\(copyRootKinds))))
        """
    }

    /// Where one row stands among copies (`DigestStanding`): its stored digest and the facts
    /// it was read at, its digest while it is a copy at all, and whether another copy, of
    /// any presence, shares that digest. Binds the root and the path; one probe of the
    /// digest index.
    static let digestStandingSQL = """
    SELECT a.content_sha1, a.content_hash_source_size, a.content_hash_source_mtime,
           CASE WHEN \(isCopy("a")) THEN a.content_sha1 END AS copy_digest,
           CASE WHEN \(isCopy("a")) THEN EXISTS (
               SELECT 1 FROM media_asset AS copy INDEXED BY \(ContentDigestSQL.indexName)
               WHERE \(isCopy("copy", of: "a")) AND copy.rowid <> a.rowid
           ) ELSE 0 END AS shared
    FROM media_asset AS a
    WHERE a.library_root_id = ? AND a.relative_path = ?
    """

    /// Whether `copy` is a copy of the copy `row` (itself included), whatever its presence:
    /// the rows a choice is written on.
    static func isCopy(_ copy: String, of row: String) -> String {
        isCopy(copy, ofDigest: "\(row).content_sha1")
    }

    /// Whether `copy` is a copy of the photo whose copies share `digest` (a SQL value),
    /// whatever its presence.
    static func isCopy(_ copy: String, ofDigest digest: String) -> String {
        """
        \(copy).content_sha1 = \(digest)
          AND \(ContentDigestSQL.isCurrent(copy))
          AND \(copy).library_root_id IN (SELECT id FROM library_root WHERE kind IN (\(copyRootKinds)))
        """
    }

    /// Sets `shown_copy_root_id` and `has_copies` for every row that `rows` selects.
    static func photoCopiesRecompute(rows: String) -> String {
        """
        UPDATE media_asset SET
            shown_copy_root_id = CASE
                WHEN \(ContentDigestSQL.isCurrent("media_asset")) AND media_asset.content_sha1 <> \(ContentDigestSQL.empty)
                THEN (
                    SELECT copy.library_root_id FROM media_asset AS copy INDEXED BY \(ContentDigestSQL.indexName)
                    WHERE \(isCopy("copy", of: "media_asset"))
                      AND \(CatalogVisibilitySQL.isPresent("copy"))
                      AND (\(copyRank("copy"))) < (\(copyRank("media_asset")))
                    ORDER BY \(copyRank("copy"))
                    LIMIT 1
                )
            END,
            has_copies = CASE
                WHEN \(isCopy("media_asset"))
                THEN EXISTS (
                    SELECT 1 FROM media_asset AS copy INDEXED BY \(ContentDigestSQL.indexName)
                    WHERE \(isCopy("copy", of: "media_asset"))
                      AND \(CatalogVisibilitySQL.isPresent("copy"))
                      AND copy.rowid <> media_asset.rowid
                )
                ELSE 0
            END
        WHERE \(rows);
        """
    }

    /// Gives every copy that `rows` selects the choice of the latest act among its copies,
    /// with that act's order, where its copies disagree; a trigger then counts the copies
    /// that took a choice (`countsJoinedChoices`).
    static func photoChoiceUnify(rows: String) -> String {
        """
        UPDATE media_asset SET (media_choice, media_choice_sequence) = (
            SELECT copy.media_choice, copy.media_choice_sequence
            FROM media_asset AS copy INDEXED BY \(ContentDigestSQL.indexName)
            WHERE \(isCopy("copy", of: "media_asset"))
            ORDER BY copy.media_choice_sequence DESC
            LIMIT 1
        )
        WHERE \(rows) AND \(isCopy("media_asset"))
          AND EXISTS (
              SELECT 1 FROM media_asset AS copy INDEXED BY \(ContentDigestSQL.indexName)
              WHERE \(isCopy("copy", of: "media_asset"))
                AND copy.media_choice_sequence IS NOT media_asset.media_choice_sequence
          );
        """
    }

    /// The rows of the digest groups a write leaves and joins.
    static let touchedGroups = "content_sha1 IN (OLD.content_sha1, NEW.content_sha1)"

    /// Takes the next act's order; a statement after it reads it from `choice_sequence`.
    static let nextChoiceAct = "UPDATE choice_sequence SET value = value + 1"

    /// Run right after `photoChoiceUnify` in a trigger: adds the copies it gave a choice to
    /// `choice_sequence.joins`, so the write that joined them can say choices changed
    /// (`choiceJoins`). A unify that writes any row changes at least one choice.
    static let countsJoinedChoices = "UPDATE choice_sequence SET joins = joins + changes();"

    /// How many copies have taken a photo's choice by joining it, ever: a write compares it
    /// before and after to know whether it changed choices besides copies.
    static func choiceJoins(_ db: Database) throws -> Int64 {
        try Int64.fetchOne(db, sql: "SELECT joins FROM choice_sequence") ?? 0
    }

    static var photoCopiesStatements: [String] {
        var statements = [
            "DROP TRIGGER media_asset_copy_inserted",
            "DROP TRIGGER media_asset_copy_deleted",
            "DROP TRIGGER media_asset_copy_updated",
            "ALTER TABLE media_asset ADD COLUMN has_copies INTEGER NOT NULL DEFAULT 0",
            "ALTER TABLE media_asset ADD COLUMN media_choice_sequence INTEGER",
            "CREATE TABLE choice_sequence (value INTEGER NOT NULL, joins INTEGER NOT NULL)",
            "INSERT INTO choice_sequence (value, joins) VALUES (0, 0)",
            """
            UPDATE media_asset SET media_choice_sequence = CASE media_choice WHEN 'liked' THEN -1 ELSE -2 END
            WHERE media_choice <> 'notRated'
            """,
            "DROP INDEX \(ContentDigestSQL.indexName)",
            """
            CREATE INDEX \(ContentDigestSQL.indexName)
            ON media_asset(\(ContentDigestSQL.indexedColumns))
            WHERE content_sha1 IS NOT NULL
            """,
        ]
        statements += photoTestedIndexes.map { "DROP INDEX \($0.name)" }
        // Only the rows that change are written: the shown copy is v60's triggers' and stays,
        // so only a copy is written, once, for `has_copies`. Written while the tested indexes
        // are dropped, so each is built once over the written rows instead of updated for
        // every one: an index holds what its table holds, whichever comes first.
        statements += [
            """
            UPDATE media_asset SET has_copies = 1
            WHERE content_sha1 IS NOT NULL AND \(isCopy("media_asset"))
              AND EXISTS (
                  SELECT 1 FROM media_asset AS copy INDEXED BY \(ContentDigestSQL.indexName)
                  WHERE \(isCopy("copy", of: "media_asset"))
                    AND \(CatalogVisibilitySQL.isPresent("copy"))
                    AND copy.rowid <> media_asset.rowid
              )
            """,
            photoChoiceUnify(rows: "content_sha1 IS NOT NULL"),
        ]
        statements += photoTestedIndexes.map { index in
            "CREATE INDEX \(index.name) ON media_asset(\(index.columns), \(photoTestedColumns))"
        }
        statements += [
            """
            CREATE TRIGGER media_asset_copy_inserted AFTER INSERT ON media_asset
            WHEN NEW.content_sha1 IS NOT NULL
            BEGIN
            \(photoCopiesRecompute(rows: "content_sha1 = NEW.content_sha1"))
            \(photoChoiceUnify(rows: "content_sha1 = NEW.content_sha1"))
            \(countsJoinedChoices)
            END
            """,
            """
            CREATE TRIGGER media_asset_copy_deleted AFTER DELETE ON media_asset
            WHEN OLD.content_sha1 IS NOT NULL
            BEGIN
            \(photoCopiesRecompute(rows: "content_sha1 = OLD.content_sha1"))
            END
            """,
            // A write that moves a copy's digest and sets its choice at once — an import's
            // landing, which brings the card's choice — is an act, ordered before the photo
            // takes the latest act among its copies.
            """
            CREATE TRIGGER media_asset_copy_updated AFTER UPDATE OF \(copyInputColumns) ON media_asset
            WHEN (OLD.content_sha1 IS NOT NULL OR NEW.content_sha1 IS NOT NULL) AND (\(copyInputChanged))
            BEGIN
            \(nextChoiceAct) WHERE NEW.media_choice IS NOT OLD.media_choice;
            UPDATE media_asset SET media_choice_sequence = (SELECT value FROM choice_sequence)
            WHERE rowid = NEW.rowid AND NEW.media_choice IS NOT OLD.media_choice;
            \(photoCopiesRecompute(rows: touchedGroups))
            \(photoChoiceUnify(rows: touchedGroups))
            \(countsJoinedChoices)
            UPDATE media_asset SET shown_copy_root_id = NULL, has_copies = 0
            WHERE rowid = NEW.rowid AND NEW.content_sha1 IS NULL AND (shown_copy_root_id IS NOT NULL OR has_copies <> 0);
            END
            """,
            // A choice written without an order is an act: it takes the next order, and every
            // copy takes the choice with it. The triggers' own writes carry an order, so they
            // start no act.
            """
            CREATE TRIGGER media_asset_choice_made AFTER UPDATE OF media_choice ON media_asset
            WHEN NEW.media_choice IS NOT OLD.media_choice
              AND NEW.media_choice_sequence IS OLD.media_choice_sequence
              AND NOT (\(copyInputChanged))
            BEGIN
            \(nextChoiceAct);
            UPDATE media_asset SET
                media_choice = NEW.media_choice,
                media_choice_sequence = (SELECT value FROM choice_sequence)
            WHERE rowid = NEW.rowid
               OR (\(isCopy("NEW")) AND \(isCopy("media_asset", of: "NEW")));
            END
            """,
        ]
        return statements
    }

    /// v65: every background owner's "what is owed" read is answered from an index that holds
    /// what it compares, never from the wide rows (plan 0116 stage 1b;
    /// `docs/research/2026-11-16-plan-0116-due-diligence.md`):
    /// - `search_embedding`, `search_text` and `photo_description` each carry their key with
    ///   the source a current row must name (`idx_*_source`), so "is this asset's derived row
    ///   current" reads a few index entries, not a 3 KB embedding row, a reading or a
    ///   description.
    /// - `idx_media_asset_product_stamps` is the newest-first order with every column the
    ///   embedding, text and description walks test a row by and build its stamp from
    ///   (`ProductStampSQL.columns`), so those walks and the search index's reconcile read no
    ///   asset row; only a returned description reads its edit.
    /// - `idx_media_asset_render_signature_owed` holds exactly the stills whose signature does not
    ///   name their thumbnail (`RenderSignatureSQL.owedPredicate`), and
    ///   `idx_media_asset_source_products_owed` exactly the rows owed their source's thumbnail
    ///   and preview (`SourceProductsSQL.owedPredicate`): a settled library reads none.
    /// - The products and library claim indexes hold only rows no source lists
    ///   (`source_item_id IS NULL`): those claims never read an Immich account's rows, which
    ///   were nine in ten of their entries, written on every enrichment flush.
    /// - `idx_media_asset_order_global` and `idx_media_asset_order_root`, the `sort_key` order
    ///   no read takes, go.
    static let owedWorkIndexesMigrationIdentifier = "v65_owed_work_indexes"

    /// Literal, as v65 built it: an applied migration's outcome never changes (ADR 0002), so
    /// no constant a later change could edit is read here.
    static let owedWorkIndexesStatements: [String] = [
        "DROP INDEX idx_media_asset_order_global",
        "DROP INDEX idx_media_asset_order_root",
        """
        CREATE INDEX idx_search_embedding_source ON search_embedding(library_root_id, relative_path, source)
        """,
        """
        CREATE INDEX idx_search_text_source ON search_text(library_root_id, relative_path, source)
        """,
        """
        CREATE INDEX idx_photo_description_source ON photo_description(library_root_id, relative_path, \
        source)
        """,
        """
        CREATE INDEX idx_media_asset_product_stamps
        ON media_asset(best_capture_local DESC, library_root_id, relative_path, \
        pending_trash_batch_unix_ms, trash_path, kind, best_kind, content_identifier, parent_path, \
        thumbnail_path, preview_path, rendered_revision, rendered_source_size, rendered_source_mtime, \
        source_products_size, source_products_mtime, faces_source_size, faces_source_mtime, edit_revision)
        """,
        """
        CREATE INDEX idx_media_asset_render_signature_owed ON media_asset(library_root_id, relative_path)
        WHERE thumbnail_path IS NOT NULL
          AND kind IN ('image', 'raw')
          AND pending_trash_batch_unix_ms IS NULL
          AND trash_path IS NULL
          AND render_signature_source IS NOT (thumbnail_path || '|' || rendered_revision || '|'
            || IFNULL(rendered_source_size, '') || '|' || IFNULL(rendered_source_mtime, '')
            || CASE WHEN (rendered_source_size IS NULL AND source_products_size IS NOT NULL)
                THEN '|source|' || source_products_size || '|' || IFNULL(source_products_mtime, '')
                ELSE '' END)
        """,
        """
        CREATE INDEX idx_media_asset_source_products_owed ON media_asset(library_root_id, relative_path)
        WHERE source_item_id IS NOT NULL
          AND hidden_by_source = 0
          AND byte_size IS NOT NULL
          AND (edit_revision = 0 AND rendered_source_size IS NULL)
          AND source_products_absent = 0
          AND (
              source_products_size IS NOT byte_size
              OR source_products_mtime IS NOT CAST(content_modified_at_unix AS INTEGER)
          )
        """,
        "DROP INDEX idx_media_asset_needs_enrichment_global",
        """
        CREATE INDEX idx_media_asset_needs_enrichment_global
        ON media_asset(best_capture_local DESC, library_root_id, relative_path)
        WHERE (metadata_source_size IS NULL
           OR metadata_source_mtime IS NULL
           OR COALESCE(byte_size, -1) <> COALESCE(metadata_source_size, -1)
           OR CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER)
              <> COALESCE(metadata_source_mtime, -1)
           OR rendered_source_size IS NULL
           OR rendered_source_mtime IS NULL
           OR COALESCE(byte_size, -1) <> COALESCE(rendered_source_size, -1)
           OR CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER)
              <> COALESCE(rendered_source_mtime, -1)
           OR content_sha1 IS NULL
           OR length(content_sha1) <> 20
           OR content_hash_source_size IS NULL
           OR content_hash_source_mtime IS NULL
           OR COALESCE(byte_size, -1) <> COALESCE(content_hash_source_size, -1)
           OR CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER)
              <> COALESCE(content_hash_source_mtime, -1)) AND source_item_id IS NULL
        """,
        "DROP INDEX idx_media_asset_needs_enrichment_root",
        """
        CREATE INDEX idx_media_asset_needs_enrichment_root
        ON media_asset(library_root_id, best_capture_local DESC, relative_path)
        WHERE (metadata_source_size IS NULL
           OR metadata_source_mtime IS NULL
           OR COALESCE(byte_size, -1) <> COALESCE(metadata_source_size, -1)
           OR CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER)
              <> COALESCE(metadata_source_mtime, -1)
           OR rendered_source_size IS NULL
           OR rendered_source_mtime IS NULL
           OR COALESCE(byte_size, -1) <> COALESCE(rendered_source_size, -1)
           OR CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER)
              <> COALESCE(rendered_source_mtime, -1)
           OR content_sha1 IS NULL
           OR length(content_sha1) <> 20
           OR content_hash_source_size IS NULL
           OR content_hash_source_mtime IS NULL
           OR COALESCE(byte_size, -1) <> COALESCE(content_hash_source_size, -1)
           OR CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER)
              <> COALESCE(content_hash_source_mtime, -1)) AND source_item_id IS NULL
        """,
        "DROP INDEX idx_media_asset_needs_enrichment_global_library",
        """
        CREATE INDEX idx_media_asset_needs_enrichment_global_library
        ON media_asset(best_capture_local DESC, library_root_id, relative_path)
        WHERE (metadata_source_size IS NULL
           OR metadata_source_mtime IS NULL
           OR COALESCE(byte_size, -1) <> COALESCE(metadata_source_size, -1)
           OR CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER)
              <> COALESCE(metadata_source_mtime, -1)
           OR rendered_source_size IS NULL
           OR rendered_source_mtime IS NULL
           OR COALESCE(byte_size, -1) <> COALESCE(rendered_source_size, -1)
           OR CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER)
              <> COALESCE(rendered_source_mtime, -1)
           OR content_sha1 IS NULL
           OR length(content_sha1) <> 20
           OR content_hash_source_size IS NULL
           OR content_hash_source_mtime IS NULL
           OR COALESCE(byte_size, -1) <> COALESCE(content_hash_source_size, -1)
           OR CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER)
              <> COALESCE(content_hash_source_mtime, -1)
           OR (best_kind = 'video' AND (faces_source_size IS NULL
           OR faces_source_mtime IS NULL
           OR COALESCE(byte_size, -1) <> COALESCE(faces_source_size, -1)
           OR CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER)
              <> COALESCE(faces_source_mtime, -1)))) AND source_item_id IS NULL
        """,
        "DROP INDEX idx_media_asset_needs_enrichment_root_library",
        """
        CREATE INDEX idx_media_asset_needs_enrichment_root_library
        ON media_asset(library_root_id, best_capture_local DESC, relative_path)
        WHERE (metadata_source_size IS NULL
           OR metadata_source_mtime IS NULL
           OR COALESCE(byte_size, -1) <> COALESCE(metadata_source_size, -1)
           OR CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER)
              <> COALESCE(metadata_source_mtime, -1)
           OR rendered_source_size IS NULL
           OR rendered_source_mtime IS NULL
           OR COALESCE(byte_size, -1) <> COALESCE(rendered_source_size, -1)
           OR CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER)
              <> COALESCE(rendered_source_mtime, -1)
           OR content_sha1 IS NULL
           OR length(content_sha1) <> 20
           OR content_hash_source_size IS NULL
           OR content_hash_source_mtime IS NULL
           OR COALESCE(byte_size, -1) <> COALESCE(content_hash_source_size, -1)
           OR CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER)
              <> COALESCE(content_hash_source_mtime, -1)
           OR (best_kind = 'video' AND (faces_source_size IS NULL
           OR faces_source_mtime IS NULL
           OR COALESCE(byte_size, -1) <> COALESCE(faces_source_size, -1)
           OR CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER)
              <> COALESCE(faces_source_mtime, -1)))) AND source_item_id IS NULL
        """,
    ]

    /// v66 a face's embedding moves out of its row into `face_embedding` (ADR 0047, Storage).
    /// A face row was 2.1 KB, its 2,048-byte embedding most of it, so one row filled a page
    /// and every People read of who the faces are read 403 MB on the owner's catalog to learn
    /// 100 bytes a face. The face row keeps everything but the vector; the vector's row
    /// carries the face's key, with cascades from it, and `id`, the reading's number: a new
    /// reading of a face inserts a new vector row, and `AUTOINCREMENT` never gives a number
    /// twice, so the vectors written since any moment are the rows above the largest `id`
    /// then. The number is never an identity: a face is its photo's path and place (ADR 0008).
    ///
    /// SQLite cannot drop a column without rewriting every row in place, which would write the
    /// whole 403 MB table to the log a second time, so the face table is rebuilt (SQLite's
    /// twelve steps): the vectors are copied out, the narrow rows copied into a new table, the
    /// old one dropped and the new one renamed, and the indexes made after the rows. Dropping
    /// a table other tables reference needs foreign keys off, so the migration registers its
    /// own deferred check, of only the three tables it rewrote (`checkedTables`).
    static let faceEmbeddingTableMigrationIdentifier = "v66_face_embedding_table"

    /// The tables v66 rewrote, whose foreign keys its deferred check reads.
    static let faceEmbeddingTableCheckedTables = ["face", "face_embedding", "face_rejection"]

    static var faceEmbeddingTableStatements: [String] {
        let narrowColumns = """
        library_root_id, relative_path, face_index, box_x, box_y, box_width, box_height, landmarks, quality,
        analysis_revision, person_id, is_not_face, assignment, likeness, is_key_photo, frame_index
        """
        return [
            """
            CREATE TABLE face_embedding (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                library_root_id INTEGER NOT NULL,
                relative_path TEXT NOT NULL,
                face_index INTEGER NOT NULL,
                embedding BLOB NOT NULL,
                FOREIGN KEY (library_root_id, relative_path, face_index)
                    REFERENCES face(library_root_id, relative_path, face_index)
                    ON UPDATE CASCADE ON DELETE CASCADE
            )
            """,
            """
            INSERT INTO face_embedding (library_root_id, relative_path, face_index, embedding)
            SELECT library_root_id, relative_path, face_index, embedding FROM face
            ORDER BY library_root_id, relative_path, face_index
            """,
            """
            CREATE TABLE face_narrow (
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
                person_id INTEGER REFERENCES person(id) ON DELETE SET NULL,
                is_not_face INTEGER NOT NULL DEFAULT 0,
                assignment INTEGER NOT NULL DEFAULT 0,
                likeness REAL,
                is_key_photo INTEGER NOT NULL DEFAULT 0,
                frame_index INTEGER,
                PRIMARY KEY (library_root_id, relative_path, face_index),
                FOREIGN KEY (library_root_id, relative_path)
                    REFERENCES media_asset(library_root_id, relative_path)
                    ON UPDATE CASCADE ON DELETE CASCADE
            )
            """,
            """
            INSERT INTO face_narrow (\(narrowColumns))
            SELECT \(narrowColumns) FROM face ORDER BY library_root_id, relative_path, face_index
            """,
            "DROP TABLE face",
            "ALTER TABLE face_narrow RENAME TO face",
            """
            CREATE UNIQUE INDEX \(FaceEmbeddingSQL.faceIndexName)
            ON face_embedding(library_root_id, relative_path, face_index)
            """,
            "CREATE UNIQUE INDEX idx_face_key_photo ON face(person_id) WHERE is_key_photo = 1",
            """
            CREATE INDEX idx_face_person_photo
            ON face(person_id, library_root_id, relative_path, is_not_face) WHERE person_id IS NOT NULL
            """,
            """
            CREATE INDEX idx_face_assigned_photo
            ON face(library_root_id, relative_path) WHERE person_id IS NOT NULL AND is_not_face = 0
            """,
        ]
    }

    /// v67: the same-photo rule's candidate read touches no wide row (ADR 0042, plan 0116
    /// bet 3). `idx_media_asset_same_photo_candidate` holds exactly the stills the rule
    /// compares (`SamePhotoSQL.candidatePredicate`) with every column the read names, and
    /// `idx_asset_metadata_same_photo` the record columns pairs are proposed from. On the
    /// owner's catalog the read walked every row of every root, 545 MB of asset rows and the
    /// 190 MB record table, for 144,410 stills, 128,671 of them an Immich external library's
    /// assets the rule now leaves out; 15,737 remain.
    static let samePhotoIndexesMigrationIdentifier = "v67_same_photo_indexes"

    /// Literal, as v67 built it (ADR 0002: an applied migration's outcome never changes).
    static let samePhotoIndexesStatements: [String] = [
        """
        CREATE INDEX idx_media_asset_same_photo_candidate ON media_asset(library_root_id, relative_path, \
        kind, capture_instant_unix, render_dhash, render_signature_source, thumbnail_path, \
        rendered_revision, rendered_source_size, rendered_source_mtime, source_products_size, \
        source_products_mtime, metadata_source_size, metadata_source_mtime, pending_trash_batch_unix_ms, \
        trash_path, hidden_by_source, source_path_sha1)
        WHERE kind IN ('image', 'raw')
          AND pending_trash_batch_unix_ms IS NULL
          AND trash_path IS NULL
          AND hidden_by_source = 0
          AND source_path_sha1 IS NULL
          AND render_dhash IS NOT NULL
          AND render_signature_source = (thumbnail_path || '|' || rendered_revision || '|'
            || IFNULL(rendered_source_size, '') || '|' || IFNULL(rendered_source_mtime, '')
            || CASE WHEN (rendered_source_size IS NULL AND source_products_size IS NOT NULL)
                THEN '|source|' || source_products_size || '|' || IFNULL(source_products_mtime, '')
                ELSE '' END)
        """,
        """
        CREATE INDEX idx_asset_metadata_same_photo ON asset_metadata(library_root_id, relative_path, \
        pixel_width, pixel_height, orientation, camera_model, serial_number, extraction_revision)
        """,
    ]

    /// v68 the hash of the assignment inputs whose assignment the catalog holds (ADR 0047,
    /// `AssignmentInputs`): one row, rewritten each time an assignment settles. While a pass's
    /// inputs hash to it, the stored guesses are assignment's output, so a launch with nothing
    /// changed assigns nothing. Not overlay: a missing or stale row only costs one assignment.
    static let settledPeopleAssignmentMigrationIdentifier = "v68_settled_people_assignment"
    static let settledPeopleAssignmentTable = "people_assignment_settled"

    static let settledPeopleAssignmentStatements = [
        """
        CREATE TABLE \(settledPeopleAssignmentTable) (
            id INTEGER PRIMARY KEY CHECK (id = 0),
            inputs BLOB NOT NULL
        )
        """,
    ]

    /// Schema v69: the name and size order indexes carry what the window's reads test a row
    /// by (`photoTestedColumns`), as the date order indexes have since v55, so a walk of All
    /// Media by name or size tests each row's visibility from its index entry instead of its
    /// table row. On the owner's catalog the name order read 152,822 pages, 9.1 s with the
    /// file's pages in the OS cache and 25.9 s in his tour, where the date order reads 3,578
    /// (`docs/research/2026-11-16-window-reads-owner-catalog.md`). Each index is dropped and
    /// made again with its own leading columns.
    static let sortOrderTestedColumnsMigrationIdentifier = "v69_sort_order_tested_columns"

    /// Literal, as v69 built it (ADR 0002: an applied migration's outcome never changes).
    static let sortOrderTestedColumnsStatements: [String] = [
        "DROP INDEX idx_media_asset_name_global_asc",
        """
        CREATE INDEX idx_media_asset_name_global_asc ON media_asset(name_sort_key ASC, library_root_id, \
        relative_path, pending_trash_batch_unix_ms, awaiting_presence, hidden_by_source, best_kind, \
        content_identifier, shown_copy_root_id, has_copies)
        """,
        "DROP INDEX idx_media_asset_name_global_desc",
        """
        CREATE INDEX idx_media_asset_name_global_desc ON media_asset(name_sort_key DESC, library_root_id, \
        relative_path, pending_trash_batch_unix_ms, awaiting_presence, hidden_by_source, best_kind, \
        content_identifier, shown_copy_root_id, has_copies)
        """,
        "DROP INDEX idx_media_asset_name_root_asc",
        """
        CREATE INDEX idx_media_asset_name_root_asc ON media_asset(library_root_id, name_sort_key ASC, \
        relative_path, pending_trash_batch_unix_ms, awaiting_presence, hidden_by_source, best_kind, \
        content_identifier, shown_copy_root_id, has_copies)
        """,
        "DROP INDEX idx_media_asset_name_root_desc",
        """
        CREATE INDEX idx_media_asset_name_root_desc ON media_asset(library_root_id, name_sort_key DESC, \
        relative_path, pending_trash_batch_unix_ms, awaiting_presence, hidden_by_source, best_kind, \
        content_identifier, shown_copy_root_id, has_copies)
        """,
        "DROP INDEX idx_media_asset_size_global_asc",
        """
        CREATE INDEX idx_media_asset_size_global_asc ON media_asset((byte_size IS NULL), byte_size ASC, \
        library_root_id, relative_path, pending_trash_batch_unix_ms, awaiting_presence, hidden_by_source, \
        best_kind, content_identifier, shown_copy_root_id, has_copies)
        """,
        "DROP INDEX idx_media_asset_size_global_desc",
        """
        CREATE INDEX idx_media_asset_size_global_desc ON media_asset((byte_size IS NULL), byte_size DESC, \
        library_root_id, relative_path, pending_trash_batch_unix_ms, awaiting_presence, hidden_by_source, \
        best_kind, content_identifier, shown_copy_root_id, has_copies)
        """,
        "DROP INDEX idx_media_asset_size_root_asc",
        """
        CREATE INDEX idx_media_asset_size_root_asc ON media_asset(library_root_id, (byte_size IS NULL), \
        byte_size ASC, relative_path, pending_trash_batch_unix_ms, awaiting_presence, hidden_by_source, \
        best_kind, content_identifier, shown_copy_root_id, has_copies)
        """,
        "DROP INDEX idx_media_asset_size_root_desc",
        """
        CREATE INDEX idx_media_asset_size_root_desc ON media_asset(library_root_id, (byte_size IS NULL), \
        byte_size DESC, relative_path, pending_trash_batch_unix_ms, awaiting_presence, hidden_by_source, \
        best_kind, content_identifier, shown_copy_root_id, has_copies)
        """,
    ]

    /// v70: which search vector file the catalog's embeddings are mapped from, and how many of
    /// its slots they commit (ADR 0048, "The index"). One row, or none while no file is built.
    /// The search index trusts a file only when its name and slot count are the ones this row
    /// holds, so a file cut short by a crash, a file of another catalog and a missing file are
    /// told apart from a current one and rebuilt from `search_embedding`, never read.
    static let searchVectorFileMigrationIdentifier = "v70_search_vector_file"

    static let searchVectorFileStatements: [String] = [
        """
        CREATE TABLE search_vector_file (
            file_id TEXT NOT NULL PRIMARY KEY,
            slots INTEGER NOT NULL
        )
        """,
    ]

    /// v71: `media_asset` is rebuilt as a narrow table (plan 0116 bet 8,
    /// `docs/research/2026-11-16-media-asset-split-study.md`). On the owner's catalog the row was
    /// about 2 KB and the table 545 MB, so every read that tests rows outside a covering index
    /// (the choices filter, the filter options, People's photos, the stacks) read about 140k
    /// pages. Three columns made most of it:
    /// - `render_gray`, a still's 1 KB grayscale render, which only Duplicates reads to confirm
    ///   a pair, moves to `render_signature`, one row per signed still.
    /// - `render_signature_source`, the thumbnail identity a signature was read from as text,
    ///   becomes `render_signature_read`: 1 while the stored signature (`render_dhash` and its
    ///   gray) is the current thumbnail's. `media_asset_render_signature_stale` clears both in
    ///   the write that changes the thumbnail's identity, so no write site has to know, as the
    ///   string made it before.
    /// - `sort_key`, the path's natural order, which only the stacks read: they order a stack's
    ///   members by the path's own natural key (`MediaSortKey.naturalKey`).
    /// The table keeps its row id. Without one, SQLite's planner, which reads no statistics in
    /// this catalog, prices a lookup by key from an index that does not cover a read above a
    /// walk of the key's range, and three reads left their partial indexes to walk a whole root
    /// (the filter's types, the faces owed and a mirror's pairing): every pinned plan stays as
    /// it was.
    ///
    /// SQLite rebuilds a table in twelve steps: the rows are copied into a new table in key
    /// order, the old table dropped and the new one renamed, then the indexes made over the
    /// rows and the triggers made again. Dropping a table other tables reference needs foreign
    /// keys off: with them on, the drop would delete every face, record, embedding, reading
    /// and description by cascade. So the migration is registered `.deferred`, and checks what
    /// it rewrote: the new table holds as many unique keys as the old one, all copied from it,
    /// so every child row keeps its parent; and `foreign_key_check` of the two tables it made.
    /// The indexes are made again from their own definitions, read from the schema, but for
    /// the two that named the string stamp, and one is new: the chosen rows' (`ChosenRowsSQL`),
    /// so a Liked or Disliked view reads its few rows and not the table.
    static let hotAssetTableMigrationIdentifier = "v71_media_asset_hot_table"

    /// The tables v71 made, whose foreign keys its check reads. v71's SQL is literal, never
    /// built from the constants today's reads use, so a later change to those cannot change
    /// what v71 does.
    static let hotAssetTableCheckedTables = ["media_asset", "render_signature"]

    /// The indexes v71 replaces rather than makes again as they were.
    static let hotAssetTableReplacedIndexes: Set<String> = [
        "idx_media_asset_render_signature_owed", "idx_media_asset_same_photo_candidate", "idx_media_asset_capture_day",
    ]

    /// The columns v71 copies as they are: every stored column but the three it removes.
    static let hotAssetCopiedColumns = """
    library_root_id, relative_path, relative_path_key, name_sort_key, name, content_type_identifier, kind, format, \
    byte_size, created_at_unix, content_modified_at_unix, file_identifier, enriched_kind, enriched_format, \
    metadata_source_size, metadata_source_mtime, thumbnail_path, preview_path, face_frames_path, duration_seconds, \
    enrichment_claimed, undecodable_by, import_batch_unix_ms, import_source_root_path, import_source_relative_path, \
    import_source_byte_size, import_source_modified_at_epoch, import_destination_byte_size, \
    import_destination_modified_at_epoch, capture_wall_compact, capture_wall_precision, capture_instant_unix, \
    assumed_utc_offset_seconds, content_sha1, content_hash_source_size, content_hash_source_mtime, shown_copy_root_id, \
    has_copies, media_choice, media_choice_sequence, stack_key_chosen_at_unix_ms, burst_key_chosen_at_unix_ms, \
    pending_trash_batch_unix_ms, trash_path, awaiting_presence, hidden_by_source, edit_recipe_json, edit_revision, \
    rendered_revision, rendered_source_size, rendered_source_mtime, source_products_size, source_products_mtime, \
    source_products_absent, faces_source_size, faces_source_mtime, faces_read_source_size, faces_read_source_mtime, \
    content_identifier, burst_identifier, source_item_id, source_path_sha1
    """

    /// `media_asset` as v71 makes it, before its rename.
    static let hotAssetTable = """
    CREATE TABLE media_asset_hot (
        library_root_id INTEGER NOT NULL REFERENCES library_root(id) ON DELETE CASCADE,
        relative_path TEXT NOT NULL,
        relative_path_key TEXT NOT NULL DEFAULT '',
        name_sort_key TEXT NOT NULL,
        name TEXT,
        content_type_identifier TEXT,
        kind TEXT,
        format TEXT,
        byte_size INTEGER,
        created_at_unix DOUBLE,
        content_modified_at_unix DOUBLE,
        file_identifier INTEGER,
        enriched_kind TEXT,
        enriched_format TEXT,
        best_kind TEXT GENERATED ALWAYS AS (COALESCE(enriched_kind, kind)) STORED,
        best_format TEXT GENERATED ALWAYS AS (COALESCE(enriched_format, format)) STORED,
        parent_path TEXT GENERATED ALWAYS AS (rtrim(relative_path, replace(relative_path, '/', ''))) VIRTUAL,
        metadata_source_size INTEGER,
        metadata_source_mtime INTEGER,
        thumbnail_path TEXT,
        preview_path TEXT,
        face_frames_path TEXT,
        duration_seconds DOUBLE,
        enrichment_claimed DOUBLE,
        undecodable_by TEXT,
        import_batch_unix_ms INTEGER,
        import_source_root_path TEXT,
        import_source_relative_path TEXT,
        import_source_byte_size INTEGER,
        import_source_modified_at_epoch DOUBLE,
        import_destination_byte_size INTEGER,
        import_destination_modified_at_epoch DOUBLE,
        capture_wall_compact INTEGER,
        capture_wall_precision TEXT,
        capture_instant_unix DOUBLE,
        assumed_utc_offset_seconds INTEGER,
        best_capture_local DOUBLE GENERATED ALWAYS AS (
            COALESCE(
                unixepoch(printf('%04d-%02d-%02d %02d:%02d:%02d',
                    capture_wall_compact / 10000000000, (capture_wall_compact / 100000000) % 100,
                    (capture_wall_compact / 1000000) % 100, (capture_wall_compact / 10000) % 100,
                    (capture_wall_compact / 100) % 100, capture_wall_compact % 100)),
                (CAST(COALESCE(capture_instant_unix, created_at_unix, content_modified_at_unix) AS INTEGER)
                    - (COALESCE(capture_instant_unix, created_at_unix, content_modified_at_unix)
                       < CAST(COALESCE(capture_instant_unix, created_at_unix, content_modified_at_unix) AS INTEGER)))
                    + assumed_utc_offset_seconds
            )
        ) VIRTUAL,
        capture_day INTEGER GENERATED ALWAYS AS (CAST(strftime('%d', best_capture_local, 'unixepoch') AS INTEGER)) VIRTUAL,
        capture_month INTEGER GENERATED ALWAYS AS (CAST(strftime('%m', best_capture_local, 'unixepoch') AS INTEGER)) VIRTUAL,
        content_sha1 BLOB,
        content_hash_source_size INTEGER,
        content_hash_source_mtime INTEGER,
        shown_copy_root_id INTEGER,
        has_copies INTEGER NOT NULL DEFAULT 0,
        media_choice TEXT NOT NULL DEFAULT 'notRated'
            CHECK (media_choice IN ('liked', 'notRated', 'disliked')),
        media_choice_sequence INTEGER,
        stack_key_chosen_at_unix_ms INTEGER,
        burst_key_chosen_at_unix_ms INTEGER,
        pending_trash_batch_unix_ms INTEGER,
        trash_path TEXT,
        awaiting_presence INTEGER NOT NULL DEFAULT 0,
        hidden_by_source INTEGER NOT NULL DEFAULT 0,
        edit_recipe_json TEXT,
        edit_revision INTEGER NOT NULL DEFAULT 0,
        rendered_revision INTEGER NOT NULL DEFAULT 0,
        rendered_source_size INTEGER,
        rendered_source_mtime INTEGER,
        source_products_size INTEGER,
        source_products_mtime INTEGER,
        source_products_absent INTEGER NOT NULL DEFAULT 0,
        faces_source_size INTEGER,
        faces_source_mtime INTEGER,
        faces_read_source_size INTEGER,
        faces_read_source_mtime INTEGER,
        content_identifier TEXT,
        burst_identifier TEXT,
        source_item_id TEXT,
        source_path_sha1 BLOB,
        render_dhash INTEGER,
        render_signature_read INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (library_root_id, relative_path)
    )
    """

    /// Whether an old row's string stamp names its current thumbnail: the signature it holds
    /// is current.
    private static let v71SignatureIsCurrent = """
    (render_signature_source IS NOT NULL AND render_signature_source = (thumbnail_path || '|' || rendered_revision || '|'
        || IFNULL(rendered_source_size, '') || '|' || IFNULL(rendered_source_mtime, '')
        || CASE WHEN (rendered_source_size IS NULL AND source_products_size IS NOT NULL)
            THEN '|source|' || source_products_size || '|' || IFNULL(source_products_mtime, '')
            ELSE '' END))
    """

    /// Clears a still's signature in the write that changes what its thumbnail is (ADR 0042):
    /// its hash and its gray were read from the old thumbnail. The identity compared is
    /// `StoredThumbnailSQL.identity`'s.
    static let renderSignatureStaleTrigger = """
    CREATE TRIGGER media_asset_render_signature_stale
    AFTER UPDATE OF thumbnail_path, rendered_revision, rendered_source_size, rendered_source_mtime,
        source_products_size, source_products_mtime ON media_asset
    WHEN NEW.render_signature_read <> 0
      AND (OLD.thumbnail_path || '|' || OLD.rendered_revision || '|'
        || IFNULL(OLD.rendered_source_size, '') || '|' || IFNULL(OLD.rendered_source_mtime, '')
        || CASE WHEN (OLD.rendered_source_size IS NULL AND OLD.source_products_size IS NOT NULL)
            THEN '|source|' || OLD.source_products_size || '|' || IFNULL(OLD.source_products_mtime, '')
            ELSE '' END)
      IS NOT (NEW.thumbnail_path || '|' || NEW.rendered_revision || '|'
        || IFNULL(NEW.rendered_source_size, '') || '|' || IFNULL(NEW.rendered_source_mtime, '')
        || CASE WHEN (NEW.rendered_source_size IS NULL AND NEW.source_products_size IS NOT NULL)
            THEN '|source|' || NEW.source_products_size || '|' || IFNULL(NEW.source_products_mtime, '')
            ELSE '' END)
    BEGIN
    UPDATE media_asset SET render_dhash = NULL, render_signature_read = 0 WHERE rowid = NEW.rowid;
    DELETE FROM render_signature
    WHERE library_root_id = NEW.library_root_id AND relative_path = NEW.relative_path;
    END
    """

    /// The indexes v71 makes: the two that named the string stamp, made over its flag
    /// (`RenderSignatureSQL.owedPredicate`, `SamePhotoSQL.candidatePredicate`); On This Day's
    /// without the tested columns it carried since v62, since a day's few hundred rows read
    /// from the narrow table cost the pages their entries did (587 against 590 on the
    /// owner-shaped catalog) and the index shrinks by most of its 13 MB; and the chosen rows'
    /// (`ChosenRowsSQL`).
    static let hotAssetTableNewIndexes = [
        """
        CREATE INDEX idx_media_asset_render_signature_owed ON media_asset(library_root_id, relative_path)
        WHERE thumbnail_path IS NOT NULL
          AND kind IN ('image', 'raw')
          AND pending_trash_batch_unix_ms IS NULL
          AND trash_path IS NULL
          AND render_signature_read = 0
        """,
        """
        CREATE INDEX idx_media_asset_same_photo_candidate ON media_asset(library_root_id, relative_path, kind,
            capture_instant_unix, render_dhash, thumbnail_path, rendered_revision, rendered_source_size,
            rendered_source_mtime, source_products_size, source_products_mtime, metadata_source_size,
            metadata_source_mtime, pending_trash_batch_unix_ms, trash_path, hidden_by_source, source_path_sha1)
        WHERE kind IN ('image', 'raw')
          AND pending_trash_batch_unix_ms IS NULL
          AND trash_path IS NULL
          AND hidden_by_source = 0
          AND source_path_sha1 IS NULL
          AND render_dhash IS NOT NULL
        """,
        """
        CREATE INDEX idx_media_asset_capture_day
        ON media_asset(capture_day, capture_month, best_capture_local DESC, library_root_id, relative_path)
        """,
        """
        CREATE INDEX idx_media_asset_chosen ON media_asset(media_choice, library_root_id, best_capture_local,
            name_sort_key, byte_size, relative_path, pending_trash_batch_unix_ms, awaiting_presence, hidden_by_source,
            best_kind, content_identifier, shown_copy_root_id, has_copies)
        WHERE media_choice <> 'notRated'
        """,
    ]

    static func migrateToHotAssetTable(_ db: Database) throws {
        let indexes = try Row.fetchAll(db, sql: """
        SELECT name, sql FROM sqlite_master
        WHERE type = 'index' AND tbl_name = 'media_asset' AND sql IS NOT NULL
        ORDER BY name
        """).filter { !hotAssetTableReplacedIndexes.contains($0["name"] as String) }
        // The old table's triggers as they stand, made again on the new one.
        let triggers = try String.fetchAll(db, sql: """
        SELECT sql FROM sqlite_master WHERE type = 'trigger' AND tbl_name = 'media_asset' ORDER BY name
        """)
        try db.execute(sql: hotAssetTable)
        try db.execute(sql: """
        INSERT INTO media_asset_hot (\(hotAssetCopiedColumns), render_dhash, render_signature_read)
        SELECT \(hotAssetCopiedColumns),
               CASE WHEN \(v71SignatureIsCurrent) THEN render_dhash END, \(v71SignatureIsCurrent)
        FROM media_asset ORDER BY library_root_id, relative_path
        """)
        try db.execute(sql: """
        CREATE TABLE render_signature (
            library_root_id INTEGER NOT NULL,
            relative_path TEXT NOT NULL,
            gray BLOB NOT NULL,
            PRIMARY KEY (library_root_id, relative_path),
            FOREIGN KEY (library_root_id, relative_path)
                REFERENCES media_asset(library_root_id, relative_path)
                ON UPDATE CASCADE ON DELETE CASCADE
        )
        """)
        try db.execute(sql: """
        INSERT INTO render_signature (library_root_id, relative_path, gray)
        SELECT library_root_id, relative_path, render_gray FROM media_asset
        WHERE \(v71SignatureIsCurrent) AND render_dhash IS NOT NULL AND render_gray IS NOT NULL
        ORDER BY library_root_id, relative_path
        """)
        let before = try Int.fetchOne(db, sql: "SELECT count(*) FROM media_asset") ?? 0
        let after = try Int.fetchOne(db, sql: "SELECT count(*) FROM media_asset_hot") ?? 0
        // Every key copied, or nothing: a throw rolls back the migration's one transaction, so
        // the catalog stays as v70 left it.
        guard before == after else {
            OtosLog.persistence.errorOperation("catalog.migration.hotAssetTable", phase: "rowsLost", fields: [
                "before": "\(before)", "after": "\(after)",
            ])
            throw DatabaseError(resultCode: .SQLITE_CONSTRAINT, message: "v71 copied \(after) of \(before) asset rows")
        }
        try db.execute(sql: "DROP TABLE media_asset")
        try db.execute(sql: "ALTER TABLE media_asset_hot RENAME TO media_asset")
        for index in indexes {
            try db.execute(sql: index["sql"] as String)
        }
        for statement in hotAssetTableNewIndexes + triggers + [renderSignatureStaleTrigger] {
            try db.execute(sql: statement)
        }
        // A violation fails the migration with its table and count, and rolls it back whole.
        for table in hotAssetTableCheckedTables {
            let violations = try Int.fetchOne(db, sql: "SELECT count(*) FROM pragma_foreign_key_check('\(table)')") ?? 0
            guard violations == 0 else {
                OtosLog.persistence.errorOperation("catalog.migration.hotAssetTable", phase: "foreignKeyViolations", fields: [
                    "table": table, "rows": "\(violations)",
                ])
                throw DatabaseError(
                    resultCode: .SQLITE_CONSTRAINT_FOREIGNKEY,
                    message: "v71 left \(violations) rows of \(table) without their parent"
                )
            }
        }
        OtosLog.persistence.noticeOperation("catalog.migration.hotAssetTable", phase: "finish", fields: [
            "rows": "\(after)", "indexes": "\(indexes.count + hotAssetTableNewIndexes.count)",
            "triggers": "\(triggers.count + 1)",
        ])
    }

    /// v72: the derived folder's files and allocated bytes by kind, kept by the writes that
    /// name and unname its files (`DerivedFolderCounters`), and the journal of files a root's
    /// rename still has to move (`DerivedFolder.journalRenames`). Created empty: the counters are
    /// unknown until the first reconciliation's census sets them, which their absence owes.
    static let derivedFolderMigrationIdentifier = "v72_derived_folder"

    static let derivedFolderStatements: [String] = [
        """
        CREATE TABLE derived_folder (
            kind TEXT NOT NULL PRIMARY KEY,
            files INTEGER NOT NULL,
            bytes INTEGER NOT NULL
        )
        """,
        """
        CREATE TABLE derived_rename (
            old_name TEXT NOT NULL PRIMARY KEY,
            new_name TEXT NOT NULL
        )
        """,
    ]

    /// v73: what the People gallery paints from (ADR 0047, "What the People UI reads"), so its
    /// read is of the people and the faces that define them, never of every face joined to its
    /// photo (7.5–7.9 s of the 10.6 s gallery read on the owner's catalog, cold).
    /// - `person_summary`: each person's photo and video counts and newest face, which
    ///   `PeopleAssignment` computes from its read and writes when they change. The newest
    ///   face follows its face's moves and is cleared when the face is deleted, until the next
    ///   pass names another; the row goes with its person.
    /// - `idx_person_summary_cover`: the face side of that foreign key, so deleting or moving a
    ///   face seeks the summary naming it.
    /// - `idx_face_anchor`: the faces on the user's word or a seed (`FaceAssignmentColumn`
    ///   3 and 2), the hard rules' facts, about 5,700 of the owner's 103,135 faces, covering
    ///   what the gallery reads of them, so only their photos' rows are sought.
    ///
    /// Frozen as literals: what this migration did never changes with later code.
    static let peopleGalleryMigrationIdentifier = "v73_people_gallery"

    static let peopleGalleryStatements: [String] = [
        """
        CREATE TABLE person_summary (
            person_id INTEGER PRIMARY KEY REFERENCES person(id) ON DELETE CASCADE,
            photos INTEGER NOT NULL,
            videos INTEGER NOT NULL,
            cover_library_root_id INTEGER,
            cover_relative_path TEXT,
            cover_face_index INTEGER,
            FOREIGN KEY (cover_library_root_id, cover_relative_path, cover_face_index)
                REFERENCES face(library_root_id, relative_path, face_index)
                ON UPDATE CASCADE ON DELETE SET NULL
        )
        """,
        """
        CREATE INDEX idx_person_summary_cover
        ON person_summary(cover_library_root_id, cover_relative_path, cover_face_index)
        """,
        """
        CREATE INDEX idx_face_anchor
        ON face(person_id, library_root_id, relative_path, assignment, is_not_face)
        WHERE assignment IN (2, 3) AND is_not_face = 0 AND person_id IS NOT NULL
        """,
    ]

    /// v74: the text Vision read in photos is matched by an index in the catalog, not by
    /// strings held in memory (ADR 0048, "Text in the photo"):
    /// - `search_text_folded`: one row per reading that holds text, its key, and the reading
    ///   folded as matching compares it (`SearchTextReading.folded`). Its `id` is an explicit
    ///   `INTEGER PRIMARY KEY`, so the launch's `VACUUM` keeps it, where it may renumber a
    ///   reading's own rowid. It goes with its reading, and moves with it, by cascade.
    /// - `search_text_word`: an FTS5 table keyed by that `id`, holding the reading's words
    ///   (`SearchTextWords`): contentless, ASCII-tokenised, no positions. The trigger deletes a
    ///   row's words when its folded row goes, however it went.
    ///
    /// Frozen as literals. The rows are written from the stored readings by
    /// `indexStoredSearchTexts`, in the migration's transaction, before anything reads them.
    static let searchTextWordsMigrationIdentifier = "v74_search_text_words"

    static let searchTextWordsStatements: [String] = [
        """
        CREATE TABLE search_text_folded (
            id INTEGER PRIMARY KEY,
            library_root_id INTEGER NOT NULL,
            relative_path TEXT NOT NULL,
            folded TEXT NOT NULL,
            UNIQUE (library_root_id, relative_path),
            FOREIGN KEY (library_root_id, relative_path)
                REFERENCES search_text(library_root_id, relative_path)
                ON UPDATE CASCADE ON DELETE CASCADE
        )
        """,
        """
        CREATE VIRTUAL TABLE search_text_word USING fts5(
            words, tokenize = 'ascii', content = '', contentless_delete = 1, detail = none
        )
        """,
        """
        CREATE TRIGGER search_text_folded_delete AFTER DELETE ON search_text_folded
        BEGIN
            DELETE FROM search_text_word WHERE rowid = OLD.id;
        END
        """,
    ]

    /// Writes the index rows of every stored reading that holds text, current or not (a stale
    /// one is matched by none, since a match reads only current readings, and is replaced when
    /// it is read again), with the code that writes them for a new reading
    /// (`SearchTextStorage.index`).
    static func indexStoredSearchTexts(_ db: Database) throws {
        let start = ContinuousClock.now
        let rows = try Row.fetchCursor(db, sql: """
        SELECT library_root_id, relative_path, lines FROM search_text WHERE lines <> '[]'
        """)
        var indexed = 0
        while let row = try rows.next() {
            let lines = try SearchTextStorage.lines(fromJSON: row["lines"])
            if try SearchTextStorage.index(lines, rootID: row["library_root_id"], path: row["relative_path"], db: db) {
                indexed += 1
            }
        }
        OtosLog.persistence.noticeOperation("catalog.migration.searchTextWords", phase: "finish", fields: [
            "indexed": "\(indexed)", "ms": "\(DiagnosticsTiming.milliseconds(since: start))",
        ])
    }

    static func migrateToWholeSecondCaptureLocal(_ db: Database) throws {
        let indexes = try Row.fetchAll(db, sql: """
        SELECT name, sql FROM sqlite_master
        WHERE type = 'index' AND tbl_name = 'media_asset' AND sql LIKE '%best_capture_local%'
        """)
        for index in indexes {
            try db.execute(sql: "DROP INDEX \(index["name"] as String)")
        }
        try db.execute(sql: "ALTER TABLE media_asset DROP COLUMN best_capture_local")
        try db.execute(sql: """
        ALTER TABLE media_asset ADD COLUMN best_capture_local DOUBLE GENERATED ALWAYS AS (
            \(bestCaptureLocalSQL)
        ) VIRTUAL
        """)
        for index in indexes {
            try db.execute(sql: index["sql"] as String)
        }
        OtosLog.persistence.noticeOperation("catalog.migration.wholeSecondCaptureLocal", phase: "finish", fields: [
            "indexes": "\(indexes.count)",
        ])
    }

    static func migrateToCaptureLocalTime(_ db: Database, timeZone: TimeZone = .current) throws {
        try db.execute(sql: "ALTER TABLE media_asset ADD COLUMN assumed_utc_offset_seconds INTEGER")
        let rows = try Row.fetchAll(db, sql: """
        SELECT library_root_id, relative_path, \(absoluteCaptureSQL) AS absolute FROM media_asset
        WHERE \(absoluteCaptureSQL) IS NOT NULL
        """)
        let update = try db.makeStatement(sql: """
        UPDATE media_asset SET assumed_utc_offset_seconds = ? WHERE library_root_id = ? AND relative_path = ?
        """)
        for row in rows {
            let offset = CaptureLocalTime.assumedUTCOffset(
                for: row["absolute"],
                previousAbsolute: nil,
                previousOffset: nil,
                timeZone: timeZone
            )
            try update.execute(arguments: [offset, row["library_root_id"] as Int64, row["relative_path"] as String])
        }
        let indexes = try Row.fetchAll(db, sql: """
        SELECT name, sql FROM sqlite_master
        WHERE type = 'index' AND tbl_name = 'media_asset' AND sql LIKE '%best_capture_unix%'
        """)
        for index in indexes {
            try db.execute(sql: "DROP INDEX \(index["name"] as String)")
        }
        try db.execute(sql: "ALTER TABLE media_asset DROP COLUMN best_capture_unix")
        try db.execute(sql: """
        ALTER TABLE media_asset ADD COLUMN best_capture_local DOUBLE GENERATED ALWAYS AS (
            \(bestCaptureLocalSQL)
        ) VIRTUAL
        """)
        for index in indexes {
            try db.execute(sql: (index["sql"] as String).replacingOccurrences(of: "best_capture_unix", with: "best_capture_local"))
        }
        OtosLog.persistence.noticeOperation("catalog.migration.captureLocalTime", phase: "finish", fields: [
            "rows": "\(rows.count)",
            "indexes": "\(indexes.count)",
            "timeZone": timeZone.identifier,
        ])
    }

    static let baselineStatements: [String] = [
        """
        CREATE TABLE library_root (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            path TEXT NOT NULL UNIQUE,
            kind TEXT NOT NULL DEFAULT 'library',
            device_identity TEXT,
            display_name TEXT,
            last_seen_at DOUBLE,
            sort_index INTEGER NOT NULL DEFAULT 0,
            case_sensitive_names INTEGER,
            device_model TEXT
        )
        """,
        """
        CREATE UNIQUE INDEX idx_library_root_device_identity
        ON library_root(device_identity)
        WHERE device_identity IS NOT NULL
        """,
        """
        CREATE TABLE media_asset (
            library_root_id INTEGER NOT NULL REFERENCES library_root(id) ON DELETE CASCADE,
            relative_path TEXT NOT NULL,
            sort_key TEXT NOT NULL,
            name_sort_key TEXT NOT NULL,
            name TEXT,
            content_type_identifier TEXT,
            kind TEXT,
            format TEXT,
            byte_size INTEGER,
            created_at_unix DOUBLE,
            content_modified_at_unix DOUBLE,
            ts_original_unix DOUBLE,
            ts_quicktime_creation_unix DOUBLE,
            ts_digitized_unix DOUBLE,
            ts_gps_unix DOUBLE,
            enriched_kind TEXT,
            enriched_format TEXT,
            best_capture_unix DOUBLE GENERATED ALWAYS AS (
                COALESCE(
                    ts_original_unix,
                    ts_quicktime_creation_unix,
                    ts_digitized_unix,
                    ts_gps_unix,
                    created_at_unix,
                    content_modified_at_unix
                )
            ) STORED,
            best_kind TEXT GENERATED ALWAYS AS (COALESCE(enriched_kind, kind)) STORED,
            best_format TEXT GENERATED ALWAYS AS (COALESCE(enriched_format, format)) STORED,
            enriched_source_size INTEGER,
            enriched_source_mtime INTEGER,
            thumbnail_path TEXT,
            duration_seconds DOUBLE,
            enrichment_claimed DOUBLE,
            import_batch_unix_ms INTEGER,
            capture_wall_compact INTEGER,
            capture_wall_precision TEXT,
            import_source_root_path TEXT,
            import_source_relative_path TEXT,
            import_source_byte_size INTEGER,
            import_source_modified_at_epoch DOUBLE,
            import_destination_byte_size INTEGER,
            import_destination_modified_at_epoch DOUBLE,
            content_hash_xxh3_128 BLOB,
            content_hash_source_size INTEGER,
            content_hash_source_mtime INTEGER,
            media_choice TEXT NOT NULL DEFAULT 'notRated'
                CHECK (media_choice IN ('liked', 'notRated', 'disliked')),
            relative_path_key TEXT NOT NULL DEFAULT '',
            pending_trash_batch_unix_ms INTEGER,
            PRIMARY KEY (library_root_id, relative_path)
        )
        """,
        """
        CREATE INDEX idx_media_asset_order_global
        ON media_asset(sort_key, library_root_id, relative_path)
        """,
        """
        CREATE INDEX idx_media_asset_order_root
        ON media_asset(library_root_id, sort_key, relative_path)
        """,
        """
        CREATE INDEX idx_media_asset_best_capture_global_asc
        ON media_asset(best_capture_unix ASC, library_root_id, relative_path)
        """,
        """
        CREATE INDEX idx_media_asset_best_capture_root_asc
        ON media_asset(library_root_id, best_capture_unix ASC, relative_path)
        """,
        """
        CREATE INDEX idx_media_asset_name_global_asc
        ON media_asset(name_sort_key ASC, library_root_id, relative_path)
        """,
        """
        CREATE INDEX idx_media_asset_name_root_asc
        ON media_asset(library_root_id, name_sort_key ASC, relative_path)
        """,
        """
        CREATE INDEX idx_media_asset_size_global_asc
        ON media_asset((byte_size IS NULL), byte_size ASC, library_root_id, relative_path)
        """,
        """
        CREATE INDEX idx_media_asset_size_root_asc
        ON media_asset(library_root_id, (byte_size IS NULL), byte_size ASC, relative_path)
        """,
        """
        CREATE INDEX idx_media_asset_best_capture_global_desc
        ON media_asset(best_capture_unix DESC, library_root_id, relative_path)
        """,
        """
        CREATE INDEX idx_media_asset_best_capture_root_desc
        ON media_asset(library_root_id, best_capture_unix DESC, relative_path)
        """,
        """
        CREATE INDEX idx_media_asset_name_global_desc
        ON media_asset(name_sort_key DESC, library_root_id, relative_path)
        """,
        """
        CREATE INDEX idx_media_asset_name_root_desc
        ON media_asset(library_root_id, name_sort_key DESC, relative_path)
        """,
        """
        CREATE INDEX idx_media_asset_size_global_desc
        ON media_asset((byte_size IS NULL), byte_size DESC, library_root_id, relative_path)
        """,
        """
        CREATE INDEX idx_media_asset_size_root_desc
        ON media_asset(library_root_id, (byte_size IS NULL), byte_size DESC, relative_path)
        """,
        """
        CREATE INDEX idx_media_asset_import_batch
        ON media_asset(import_batch_unix_ms, library_root_id, relative_path)
        WHERE import_batch_unix_ms IS NOT NULL
        """,
        // The claim indexes as v1 created them, over the one enrichment stamp v13 split.
        // Their text is frozen here because it names columns v13 renames; v13 drops them
        // and creates the current ones from the gateway's predicates.
        v1ClaimIndex(EnrichmentClaimGateway.broadGlobalIndexName, global: true, broad: true),
        v1ClaimIndex(EnrichmentClaimGateway.broadRootIndexName, global: false, broad: true),
        v1ClaimIndex(EnrichmentClaimGateway.metadataOnlyGlobalIndexName, global: true, broad: false),
        v1ClaimIndex(EnrichmentClaimGateway.metadataOnlyRootIndexName, global: false, broad: false),
        """
        CREATE INDEX idx_media_asset_relative_path_key
        ON media_asset(library_root_id, relative_path_key)
        """,
        """
        CREATE INDEX idx_media_asset_pending_trash
        ON media_asset(pending_trash_batch_unix_ms, library_root_id, relative_path)
        WHERE pending_trash_batch_unix_ms IS NOT NULL
        """,
        """
        CREATE TABLE asset_metadata (
            library_root_id INTEGER NOT NULL,
            relative_path TEXT NOT NULL,
            family TEXT,
            file_extension TEXT,
            brand TEXT,
            camera_make TEXT,
            camera_model TEXT,
            lens_model TEXT,
            serial_number TEXT,
            orientation INTEGER,
            pixel_width INTEGER,
            pixel_height INTEGER,
            duration_seconds DOUBLE,
            frame_rate DOUBLE,
            video_codec TEXT,
            primary_latitude DOUBLE,
            primary_longitude DOUBLE,
            primary_altitude_meters DOUBLE,
            metadata_extra_json TEXT,
            PRIMARY KEY (library_root_id, relative_path),
            FOREIGN KEY (library_root_id, relative_path)
                REFERENCES media_asset(library_root_id, relative_path)
                ON DELETE CASCADE
                ON UPDATE CASCADE
        )
        """,
        """
        CREATE INDEX idx_asset_metadata_camera_model
        ON asset_metadata(camera_model)
        """,
        """
        CREATE INDEX idx_asset_metadata_dimensions
        ON asset_metadata(pixel_width, pixel_height)
        """,
        """
        CREATE TABLE media_companion (
            library_root_id INTEGER NOT NULL,
            relative_path TEXT NOT NULL,
            primary_relative_path TEXT,
            kind TEXT NOT NULL,
            byte_size INTEGER,
            content_modified_at DOUBLE,
            relative_path_key TEXT NOT NULL DEFAULT '',
            PRIMARY KEY (library_root_id, relative_path),
            FOREIGN KEY (library_root_id) REFERENCES library_root(id) ON DELETE CASCADE
        )
        """,
        """
        CREATE INDEX idx_media_companion_primary
        ON media_companion(library_root_id, primary_relative_path)
        """,
        """
        CREATE INDEX idx_media_companion_relative_path_key
        ON media_companion(library_root_id, relative_path_key)
        """,
        // The import journal: one row per file an import is copying or publishing, naming
        // every staging file it creates (companions in the table after it).
        """
        CREATE TABLE active_file_operation (
            operation_key TEXT PRIMARY KEY NOT NULL,
            source_kind TEXT NOT NULL,
            source_device_identity TEXT,
            source_root_path TEXT NOT NULL,
            source_relative_path TEXT NOT NULL,
            destination_root_path TEXT NOT NULL,
            destination_relative_path TEXT NOT NULL,
            staging_path TEXT,
            content_hash_xxh3_128 BLOB,
            import_batch_unix_ms INTEGER NOT NULL,
            source_byte_size INTEGER NOT NULL,
            source_modified_at DOUBLE NOT NULL,
            destination_modified_at DOUBLE,
            phase TEXT NOT NULL,
            updated_at DOUBLE NOT NULL
        )
        """,
        """
        CREATE TABLE active_file_operation_companion_staging (
            operation_key TEXT NOT NULL
                REFERENCES active_file_operation(operation_key) ON DELETE CASCADE,
            staging_path TEXT NOT NULL,
            PRIMARY KEY (operation_key, staging_path)
        )
        """,
        """
        CREATE TABLE active_source_erase (
            operation_key TEXT PRIMARY KEY NOT NULL,
            source_kind TEXT NOT NULL,
            source_device_identity TEXT,
            source_root_path TEXT NOT NULL,
            source_relative_path TEXT NOT NULL,
            source_byte_size INTEGER,
            updated_at DOUBLE NOT NULL
        )
        """,
        """
        CREATE TABLE active_reorganization_component (
            component_key TEXT PRIMARY KEY NOT NULL,
            library_root_path TEXT NOT NULL,
            plan_generation INTEGER NOT NULL,
            planned_root_revision INTEGER NOT NULL,
            phase TEXT NOT NULL,
            next_step_index INTEGER NOT NULL,
            created_at DOUBLE NOT NULL,
            updated_at DOUBLE NOT NULL
        )
        """,
        """
        CREATE TABLE active_reorganization_member (
            component_key TEXT NOT NULL,
            member_index INTEGER NOT NULL,
            member_kind TEXT NOT NULL,
            logical_source_relative_path TEXT NOT NULL,
            current_relative_path TEXT NOT NULL,
            final_relative_path TEXT NOT NULL,
            byte_size INTEGER NOT NULL,
            content_modified_at DOUBLE NOT NULL,
            PRIMARY KEY (component_key, member_index),
            FOREIGN KEY (component_key)
                REFERENCES active_reorganization_component(component_key)
                ON DELETE CASCADE
        )
        """,
        """
        CREATE TABLE active_reorganization_step (
            component_key TEXT NOT NULL,
            step_index INTEGER NOT NULL,
            member_index INTEGER NOT NULL,
            source_relative_path TEXT NOT NULL,
            destination_relative_path TEXT NOT NULL,
            phase TEXT NOT NULL,
            PRIMARY KEY (component_key, step_index),
            FOREIGN KEY (component_key, member_index)
                REFERENCES active_reorganization_member(component_key, member_index)
                ON DELETE CASCADE
        )
        """,
        """
        CREATE TABLE active_reorganization_directory (
            component_key TEXT NOT NULL,
            relative_path TEXT NOT NULL,
            phase TEXT NOT NULL,
            PRIMARY KEY (component_key, relative_path),
            FOREIGN KEY (component_key)
                REFERENCES active_reorganization_component(component_key)
                ON DELETE CASCADE
        )
        """,
        // Identity remaps a settled reorganization committed and the window has not yet
        // applied (ARC-052).
        """
        CREATE TABLE pending_identity_remap_batch (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            library_root_path TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE pending_identity_remap (
            batch_id INTEGER NOT NULL REFERENCES pending_identity_remap_batch(id) ON DELETE CASCADE,
            ordinal INTEGER NOT NULL,
            old_relative_path TEXT NOT NULL,
            new_relative_path TEXT NOT NULL,
            PRIMARY KEY (batch_id, ordinal)
        )
        """,
    ]

    /// A claim index over rows owing a product, newest first: the claim queries walk these
    /// by name with `INDEXED BY`, so the `WHERE` text is the gateway's predicate verbatim.
    /// `orderColumn` is the capture-order column of the schema the migration runs against:
    /// `best_capture_unix` before v23, `best_capture_local` from it.
    static func claimIndex(_ name: String, global: Bool, claim: EnrichmentClaim, orderColumn: String) -> String {
        claimIndex(
            name,
            global: global,
            predicate: EnrichmentClaimGateway.stalenessSQLPredicate(claim),
            orderColumn: orderColumn
        )
    }

    private static func v1ClaimIndex(_ name: String, global: Bool, broad: Bool) -> String {
        let metadata = """
        enriched_source_size IS NULL
           OR enriched_source_mtime IS NULL
           OR COALESCE(byte_size, -1) <> COALESCE(enriched_source_size, -1)
           OR CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER)
              <> COALESCE(enriched_source_mtime, -1)
        """
        let hash = """
        content_hash_xxh3_128 IS NULL
           OR length(content_hash_xxh3_128) <> 16
           OR content_hash_source_size IS NULL
           OR content_hash_source_mtime IS NULL
           OR COALESCE(byte_size, -1) <> COALESCE(content_hash_source_size, -1)
           OR CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER)
              <> COALESCE(content_hash_source_mtime, -1)
        """
        let predicate = broad
            ? """
            \(metadata)
               OR \(hash)
            """
            : metadata
        return claimIndex(name, global: global, predicate: predicate, orderColumn: "best_capture_unix")
    }

    private static func claimIndex(_ name: String, global: Bool, predicate: String, orderColumn: String) -> String {
        let columns = global
            ? "\(orderColumn) DESC, library_root_id, relative_path"
            : "library_root_id, \(orderColumn) DESC, relative_path"
        return """
        CREATE INDEX \(name)
        ON media_asset(\(columns))
        WHERE \(predicate)
        """
    }
}
