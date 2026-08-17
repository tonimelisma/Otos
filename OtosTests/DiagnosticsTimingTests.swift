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

    @Test func durationOverloadMatchesInstantOverload() {
        let clock = ContinuousClock()
        let start = clock.now
        let end = start.advanced(by: .milliseconds(1234))
        #expect(DiagnosticsTiming.milliseconds(start.duration(to: end)) == 1234)
    }

    @Test func elapsedMillisecondsHelperNoLongerDropsWholeSeconds() {
        let clock = ContinuousClock()
        let start = clock.now
        let end = start.advanced(by: .seconds(3) + .milliseconds(200))
        #expect(elapsedMilliseconds(from: start, to: end) == "3200")
    }
}

struct IntentToPaintMeasurementTests {
    @MainActor
    @Test func matchingScopeCompletesPendingMeasurement() {
        let monitor = MainRunLoopStallMonitor()
        monitor.beginIntentToPaint(scope: .allMedia)
        #expect(monitor.completeIntentToPaint(appliedScope: .allMedia))
        #expect(!monitor.completeIntentToPaint(appliedScope: .allMedia))
    }

    @MainActor
    @Test func unrelatedScopeDoesNotCompletePendingMeasurement() {
        let monitor = MainRunLoopStallMonitor()
        let path = LibraryRootPath(rawValue: "/tmp/Lib")
        monitor.beginIntentToPaint(scope: .library(path))
        #expect(!monitor.completeIntentToPaint(appliedScope: .allMedia))
        #expect(monitor.completeIntentToPaint(appliedScope: .library(path)))
    }

    @MainActor
    @Test func newerIntentReplacesPendingMeasurement() {
        let monitor = MainRunLoopStallMonitor()
        let path = LibraryRootPath(rawValue: "/tmp/Lib")
        monitor.beginIntentToPaint(scope: .allMedia)
        monitor.beginIntentToPaint(scope: .library(path))
        #expect(!monitor.completeIntentToPaint(appliedScope: .allMedia))
        #expect(monitor.completeIntentToPaint(appliedScope: .library(path)))
    }
}
