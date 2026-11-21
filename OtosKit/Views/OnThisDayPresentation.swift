import Foundation

/// On This Day presentation guide
///
/// The one place that words On This Day's facts (`docs/design/on-this-day.md`): the bar,
/// an anniversary's card, the story player's bar and the date on its picture. Pure, so every
/// string is unit-tested without views. A date is formatted from the real instant of its
/// day (midday, in the user's zone) with a template in the user's own calendar and locale
/// — `9 November 2023` in en_GB, `November 9, 2023` in en_US, `令和5年11月9日` under the
/// Japanese calendar — never assembled from `CalendarDay`'s Gregorian numbers.
nonisolated enum OnThisDayPresentation {
    /// `1 year ago`, `3 years ago`, `1 month ago`, `14 months ago`: a card's L1 and the
    /// story bar's L1.
    static func ago(_ interval: OnThisDayInterval) -> String {
        switch interval {
        case let .years(years):
            years == 1 ? "1 year ago" : "\(years.formatted()) years ago"
        case let .months(months):
            months == 1 ? "1 month ago" : "\(months.formatted()) months ago"
        }
    }

    /// How long before `today` the anniversary is, worded.
    static func ago(_ anniversary: OnThisDayAnniversary, today: CalendarDay) -> String {
        ago(OnThisDayAnniversaryPolicy.interval(anniversary, today: today))
    }

    /// The bar's L1: the day the scope asks about, `9 November`.
    static func dayTitle(_ day: CalendarDay, locale: Locale = .current, calendar: Calendar = .current) -> String {
        format(day, template: "dMMMM", locale: locale, calendar: calendar)
    }

    /// The bar's L3 for what the scope published: its count, `No photos or videos from
    /// earlier years or months` only once the scope is known to hold none, and nothing while that is
    /// not known — libraries still being checked or offline, or a filter that emptied it,
    /// which the empty state below names (honest numbers, or none).
    static func barSummary(_ onThisDay: CatalogOnThisDayState?, emptyState: CatalogMediaEmptyState?) -> String {
        if let onThisDay, !onThisDay.anniversaries.isEmpty {
            return barSummary(
                itemCount: onThisDay.itemCount,
                runCount: onThisDay.anniversaries.count,
                isYears: onThisDay.isYears
            )
        }
        if case .nothingOnThisDay? = emptyState {
            return barSummary(itemCount: 0, runCount: 0, isYears: true)
        }
        return ""
    }

    /// The bar's L3: `14 photos and videos from 4 years`, or `612 photos and videos from 4
    /// months` when no earlier year holds the day.
    static func barSummary(itemCount: Int, runCount: Int, isYears: Bool) -> String {
        guard itemCount > 0 else {
            return "No photos or videos from earlier years or months"
        }
        let items = itemCount == 1 ? "1 photo or video" : "\(itemCount.formatted()) photos and videos"
        let unit = isYears ? "year" : "month"
        let runs = runCount == 1 ? "1 \(unit)" : "\(runCount.formatted()) \(unit)s"
        return "\(items) from \(runs)"
    }

    /// A card's L3: `9 Nov 2023 · 14`.
    static func cardCaption(
        _ anniversary: OnThisDayAnniversary,
        locale: Locale = .current,
        calendar: Calendar = .current
    ) -> String {
        "\(format(anniversary.day, template: "dMMMy", locale: locale, calendar: calendar)) · \(anniversary.count.formatted())"
    }

    /// A card's VoiceOver label: `3 years ago, 14 items, 9 November 2023` (DES-082).
    static func cardAccessibilityLabel(
        _ anniversary: OnThisDayAnniversary,
        title: String? = nil,
        today: CalendarDay,
        locale: Locale = .current,
        calendar: Calendar = .current
    ) -> String {
        let items = anniversary.count == 1 ? "1 item" : "\(anniversary.count.formatted()) items"
        let date = fullDate(anniversary.day, locale: locale, calendar: calendar)
        return ([title].compactMap(\.self) + [ago(anniversary, today: today), items, date]).joined(separator: ", ")
    }

    /// The date on the story's picture and in VoiceOver: `9 November 2023`.
    static func fullDate(_ day: CalendarDay, locale: Locale = .current, calendar: Calendar = .current) -> String {
        format(day, template: "dMMMMy", locale: locale, calendar: calendar)
    }

    /// The story bar's position within the anniversary: `4/12`.
    static func position(_ position: Int, of count: Int) -> String {
        "\(position.formatted())/\(count.formatted())"
    }

    /// The empty state's message: `Photos and videos taken on 9 November in earlier years,
    /// or on this day in earlier months, appear here.`
    static func emptyMessage(_ day: CalendarDay, locale: Locale = .current, calendar: Calendar = .current) -> String {
        "Photos and videos taken on \(dayTitle(day, locale: locale, calendar: calendar)) in earlier years, "
            + "or on this day in earlier months, appear here."
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
