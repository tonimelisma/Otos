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
            claimIndex(EnrichmentClaimGateway.broadGlobalIndexName, global: true, claim: .products, orderColumn: "best_capture_unix"),
            claimIndex(EnrichmentClaimGateway.broadRootIndexName, global: false, claim: .products, orderColumn: "best_capture_unix"),
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

    /// The claim index pair `v18_faces` made for a library's rows, and the products they
    /// owed: every product, faces included. `v30_faces_from_preview` drops them.
    private static let libraryGlobalIndexName = "idx_media_asset_needs_enrichment_global_library"
    private static let libraryRootIndexName = "idx_media_asset_needs_enrichment_root_library"
    private static var libraryClaimPredicate: String {
        """
        \(EnrichmentClaimGateway.stalenessSQLPredicate(.products))
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
        func cell(_ column: String, lowest: Int, highest: Int) -> String {
            let scaled = "(\(column) * 50.0)"
            return "MIN(MAX(CAST(\(scaled) AS INTEGER) - (\(scaled) < CAST(\(scaled) AS INTEGER)), \(lowest)), \(highest))"
        }
        return [
            """
            ALTER TABLE asset_metadata ADD COLUMN place_cell_latitude INTEGER
            GENERATED ALWAYS AS (\(cell("primary_latitude", lowest: -4500, highest: 4499))) VIRTUAL
            """,
            """
            ALTER TABLE asset_metadata ADD COLUMN place_cell_longitude INTEGER
            GENERATED ALWAYS AS (\(cell("primary_longitude", lowest: -9000, highest: 8999))) VIRTUAL
            """,
            """
            CREATE INDEX idx_asset_metadata_place_cell
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

    /// The absolute time an item without a wall clock is placed by, as SQL over `media_asset`.
    static let absoluteCaptureSQL = "COALESCE(capture_instant_unix, created_at_unix, content_modified_at_unix)"

    /// `best_capture_local`'s definition: the stored wall clock (`YYYYMMDDHHMMSS`) as
    /// seconds of a UTC reading, else the absolute time plus the assumed offset. A wall that
    /// is not a real date-time is NULL to `unixepoch` and falls through to the absolute time.
    static let bestCaptureLocalSQL = """
    COALESCE(
        unixepoch(printf('%04d-%02d-%02d %02d:%02d:%02d',
            capture_wall_compact / 10000000000, (capture_wall_compact / 100000000) % 100,
            (capture_wall_compact / 1000000) % 100, (capture_wall_compact / 10000) % 100,
            (capture_wall_compact / 100) % 100, capture_wall_compact % 100)),
        \(absoluteCaptureSQL) + assumed_utc_offset_seconds
    )
    """

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
