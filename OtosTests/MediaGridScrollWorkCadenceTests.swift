import Foundation
@testable import OtosKit
import Testing

/// A trailing edge alone never fires while scrolling continues — it is cancelled and
/// rescheduled by each bounds notification, and those arrive faster than its window.
/// The maximum wait is what serves a sustained fling.
struct MediaGridScrollWorkCadenceTests {
    @Test func aBurstThatIsStillRunningIsServedByTheMaximumWait() {
        #expect(MediaGridScrollWorkCadence.runsImmediately(sinceLastRun: 0.1))
        #expect(MediaGridScrollWorkCadence.runsImmediately(sinceLastRun: 5))
    }

    @Test func workJustRunIsLeftToTheTrailingEdge() {
        #expect(!MediaGridScrollWorkCadence.runsImmediately(sinceLastRun: 0))
        #expect(!MediaGridScrollWorkCadence.runsImmediately(sinceLastRun: 0.099))
    }

    @Test func theMaximumWaitOutlastsTheCoalesceWindow() {
        // Otherwise the maximum wait would fire first every time and the trailing edge
        // — which is what collapses a burst that ends — would never be reached.
        #expect(MediaGridScrollWorkCadence.maximumWait > MediaGridScrollWorkCadence.coalesceWindow)
    }

    @Test func aTickRateFasterThanTheWindowStillGetsServed() {
        // The measured case: bounds notifications ~6.5 ms apart against a 16 ms window,
        // so every trailing edge is cancelled. Walk that rate forward and confirm the
        // maximum wait fires, and roughly as often as it promises.
        let tick = 0.0065
        var sinceLastRun = 0.0
        var runs = 0
        for _ in 0 ..< Int(1.0 / tick) {
            sinceLastRun += tick
            if MediaGridScrollWorkCadence.runsImmediately(sinceLastRun: sinceLastRun) {
                runs += 1
                sinceLastRun = 0
            }
        }
        #expect(runs >= 8)
        #expect(runs <= 10)
    }
}
