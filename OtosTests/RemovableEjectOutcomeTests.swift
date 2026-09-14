import Darwin
import Foundation
@testable import OtosKit
import Testing

struct RemovableEjectOutcomeTests {
    @MainActor
    @Test func missingIdentitySurfacesEjectFailure() {
        let temp = PreferencesDomain.suite(UUID().uuidString)
        let model = CatalogWindowViewModel(
            catalogStore: CatalogStore(location: .inMemory),
            catalogProjection: CatalogProjection(),
            startsStallMonitor: false,
            startsEnrichment: false,
            startsSourceMonitoring: false,
            preferencesDomain: temp
        )
        model.ejectRemovableSource(LibraryRoot(
            path: LibraryRootPath(rawValue: "/Volumes/Gone"),
            kind: .removableVolume
        ))
        #expect(model.ejectAlertMessage?.contains("device identity") == true)
    }

    @Test func busyErrorMapsFromPOSIXUnderlyingEBUSY() {
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY), userInfo: nil)
        let error = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteUnknownError,
            userInfo: [NSUnderlyingErrorKey: underlying]
        )
        let outcome = CatalogWindowViewModel.removableEjectOutcome(
            for: error,
            displayName: "CARD"
        )
        #expect(outcome == .busy(displayName: "CARD"))
    }

    @Test func busyErrorMapsFromDiskArbitrationDissenter() {
        let error = NSError(
            domain: "com.apple.DiskArbitration.DADissenterError",
            code: 1,
            userInfo: nil
        )
        let outcome = CatalogWindowViewModel.removableEjectOutcome(
            for: error,
            displayName: "CARD"
        )
        #expect(outcome == .busy(displayName: "CARD"))
    }

    /// 2026-09-13: `NSWorkspace.unmountAndEjectDevice` reported the card as
    /// `NSOSStatusErrorDomain -47` (`fBsyErr`). Typed, not matched on the
    /// English description — an OSStatus error's generated description does
    /// not say "busy".
    @Test func busyErrorMapsFromCarbonFileBusyStatus() {
        let error = NSError(domain: NSOSStatusErrorDomain, code: -47, userInfo: nil)
        #expect(!error.localizedDescription.localizedCaseInsensitiveContains("busy"))
        let outcome = CatalogWindowViewModel.removableEjectOutcome(for: error, displayName: "CARD")
        #expect(outcome == .busy(displayName: "CARD"))
    }

    /// A busy volume is retried on a bounded schedule; the first attempt that
    /// succeeds ends it.
    @Test func ejectRetriesWhileTheVolumeIsBusyAndStopsOnceItIsNot() async throws {
        let (store, root) = try await Self.attachedCard(identity: "volume:eject-retry")
        let attempts = Counter()
        let outcome = await CatalogWindowViewModel.performEjectRemovableSource(
            root,
            store: store,
            coordinator: nil,
            retryDelays: [.milliseconds(10), .milliseconds(10), .milliseconds(10)],
            unmount: { _ in
                if await attempts.next() < 3 {
                    throw NSError(domain: NSOSStatusErrorDomain, code: -47, userInfo: nil)
                }
            }
        )
        #expect(outcome == .ejected)
        #expect(await attempts.count == 3)
    }

    /// Past the last delay a still-busy volume is reported busy — the alert's
    /// wording, not silence.
    @Test func ejectReportsBusyOnceRetriesAreExhausted() async throws {
        let (store, root) = try await Self.attachedCard(identity: "volume:eject-exhausted")
        let attempts = Counter()
        let outcome = await CatalogWindowViewModel.performEjectRemovableSource(
            root,
            store: store,
            coordinator: nil,
            retryDelays: [.milliseconds(10), .milliseconds(10)],
            unmount: { _ in
                _ = await attempts.next()
                throw NSError(domain: NSOSStatusErrorDomain, code: -47, userInfo: nil)
            }
        )
        #expect(outcome == .busy(displayName: root.displayName))
        #expect(await attempts.count == 3, "the first attempt and one per delay")
    }

    /// A failure that is not "busy" is not retried.
    @Test func ejectDoesNotRetryANonBusyFailure() async throws {
        let (store, root) = try await Self.attachedCard(identity: "volume:eject-failed")
        let attempts = Counter()
        let outcome = await CatalogWindowViewModel.performEjectRemovableSource(
            root,
            store: store,
            coordinator: nil,
            retryDelays: [.milliseconds(10)],
            unmount: { _ in
                _ = await attempts.next()
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: nil)
            }
        )
        guard case .failed = outcome else {
            Issue.record("Expected a failed outcome, got \(outcome)")
            return
        }
        #expect(await attempts.count == 1)
    }

    private actor Counter {
        private(set) var count = 0
        func next() -> Int {
            count += 1
            return count
        }
    }

    private static func attachedCard(identity: String) async throws -> (CatalogStore, LibraryRoot) {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let cardURL = temp.appending(path: "Card", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cardURL, withIntermediateDirectories: true)
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.attachRemovableVolume(
            mountURL: cardURL,
            identity: identity,
            displayName: "Card",
            isEjectable: true
        )
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardURL)
        let snapshot = try await waitForCatalogStoreState(store) { snap in
            snap.removableSources.contains { $0.path == cardPath && !$0.isScanning }
        }
        let root = try #require(snapshot.removableSources.first { $0.path == cardPath }?.root)
        return (store, root)
    }

    @Test func busyErrorMapsFromLocalizedDescriptionFallback() {
        let error = NSError(
            domain: "Test",
            code: 999,
            userInfo: [NSLocalizedDescriptionKey: "The disk couldn't be ejected because it is in use."]
        )
        let outcome = CatalogWindowViewModel.removableEjectOutcome(
            for: error,
            displayName: "CARD"
        )
        #expect(outcome == .busy(displayName: "CARD"))
    }

    @Test func userCancelledMapsToCancelledNotBusy() {
        let error = NSError(
            domain: NSCocoaErrorDomain,
            code: NSUserCancelledError,
            userInfo: nil
        )
        let outcome = CatalogWindowViewModel.removableEjectOutcome(
            for: error,
            displayName: "CARD"
        )
        #expect(outcome == .cancelled)
    }

    @Test func failedErrorMapsGenericDescription() {
        let error = NSError(
            domain: "Test",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Unmount failed for an unknown reason."]
        )
        let outcome = CatalogWindowViewModel.removableEjectOutcome(
            for: error,
            displayName: "CARD"
        )
        #expect(outcome == .failed(description: "Unmount failed for an unknown reason."))
    }

    @Test func unknownCocoaWriteErrorWithoutBusyUnderlyingMapsToFailed() {
        let error = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteUnknownError,
            userInfo: [NSLocalizedDescriptionKey: "The operation couldn’t be completed."]
        )
        let outcome = CatalogWindowViewModel.removableEjectOutcome(
            for: error,
            displayName: "CARD"
        )
        #expect(outcome == .failed(description: "The operation couldn’t be completed."))
    }
}
