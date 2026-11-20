import Foundation
@testable import OtosKit
import Testing

/// DES-123: the scrub label names the bar's day only as finely as one knob point can pick.
struct MediaGridScrubPolicyTests {
    private static let day: TimeInterval = 86400
    private static let year: TimeInterval = 365 * day

    @Test func granularityFollowsWhatOneKnobPointCovers() {
        // Ten years on a 900 pt track: about four days a point, so a month.
        #expect(MediaGridScrubPolicy.granularity(span: 10 * Self.year, trackHeight: 900) == .month)
        // A week on any track: a day.
        #expect(MediaGridScrubPolicy.granularity(span: 7 * Self.day, trackHeight: 900) == .day)
        // Forty years on a 300 pt track: about seven weeks a point, so a year.
        #expect(MediaGridScrubPolicy.granularity(span: 40 * Self.year, trackHeight: 300) == .year)
        // The edges: exactly a day a point is a month; exactly thirty days a point, a year.
        #expect(MediaGridScrubPolicy.granularity(span: 100 * Self.day, trackHeight: 100) == .month)
        #expect(MediaGridScrubPolicy.granularity(span: 3000 * Self.day, trackHeight: 100) == .year)
        // No track measured yet: the finest, never a division by zero.
        #expect(MediaGridScrubPolicy.granularity(span: Self.year, trackHeight: 0) == .day)
    }

    @Test func theSpanIsEarliestToLatestWhateverTheOrder() {
        let dates = [Date(timeIntervalSince1970: 500), Date(timeIntervalSince1970: 100), Date(timeIntervalSince1970: 900)]
        #expect(MediaGridScrubPolicy.span(of: dates) == 800)
        #expect(MediaGridScrubPolicy.span(of: [Date]()) == 0)
        #expect(MediaGridScrubPolicy.span(of: [Date(timeIntervalSince1970: 7)]) == 0)
    }

    @Test func theLabelSaysOnlyWhatItsGranularityCanPick() throws {
        let locale = Locale(identifier: "en_US")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = try #require(calendar.date(from: DateComponents(year: 2020, month: 5, day: 28, hour: 12)))
        #expect(MediaGridScrubPolicy.text(for: date, granularity: .year, locale: locale) == "2020")
        #expect(MediaGridScrubPolicy.text(for: date, granularity: .month, locale: locale) == "May 2020")
        #expect(MediaGridScrubPolicy.text(for: date, granularity: .day, locale: locale) == "May 28, 2020")
        #expect(MediaGridScrubPolicy.text(for: nil, granularity: .day, locale: locale) == "No Date")
    }
}
