import Foundation
@testable import OtosKit
import Testing

/// A trailing edge alone never fires while scrolling continues — it is cancelled and
/// rescheduled by each bounds notification, and those arrive faster than its window.
/// The maximum wait is what serves a sustained fling.
struct MediaGridScrollWorkCadenceTests {
    @Test func workThatHasNeverRunRunsNow() {
        #expect(MediaGridScrollWorkCadence.runsImmediately(sinceLastRun: nil))
    }

    @Test func aTickRateFasterThanTheWindowStillGetsServed() {
        // The measured case: bounds notifications ~6.5 ms apart against a 16 ms window,
        // so every trailing edge is cancelled. Walk that rate forward and confirm the
        // maximum wait fires, and roughly as often as it promises.
        let tick = Duration.microseconds(6500)
        var sinceLastRun = Duration.zero
        var runs = 0
        for _ in 0 ..< Int(1.0 / 0.0065) {
            sinceLastRun += tick
            if MediaGridScrollWorkCadence.runsImmediately(sinceLastRun: sinceLastRun) {
                runs += 1
                sinceLastRun = .zero
            }
        }
        #expect(runs >= 8)
        #expect(runs <= 10)
    }
}
