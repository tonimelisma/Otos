import Foundation
@testable import OtosKit
import Testing

struct RelativeDateTextTests {
    @Test func todayAndYesterdayUseNamedText() throws {
        let calendar = fixedCalendar()
        let now = try fixedDate(year: 2026, month: 6, day: 10, hour: 12, calendar: calendar)
        let earlierToday = try fixedDate(year: 2026, month: 6, day: 10, hour: 1, calendar: calendar)
        let yesterday = try fixedDate(year: 2026, month: 6, day: 9, hour: 23, calendar: calendar)

        #expect(RelativeDateText.string(for: earlierToday, now: now, calendar: calendar) == "Today")
        #expect(RelativeDateText.string(for: yesterday, now: now, calendar: calendar) == "Yesterday")
    }

    @Test func previousTwoThroughSixDaysUseLastWeekday() throws {
        let calendar = fixedCalendar()
        let now = try fixedDate(year: 2026, month: 6, day: 10, hour: 12, calendar: calendar)
        let cases: [(day: Int, expected: String)] = [
            (8, "Last Monday"),
            (7, "Last Sunday"),
            (6, "Last Saturday"),
            (5, "Last Friday"),
            (4, "Last Thursday"),
        ]

        for testCase in cases {
            let date = try fixedDate(year: 2026, month: 6, day: testCase.day, hour: 9, calendar: calendar)
            #expect(RelativeDateText.string(for: date, now: now, calendar: calendar) == testCase.expected)
        }
    }

    @Test func sevenDaysAgoAndSameYearUseMonthDay() throws {
        let calendar = fixedCalendar()
        let now = try fixedDate(year: 2026, month: 6, day: 10, hour: 12, calendar: calendar)
        let sevenDaysAgo = try fixedDate(year: 2026, month: 6, day: 3, hour: 12, calendar: calendar)
        let olderSameYear = try fixedDate(year: 2026, month: 2, day: 14, hour: 12, calendar: calendar)

        #expect(RelativeDateText.string(for: sevenDaysAgo, now: now, calendar: calendar) == "June 3")
        #expect(RelativeDateText.string(for: olderSameYear, now: now, calendar: calendar) == "February 14")
    }

    @Test func olderYearUsesMonthDayYear() throws {
        let calendar = fixedCalendar()
        let now = try fixedDate(year: 2026, month: 6, day: 10, hour: 12, calendar: calendar)
        let older = try fixedDate(year: 2022, month: 6, day: 5, hour: 12, calendar: calendar)

        #expect(RelativeDateText.string(for: older, now: now, calendar: calendar) == "June 5, 2022")
    }

    @Test func futureDateUsesAbsoluteText() throws {
        let calendar = fixedCalendar()
        let now = try fixedDate(year: 2026, month: 6, day: 10, hour: 12, calendar: calendar)
        let future = try fixedDate(year: 2026, month: 6, day: 12, hour: 12, calendar: calendar)

        #expect(RelativeDateText.string(for: future, now: now, calendar: calendar) == "June 12")
    }

    @Test func yearBoundaryStillUsesNearDateNames() throws {
        let calendar = fixedCalendar()
        let now = try fixedDate(year: 2026, month: 1, day: 1, hour: 12, calendar: calendar)
        let yesterday = try fixedDate(year: 2025, month: 12, day: 31, hour: 12, calendar: calendar)

        #expect(RelativeDateText.string(for: yesterday, now: now, calendar: calendar) == "Yesterday")
    }
}

private func fixedCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_US")
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

private func fixedDate(
    year: Int,
    month: Int,
    day: Int,
    hour: Int,
    calendar: Calendar
) throws -> Date {
    try #require(calendar.date(from: DateComponents(
        calendar: calendar,
        timeZone: calendar.timeZone,
        year: year,
        month: month,
        day: day,
        hour: hour
    )))
}
