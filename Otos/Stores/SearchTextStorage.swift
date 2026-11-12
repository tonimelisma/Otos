import Foundation

/// Search text storage guide (ADR 0048)
///
/// The text Vision recognised in an asset's stored preview (`search_text`, one row per
/// asset; a move carries it and a proven deletion ends it, by cascade). Only stills have a
/// preview; the 256 px thumbnail is too small to read text from. The row names the preview and
/// the recognition revision it was read from (`currentSource`), so a new preview makes it
/// stale; a preview with no text is recorded with no lines and not read again until it
/// changes.
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
    static func owedFrom(rootCount: Int) -> String {
        """
        FROM media_asset AS a
        LEFT JOIN search_text AS t
            ON t.library_root_id = a.library_root_id AND t.relative_path = a.relative_path
        WHERE a.library_root_id IN (\(Array(repeating: "?", count: rootCount).joined(separator: ", ")))
          AND a.preview_path IS NOT NULL
          AND a.pending_trash_batch_unix_ms IS NULL
          AND a.trash_path IS NULL
          AND t.source IS NOT \(currentSource("a"))
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

/// What reading one preview found: its lines, empty when it holds none or did not decode — so
/// it is not offered again until it changes.
nonisolated struct SearchTextResult: Equatable, Sendable {
    let id: MediaAssetID
    let source: String
    let lines: [RecognizedTextLine]
}
