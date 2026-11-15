import Foundation
import GRDB

/// Anniversary match guide
///
/// On This Day's calendar question as SQL over the local capture time the catalog stores
/// (ADR 0049, ADR 0039). `best_capture_local` is the reading of the clock where the item
/// was taken, counted in seconds on a UTC calendar, so SQLite's own `strftime(…,
/// 'unixepoch')` writes the date that clock showed — the day `CatalogStore`'s day buckets
/// name — with no zone applied: a daylight-saving day is midnight to midnight like any
/// other, and a photo taken in California keeps its California evening.
///
/// A match is a day and an end: `years` is the day's month and day on a row taken before the
/// day's year began; `months` is the day of the month on a row taken before the day's month
/// began. A day the calendar does not have in some year or month — 29 February in a common
/// year, 31 April — is a date SQLite never writes, so it matches nothing there. Undated rows
/// have no date and never match. The predicate holds no list of days, so its size is the same
/// for a library of one year and of a century.
///
/// The date SQLite writes is stored as `media_asset.capture_day` and `capture_month` (schema
/// v62), generated from `best_capture_local` by `daySQL` and `monthSQL`, and `indexName` is
/// led by them: a match seeks the day's rows, a few hundred of a catalog of hundreds of
/// thousands, where testing the date of every row before the end walked the whole capture
/// index (29,000 pages on the owner's catalog,
/// `docs/research/2026-11-15-proportional-small-scopes.md`).
nonisolated struct AnniversaryMatch: Equatable, Sendable {
    enum Unit: String, Sendable {
        case years
        case months
    }

    let unit: Unit
    /// Rows match only when taken before this local time: the start of the day's year for
    /// `years`, of its month for `months`.
    let end: Double
    /// The day of the month a row must show.
    let day: Int
    /// The month a row must show, for `years`; nil for `months`, which match any month.
    let month: Int?

    /// The index a match seeks its rows through.
    static let indexName = "idx_media_asset_capture_day"

    /// The day of the month `best_capture_local` shows, as `capture_day` stores it.
    static let daySQL = "CAST(strftime('%d', best_capture_local, 'unixepoch') AS INTEGER)"
    /// The month `best_capture_local` shows, as `capture_month` stores it.
    static let monthSQL = "CAST(strftime('%m', best_capture_local, 'unixepoch') AS INTEGER)"

    /// The day's month and day in an earlier year.
    static func years(for day: CalendarDay) -> AnniversaryMatch? {
        CaptureLocalTime(startOf: CalendarDay(year: day.year, month: 1, day: 1)).map {
            AnniversaryMatch(unit: .years, end: $0.seconds, day: day.day, month: day.month)
        }
    }

    /// The day of the month in an earlier month.
    static func months(for day: CalendarDay) -> AnniversaryMatch? {
        CaptureLocalTime(startOf: CalendarDay(year: day.year, month: day.month, day: 1)).map {
            AnniversaryMatch(unit: .months, end: $0.seconds, day: day.day, month: nil)
        }
    }

    /// The predicate over the columns of `row`, with `arguments` as its arguments, in the
    /// order of `indexName`'s columns.
    func sql(row: String) -> String {
        let month = month == nil ? "" : " AND \(row).capture_month = ?"
        return "(\(row).capture_day = ?\(month) AND \(row).best_capture_local < ?)"
    }

    var arguments: [any DatabaseValueConvertible] {
        [day] + (month.map { [$0] } ?? []) + [end]
    }
}
