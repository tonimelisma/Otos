import Foundation
import MediaMetadata
@testable import OtosKit
import Testing

/// ENR-003: the catalog sorts by the library's capture instant, asked of the stored
/// records — the first role in `CaptureTimestamps.instantPrecedence` whose time has a UTC
/// instant. A record that is not a capture time is left out.
struct CaptureInstantTests {
    private func instant(_ records: [CaptureTimestampRecord]) -> Date? {
        CaptureTimestamps(records: records).captureInstant?.time.instant
    }

    private func at(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    // Validates: ENR-003
    @Test func theCameraClockComesBeforeTheContainerAndGPS() {
        // A floating original pins no instant; the digitized time is the next camera
        // clock, ahead of QuickTime's creation date and the GPS fix.
        let records: [CaptureTimestampRecord] = [
            .absolute(.gps, instant: at(400)),
            .absolute(.quickTimeCreation, instant: at(300)),
            .absolute(.digitized, instant: at(200)),
            .floating(.original),
        ]
        #expect(instant(records) == at(200))
    }

    // Validates: ENR-003
    /// A stored record that is not a capture time — an unknown precision, missing or
    /// out-of-range components, a role this build does not know — is left out, so the next
    /// role answers.
    @Test func aRecordThatIsNotACaptureTimeIsLeftOut() {
        var unknownPrecision = CaptureTimestampRecord.absolute(.original, instant: at(100))
        unknownPrecision.precision = "sometime"
        var badMonth = CaptureTimestampRecord.absolute(.digitized, instant: at(150))
        badMonth.month = 13
        var unknownRole = CaptureTimestampRecord.absolute(.original, instant: at(50))
        unknownRole.role = "laterRole"
        let fallback = CaptureTimestampRecord.absolute(.gps, instant: at(400))
        #expect(instant([unknownPrecision, badMonth, unknownRole, fallback]) == at(400))
    }
}
