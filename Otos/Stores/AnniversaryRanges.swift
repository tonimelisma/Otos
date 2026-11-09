import Foundation

/// Anniversary ranges guide
///
/// Pure translation of On This Day's calendar question into the instants the catalog
/// stores (ADR 0049). A row matches when its day bucket — `best_capture_unix` in the time
/// zone, as `CatalogStore.orderedAssetIDs` buckets days — has the day's month and day in an
/// earlier year. Each year is one half-open range from the local start of that day to the
/// local start of the next, made with `CalendarDay.calendar(in:)` (Gregorian, whatever the
/// user's calendar), so a day that is 23 or 25 hours long across a daylight-saving change
/// is covered exactly, and a day the year does not have (29 February in a common year)
/// contributes no range.
///
/// The ranges run from the earliest dated year the scope holds through the year before
/// the day's own: the floor comes from the catalog in the same read, so the ranges are
/// finite and every year that could match is covered.
nonisolated enum AnniversaryRanges {
    /// Half-open `best_capture_unix` ranges, oldest year first. Empty when nothing in the
    /// scope is dated (`earliestCaptureUnix` nil) or nothing is dated before the day's year.
    static func ranges(
        for day: CalendarDay,
        earliestCaptureUnix: Double?,
        timeZone: TimeZone = .current
    ) -> [Range<Double>] {
        let calendar = CalendarDay.calendar(in: timeZone)
        guard let earliestCaptureUnix else {
            return []
        }
        let floorYear = calendar.component(.year, from: Date(timeIntervalSince1970: earliestCaptureUnix))
        guard floorYear < day.year else {
            return []
        }
        var ranges: [Range<Double>] = []
        ranges.reserveCapacity(day.year - floorYear)
        for year in floorYear ..< day.year {
            guard let start = day.inYear(year).start(in: timeZone),
                  let next = calendar.date(byAdding: .day, value: 1, to: start)
            else {
                continue
            }
            let end = calendar.startOfDay(for: next)
            ranges.append(start.timeIntervalSince1970 ..< end.timeIntervalSince1970)
        }
        return ranges
    }
}
