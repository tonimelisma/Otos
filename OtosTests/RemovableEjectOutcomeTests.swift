import Darwin
import DiskArbitration
import Foundation
@testable import OtosKit
import Testing

@Suite(.testScope)
struct RemovableEjectOutcomeTests {
    @MainActor
    @Test func missingIdentitySurfacesEjectFailure() {
        let temp = PreferencesDomain.suite(UUID().uuidString)
        let model = CatalogWindowViewModel(
            catalogStore: makeTestStore(location: .inMemory),
            catalogProjection: CatalogProjection(),
            startsStallMonitor: false,
            startsEnrichment: false,
            startsSourceMonitoring: false,
            preferencesDomain: temp,
            volumeCapacity: ampleVolumeCapacity,
            trashFiles: .refusing
        )
        model.ejectRemovableSource(LibraryRoot(
            path: LibraryRootPath(rawValue: "/Volumes/Gone"),
            kind: .removableVolume
        ))
        #expect(model.ejectAlertMessage?.contains("device identity") == true)
    }

    /// Measured on macOS 27.0.1 against a held file on a scratch volume:
    /// DiskArbitration refuses with `unix_err(EBUSY)`, `0xC010`, and no status string.
    @Test func aBusyVolumeIsTheMeasuredUnixEBUSYStatus() {
        #expect(DiskEjector.unixError(EBUSY) == 0xC010)
        #expect(DiskEjector.outcome(refusal: 0xC010) == .busy)
        #expect(DiskEjector.outcome(refusal: DAReturn(truncatingIfNeeded: kDAReturnBusy)) == .busy)
        #expect(DiskEjector.outcome(refusal: DiskEjector.unixError(EPERM)) == .refused(status: DiskEjector.unixError(EPERM)))
        #expect(DiskEjector.bsdError(in: DiskEjector.unixError(EPERM)) == EPERM)
        #expect(DiskEjector.bsdError(in: DAReturn(truncatingIfNeeded: kDAReturnNotPermitted)) == nil)
    }

    /// The alert names the BSD error in the system's words when the status carries one,
    /// and invents no cause when it does not.
    @Test func aRefusalDescribesOnlyTheCauseItCarries() {
        let withCause = CatalogWindowViewModel.ejectFailureDescription(
            displayName: "CARD",
            status: DiskEjector.unixError(EPERM)
        )
        #expect(withCause.hasSuffix("\(String(cString: strerror(EPERM))).") == true)
        let withoutCause = CatalogWindowViewModel.ejectFailureDescription(
            displayName: "CARD",
            status: DAReturn(truncatingIfNeeded: kDAReturnNotPermitted)
        )
        #expect(withoutCause == "The disk \u{201C}CARD\u{201D} couldn\u{2019}t be ejected.")
    }

    /// A busy volume is retried on a bounded schedule; the first attempt that
    /// succeeds ends it.
    @Test func ejectRetriesWhileTheVolumeIsBusyAndStopsOnceItIsNot() async throws {
        let (store, root) = try await Self.attachedCard(identity: .volume(uuid: "eject-retry"))
        let attempts = Counter()
        let outcome = await CatalogWindowViewModel.performEjectRemovableSource(
            root,
            store: store,
            coordinator: nil,
            previewLoader: nil,
            retryDelays: [.milliseconds(10), .milliseconds(10), .milliseconds(10)],
            eject: { _ in await attempts.next() < 3 ? .busy : .ejected }
        )
        #expect(outcome == .ejected)
        #expect(await attempts.count == 3)
    }

    /// Past the last delay a still-busy volume is reported busy — the alert's
    /// wording, not silence.
    @Test func ejectReportsBusyOnceRetriesAreExhausted() async throws {
        let (store, root) = try await Self.attachedCard(identity: .volume(uuid: "eject-exhausted"))
        let attempts = Counter()
        let outcome = await CatalogWindowViewModel.performEjectRemovableSource(
            root,
            store: store,
            coordinator: nil,
            previewLoader: nil,
            retryDelays: [.milliseconds(10), .milliseconds(10)],
            eject: { _ in
                _ = await attempts.next()
                return .busy
            }
        )
        #expect(outcome == .busy(displayName: root.displayName))
        #expect(await attempts.count == 3, "the first attempt and one per delay")
    }

    /// A refusal that is not "busy" is not retried.
    @Test func ejectDoesNotRetryANonBusyRefusal() async throws {
        let (store, root) = try await Self.attachedCard(identity: .volume(uuid: "eject-failed"))
        let attempts = Counter()
        let outcome = await CatalogWindowViewModel.performEjectRemovableSource(
            root,
            store: store,
            coordinator: nil,
            previewLoader: nil,
            retryDelays: [.milliseconds(10)],
            eject: { _ in
                _ = await attempts.next()
                return .refused(status: DiskEjector.unixError(EPERM))
            }
        )
        guard case .failed = outcome else {
            Issue.record("Expected a failed outcome, got \(outcome)")
            return
        }
        #expect(await attempts.count == 1)
    }

    /// An import copying from the card holds its files open, and it is Otos's own work:
    /// the eject is refused at once, before any unmount attempt or retry.
    @Test func anEjectDuringAnImportIsRefusedAtOnce() async throws {
        let (store, root) = try await Self.attachedCard(identity: .volume(uuid: "eject-importing"))
        let attempts = Counter()
        let outcome = await CatalogWindowViewModel.performEjectRemovableSource(
            root,
            store: store,
            coordinator: nil,
            previewLoader: nil,
            importInProgress: true,
            retryDelays: [.milliseconds(10)],
            eject: { _ in
                _ = await attempts.next()
                return .ejected
            }
        )
        #expect(outcome == .busy(displayName: root.displayName))
        #expect(await attempts.isUntouched)
    }

    /// The preview loader has finished its reads on the card before the first unmount
    /// attempt, and is released again once the eject has its outcome.
    @Test func previewReadsAreReleasedBeforeTheUnmountAndResumedAfterIt() async throws {
        for (identity, result) in [(DeviceIdentity.volume(uuid: "eject-drain-ok"), DiskEjector.Outcome.ejected), (.volume(uuid: "eject-drain-busy"), .busy)] {
            let (store, root) = try await Self.attachedCard(identity: identity)
            let readers = ReaderEvents()
            _ = await CatalogWindowViewModel.performEjectRemovableSource(
                root,
                store: store,
                coordinator: nil,
                previewLoader: readers,
                retryDelays: [],
                eject: { _ in
                    await readers.record("eject")
                    return result
                }
            )
            #expect(await readers.events == ["quiesce:\(root.path.rawValue)", "eject", "resume:\(root.path.rawValue)"])
        }
    }

    private actor ReaderEvents: PreviewLoading {
        private(set) var events: [String] = []

        func record(_ event: String) {
            events.append(event)
        }

        nonisolated func preview(for request: PreviewImageLoader.Request) async -> PreviewImageLoader.Outcome {
            .unavailable
        }

        func quiesce(under root: LibraryRootPath) {
            events.append("quiesce:\(root.rawValue)")
        }

        func resume(under root: LibraryRootPath) {
            events.append("resume:\(root.rawValue)")
        }
    }

    private actor Counter {
        private(set) var count = 0
        var isUntouched: Bool {
            count < 1
        }

        func next() -> Int {
            count += 1
            return count
        }
    }

    private static func attachedCard(identity: DeviceIdentity) async throws -> (CatalogStore, LibraryRoot) {
        let temp = try makeTestDirectory()
        let cardURL = temp.appending(path: "Card", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cardURL, withIntermediateDirectories: true)
        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.attachRemovableVolume(
            mountURL: cardURL,
            identity: identity,
            displayName: "Card",
            isEjectable: true,
            capabilities: .unknown
        )
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardURL)
        let snapshot = try await waitForCatalogStoreState(store) { snap in
            snap.removableSources.contains { $0.path == cardPath && !$0.isScanning }
        }
        let root = try #require(snapshot.removableSources.first { $0.path == cardPath }?.root)
        return (store, root)
    }
}

/// The eject itself, against a real disk: DiskArbitration's own report decides the
/// outcome. ExFAT, as camera cards are formatted.
///
/// An unmount asks every DiskArbitration client on the Mac that registered for unmount
/// approval, and any of them may dissent with `kDAReturnBusy`: a holder outside Otos, which
/// `DiskEjector` reports as `.busy` like an open file. Under a full suite beside other
/// checks, one such client dissented about ten seconds after the released volume's unmount
/// was asked for (`docs/research/2026-11-15-a-released-card-refused-by-another-client.md`).
/// So the released volume is ejected as Otos ejects a card (`performEjectRemovableSource`):
/// a busy refusal is asked again after its backoff, which nothing can replace — no client
/// reports when it stops dissenting.
struct DiskEjectorLiveDiskImageTests {
    @Test func aHeldVolumeIsBusyAndAReleasedOneEjects() async throws {
        let image = try MountedTestDiskImage.attach(filesystem: "ExFAT")
        defer { image.detach() }
        let held = image.mountURL.appending(path: "held.txt")
        try Data("held".utf8).write(to: held)
        let handle = try FileHandle(forReadingFrom: held)

        #expect(await DiskEjector.eject(volumeAt: image.mountURL) == .busy)
        #expect(FileManager.default.fileExists(atPath: image.mountURL.path(percentEncoded: false)))

        try handle.close()
        var outcome = await DiskEjector.eject(volumeAt: image.mountURL)
        for delay in CatalogWindowViewModel.ejectBusyRetryDelays where outcome == .busy {
            // time: backoff — a DiskArbitration client outside Otos dissented; none reports when it stops
            try await Task.sleep(for: delay)
            outcome = await DiskEjector.eject(volumeAt: image.mountURL)
        }
        #expect(outcome == .ejected)
        #expect(!FileManager.default.fileExists(atPath: held.path(percentEncoded: false)))
    }
}
