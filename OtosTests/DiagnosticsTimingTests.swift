import Foundation
@testable import Otos
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
