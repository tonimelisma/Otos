import Foundation
@testable import OtosKit
import Testing

struct MediaGridDayHeaderPresentationTests {
    private static let calendar = Calendar(identifier: .gregorian)
    private static let now = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14T22:13:20Z

    @Test func todayReadsToday() {
        let presentation = MediaGridDayHeaderPresentation.map(
            date: Self.now,
            itemCount: 3,
            now: Self.now,
            calendar: Self.calendar
        )
        #expect(presentation.dateText == "Today")
        #expect(presentation.countText == "3 items")
    }

    @Test func nilDateReadsNoDate() {
        let presentation = MediaGridDayHeaderPresentation.map(
            date: nil,
            itemCount: 5,
            now: Self.now,
            calendar: Self.calendar
        )
        #expect(presentation.dateText == "No Date")
    }

    @Test func singleItemUsesSingularNoun() {
        let presentation = MediaGridDayHeaderPresentation.map(
            date: Self.now,
            itemCount: 1,
            now: Self.now,
            calendar: Self.calendar
        )
        #expect(presentation.countText == "1 item")
    }

    @Test func zeroItemsStillPluralizes() {
        let presentation = MediaGridDayHeaderPresentation.map(
            date: Self.now,
            itemCount: 0,
            now: Self.now,
            calendar: Self.calendar
        )
        #expect(presentation.countText == "0 items")
    }
}
