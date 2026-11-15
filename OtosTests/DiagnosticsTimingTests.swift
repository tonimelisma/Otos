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

    /// A scope drawn by a pane in place of the grid has a surface, and its paint is
    /// the pane getting what it draws: the People gallery and the duplicates list only once
    /// their owners have built.
    @Test func scopesNotDrawnByTheGridNameTheirSurface() {
        var state = CatalogWindowState.empty
        let surfaces: [(SidebarSelection, CatalogDetailSurface?)] = [
            (.people, .people), (.duplicates, .duplicates), (.places, .placesMap),
            (.onThisDay(CalendarDay(year: 2026, month: 11, day: 15)), .onThisDay), (.allMedia, nil),
        ]
        for (scope, surface) in surfaces {
            state.resolvedSidebarSelection = scope
            #expect(state.detailSurface == surface, "\(scope)")
        }
        state.resolvedSidebarSelection = .places
        #expect(state.detailSurfaceHasContent)
        state.resolvedSidebarSelection = .people
        #expect(!state.detailSurfaceHasContent, "People claims nothing before its first build")
        state.resolvedSidebarSelection = .allMedia
        #expect(!state.detailSurfaceHasContent, "the grid ends its own measurement")
    }

    @MainActor
    @Test func aPaneSurfaceCompletesTheMeasurementOfItsScope() {
        let monitor = MainRunLoopStallMonitor()
        monitor.beginIntentToPaint(scope: .people)
        #expect(!monitor.completeIntentToPaint(appliedScope: .places, surface: "placesMap"))
        #expect(monitor.completeIntentToPaint(appliedScope: .people, surface: "people"))
    }
}
