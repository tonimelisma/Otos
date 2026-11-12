import Foundation

/// On This Day anniversary policy guide
///
/// Pure grouping of the On This Day scope's items into anniversaries (ADR 0049). The
/// scope's reads use its fixed order (`SidebarSelection.fixedSort`: newest capture first),
/// so the items of one day are contiguous and the days arrive newest first — one year ago
/// before three, one month ago before two. A run is the Gregorian year and month
/// (`CalendarDay.calendar(in:)`) of the item's day bucket, the same bucket the grid groups
/// days by (DES-069), whatever calendar the user reads dates in: the scope holds one day
/// per month at most, so a year and month names the run whether the scope matched earlier
/// years or earlier months. An undated item has no anniversary and never reaches this
/// scope; one that did would belong to no run and is left out rather than guessed at.
nonisolated enum OnThisDayAnniversaryPolicy {
    /// The anniversaries of `orderedIDs` in play order, or nil when the day buckets do not
    /// pair with the IDs — then the runs are not known, and nothing is claimed.
    static func anniversaries(
        day: CalendarDay,
        orderedIDs: [MediaAssetID],
        dayBuckets: [Date?],
        timeZone: TimeZone = .current
    ) -> [OnThisDayAnniversary]? {
        guard dayBuckets.count == orderedIDs.count else {
            return nil
        }
        let calendar = CalendarDay.calendar(in: timeZone)
        var anniversaries: [OnThisDayAnniversary] = []
        var runStart: Int?
        var runDay: CalendarDay?
        func closeRun(endingAt end: Int) {
            guard let start = runStart, let runDay else {
                return
            }
            anniversaries.append(OnThisDayAnniversary(
                day: runDay,
                keyItem: orderedIDs[start],
                firstIndex: start,
                count: end - start
            ))
        }
        for (index, bucket) in dayBuckets.enumerated() {
            let bucketDay = bucket.map { date in
                let components = calendar.dateComponents([.year, .month], from: date)
                return CalendarDay(year: components.year ?? 0, month: components.month ?? 0, day: day.day)
            }
            guard bucketDay != runDay else {
                continue
            }
            closeRun(endingAt: index)
            runStart = bucketDay == nil ? nil : index
            runDay = bucketDay
        }
        closeRun(endingAt: dayBuckets.count)
        return anniversaries
    }

    /// The anniversary whose run holds `index`.
    static func anniversary(containing index: Int, in anniversaries: [OnThisDayAnniversary]) -> OnThisDayAnniversary? {
        anniversaries.first { $0.indexes.contains(index) }
    }

    /// How long before `today` the anniversary is: `.years(1)` for last year's, `.months(2)`
    /// for the day two months back.
    static func interval(_ anniversary: OnThisDayAnniversary, today: CalendarDay) -> OnThisDayInterval {
        let months = (today.year - anniversary.day.year) * 12 + today.month - anniversary.day.month
        return months % 12 == 0 ? .years(months / 12) : .months(months)
    }
}
