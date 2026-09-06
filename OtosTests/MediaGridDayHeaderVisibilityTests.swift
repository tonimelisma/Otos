import Foundation
@testable import OtosKit
import Testing

/// DES-069: every day section draws its own in-flow header except the first, whose
/// header the bar already covers and which rubber-band scrolling would otherwise slide
/// out from under the bar as a duplicate.
struct MediaGridDayHeaderVisibilityTests {
    @Test func theFirstSectionDoesNotDrawItsOwnHeader() {
        #expect(!MediaGridDayHeaderVisibility.drawsInFlowHeader(section: 0))
    }

    @Test func everyOtherSectionDoes() {
        #expect(MediaGridDayHeaderVisibility.drawsInFlowHeader(section: 1))
        #expect(MediaGridDayHeaderVisibility.drawsInFlowHeader(section: 417))
    }
}
