import Foundation

/// Formats the compact capture-date text shown on grid tiles.
///
/// This is deliberately tiny product policy rather than a general date library:
/// Foundation's relative formatters do not provide Otos's exact cascade of
/// today/yesterday, last weekday for the previous week, then absolute dates. The
/// caller injects `now` and `calendar` in tests so boundary behavior is
/// deterministic across time zones and locales.
nonisolated enum RelativeDateText {
    static func string(
        for date: Date,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> String {
        let dateStart = calendar.startOfDay(for: date)
        let nowStart = calendar.startOfDay(for: now)
        let dayDelta = calendar.dateComponents([.day], from: dateStart, to: nowStart).day ?? 0

        switch dayDelta {
        case 0:
            return "Today"
        case 1:
            return "Yesterday"
        case 2 ... 6:
            return "Last \(date.formatted(weekdayStyle(calendar: calendar)))"
        default:
            return date.formatted(absoluteStyle(for: date, now: now, calendar: calendar))
        }
    }

    private static func absoluteStyle(
        for date: Date,
        now: Date,
        calendar: Calendar
    ) -> Date.FormatStyle {
        let locale = calendar.locale ?? .current
        let dateYear = calendar.component(.year, from: date)
        let nowYear = calendar.component(.year, from: now)
        let base = Date.FormatStyle(
            date: .omitted,
            time: .omitted,
            locale: locale,
            calendar: calendar,
            timeZone: calendar.timeZone
        )
        if dateYear == nowYear {
            return base.month(.wide).day()
        }
        return base.month(.wide).day().year()
    }

    private static func weekdayStyle(calendar: Calendar) -> Date.FormatStyle {
        Date.FormatStyle(
            date: .omitted,
            time: .omitted,
            locale: calendar.locale ?? .current,
            calendar: calendar,
            timeZone: calendar.timeZone
        )
        .weekday(.wide)
    }
}
