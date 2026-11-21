import Foundation

// Calendar day guide
//
// `CalendarDay` is a day as a Gregorian calendar in the user's time zone names it — year,
// month and day — never an instant. On This Day (ADR 0049) asks a question about the
// calendar ("taken on 9 November"), so its scope carries this value, and the gateway turns
// it into instants only at the read.
//
// The one calendar every On This Day computation uses is `CalendarDay.calendar(in:)`:
// Gregorian, in a time zone. Never `Calendar.current`, whose year is an era year under the
// Japanese calendar (Reiwa 8, where Gregorian says 2026) and 2569 under the Buddhist one,
// so years would neither compare nor subtract. The grid's day buckets
// (`Calendar.startOfDay`) depend only on the zone, so the two agree on which day an item
// belongs to. What the user reads is formatted from real dates in their own calendar and
// locale (`OnThisDayPresentation`), never from these numbers.

/// A day of the Gregorian calendar in a time zone: year, month and day, with no time.
nonisolated struct CalendarDay: Hashable, Sendable {
    let year: Int
    let month: Int
    let day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// The day `date` falls on in `timeZone`.
    init(_ date: Date, timeZone: TimeZone = .current) {
        let components = Self.calendar(in: timeZone).dateComponents([.year, .month, .day], from: date)
        self.init(year: components.year ?? 0, month: components.month ?? 0, day: components.day ?? 0)
    }

    /// The calendar On This Day counts days and years with: Gregorian, in `timeZone`.
    static func calendar(in timeZone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// Today, in the user's time zone as it is now.
    static func today() -> CalendarDay {
        CalendarDay(Date())
    }

    /// The same month and day in `year`.
    func inYear(_ year: Int) -> CalendarDay {
        CalendarDay(year: year, month: month, day: day)
    }

    /// The instant this day starts at in `timeZone`, or nil when the year has no such day
    /// (29 February in a common year).
    func start(in timeZone: TimeZone = .current) -> Date? {
        let calendar = Self.calendar(in: timeZone)
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
            return nil
        }
        // A calendar resolves an impossible day leniently (29 February 2023 is 1 March);
        // that day does not exist, so it starts nowhere.
        guard CalendarDay(date, timeZone: timeZone) == self else {
            return nil
        }
        return calendar.startOfDay(for: date)
    }

    var diagnosticDescription: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }
}
