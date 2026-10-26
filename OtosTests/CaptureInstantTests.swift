import Foundation
import MediaMetadata
@testable import OtosKit
import Testing

/// ENR-003: the catalog sorts by the library's capture instant — the first role in
/// `CaptureTimestamps.instantPrecedence` whose stored record has a UTC instant.
struct CaptureInstantTests {
    private func record(_ role: CaptureTimestamps.Role, _ seconds: TimeInterval?) -> CaptureTimestampRecord {
        CaptureTimestampRecord(role: role.rawValue, instant: seconds.map { Date(timeIntervalSince1970: $0) })
    }

    @Test func theCameraClockComesBeforeTheContainerAndGPS() {
        // A floating original pins no instant; the digitized time is the next camera
        // clock, ahead of QuickTime's creation date and the GPS fix.
        let records = [
            record(.gps, 400),
            record(.quickTimeCreation, 300),
            record(.digitized, 200),
            record(.original, nil),
        ]
        #expect(CaptureInstant.select(from: records) == Date(timeIntervalSince1970: 200))
    }

    @Test func quickTimeContentCreateCountsAndGPSIsLast() {
        #expect(
            CaptureInstant.select(from: [record(.gps, 400), record(.quickTimeContentCreate, 250)])
                == Date(timeIntervalSince1970: 250)
        )
        #expect(CaptureInstant.select(from: [record(.gps, 400)]) == Date(timeIntervalSince1970: 400))
    }

    @Test func noInstantIsNoCaptureInstant() {
        #expect(CaptureInstant.select(from: [record(.original, nil)]) == nil)
        #expect(CaptureInstant.select(from: []) == nil)
    }
}
