import Foundation

/// Search text storage guide (ADR 0048)
///
/// The text Vision recognised in an asset's stored preview (`search_text`, one row per
/// asset; a move carries it and a proven deletion ends it, by cascade). Only stills have a
/// preview; the 256 px thumbnail is too small to read text from. The row names the preview and
/// the recognition revision it was read from (`currentSource`), so a new preview makes it
/// stale; a preview with no text is recorded with no lines and not read again until it
/// changes. A preview that does not decode is not read, so nothing is recorded for it and it
/// stays owed.
///
/// `lines` is the reading as JSON: each recognised line with the confidence Vision gave it
/// (`RecognizedTextLine`), so search can match every line and the Info pane show the certain
/// ones.
nonisolated enum SearchTextStorage {
    /// Each reading's key with the source it names (v65).
    static let sourceIndexName = "idx_search_text_source"

    /// The source a text row must name to be current, for `row` (a table or alias).
    static func currentSource(_ row: String) -> String {
        "(\(row).preview_path || '|' || \(StoredThumbnailSQL.identity(row)) || '|t\(SearchTextReading.revision)')"
    }

    /// `FROM … WHERE …` over the stills owed a text reading in `rootCount` roots.
    static func owedFrom(rootCount: Int) -> String {
        """
        FROM media_asset AS a INDEXED BY \(ProductStampSQL.indexName)
        LEFT JOIN search_text AS t INDEXED BY \(sourceIndexName)
            ON t.library_root_id = a.library_root_id AND t.relative_path = a.relative_path
        WHERE a.library_root_id IN (\(Array(repeating: "?", count: rootCount).joined(separator: ", ")))
          AND a.preview_path IS NOT NULL
          AND a.pending_trash_batch_unix_ms IS NULL
          AND a.trash_path IS NULL
          AND t.source IS NOT \(currentSource("a"))
        """
    }

    /// A page of the text reader's newest-first walk (`CandidateWalk.capturePage`) through the
    /// window's date order index; the preview's stamp is read from the row.
    static func candidatesSQL(rootCount: Int, position: String, order: String) -> String {
        """
        SELECT a.best_capture_local, a.library_root_id, a.relative_path, a.preview_path,
               \(currentSource("a")) AS source
        \(owedFrom(rootCount: rootCount))
          AND \(position)
        \(order)
        LIMIT ?
        """
    }

    /// The keys of the current readings in `rootCount` roots, empty ones included: each still's
    /// preview identity from the product stamps index and its reading's source from the text
    /// source index, the asset side outer, so the check reads neither table.
    static func currentReadingIDsSQL(rootCount: Int) -> String {
        """
        SELECT a.library_root_id, a.relative_path
        FROM media_asset AS a INDEXED BY \(ProductStampSQL.indexName)
        CROSS JOIN search_text AS t INDEXED BY \(sourceIndexName)
            ON t.library_root_id = a.library_root_id AND t.relative_path = a.relative_path
            AND t.source = \(currentSource("a"))
        WHERE a.library_root_id IN (\(Array(repeating: "?", count: rootCount).joined(separator: ", ")))
          AND a.preview_path IS NOT NULL
        """
    }

    /// One root's stored readings in key order after a path, through the text table's key
    /// (`CandidateWalk.keyPage`; binds the root, the path, the limit).
    static let storedLinesSQL = """
    SELECT library_root_id, relative_path, lines
    FROM search_text INDEXED BY sqlite_autoindex_search_text_1
    WHERE library_root_id = ? AND relative_path > ?
    ORDER BY relative_path
    LIMIT ?
    """

    /// One still's current reading by its key (binds the root and the path).
    static let currentLinesByKeySQL = """
    SELECT t.lines
    FROM search_text AS t
    JOIN media_asset AS a ON a.library_root_id = t.library_root_id AND a.relative_path = t.relative_path
    WHERE t.library_root_id = ? AND t.relative_path = ?
      AND t.source = \(currentSource("a"))
    """

    static func linesJSON(_ lines: [RecognizedTextLine]) throws -> String {
        try String(decoding: JSONEncoder().encode(lines), as: UTF8.self)
    }

    static func lines(fromJSON json: String) throws -> [RecognizedTextLine] {
        try JSONDecoder().decode([RecognizedTextLine].self, from: Data(json.utf8))
    }
}

/// One stored reading as search matches it (`SearchTextReading.searchable`): empty when the
/// preview held no text.
nonisolated struct StoredSearchText: Sendable {
    let id: MediaAssetID
    let text: String
}

/// One line Vision recognised in a preview, with its confidence (0–1).
nonisolated struct RecognizedTextLine: Codable, Equatable, Sendable {
    let text: String
    let confidence: Float
}

/// A still whose stored preview has no current text reading.
nonisolated struct SearchTextCandidate: Equatable, Sendable {
    let id: MediaAssetID
    let previewPath: String
    let source: String
}

/// What reading one preview found: its lines, empty when it holds none — so it is not offered
/// again until it changes.
nonisolated struct SearchTextResult: Equatable, Sendable {
    let id: MediaAssetID
    let source: String
    let lines: [RecognizedTextLine]
}
