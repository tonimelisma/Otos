import Foundation
@testable import OtosKit
import Testing

struct DiagnosticsTimingTests {
    @Test func instantOverloadIncludesWholeSecondsNotJustFractional() {
        let clock = ContinuousClock()
        let start = clock.now
        let end = start.advanced(by: .seconds(2) + .milliseconds(500))
        #expect(DiagnosticsTiming.milliseconds(from: start, to: end) == 2500)
    }

    @Test func elapsedMillisecondsHelperNoLongerDropsWholeSeconds() {
        let clock = ContinuousClock()
        let start = clock.now
        let end = start.advanced(by: .seconds(3) + .milliseconds(200))
        #expect(elapsedMilliseconds(from: start, to: end) == "3200")
    }
}

struct IntentToPaintMeasurementTests {
    /// A newer intent closes the pending one as abandoned rather than leaving
    /// its interval open: an abandoned navigation must never read as a hung one.
    @MainActor
    @Test func newerIntentAbandonsPendingMeasurement() {
        let monitor = MainRunLoopStallMonitor()
        let path = LibraryRootPath(rawValue: "/tmp/Lib")
        #expect(!monitor.beginIntentToPaint(scope: .allMedia))
        #expect(monitor.beginIntentToPaint(scope: .library(path)))
        #expect(!monitor.completeIntentToPaint(appliedScope: .allMedia))
        #expect(monitor.completeIntentToPaint(appliedScope: .library(path)))
        #expect(!monitor.beginIntentToPaint(scope: .allMedia), "a completed intent leaves nothing to abandon")
    }
}
