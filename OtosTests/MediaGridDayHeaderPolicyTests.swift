import Foundation
@testable import OtosKit
import Testing

/// DES-069: every day section draws its own in-flow header except the first, whose
/// header the bar already covers and which rubber-band scrolling would otherwise slide
/// out from under the bar as a duplicate.
struct MediaGridDayHeaderPolicyTests {
    private let days: [MediaGridDayBarPolicy.Day?] = [
        MediaGridDayBarPolicy.Day(date: Date(timeIntervalSince1970: 86400 * 2), itemCount: 3),
        MediaGridDayBarPolicy.Day(date: Date(timeIntervalSince1970: 86400), itemCount: 5),
        MediaGridDayBarPolicy.Day(date: nil, itemCount: 1),
    ]

    @Test func theFirstSectionDoesNotDrawItsOwnHeader() {
        #expect(MediaGridDayHeaderPolicy.presentation(section: 0, daySections: days) == nil)
    }

    @Test func everyOtherSectionDrawsItsDayAndCount() {
        #expect(
            MediaGridDayHeaderPolicy.presentation(section: 1, daySections: days)
                == .map(date: Date(timeIntervalSince1970: 86400), itemCount: 5)
        )
        #expect(
            MediaGridDayHeaderPolicy.presentation(section: 2, daySections: days)
                == .map(date: nil, itemCount: 1)
        )
    }

    @Test func anUngroupedOrUnknownSectionDrawsNothing() {
        #expect(MediaGridDayHeaderPolicy.presentation(section: 1, daySections: [nil, nil]) == nil)
        #expect(MediaGridDayHeaderPolicy.presentation(section: 3, daySections: days) == nil)
    }
}
