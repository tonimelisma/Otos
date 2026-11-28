import Foundation

/// Which of a day's photos On This Day shows and in what order (ADR 0049,
/// following Apple Photos' Memories): never a photo the user Disliked, never one
/// Vision is confident is a screenshot or a document, and a day's Liked photos first. Labels
/// count only from the photo's current search row, the one read from the thumbnail it has
/// now (`SearchEmbeddingStorage.currentSource`): a photo not yet read for search, or whose
/// row was read from an earlier picture — a new thumbnail, a new file at the path, a new
/// model — is unknown and stays, since an unknown is not a screenshot. A stack is judged by
/// its key (`shows`).
nonisolated enum OnThisDayPicks {
    /// The scene labels that leave a photo out: Vision's confident labels as search stores
    /// them (`search_embedding.confident_labels`, comma-separated identifiers).
    static let excludedLabels = ["screenshot", "document"]

    /// Whether a `search_embedding` row's confident labels hold an excluded label, whatever
    /// picture the row was read from; `leftOutSQL` adds that it is the photo's current one.
    static var leftOutLabelSQL: String {
        excludedLabels
            .map { "(',' || confident_labels || ',') LIKE '%,\($0),%'" }
            .joined(separator: " OR ")
    }

    /// The anniversary scope's extra `WHERE` terms over `media_asset`. The years-or-months
    /// match reads the same clause, so a day holding only screenshots is no anniversary. A
    /// row's own search row is sought by its key, only for a row the day's other terms kept.
    /// A `NOT IN` over every left-out row was rejected on measurement: when a read starts
    /// from another table — the filter's place options start from the named cells — SQLite
    /// ran it for each outer row, 9–12 s on the reference library's 166,554-photo catalog against 0.15 s
    /// for this form (2026-11-13).
    static var exclusionSQL: String {
        """

          AND media_asset.media_choice <> 'disliked'
          AND NOT \(leftOutSQL("media_asset"))
        """
    }

    /// Whether the labels leave `asset`'s photo out (`asset` a `media_asset` table or alias):
    /// its search row, sought by the asset's key, is current for the thumbnail it has now and
    /// holds an excluded label. The one rule for the scope's exclusion and for a label write's
    /// question whether it moved a photo into or out of On This Day. The thumbnail columns the
    /// currency reads come from the asset row the scope's media choice is already read from,
    /// so the check adds no page to the scope's read (`CatalogStoreQueryPlanTests`).
    static func leftOutSQL(_ asset: String) -> String {
        """
        EXISTS (
            SELECT 1 FROM search_embedding
            WHERE search_embedding.library_root_id = \(asset).library_root_id
              AND search_embedding.relative_path = \(asset).relative_path
              AND search_embedding.source = \(SearchEmbeddingStorage.currentSource(asset))
              AND (\(leftOutLabelSQL))
        )
        """
    }

    /// Whether On This Day shows `id`, a row `exclusionSQL` left in: unless it is a file of a
    /// stack whose key is Disliked. A choice on a collapsed stack is its key's (ADR 0052), so
    /// such a stack's every file leaves, the key's RAW twin and a burst's other frames with it.
    /// The one answer both the cards (`CatalogStore.orderedAssetIDs`) and the years-or-months
    /// match (`anniversaryMatch`) ask, so a year is offered exactly when its card holds a photo.
    static func shows(_ id: MediaAssetID, stacks: CatalogStacks) -> Bool {
        !stacks.isInStackWithDislikedKey(id)
    }

    /// The most photos one anniversary shows (from the day sizes in
    /// `docs/research/2026-11-13-on-this-day-picks.md`: 73 % of the reference library's days hold no more).
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
