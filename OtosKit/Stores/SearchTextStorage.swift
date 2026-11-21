import Foundation
import GRDB

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
/// `lines` is the reading as JSON (`TextReading`): the size of the picture read, and each
/// recognised line with the confidence Vision gave it and where it sits in the picture, so
/// search can match every line and the Info pane show the ones a person reads as the photo's
/// text (`SearchTextReading.shown`).
///
/// Each reading that holds a word is also in the text index (v74): its folded text in
/// `search_text_folded` and its words in the FTS5 table `search_text_word` (`SearchTextWords`),
/// written with the reading in its transaction (`index`) and gone with it by cascade and a
/// trigger. A query's words are matched there (`matchSQL`), never against readings in memory.
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
          AND \(owedPredicate)
        """
    }

    /// What makes still `a` owed a text reading, `t` its stored one.
    static let owedPredicate = """
    a.preview_path IS NOT NULL
      AND a.pending_trash_batch_unix_ms IS NULL
      AND a.trash_path IS NULL
      AND t.source IS NOT \(currentSource("a"))
    """

    /// One still, by its key (binds the root and the path), when it is owed a text reading:
    /// what the index reads for a change that names its rows.
    static let keyedCandidateSQL = """
    SELECT a.best_capture_local, a.library_root_id, a.relative_path, a.preview_path,
           \(currentSource("a")) AS source
    FROM media_asset AS a
    LEFT JOIN search_text AS t
        ON t.library_root_id = a.library_root_id AND t.relative_path = a.relative_path
    WHERE \(AssetKey.exactText("a"))
      AND \(owedPredicate)
    """

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

    /// The text index's rows for a reading (v74, `SearchTextWords`): the reading folded as
    /// matching compares it, keyed by an id the words are stored under.
    static let deleteFoldedSQL = "DELETE FROM search_text_folded WHERE \(AssetKey.exactText())"
    static let insertFoldedSQL = "INSERT INTO search_text_folded (library_root_id, relative_path, folded) VALUES (?, ?, ?)"
    static let insertWordsSQL = "INSERT INTO search_text_word (rowid, words) VALUES (?, ?)"

    /// Replaces one reading's rows in the text index with those of `searchable`, the reading's
    /// text as search matches it (`SearchTextReading.searchable`), in the caller's write, so the
    /// index changes in the transaction that stores the reading: the old folded row goes (its
    /// trigger takes its words), and a reading that holds a word gets new ones. Returns whether
    /// it was indexed.
    static func index(searchable: String, rootID: Int64, path: String, db: Database) throws -> Bool {
        try db.cachedStatement(sql: deleteFoldedSQL).execute(
            arguments: AssetKey(rootID: rootID, path: MediaRelativePath(rawValue: path)).arguments
        )
        let folded = SearchTextReading.folded(searchable)
        let words = SearchTextWords.of(folded: folded)
        guard !words.isEmpty else { return false }
        try db.cachedStatement(sql: insertFoldedSQL).execute(arguments: [rootID, path, folded])
        try db.cachedStatement(sql: insertWordsSQL).execute(arguments: [db.lastInsertedRowID, words])
        return true
    }

    /// The current readings whose words the index expression (bound) holds, with each one's
    /// folded text, for `SearchTextQuery.matches(folded:)` to decide: the text index first,
    /// then each returned row's reading and asset by key, to keep only a reading whose source is
    /// its asset's current one (a stale reading matches nothing).
    static let matchSQL = """
    SELECT f.library_root_id, f.relative_path, f.folded
    FROM search_text_word
    CROSS JOIN search_text_folded AS f ON f.id = search_text_word.rowid
    CROSS JOIN search_text AS t INDEXED BY \(sourceIndexName)
        ON t.library_root_id = f.library_root_id AND t.relative_path = f.relative_path
    CROSS JOIN media_asset AS a ON a.library_root_id = f.library_root_id AND a.relative_path = f.relative_path
    WHERE search_text_word MATCH ?
      AND t.source = \(currentSource("a"))
    """

    /// The index expression of `queries`: each one's words (`SearchTextQuery.indexExpression`),
    /// any of them. Nil when none has a word.
    static func indexExpression(_ queries: [SearchTextQuery]) -> String? {
        var seen: Set<String> = []
        let each = queries.compactMap(\.indexExpression).filter { seen.insert($0).inserted }
        guard !each.isEmpty else { return nil }
        return each.count == 1 ? each[0] : each.map { "(\($0))" }.joined(separator: " OR ")
    }

    static func readingJSON(_ reading: TextReading) throws -> String {
        try String(decoding: JSONEncoder().encode(reading), as: UTF8.self)
    }

    static func reading(fromJSON json: String) throws -> TextReading {
        try JSONDecoder().decode(TextReading.self, from: Data(json.utf8))
    }

    static let photoInfoLinesSQL = """
    SELECT t.lines FROM search_text AS t
    JOIN media_asset AS a ON a.library_root_id = t.library_root_id AND a.relative_path = t.relative_path
    WHERE \(AssetKey.exactText("t"))
      AND t.source = \(SearchTextStorage.currentSource("a"))
    """

    static let textSourceIsCurrentSQL = """
    SELECT \(SearchTextStorage.currentSource("media_asset")) = ?
    FROM media_asset WHERE \(AssetKey.exactText())
    """

    static let writeReadingSQL = """
    INSERT INTO search_text (library_root_id, relative_path, source, lines) VALUES (?, ?, ?, ?)
    ON CONFLICT (library_root_id, relative_path) DO UPDATE SET source = excluded.source, lines = excluded.lines
    """
}

/// What one read of the text index found (`CatalogStore.searchTextMatches`): the assets
/// matched, and how many rows the index returned for the exact match to decide.
nonisolated struct SearchTextMatches: Sendable, Equatable {
    let ids: Set<MediaAssetID>
    let candidates: Int
}

/// What Vision read in one picture: the picture's size in pixels, and each line it recognised,
/// in reading order; no lines when it holds no text.
nonisolated struct TextReading: Codable, Equatable, Sendable {
    let width: Int
    let height: Int
    let lines: [RecognizedTextLine]

    /// A picture `width` × `height` with no text.
    static func empty(width: Int, height: Int) -> TextReading {
        TextReading(width: width, height: height, lines: [])
    }
}

/// One line Vision recognised in a picture, with its confidence (0–1) and where it sits.
nonisolated struct RecognizedTextLine: Codable, Equatable, Sendable {
    let text: String
    let confidence: Float
    let box: TextBox
}

/// Where a line sits in the picture it was read from, as fractions of the picture's width and
/// height from its top-left corner: `top` is the line's top edge, `bottom` its bottom edge.
nonisolated struct TextBox: Codable, Equatable, Sendable {
    let left: Double
    let top: Double
    let right: Double
    let bottom: Double

    /// The whole picture.
    static let whole = TextBox(left: 0, top: 0, right: 1, bottom: 1)
}

/// A still whose stored preview has no current text reading.
nonisolated struct SearchTextCandidate: Equatable, Sendable {
    let id: MediaAssetID
    let previewPath: String
    let source: String
}

/// What reading one preview found: its reading, with no lines when it holds none — so it is not
/// offered again until it changes.
nonisolated struct SearchTextResult: Equatable, Sendable {
    let id: MediaAssetID
    let source: String
    let reading: TextReading
}
