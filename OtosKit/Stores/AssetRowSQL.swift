import GRDB

/// Asset row SQL guide (ADR 0002, ADR 0008)
///
/// The statements of an asset's own `media_asset` row that are not enrichment's: its key and
/// its spellings (a scan's upsert, respell and witnessed move), its source's facts, the Trash,
/// its copies, and what the user authored on it — a media choice, a stack's key choice, an
/// edit recipe. `CatalogStore` owns when each runs and what it announces; this enum owns only
/// the text. What enrichment writes on the same row is `AssetEnrichmentSQL`'s.
nonisolated enum AssetRowSQL {
    static let photoInfoAssetSQL = """
    SELECT import_batch_unix_ms, edit_recipe_json IS NOT NULL AS edited,
           (\(ContentDigestSQL.isCurrent("media_asset"))) AS has_digest,
           \(PhotoCopySQL.isCopy("media_asset")) AS is_copy
    FROM media_asset WHERE \(AssetKey.exactText())
    """

    static let photoInfoCopiesSQL = """
    SELECT root.path FROM media_asset AS a
    JOIN media_asset AS copy INDEXED BY \(PhotoCopySQL.indexName)
      ON \(PhotoCopySQL.isCopy("copy", of: "a"))
    JOIN library_root AS root ON root.id = copy.library_root_id
    WHERE \(AssetKey.exactText("a"))
      AND NOT (copy.library_root_id = a.library_root_id AND copy.relative_path = a.relative_path)
      AND \(CatalogVisibilitySQL.isPresent("copy"))
    ORDER BY \(CatalogSchema.copyRank("copy"))
    """

    static let askedPhotoBurstSQL = """
    SELECT CASE WHEN best_kind IN ('raw', 'image') THEN burst_identifier END FROM media_asset
    WHERE \(AssetKey.exactText())
    """

    static let photoCopyKeySQL = """
    SELECT CASE WHEN has_copies = 1 THEN copy_key END FROM media_asset
    WHERE \(AssetKey.exactText())
    """

    static let photoCaptureLocalSQL = "SELECT best_capture_local FROM media_asset WHERE \(AssetKey.exactText())"

    static let setChoiceSQL = "UPDATE media_asset SET media_choice = ? WHERE \(AssetKey.exactText())"

    static let setPendingTrashSQL = """
    UPDATE media_asset SET pending_trash_batch_unix_ms = ?
    WHERE \(AssetKey.exactText())
      AND (pending_trash_batch_unix_ms IS NULL) = ?
      AND trash_path IS NULL
    """

    static let carriedWorkSQL = "SELECT media_choice, edit_recipe_json FROM media_asset WHERE \(AssetKey.exactText())"

    static let restoredRowIsBackSQL = """
    SELECT EXISTS(
        SELECT 1 FROM media_asset
        WHERE \(AssetKey.exactText())
          AND pending_trash_batch_unix_ms IS NULL AND trash_path IS NULL
    )
    """

    static func stackKeyChoiceSQL(_ kind: PhotoStackKind) -> String {
        "SELECT \(stackKeyChosenColumn(kind)) FROM media_asset WHERE \(AssetKey.exactText())"
    }

    static func setStackKeyChoiceSQL(_ kind: PhotoStackKind) -> String {
        let column = stackKeyChosenColumn(kind)
        return """
        UPDATE media_asset SET \(column) = ?
        WHERE \(AssetKey.exactText()) AND \(column) IS NOT ?
        """
    }

    static let mediaChoiceSQL = "SELECT media_choice FROM media_asset WHERE \(AssetKey.exactText())"

    static let changeMediaChoiceSQL = """
    UPDATE media_asset
    SET media_choice = ?
    WHERE \(AssetKey.exactText()) AND media_choice <> ?
    """

    static let editRecipeSQL = """
    SELECT edit_recipe_json, edit_revision FROM media_asset
    WHERE \(AssetKey.exactText())
    """

    static let editRecipeRowSQL = """
    SELECT edit_recipe_json, edit_revision, byte_size, content_modified_at_unix, best_kind FROM media_asset
    WHERE \(AssetKey.exactText())
    """

    static let writeEditRecipeSQL = """
    UPDATE media_asset SET edit_recipe_json = ?, edit_revision = ?,
        rendered_revision = CASE WHEN ? THEN ? ELSE rendered_revision END
    WHERE \(AssetKey.exactText())
    """

    static let replacedEditRecipeRowSQL = """
    SELECT edit_recipe_json, edit_revision, best_kind FROM media_asset
    WHERE \(AssetKey.exactText())
    """

    static let sourceHiddenSQL = """
    UPDATE media_asset SET hidden_by_source = ?
    WHERE \(AssetKey.exactText()) AND hidden_by_source IS NOT ?
    """

    static let sourceItemFactsSQL = """
    UPDATE media_asset SET source_item_id = ?, source_path_sha1 = ?, source_products_absent = ?
    WHERE \(AssetKey.exactText())
      AND (source_item_id IS NOT ? OR source_path_sha1 IS NOT ? OR source_products_absent IS NOT ?)
    """

    static let sourceDigestSQL = """
    UPDATE media_asset SET
        content_sha1 = ?,
        content_hash_source_size = COALESCE(byte_size, -1),
        content_hash_source_mtime = CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER)
    WHERE \(AssetKey.exactText()) AND (\(ContentDigestSQL.current("media_asset"))) IS NOT ?
    """

    static let sourceItemIDSQL = "SELECT source_item_id FROM media_asset WHERE \(AssetKey.exactText())"

    static let storedByteSizeSQL = "SELECT byte_size FROM media_asset WHERE \(AssetKey.exactText())"

    static let markTrashedSQL = """
    UPDATE media_asset
    SET trash_path = ?, pending_trash_batch_unix_ms = ?, enrichment_claimed = NULL
    WHERE \(AssetKey.exactText())
    """

    static let deleteAssetRowSQL = "DELETE FROM media_asset WHERE \(AssetKey.exactText())"

    static let deletionTargetSQL = """
    SELECT thumbnail_path, preview_path, face_frames_path, trash_path
    FROM media_asset
    WHERE \(AssetKey.exactText())
    """

    /// A `relative_path` that is `subtree` itself or inside `subtree/`, never a sibling
    /// such as `subtree2` or `subtree.jpg`. One range of the binary-collated path,
    /// `[subtree, subtree0)` (`0` is the byte after `/`), which the
    /// `(library_root_id, relative_path)` key seeks; inside it, only `subtree` and paths at
    /// or after `subtree/` are kept. A `LIKE` prefix, or an `OR` of two ranges, makes SQLite
    /// read every row of the root once per folder. Bound with `subtreeArguments`.
    static let subtreeSQL = """
    (relative_path >= ? AND relative_path < ? AND (relative_path = ? OR relative_path >= ?))
    """

    static let rowAtPathSQL = "SELECT 1 FROM media_asset WHERE \(AssetKey.exactText())"

    static let spellingsOfPathSQL = """
    SELECT relative_path, 0 AS at_path FROM media_asset
    WHERE \(AssetKey.volumeAware()) AND relative_path <> ?
    UNION ALL
    SELECT relative_path, 1 AS at_path FROM media_asset
    WHERE \(AssetKey.exactText())
    """

    static let respellAssetSQL = """
    UPDATE media_asset SET relative_path = ?, relative_path_key = ?, awaiting_presence = 0
    WHERE \(AssetKey.exactText())
    """

    static let moveAssetRowSQL = """
    UPDATE media_asset SET library_root_id = ?, relative_path = ?, relative_path_key = ?
    WHERE \(AssetKey.exactText())
    """

    static let putBackFromTrashSQL = """
    UPDATE media_asset SET pending_trash_batch_unix_ms = NULL, trash_path = NULL
    WHERE \(AssetKey.exactText()) AND trash_path IS NOT NULL
    """

    /// Where one row stands among copies (`DigestStanding`): its stored digest and the facts
    /// it was read at, its copy key (v79), and whether another row, of any presence, shares
    /// that key. Binds the root and the path; one probe of the copy key's index.
    static let digestStandingSQL = """
    SELECT a.content_sha1, a.content_hash_source_size, a.content_hash_source_mtime,
           a.copy_key AS copy_key,
           CASE WHEN \(PhotoCopySQL.isCopy("a")) THEN EXISTS (
               SELECT 1 FROM media_asset AS copy INDEXED BY \(PhotoCopySQL.indexName)
               WHERE \(PhotoCopySQL.isCopy("copy", of: "a")) AND copy.rowid <> a.rowid
           ) ELSE 0 END AS shared
    FROM media_asset AS a
    WHERE \(AssetKey.exactText("a"))
    """

    static let stackCandidateExistsSQL = """
    SELECT EXISTS (
        SELECT 1 FROM media_asset INDEXED BY idx_media_asset_stack_candidate
        WHERE library_root_id = ? AND best_kind IN ('raw', 'image') AND parent_path = ?
          AND relative_path <> ?
          AND (best_kind = 'raw' OR ?)
          AND \(CatalogVisibilitySQL.isPresent("media_asset"))
    )
    """

    static let pendingTrashOfBatchSQL = """
    SELECT library_root_id, relative_path, pending_trash_batch_unix_ms
    FROM media_asset INDEXED BY idx_media_asset_pending_trash
    WHERE pending_trash_batch_unix_ms IS NOT NULL AND trash_path IS NULL
    ORDER BY pending_trash_batch_unix_ms, library_root_id, relative_path
    """

    static let highestRowIDSQL = "SELECT MAX(rowid) FROM media_asset"

    static let writeSourceByteSizeSQL = """
    UPDATE media_asset SET byte_size = ?
    WHERE library_root_id = ? AND source_item_id = ? AND byte_size IS NOT ?
    """

    static let pathOfSourceItemSQL = "SELECT relative_path FROM media_asset WHERE library_root_id = ? AND source_item_id = ?"

    static let importBatchCountSQL = "SELECT COUNT(*) FROM media_asset WHERE import_batch_unix_ms = ?"

    /// The rows of `count` source items (bound after the root) in one root.
    static func rowsOfSourceItemsSQL(count: Int) -> String {
        """
        SELECT source_item_id, relative_path, hidden_by_source FROM media_asset
        WHERE library_root_id = ? AND source_item_id IN (\(Array(repeating: "?", count: count).joined(separator: ", ")))
        """
    }

    /// The assets of `rootCount` roots that a search's facts allow (ADR 0048), with each one's
    /// coordinate: captured within a span (`dated`, two bounds), inside a place's box
    /// (`placed`, four bounds), and holding a face of each of `people` people (one id each).
    /// Binds the roots, then each fact's values in that order.
    static func factMatchesSQL(rootCount: Int, dated: Bool, placed: Bool, people: Int) -> String {
        var clauses = ["a.library_root_id IN (\(Array(repeating: "?", count: rootCount).joined(separator: ", ")))"]
        if dated {
            clauses.append("a.best_capture_local >= ? AND a.best_capture_local < ?")
        }
        if placed {
            clauses.append("m.primary_latitude BETWEEN ? AND ? AND m.primary_longitude BETWEEN ? AND ?")
        }
        clauses += Array(repeating: """
        EXISTS (SELECT 1 FROM face AS f WHERE f.library_root_id = a.library_root_id
            AND f.relative_path = a.relative_path AND f.person_id = ?)
        """, count: people)
        return """
        SELECT a.library_root_id, a.relative_path, m.primary_latitude, m.primary_longitude
        FROM media_asset AS a
        LEFT JOIN asset_metadata AS m ON m.library_root_id = a.library_root_id AND m.relative_path = a.relative_path
        WHERE \(clauses.joined(separator: " AND "))
        """
    }

    static let awaitPresenceSQL = "UPDATE media_asset SET awaiting_presence = 1 WHERE library_root_id = ? AND awaiting_presence = 0"

    static let revealRootSQL = "UPDATE media_asset SET awaiting_presence = 0 WHERE library_root_id = ? AND awaiting_presence <> 0"

    static let revealAllSQL = "UPDATE media_asset SET awaiting_presence = 0 WHERE awaiting_presence <> 0"

    static let existingRowsOfRootSQL = """
    SELECT relative_path, thumbnail_path, preview_path, face_frames_path, metadata_source_size,
        metadata_source_mtime, trash_path
    FROM media_asset
    WHERE library_root_id = ?
      AND \(AssetRowSQL.subtreeSQL)
    """

    static let existingRowsOfSubtreeSQL = """
    SELECT relative_path, thumbnail_path, preview_path, face_frames_path, metadata_source_size,
        metadata_source_mtime, trash_path
    FROM media_asset
    WHERE library_root_id = ?
    """

    static let primariesInDirectorySQL = """
    SELECT relative_path, name, content_type_identifier, kind, format,
           byte_size, created_at_unix, content_modified_at_unix
    FROM media_asset
    WHERE library_root_id = ? AND parent_path = ?
    """

    static let moveWitnessesSQL = """
    SELECT a.library_root_id, a.relative_path, r.path AS root_path
    FROM media_asset a JOIN library_root r ON r.id = a.library_root_id
    WHERE a.file_identifier = ? AND a.byte_size = ?
      AND CAST(COALESCE(a.created_at_unix, -1) AS INTEGER) = ?
    """

    static let upsertScannedSQL = """
    INSERT INTO media_asset (
        library_root_id,
        relative_path,
        relative_path_key,
        name_sort_key,
        name,
        content_type_identifier,
        kind,
        format,
        byte_size,
        created_at_unix,
        content_modified_at_unix,
        file_identifier,
        assumed_utc_offset_seconds
    )
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(library_root_id, relative_path) DO UPDATE SET
        assumed_utc_offset_seconds = CASE
            WHEN CAST(COALESCE(media_asset.capture_instant_unix, media_asset.created_at_unix,
                               media_asset.content_modified_at_unix) AS INTEGER)
              IS CAST(COALESCE(media_asset.capture_instant_unix, excluded.created_at_unix,
                               excluded.content_modified_at_unix) AS INTEGER)
            THEN media_asset.assumed_utc_offset_seconds
            ELSE excluded.assumed_utc_offset_seconds
        END,
        name_sort_key = excluded.name_sort_key,
        name = excluded.name,
        content_type_identifier = excluded.content_type_identifier,
        kind = excluded.kind,
        format = excluded.format,
        byte_size = excluded.byte_size,
        created_at_unix = excluded.created_at_unix,
        content_modified_at_unix = excluded.content_modified_at_unix,
        file_identifier = excluded.file_identifier,
        relative_path_key = excluded.relative_path_key,
        awaiting_presence = 0
    WHERE media_asset.awaiting_presence <> 0
       OR media_asset.relative_path_key IS NOT excluded.relative_path_key
       OR media_asset.file_identifier IS NOT excluded.file_identifier
       OR media_asset.name_sort_key IS NOT excluded.name_sort_key
       OR media_asset.name IS NOT excluded.name
       OR media_asset.content_type_identifier IS NOT excluded.content_type_identifier
       OR media_asset.kind IS NOT excluded.kind
       OR media_asset.format IS NOT excluded.format
       OR media_asset.byte_size IS NOT excluded.byte_size
       OR CAST(COALESCE(media_asset.created_at_unix, -1) AS INTEGER)
          IS NOT CAST(COALESCE(excluded.created_at_unix, -1) AS INTEGER)
       OR CAST(COALESCE(media_asset.content_modified_at_unix, -1) AS INTEGER)
          IS NOT CAST(COALESCE(excluded.content_modified_at_unix, -1) AS INTEGER)
    """

    static func subtreeArguments(_ subtree: MediaRelativePath) -> StatementArguments {
        let path = subtree.rawValue
        return [path, path + "0", path, path + "/"]
    }

    /// What a scan pass's baseline reads of a root's present rows, or of those under a
    /// subtree (binds the root, then `subtreeArguments`).
    static func scanBaselineSQL(underSubtree: Bool) -> String {
        """
        SELECT relative_path, relative_path_key, name_sort_key, name, content_type_identifier, kind, format,
            byte_size, created_at_unix, content_modified_at_unix, file_identifier
        FROM media_asset
        WHERE library_root_id = ? AND awaiting_presence = 0 AND trash_path IS NULL\(underSubtree ? " AND \(subtreeSQL)" : "")
        """
    }

    static let settleImportedAssetSQL = """
    UPDATE media_asset
    SET import_batch_unix_ms = ?,
        import_source_root_path = ?,
        import_source_relative_path = ?,
        import_source_byte_size = ?,
        import_source_modified_at_epoch = ?,
        import_destination_byte_size = ?,
        import_destination_modified_at_epoch = ?,
        content_sha1 = ?,
        content_hash_source_size = ?,
        content_hash_source_mtime = ?,
        media_choice = COALESCE(
            (SELECT media_choice FROM media_asset
             WHERE \(AssetKey.exactText())),
            media_choice
        ),
        edit_recipe_json = COALESCE(
            (SELECT edit_recipe_json FROM media_asset
             WHERE \(AssetKey.exactText())),
            edit_recipe_json
        ),
        edit_revision = COALESCE(
            (SELECT edit_revision FROM media_asset
             WHERE \(AssetKey.exactText())),
            edit_revision
        )
    WHERE \(AssetKey.exactText())
    """

    static let remapAssetPathRenamingSQL = """
    UPDATE media_asset
    SET relative_path = ?,
        relative_path_key = ?,
        name_sort_key = ?,
        name = ?
    WHERE \(AssetKey.exactText())
    """

    static let remapAssetPathSQL = """
    UPDATE media_asset
    SET relative_path = ?, relative_path_key = ?
    WHERE \(AssetKey.exactText())
    """

    /// A pair's file and a burst's frame are chosen apart, so choosing one never clears
    /// the other.
    static func stackKeyChosenColumn(_ kind: PhotoStackKind) -> String {
        switch kind {
        case .pair: "stack_key_chosen_at_unix_ms"
        case .burst: "burst_key_chosen_at_unix_ms"
        }
    }
}
