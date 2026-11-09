import Foundation

/// On This Day presentation guide
///
/// The one place that words On This Day's facts (`docs/design/on-this-day.md`): the bar,
/// a year's card, the story player's bar and the date on its picture. Pure, so every
/// string is unit-tested without views. A date is formatted from the real instant of its
/// day (midday, in the user's zone) with a template in the user's own calendar and locale
/// — `9 November 2023` in en_GB, `November 9, 2023` in en_US, `令和5年11月9日` under the
/// Japanese calendar — never assembled from `CalendarDay`'s Gregorian numbers.
nonisolated enum OnThisDayPresentation {
    /// `1 year ago`, `3 years ago`: a card's L1 and the story bar's L1.
    static func yearsAgo(_ years: Int) -> String {
        years == 1 ? "1 year ago" : "\(years.formatted()) years ago"
    }

    /// The bar's L1: the day the scope asks about, `9 November`.
    static func dayTitle(_ day: CalendarDay, locale: Locale = .current, calendar: Calendar = .current) -> String {
        format(day, template: "dMMMM", locale: locale, calendar: calendar)
    }

    /// The bar's L3 for what the scope published: its count, `No photos or videos from
    /// earlier years` only once the scope is known to hold none, and nothing while that is
    /// not known — libraries still being checked or offline, or a filter that emptied it,
    /// which the empty state below names (honest numbers, or none).
    static func barSummary(_ onThisDay: CatalogOnThisDayState?, emptyState: CatalogMediaEmptyState) -> String {
        if let onThisDay, !onThisDay.years.isEmpty {
            return barSummary(itemCount: onThisDay.itemCount, yearCount: onThisDay.years.count)
        }
        if case .nothingOnThisDay = emptyState {
            return barSummary(itemCount: 0, yearCount: 0)
        }
        return ""
    }

    /// The bar's L3: `14 photos and videos from 4 years`.
    static func barSummary(itemCount: Int, yearCount: Int) -> String {
        guard itemCount > 0 else {
            return "No photos or videos from earlier years"
        }
        let items = itemCount == 1 ? "1 photo or video" : "\(itemCount.formatted()) photos and videos"
        let years = yearCount == 1 ? "1 year" : "\(yearCount.formatted()) years"
        return "\(items) from \(years)"
    }

    /// A card's L3: `9 Nov 2023 · 14`.
    static func cardCaption(_ year: OnThisDayYear, locale: Locale = .current, calendar: Calendar = .current) -> String {
        "\(format(year.day, template: "dMMMy", locale: locale, calendar: calendar)) · \(year.count.formatted())"
    }

    /// A card's VoiceOver label: `3 years ago, 14 items, 9 November 2023` (DES-082).
    static func cardAccessibilityLabel(
        _ year: OnThisDayYear,
        today: CalendarDay,
        locale: Locale = .current,
        calendar: Calendar = .current
    ) -> String {
        let items = year.count == 1 ? "1 item" : "\(year.count.formatted()) items"
        let date = fullDate(year.day, locale: locale, calendar: calendar)
        return "\(yearsAgo(OnThisDayYearPolicy.yearsAgo(year, today: today))), \(items), \(date)"
    }

    /// The date on the story's picture and in VoiceOver: `9 November 2023`.
    static func fullDate(_ day: CalendarDay, locale: Locale = .current, calendar: Calendar = .current) -> String {
        format(day, template: "dMMMMy", locale: locale, calendar: calendar)
    }

    /// The story bar's position within the year: `4/12`.
    static func position(_ position: Int, of count: Int) -> String {
        "\(position.formatted())/\(count.formatted())"
    }

    /// The empty state's message: `Photos and videos taken on 9 November in earlier years
    /// appear here.`
    static func emptyMessage(_ day: CalendarDay, locale: Locale = .current, calendar: Calendar = .current) -> String {
        "Photos and videos taken on \(dayTitle(day, locale: locale, calendar: calendar)) in earlier years appear here."
    }

    /// `day` at midday in the user's zone — an instant inside that day in any zone a
    /// formatter could apply — written in `calendar` and `locale` from `template`.
    private static func format(_ day: CalendarDay, template: String, locale: Locale, calendar: Calendar) -> String {
        guard let start = day.start(), let midday = CalendarDay.calendar().date(byAdding: .hour, value: 12, to: start) else {
            return day.diagnosticDescription
        }
        var reading = calendar
        reading.locale = locale
        reading.timeZone = .current
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = reading
        formatter.timeZone = .current
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: midday)
    }
}
