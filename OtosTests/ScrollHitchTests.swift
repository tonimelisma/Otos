import AppKit
@testable import OtosKit
import Testing

/// A measured continuous scroll counts a frame as late by Apple's hitch rule, over the
/// display link's own timestamps, and never starts where no frame can be presented.
@Suite(.testScope)
@MainActor
struct ScrollHitchTests {
    /// 120 Hz: a refresh is 1/120 s.
    private let refresh = 1.0 / 120

    @Test func framesOnTimeOrWithinJitterAddNoHitchTime() {
        var tally = ScrollFrameTally()
        var time = 100.0
        for jitter in [0.0, 0.002, -0.001, 0.004, 0.0] {
            tally.record(timestamp: time, expected: refresh)
            time += refresh + jitter
        }
        #expect(tally.frames == 4)
        #expect(tally.hitchSeconds == 0)
        #expect(abs(tally.refreshSeconds - refresh) < 1e-9)
    }

    /// A main thread held 200 ms delays the next callback by as much: the time past one
    /// refresh is the hitch, and the long frame is the worst.
    @Test func aHeldFrameAddsTheTimePastOneRefresh() {
        var tally = ScrollFrameTally()
        tally.record(timestamp: 10, expected: refresh)
        tally.record(timestamp: 10 + refresh, expected: refresh)
        tally.record(timestamp: 10 + refresh + 0.2, expected: refresh)
        tally.record(timestamp: 10 + 2 * refresh + 0.2, expected: refresh)
        #expect(tally.frames == 3)
        #expect(abs(tally.hitchSeconds - (0.2 - refresh)) < 1e-9)
        #expect(abs(tally.worstFrameSeconds - 0.2) < 1e-9)
        #expect(abs(tally.durationSeconds - (2 * refresh + 0.2)) < 1e-9)
    }

    @Test func theReportStatesHitchTimePerSecondOfScroll() {
        let report = ScrollHitchReport(
            revision: 1, ending: .complete, frames: 960, durationMs: 8000, hitchMs: 1234,
            worstFrameMs: 220, refreshMicroseconds: 8333, points: 12000
        )
        #expect(report.hitchMsPerSecond == 154.3)
    }

    @Test func aScrollNeedsAGrid() {
        let monitor = MainRunLoopStallMonitor()
        #expect(monitor.measureContinuousScroll(points: 100, pointsPerSecond: 100) == .noGrid)
    }
}

extension AppKitWindowTests {
    @MainActor
    struct ScrollHitchWindowTests {
        /// A window that is not on screen presents no frames, so the scroll does not start,
        /// and says why.
        @Test func aScrollDoesNotStartInAWindowThatIsNotOnScreen() {
            let monitor = MainRunLoopStallMonitor()
            let window = NSWindow(
                contentRect: NSRect(x: -4000, y: -4000, width: 200, height: 200),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.animationBehavior = .none
            window.isReleasedWhenClosed = false
            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
            window.contentView = scrollView
            monitor.registerGridScrollView(scrollView)
            #expect(!window.occlusionState.contains(.visible))
            #expect(monitor.measureContinuousScroll(points: 100, pointsPerSecond: 100) == .windowOccluded)
        }
    }
}
