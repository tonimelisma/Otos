import Foundation
@testable import OtosKit
import Testing

/// DES-069's day bar names the day that owns the viewport's top edge, so a date is
/// on screen at all times without the same day ever being drawn twice.
struct MediaGridDayBarPolicyTests {
    private static let calendar = Calendar(identifier: .gregorian)
    private static let now = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14T22:13:20Z
    private static let yesterday = now.addingTimeInterval(-86400)

    private static func barText(
        headerMinY: CGFloat?,
        viewportMinY: CGFloat,
        date: Date? = now,
        itemCount: Int = 4,
        precedingDay: MediaGridDayBarPolicy.Day? = nil
    ) -> MediaGridDayHeaderPresentation? {
        MediaGridDayBarPolicy.barPresentation(
            topEdge: MediaGridDayBarPolicy.TopEdge(
                day: MediaGridDayBarPolicy.Day(date: date, itemCount: itemCount),
                headerMinY: headerMinY,
                precedingDay: precedingDay
            ),
            viewportMinY: viewportMinY,
            now: now,
            calendar: calendar
        )
    }

    @Test func noDaySectionAtTheTopShowsNoBar() {
        // `.ungrouped` — Filename or Size sort — reaches the policy as a nil top edge.
        #expect(
            MediaGridDayBarPolicy.barPresentation(
                topEdge: nil,
                viewportMinY: 0,
                now: Self.now,
                calendar: Self.calendar
            ) == nil
        )
    }

    @Test func headerAboveTheViewportNamesThatDay() {
        // Deep inside a run: the header is long gone and the bar carries the date.
        let result = Self.barText(headerMinY: nil, viewportMinY: 4200)
        #expect(result?.dateText == "Today")
        #expect(result?.countText == "4 items")
    }

    @Test func headerClippedByTheTopEdgeNamesThatDay() {
        // The header is still in the viewport but its top has passed the edge, so the
        // bar sits exactly over it — covering it rather than duplicating it.
        #expect(Self.barText(headerMinY: 599.5, viewportMinY: 600)?.dateText == "Today")
    }

    @Test func topEdgeInTheGapAboveAHeaderKeepsNamingThePrecedingDay() {
        // Between one day's last row and the next day's header lies up to 24 pt of
        // section inset. The edge is in that gap, so the preceding day still owns it —
        // this is what stops the bar blinking out and back at every day boundary.
        let result = Self.barText(
            headerMinY: 610,
            viewportMinY: 600,
            precedingDay: MediaGridDayBarPolicy.Day(date: Self.yesterday, itemCount: 9)
        )
        #expect(result?.dateText == "Yesterday")
        #expect(result?.countText == "9 items")
    }

    @Test func restingAtTheStartOfTheGridHidesTheBar() {
        // The first day's own header is fully visible and there is no preceding day,
        // so the header is the one rendering and the bar stays out of the way.
        #expect(Self.barText(headerMinY: 12, viewportMinY: 0, precedingDay: nil) == nil)
    }

    @Test func undatedSectionNamesItselfInTheBar() {
        let result = Self.barText(headerMinY: nil, viewportMinY: 900, date: nil, itemCount: 1)
        #expect(result?.dateText == "No Date")
        #expect(result?.countText == "1 item")
    }
}
