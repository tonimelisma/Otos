import Foundation

/// Anniversary match guide
///
/// On This Day's calendar question as SQL over the local capture time the catalog stores
/// (ADR 0049, ADR 0039). `best_capture_local` is the reading of the clock where the item
/// was taken, counted in seconds on a UTC calendar, so SQLite's own `strftime(…,
/// 'unixepoch')` writes the date that clock showed — the day `CatalogStore`'s day buckets
/// name — with no zone applied: a daylight-saving day is midnight to midnight like any
/// other, and a photo taken in California keeps its California evening.
///
/// A match is a date pattern and an end: `years` is the day's month and day (`11-12`) on a
/// row taken before the day's year began; `months` is the day of the month (`12`) on a row
/// taken before the day's month began. A day the calendar does not have in some year or
/// month — 29 February in a common year, 31 April — is a date SQLite never writes, so it
/// matches nothing there. Undated rows have no date and never match. The predicate holds
/// no list of days, so its size is the same for a library of one year and of a century.
nonisolated struct AnniversaryMatch: Equatable, Sendable {
    enum Unit: String, Sendable {
        case years
        case months
    }

    let unit: Unit
    /// Rows match only when taken before this local time: the start of the day's year for
    /// `years`, of its month for `months`.
    let end: Double
    /// The date the row must show, as `strftimeFormat` writes it.
    let date: String

    /// The day's month and day in an earlier year.
    static func years(for day: CalendarDay) -> AnniversaryMatch? {
        CaptureLocalTime(startOf: CalendarDay(year: day.year, month: 1, day: 1)).map {
            AnniversaryMatch(unit: .years, end: $0.seconds, date: String(format: "%02d-%02d", day.month, day.day))
        }
    }

    /// The day of the month in an earlier month.
    static func months(for day: CalendarDay) -> AnniversaryMatch? {
        CaptureLocalTime(startOf: CalendarDay(year: day.year, month: day.month, day: 1)).map {
            AnniversaryMatch(unit: .months, end: $0.seconds, date: String(format: "%02d", day.day))
        }
    }

    /// The `strftime` format whose output `date` is: a constant of the unit, never input.
    var strftimeFormat: String {
        switch unit {
        case .years: "%m-%d"
        case .months: "%d"
        }
    }

    /// The predicate over `column`, with `end` and `date` as its two arguments.
    func sql(column: String) -> String {
        "(\(column) < ? AND strftime('\(strftimeFormat)', \(column), 'unixepoch') = ?)"
    }
}
