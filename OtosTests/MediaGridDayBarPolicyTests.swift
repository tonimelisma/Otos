import Foundation
@testable import OtosKit
import Testing

/// DES-069's day bar is a copy of the in-flow header for whichever day owns the
/// viewport's top edge — the same label at two moments, which is what a pinned header
/// is. These pin the "which day" half; the geometry it reads is the layout's.
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
    ) -> MediaGridDayLabelPresentation? {
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

    // Validates: APP-030
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

    // Validates: APP-030
    @Test func headerAboveTheViewportNamesThatDay() {
        // Deep inside a run: the header is long gone and the bar carries the date.
        let result = Self.barText(headerMinY: nil, viewportMinY: 4200)
        #expect(result?.dateText == "Today")
        #expect(result?.countText == "4 items")
    }

    // Validates: APP-030
    @Test func restingAtTheTopOfTheGridStillNamesTheFirstDay() {
        // The bar is on continuously under Date sort. At the top it rests exactly on
        // section 0's header, drawing the same label in the same rect, so leaving it
        // on costs nothing visible and spares the design a state to get wrong.
        #expect(Self.barText(headerMinY: 0, viewportMinY: 0)?.dateText == "Today")
    }

    // Validates: APP-030
    @Test func theScrollEdgeIsDrawnOnlyOnceTheGridLeavesItsTop() {
        // The hairline means "content passes under this bar". At the top nothing does.
        #expect(!MediaGridDayBarPolicy.showsScrollEdge(viewportMinY: 0))
        #expect(!MediaGridDayBarPolicy.showsScrollEdge(viewportMinY: -40))
        #expect(!MediaGridDayBarPolicy.showsScrollEdge(viewportMinY: 0.5))
        #expect(MediaGridDayBarPolicy.showsScrollEdge(viewportMinY: 40))
    }

    // Validates: APP-030
    @Test func topEdgeInTheGapAboveAHeaderKeepsNamingThePrecedingDay() {
        // The edge sits in the section inset above the next header. That gap still
        // belongs to the day being left — naming the incoming day instead would print
        // the same date twice, a few points apart.
        let result = Self.barText(
            headerMinY: 610,
            viewportMinY: 600,
            precedingDay: MediaGridDayBarPolicy.Day(date: Self.yesterday, itemCount: 9)
        )
        #expect(result?.dateText == "Yesterday")
        #expect(result?.countText == "9 items")
    }

    // Validates: APP-030
    @Test func undatedSectionNamesItselfInTheBar() {
        let result = Self.barText(headerMinY: nil, viewportMinY: 900, date: nil, itemCount: 1)
        #expect(result?.dateText == "No Date")
        #expect(result?.countText == "1 item")
    }
}
