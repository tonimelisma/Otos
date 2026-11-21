import GRDB
import MediaMetadata

/// Asset enrichment SQL guide (ADR 0009, ADR 0011)
///
/// The statements of what enrichment derives onto an asset's `media_asset` row from its bytes:
/// the metadata record's stamp and projection, the content digest, renderings and thumbnails
/// (Otos's own or the source's), the render signature, the faces' stamp, and the claims and
/// verdicts that order that work. Each write names the source facts it was read at, so a row
/// that changed since is left alone. `CatalogStore` owns when each runs and what it announces;
/// this enum owns only the text.
nonisolated enum AssetEnrichmentSQL {
    static let oweFacesAgainSQL = """
    UPDATE media_asset SET faces_source_size = NULL, faces_source_mtime = NULL
    WHERE \(AssetKey.exactText()) AND faces_source_size IS NOT NULL
    """

    static let previewFacesAreCurrentSQL = """
    SELECT 1 FROM media_asset
    WHERE \(AssetKey.exactText()) AND preview_path IS ?
      AND (\(PreviewFaceSQL.previewSize)) IS ? AND (\(PreviewFaceSQL.previewMTime)) IS ?
      AND rendered_revision = ?
    """

    static let renderedEditRowSQL = """
    SELECT edit_revision, byte_size, content_modified_at_unix, thumbnail_path, preview_path
    FROM media_asset WHERE \(AssetKey.exactText())
    """

    static let writeRenderedEditProductsSQL = """
    UPDATE media_asset SET thumbnail_path = ?, preview_path = ?, rendered_revision = ?
    WHERE \(AssetKey.exactText())
    """

    /// Every edit not yet rendered, through `idx_media_asset_unrendered_edit` (v55): the
    /// rows it changes, never every row.
    static let releaseAllUnrenderedEditsSQL = """
    UPDATE media_asset SET rendered_source_size = NULL, rendered_source_mtime = NULL
    WHERE edit_revision <> rendered_revision
    """

    static let releaseUnrenderedEditSQL = """
    UPDATE media_asset SET rendered_source_size = NULL, rendered_source_mtime = NULL
    WHERE \(AssetKey.exactText()) AND edit_revision <> rendered_revision
    """

    static let applyContentHashSQL = """
    UPDATE media_asset SET
        content_sha1 = ?,
        content_hash_source_size = ?,
        content_hash_source_mtime = ?,
        enrichment_claimed = NULL
    WHERE \(AssetKey.exactText())
      AND COALESCE(byte_size, -1) = COALESCE(?, -1)
      AND CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER) = COALESCE(?, -1)
    """

    static let releaseContentHashClaimSQL = "UPDATE media_asset SET enrichment_claimed = NULL WHERE \(AssetKey.exactText())"

    /// One root's rows owed a metadata re-read, in path order after a path, through the asset
    /// key (`CandidateWalk.keyPage`: binds the root, the path, the limit). The roots are
    /// named, so the walk never reaches an account's rows to discard them.
    static let metadataRefreshCandidatesSQL = """
    SELECT a.library_root_id, a.relative_path, a.byte_size, a.metadata_source_mtime,
        (\(predatesContentIdentifierSQL) AND m.camera_make = 'Apple') AS may_complete_live_photo
    FROM media_asset a INDEXED BY sqlite_autoindex_media_asset_1
    CROSS JOIN asset_metadata m ON m.library_root_id = a.library_root_id AND m.relative_path = a.relative_path
    WHERE a.library_root_id = ? AND a.relative_path > ?
        AND COALESCE(m.extraction_revision, 0) < \(currentExtractionRevisionSQL)
        AND NOT (\(EnrichmentClaimGateway.metadataStalenessSQLPredicate()))
    ORDER BY a.relative_path
    LIMIT ?
    """

    /// A record read before MediaMetadata reported the content identifier (0.8.2), of a
    /// family that can carry one. v7 cleared every stored revision and v9 cleared these
    /// families' again, and every read since stores its revision, so a NULL revision here
    /// is exactly a record the identifier was never read for.
    static let predatesContentIdentifierSQL =
        "(m.family IN ('heif', 'jpeg', 'isoBMFF') AND m.extraction_revision IS NULL)"

    static let metadataRefreshStillOwedSQL = """
    SELECT 1 FROM media_asset a JOIN asset_metadata m USING (library_root_id, relative_path)
    WHERE \(AssetKey.exactText("a"))
        AND a.byte_size IS ? AND a.metadata_source_size IS ? AND a.metadata_source_mtime IS ?
        AND NOT (\(EnrichmentClaimGateway.metadataStalenessSQLPredicate()))
        AND COALESCE(m.extraction_revision, 0) < \(AssetEnrichmentSQL.currentExtractionRevisionSQL)
    """

    static let sourceProductsAbsentSQL = """
    UPDATE media_asset SET source_products_absent = 1
    WHERE \(AssetKey.exactText()) AND source_products_absent IS NOT 1
    """

    static let writeRenderSignatureSQL = """
    UPDATE media_asset
    SET render_dhash = ?, render_signature_read = 1
    WHERE \(AssetKey.exactText())
      AND \(StoredThumbnailSQL.identity("media_asset")) = ?
    """

    static let deleteRenderGraySQL = "DELETE FROM \(RenderSignatureSQL.grayTable) WHERE \(AssetKey.exactText())"

    static let renameDerivedImagesSQL = """
    UPDATE media_asset
    SET thumbnail_path = ?, preview_path = ?, face_frames_path = ?
    WHERE \(AssetKey.exactText())
    """

    /// A row that shows its source's own thumbnail and preview (ADR 0046 §7): never
    /// edited, so no rendering of an edit is owed, and not yet rendered by Otos. An edited
    /// still always shows Otos's rendering, so the source's images are neither fetched for
    /// it nor written to it. The one predicate both the fetch and its write test, so a row
    /// is offered exactly when its products would be applied.
    static let showsSourceProductsSQL = "(edit_revision = 0 AND rendered_source_size IS NULL)"

    static func enrichmentResultMatchesSQL(_ edit: CatalogStore.EnrichmentResultEdit) -> String {
        """
        SELECT 1
        FROM media_asset
        WHERE \(AssetKey.exactText())
            AND COALESCE(byte_size, -1) = ?
            AND (
                (content_modified_at_unix IS NULL AND ? = -1)
                OR (content_modified_at_unix >= ? AND content_modified_at_unix < ?)
            )
            AND \(edit.conditionSQL)
        """
    }

    static let writeContentHashSQL = """
    UPDATE media_asset SET
        content_sha1 = ?,
        content_hash_source_size = ?,
        content_hash_source_mtime = ?
    WHERE \(AssetKey.exactText())
    """

    static let writeUndecodableSQL = "UPDATE media_asset SET undecodable_by = ? WHERE \(AssetKey.exactText())"

    static let writeFaceFramesSQL = "UPDATE media_asset SET face_frames_path = ? WHERE \(AssetKey.exactText())"

    /// `releaseUndecodedByAnotherDecoder`'s stills, sought through `idx_media_asset_undecodable`.
    static let releaseUndecodedStillsSQL = """
    UPDATE media_asset SET
        rendered_source_size = NULL, rendered_source_mtime = NULL,
        undecodable_by = NULL
    WHERE undecodable_by IS NOT NULL AND undecodable_by <> ? AND best_kind IS NOT 'video'
    """

    /// `releaseUndecodedByAnotherDecoder`'s videos, sought through `idx_media_asset_undecodable`.
    static let releaseUndecodedVideosSQL = """
    UPDATE media_asset SET
        faces_source_size = NULL, faces_source_mtime = NULL,
        undecodable_by = NULL
    WHERE undecodable_by IS NOT NULL AND undecodable_by <> ? AND best_kind = 'video'
    """

    static let facesReadSourceSQL =
        "SELECT faces_read_source_size, faces_read_source_mtime FROM media_asset WHERE \(AssetKey.exactText())"

    static let writeFacesStampSQL = """
    UPDATE media_asset SET faces_source_size = ?, faces_source_mtime = ?,
        faces_read_source_size = ?, faces_read_source_mtime = ?
    WHERE \(AssetKey.exactText())
    """

    static let writeRenderingSQL = """
    UPDATE media_asset SET
        thumbnail_path = ?,
        preview_path = ?,
        rendered_revision = ?,
        rendered_source_size = ?,
        rendered_source_mtime = ?
    WHERE \(AssetKey.exactText())
    """

    static let writeSourceProductsSQL = """
    UPDATE media_asset SET
        thumbnail_path = ?,
        preview_path = ?,
        source_products_size = ?,
        source_products_mtime = ?
    WHERE \(AssetKey.exactText())
    """

    static let writeProvisionalThumbnailSQL = "UPDATE media_asset SET thumbnail_path = ? WHERE \(AssetKey.exactText())"

    static let writeMetadataStampSQL = """
    UPDATE media_asset SET metadata_source_size = ?, metadata_source_mtime = ?
    WHERE \(AssetKey.exactText())
    """

    static let metadataProjectionDatesSQL = """
    SELECT \(CatalogSchema.absoluteCaptureSQL) AS absolute, created_at_unix, content_modified_at_unix,
           assumed_utc_offset_seconds
    FROM media_asset WHERE \(AssetKey.exactText())
    """

    static let writeMetadataProjectionSQL = """
    UPDATE media_asset SET
        assumed_utc_offset_seconds = ?,
        capture_instant_unix = ?,
        enriched_kind = ?,
        enriched_format = ?,
        duration_seconds = ?,
        capture_wall_compact = ?,
        capture_wall_precision = ?,
        content_identifier = ?,
        burst_identifier = ?
    WHERE \(AssetKey.exactText())
    """

    static let lacksThumbnailSQL = "SELECT thumbnail_path IS NULL FROM media_asset WHERE \(AssetKey.exactText())"

    static func updateThumbnailPathSQL(onlyWhenMissing: Bool) -> String {
        let missingPredicate = onlyWhenMissing ? "AND thumbnail_path IS NULL" : ""
        return """
        UPDATE media_asset
        SET thumbnail_path = ?
        WHERE \(AssetKey.exactText())
          \(missingPredicate)
        """
    }

    /// The columns `CatalogStore.EnrichmentOverlayBeforeWrite` reads before and after an
    /// enrichment overwrite, in its order.
    static let overlayBeforeWriteSQL = """
    SELECT a.best_capture_local, a.best_kind, a.best_format, a.capture_wall_compact, a.thumbnail_path,
        a.preview_path, a.face_frames_path, a.content_identifier, a.burst_identifier,
        m.primary_latitude, m.primary_longitude, a.parent_path
    FROM media_asset AS a
    LEFT JOIN asset_metadata AS m USING (library_root_id, relative_path)
    WHERE \(AssetKey.exactText("a"))
    """

    static let requestEnrichmentDownloadSQL = """
    UPDATE media_asset SET
        metadata_source_size = NULL, metadata_source_mtime = NULL,
        rendered_source_size = NULL, rendered_source_mtime = NULL
    WHERE \(AssetKey.exactText())
        AND byte_size IS ? AND metadata_source_size IS ? AND metadata_source_mtime IS ?
        AND EXISTS (
            SELECT 1 FROM asset_metadata m
            WHERE m.library_root_id = media_asset.library_root_id
                AND m.relative_path = media_asset.relative_path
                AND \(AssetEnrichmentSQL.predatesContentIdentifierSQL)
        )
    """

    static let restampDigestSizeSQL = """
    UPDATE media_asset SET content_hash_source_size = byte_size
    WHERE library_root_id = ? AND source_item_id = ? AND content_sha1 IS NOT NULL
      AND content_hash_source_size = -1 AND byte_size IS NOT NULL
    """

    static let deleteDerivedRenameSQL = "DELETE FROM derived_rename WHERE old_name = ? AND new_name = ?"

    static let derivedImagesOfRootSQL = """
    SELECT relative_path, thumbnail_path, preview_path, face_frames_path
    FROM media_asset WHERE library_root_id = ?
    """

    static let reusableEnrichmentOverlaySQL = """
    SELECT m.enriched_kind, m.enriched_format,
           m.metadata_source_size, m.metadata_source_mtime,
           m.rendered_source_size, m.rendered_source_mtime, m.rendered_revision,
           m.edit_recipe_json, m.edit_revision,
           m.thumbnail_path, m.preview_path,
           a.metadata_extra_json
    FROM media_asset m
    LEFT JOIN asset_metadata a
      ON a.library_root_id = m.library_root_id
     AND a.relative_path = m.relative_path
    WHERE \(AssetKey.exactText("m"))
    """

    /// The library's current revision for `asset_metadata.family`, as SQL: one `WHEN` per
    /// family the library names, and its `unknown` revision for anything else.
    static var currentExtractionRevisionSQL: String {
        let cases = MediaFormat.Family.allCases.map {
            "WHEN '\($0.rawValue)' THEN \(MediaMetadataReader.extractionRevision(for: $0))"
        }
        return "(CASE m.family \(cases.joined(separator: " ")) ELSE \(MediaMetadataReader.extractionRevision(for: .unknown)) END)"
    }
}
