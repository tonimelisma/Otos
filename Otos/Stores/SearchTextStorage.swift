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
    /// The source a text row must name to be current, for `row` (a table or alias).
    static func currentSource(_ row: String) -> String {
        "(\(row).preview_path || '|' || \(StoredThumbnailSQL.identity(row)) || '|t\(SearchTextReading.revision)')"
    }

    /// `FROM … WHERE …` over the stills owed a text reading in `rootCount` roots.
    static func owedFrom(rootCount: Int, indexedBy index: String? = nil) -> String {
        """
        FROM media_asset AS a\(index.map { " INDEXED BY \($0)" } ?? "")
        LEFT JOIN search_text AS t
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
        \(owedFrom(rootCount: rootCount, indexedBy: CandidateWalk.captureIndex))
          AND \(position)
        \(order)
        LIMIT ?
        """
    }

    /// The current, non-empty readings in `rootCount` roots (bound in order): the asset's key,
    /// then its lines when `lines`. Each row is found by the text table's key and its asset by
    /// the asset's (`CatalogStoreQueryPlanTests`).
    static func currentReadingsSQL(rootCount: Int, lines: Bool) -> String {
        """
        SELECT t.library_root_id, t.relative_path\(lines ? ", t.lines" : "")
        FROM search_text AS t
        JOIN media_asset AS a ON a.library_root_id = t.library_root_id AND a.relative_path = t.relative_path
        WHERE t.library_root_id IN (\(Array(repeating: "?", count: rootCount).joined(separator: ", "))) AND t.lines <> '[]'
          AND t.source = \(currentSource("a"))
        """
    }

    static func linesJSON(_ lines: [RecognizedTextLine]) throws -> String {
        try String(decoding: JSONEncoder().encode(lines), as: UTF8.self)
    }

    static func lines(fromJSON json: String) throws -> [RecognizedTextLine] {
        try JSONDecoder().decode([RecognizedTextLine].self, from: Data(json.utf8))
    }
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
