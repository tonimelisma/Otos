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

    @Test func fallbackUsesTheSuppliedLocalTimeZone() throws {
        let timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let calendar = Calendar(identifier: .gregorian)
        let result = ImportNaming.timestamp(
            wallCompact: nil,
            fallbackModifiedAt: Date(timeIntervalSince1970: 1_754_000_000),
            calendar: calendar,
            timeZone: timeZone
        )
        #expect(result?.hour != nil)
        #expect(result == ImportNaming.timestamp(
            wallCompact: nil,
            fallbackModifiedAt: Date(timeIntervalSince1970: 1_754_000_000),
            calendar: calendar,
            timeZone: timeZone
        ))
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
