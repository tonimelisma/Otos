import Foundation

/// On This Day year policy guide
///
/// Pure grouping of the On This Day scope's items into years (ADR 0049). The scope's reads
/// use its fixed order (`SidebarSelection.fixedSort`: newest capture first), so the items
/// of one year are contiguous and the years arrive newest first — one year ago before
/// three. A year is the Gregorian year (`CalendarDay.calendar(in:)`) of the item's day
/// bucket, the same bucket the grid groups days by (DES-069), whatever calendar the user
/// reads dates in. An undated item has no anniversary and never reaches this
/// scope; one that did would belong to no year and is left out rather than guessed at.
nonisolated enum OnThisDayYearPolicy {
    /// The years of `orderedIDs` in play order, or nil when the day buckets do not pair
    /// with the IDs — then the years are not known, and nothing is claimed.
    static func years(
        day: CalendarDay,
        orderedIDs: [MediaAssetID],
        dayBuckets: [Date?],
        timeZone: TimeZone = .current
    ) -> [OnThisDayYear]? {
        guard dayBuckets.count == orderedIDs.count else {
            return nil
        }
        let calendar = CalendarDay.calendar(in: timeZone)
        var years: [OnThisDayYear] = []
        var runStart: Int?
        var runYear: Int?
        func closeRun(endingAt end: Int) {
            guard let start = runStart, let year = runYear else {
                return
            }
            years.append(OnThisDayYear(
                day: day.inYear(year),
                keyItem: orderedIDs[start],
                firstIndex: start,
                count: end - start
            ))
        }
        for (index, bucket) in dayBuckets.enumerated() {
            let year = bucket.map { calendar.component(.year, from: $0) }
            guard year != runYear else {
                continue
            }
            closeRun(endingAt: index)
            runStart = year == nil ? nil : index
            runYear = year
        }
        closeRun(endingAt: dayBuckets.count)
        return years
    }

    /// The year whose run holds `index`.
    static func year(containing index: Int, in years: [OnThisDayYear]) -> OnThisDayYear? {
        years.first { $0.indexes.contains(index) }
    }

    /// How many years before `today` the year is: `1` for last year.
    static func yearsAgo(_ year: OnThisDayYear, today: CalendarDay) -> Int {
        today.year - year.year
    }
}
