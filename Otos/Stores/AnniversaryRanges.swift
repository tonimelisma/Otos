import Foundation

/// Anniversary ranges guide
///
/// Pure translation of On This Day's calendar question into the local capture times the
/// catalog stores (ADR 0049, ADR 0039). A row matches when its day — the day it was taken
/// on, on the clock where it was taken (`CaptureLocalTime.day`), as `CatalogStore`'s day
/// buckets name it — has the day's month and day in an earlier year. Each year is one
/// half-open range of `best_capture_local` from that day's midnight to the next. A local
/// time has no zone, so every day is 24 hours long and no daylight-saving change moves an
/// edge; a day the year does not have (29 February in a common year) contributes no range.
///
/// The ranges run from the earliest dated year the scope holds through the year before
/// the day's own: the floor comes from the catalog in the same read, so the ranges are
/// finite and every year that could match is covered.
nonisolated enum AnniversaryRanges {
    /// Half-open `best_capture_local` ranges, oldest year first. Empty when nothing in the
    /// scope is dated (`earliest` nil) or nothing is dated before the day's year.
    static func ranges(for day: CalendarDay, earliest: CaptureLocalTime?) -> [Range<Double>] {
        guard let floorYear = earliest?.day.year, floorYear < day.year else {
            return []
        }
        var ranges: [Range<Double>] = []
        ranges.reserveCapacity(day.year - floorYear)
        for year in floorYear ..< day.year {
            guard let start = CaptureLocalTime(startOf: day.inYear(year)) else {
                continue
            }
            ranges.append(start.seconds ..< start.seconds + 86400)
        }
        return ranges
    }
}
