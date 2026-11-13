import Foundation

/// Which of a day's photos On This Day shows and in what order (ADR 0049, owner direction
/// 2026-11-13, following Apple Photos' Memories): never a photo the user Disliked, never one
/// Vision is confident is a screenshot or a document, and a day's Liked photos first. A
/// photo not yet read for search has no labels and stays: an unknown is not a screenshot.
nonisolated enum OnThisDayPicks {
    /// The scene labels that leave a photo out: Vision's confident labels as search stores
    /// them (`search_embedding.confident_labels`, comma-separated identifiers).
    static let excludedLabels = ["screenshot", "document"]

    /// Whether a `search_embedding` row's confident labels hold an excluded label. One text
    /// for the partial index `idx_search_embedding_left_out` and for the query that reads it,
    /// since SQLite uses a partial index only when the query states its condition.
    static var leftOutLabelSQL: String {
        excludedLabels
            .map { "(',' || confident_labels || ',') LIKE '%,\($0),%'" }
            .joined(separator: " OR ")
    }

    /// The anniversary scope's extra `WHERE` terms over `media_asset`. The years-or-months
    /// match reads the same clause, so a day holding only screenshots is no anniversary. The
    /// left-out rows are read once per query from their own small index, not looked up per
    /// row of the day.
    static var exclusionSQL: String {
        """

          AND media_asset.media_choice <> 'disliked'
          AND (media_asset.library_root_id, media_asset.relative_path) NOT IN (
              SELECT library_root_id, relative_path FROM search_embedding
              WHERE \(leftOutLabelSQL)
          )
        """
    }

    /// The most photos one anniversary shows (owner, 2026-11-12, from the day sizes in
    /// `docs/research/2026-11-13-on-this-day-picks.md`: 73 % of the owner's days hold no more).
    static let anniversaryCap = 25

    /// The positions of `dayBuckets` On This Day keeps: the first `anniversaryCap` of each
    /// day's run, so its Liked photos and then its newest. It runs on the collapsed order,
    /// so a RAW+JPEG pair or a burst counts once.
    static func keptPositions(dayBuckets: [Date?]) -> [Int]? {
        var kept: [Int] = []
        var inRun = 0
        for position in dayBuckets.indices {
            let startsRun = position == 0 || dayBuckets[position] != dayBuckets[position - 1]
            inRun = startsRun ? 1 : inRun + 1
            if inRun <= anniversaryCap {
                kept.append(position)
            }
        }
        return kept.count == dayBuckets.count ? nil : kept
    }

    /// `rows` in the scope's order, newest first, with each day's Liked photos moved to its
    /// front, each group keeping its order. A day is the day bucket the grid and the
    /// anniversaries use (`CaptureLocalTime.dayNumber`).
    static func likedFirst(_ rows: [CatalogQueryGateway.OrderedAssetIDRow]) -> [CatalogQueryGateway.OrderedAssetIDRow] {
        guard rows.contains(where: \.isLiked) else { return rows }
        var result: [CatalogQueryGateway.OrderedAssetIDRow] = []
        result.reserveCapacity(rows.count)
        var start = rows.startIndex
        while start < rows.endIndex {
            let day = rows[start].captureLocalTime?.dayNumber
            var end = start
            while end < rows.endIndex, rows[end].captureLocalTime?.dayNumber == day {
                end += 1
            }
            let run = rows[start ..< end]
            result += run.filter(\.isLiked)
            result += run.filter { !$0.isLiked }
            start = end
        }
        return result
    }
}
