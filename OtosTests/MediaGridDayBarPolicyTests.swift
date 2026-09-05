import Foundation
@testable import OtosKit
import Testing

/// DES-069's day bar is the grid's only rendering of the current day: it names the
/// section holding the topmost visible item, and shows nothing when there is no day
/// structure to name.
struct MediaGridDayBarPolicyTests {
    private static let calendar = Calendar(identifier: .gregorian)
    private static let now = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14T22:13:20Z
    private static let yesterday = now.addingTimeInterval(-86400)

    private static func bar(
        days: [MediaGridDayBarPolicy.Day?],
        topmostSection: Int?
    ) -> MediaGridDayBarPresentation? {
        MediaGridDayBarPolicy.barPresentation(
            days: days,
            topmostSection: topmostSection,
            now: now,
            calendar: calendar
        )
    }

    private static let twoDays: [MediaGridDayBarPolicy.Day?] = [
        MediaGridDayBarPolicy.Day(date: now, itemCount: 4),
        MediaGridDayBarPolicy.Day(date: yesterday, itemCount: 9),
    ]

    @Test func namesTheSectionHoldingTheTopmostVisibleItem() {
        #expect(Self.bar(days: Self.twoDays, topmostSection: 0)?.dateText == "Today")
        #expect(Self.bar(days: Self.twoDays, topmostSection: 0)?.countText == "4 items")
    }

    @Test func followsTheTopEdgeIntoTheNextRun() {
        // The inset gap between two runs belongs to whichever section the topmost
        // visible item is in — by the time the edge is in that gap, the previous
        // run's last row has already left the viewport.
        let result = Self.bar(days: Self.twoDays, topmostSection: 1)
        #expect(result?.dateText == "Yesterday")
        #expect(result?.countText == "9 items")
    }

    @Test func ungroupedSectionShowsNoBar() {
        // Filename or Size sort: one `.ungrouped` section, no day relationship to name.
        #expect(Self.bar(days: [nil], topmostSection: 0) == nil)
    }

    @Test func nothingVisibleShowsNoBar() {
        #expect(Self.bar(days: Self.twoDays, topmostSection: nil) == nil)
    }

    @Test func sectionOutsideTheAppliedStructureShowsNoBar() {
        // Geometry comes from the layout and the day facts from the last applied
        // snapshot; a bar that blanks is a better failure than a trap.
        #expect(Self.bar(days: Self.twoDays, topmostSection: 7) == nil)
        #expect(Self.bar(days: [], topmostSection: 0) == nil)
        #expect(Self.bar(days: Self.twoDays, topmostSection: -1) == nil)
    }

    @Test func undatedSectionNamesItselfInTheBar() {
        let days: [MediaGridDayBarPolicy.Day?] = [MediaGridDayBarPolicy.Day(date: nil, itemCount: 1)]
        let result = Self.bar(days: days, topmostSection: 0)
        #expect(result?.dateText == "No Date")
        #expect(result?.countText == "1 item")
    }
}
