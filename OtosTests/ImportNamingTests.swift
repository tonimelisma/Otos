import Foundation
@testable import OtosKit
import Testing

struct ImportNamingTests {
    private static let calendar: Calendar = {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return value
    }()

    @Test func embeddedWallClockWinsOverFilesystemMtime() {
        let result = ImportNaming.timestamp(
            wallCompact: 20_260_814_163_418,
            fallbackModifiedAt: Date(timeIntervalSince1970: 0),
            calendar: Self.calendar,
            timeZone: Self.calendar.timeZone
        )
        #expect(result == CaptureWallComponents(year: 2026, month: 8, day: 14, hour: 16, minute: 34, second: 18))
    }

    /// 1_754_000_000 is 2025-07-31 22:13:20 UTC. The calendar carries UTC so the result
    /// can only match if the supplied zone, not the calendar's own, decides the wall time.
    @Test func fallbackUsesTheSuppliedLocalTimeZone() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let modifiedAt = Date(timeIntervalSince1970: 1_754_000_000)
        let losAngeles = try ImportNaming.timestamp(
            wallCompact: nil,
            fallbackModifiedAt: modifiedAt,
            calendar: calendar,
            timeZone: #require(TimeZone(identifier: "America/Los_Angeles"))
        )
        let tokyo = try ImportNaming.timestamp(
            wallCompact: nil,
            fallbackModifiedAt: modifiedAt,
            calendar: calendar,
            timeZone: #require(TimeZone(identifier: "Asia/Tokyo"))
        )
        #expect(losAngeles == CaptureWallComponents(year: 2025, month: 7, day: 31, hour: 15, minute: 13, second: 20))
        #expect(tokyo == CaptureWallComponents(year: 2025, month: 8, day: 1, hour: 7, minute: 13, second: 20))
    }

    @Test func noFactsReturnsNilInsteadOfEpochSentinel() {
        #expect(
            ImportNaming.timestamp(
                wallCompact: nil,
                fallbackModifiedAt: nil,
                calendar: Self.calendar,
                timeZone: Self.calendar.timeZone
            ) == nil
        )
    }
}
