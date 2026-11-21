import GRDB

/// Companion SQL guide (ADR 0002)
///
/// The statements of `media_companion`, the sidecar files a scan inventories beside their
/// primary asset, keyed like an asset. `CatalogStore` owns when each runs; this enum owns only
/// the text.
nonisolated enum MediaCompanionSQL {
    static let respellCompanionSQL = """
    UPDATE media_companion SET relative_path = ?, relative_path_key = ?
    WHERE \(AssetKey.exactText())
    """

    static let deleteCompanionRowSQL = """
    DELETE FROM media_companion
    WHERE \(AssetKey.exactText())
    """

    static let companionsOfAssetSQL = """
    SELECT relative_path FROM media_companion
    WHERE library_root_id = ? AND primary_relative_path = ?
    ORDER BY relative_path
    """

    static let pathsOfSubtreeSQL = """
    SELECT relative_path
    FROM media_companion
    WHERE library_root_id = ?
      AND \(AssetRowSQL.subtreeSQL)
    """

    static let pathsOfRootSQL = """
    SELECT relative_path
    FROM media_companion
    WHERE library_root_id = ?
    """

    static let companionsOfRootSQL = """
    SELECT relative_path, primary_relative_path, kind, byte_size, content_modified_at
    FROM media_companion
    WHERE library_root_id = ?
    ORDER BY relative_path COLLATE NOCASE, relative_path
    """

    static let otherSpellingSQL = """
    SELECT relative_path FROM media_companion
    WHERE \(AssetKey.volumeAware()) AND relative_path <> ? LIMIT 1
    """

    static let upsertSQL = """
    INSERT INTO media_companion (
        library_root_id,
        relative_path,
        relative_path_key,
        primary_relative_path,
        kind,
        byte_size,
        content_modified_at
    )
    VALUES (?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(library_root_id, relative_path) DO UPDATE SET
        primary_relative_path = excluded.primary_relative_path,
        kind = excluded.kind,
        byte_size = excluded.byte_size,
        content_modified_at = excluded.content_modified_at,
        relative_path_key = excluded.relative_path_key
    WHERE media_companion.primary_relative_path IS NOT excluded.primary_relative_path
       OR media_companion.relative_path_key IS NOT excluded.relative_path_key
       OR media_companion.kind IS NOT excluded.kind
       OR media_companion.byte_size IS NOT excluded.byte_size
       OR CAST(COALESCE(media_companion.content_modified_at, -1) AS INTEGER)
          IS NOT CAST(COALESCE(excluded.content_modified_at, -1) AS INTEGER)
    """

    /// What a scan pass's baseline reads of a root's companions, or of those under a subtree
    /// (binds the root, then `AssetRowSQL.subtreeArguments`).
    static func scanBaselineSQL(underSubtree: Bool) -> String {
        """
        SELECT relative_path, relative_path_key, kind, byte_size, content_modified_at
        FROM media_companion
        WHERE library_root_id = ?\(underSubtree ? " AND \(AssetRowSQL.subtreeSQL)" : "")
        """
    }

    static let remapCompanionPathSQL = """
    UPDATE media_companion
    SET relative_path = ?, relative_path_key = ?
    WHERE \(AssetKey.exactText())
    """

    static let remapPrimaryPathSQL = """
    UPDATE media_companion
    SET primary_relative_path = ?
    WHERE library_root_id = ?
      AND primary_relative_path = ?
    """
}
