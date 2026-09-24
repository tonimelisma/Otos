import Foundation
@testable import OtosKit
import Testing

/// ARC-047 / ADR 0024: whether a source's live inventory is trustworthy enough to
/// offer Import is a pure function of its catalog availability/activity —
/// covers every combination `CatalogLibraryActivity`/`LibraryAvailability` can
/// report.
struct ImportSourceReadinessTests {
    private func state(
        availability: LibraryAvailability,
        activity: CatalogLibraryActivity
    ) -> CatalogLibraryState {
        CatalogLibraryState(
            root: LibraryRoot(path: LibraryRootPath(rawValue: "/Volumes/CARD"), kind: .removableVolume),
            availability: availability,
            activity: activity
        )
    }

    @Test func availableAndIdleIsReady() {
        #expect(ImportSourceReadiness.evaluate(state(availability: .available, activity: .idle)) == .ready)
    }

    @Test func availableAndScanningIsPreparing() {
        #expect(ImportSourceReadiness.evaluate(state(availability: .available, activity: .scanning)) == .preparing)
    }

    @Test func availableAndEnumeratingIsPreparing() {
        #expect(ImportSourceReadiness.evaluate(state(availability: .available, activity: .enumerating)) == .preparing)
    }

    @Test func unavailableIsUnreachableRegardlessOfActivity() {
        #expect(ImportSourceReadiness.evaluate(state(availability: .unavailable, activity: .idle)) == .unreachable)
        #expect(ImportSourceReadiness.evaluate(state(availability: .unavailable, activity: .scanning)) == .unreachable)
        #expect(ImportSourceReadiness.evaluate(state(availability: .unavailable, activity: .enumerating))
            == .unreachable)
    }

    @Test func unknownIsUnreachableRegardlessOfActivity() {
        #expect(ImportSourceReadiness.evaluate(state(availability: .unknown, activity: .idle)) == .unreachable)
        #expect(ImportSourceReadiness.evaluate(state(availability: .unknown, activity: .scanning)) == .unreachable)
        #expect(ImportSourceReadiness.evaluate(state(availability: .unknown, activity: .enumerating)) == .unreachable)
    }
}
