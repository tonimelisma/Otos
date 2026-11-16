import Foundation
@testable import OtosKit
import Testing

/// ENR-009: every materialization demand ends on a fact, never only on its transfer's
/// success. A held row ends when its row is deleted, its root is removed or stops being
/// readable, a slot frees, or its pacing passes; a demand at the outstanding limit is held,
/// whichever path demanded it.
@Suite(.testScope)
struct EnrichmentHoldEndingTests {
    private let start = ContinuousClock.now
    private let pacing = EnrichmentRetrySchedule.production.ledgerPacing

    private func work(_ id: MediaAssetID, sourceSize: Int64? = 100, attemptCount: Int = 0) -> EnrichmentCoordinator.DownloadWork {
        EnrichmentCoordinator.DownloadWork(
            id: id, url: id.fileURL, sourceSize: sourceSize, captureLocalTime: nil,
            isVideo: true, attemptCount: attemptCount
        )
    }

    /// A schedule holding `id` for the pacing after its last in-window retry failed at `start`.
    private func pacedHold(_ id: MediaAssetID) throws -> EnrichmentSchedule {
        var schedule = EnrichmentSchedule(retrySchedule: .production)
        let last = work(id, attemptCount: EnrichmentRetrySchedule.production.backgroundDownloadDelays.count)
        schedule.demand(last, ownsStoreClaim: true, outstandingLimit: 16)
        _ = schedule.takeSubmissions(globalLimit: 16, backgroundPerRoot: 16, viewport: [], now: start)
        let finished = schedule.finish(last, outcome: .requestFailed, now: start)
        let settlement = try #require(finished)
        guard case .paced = settlement.disposition else {
            Issue.record("expected the pacing hold, got \(settlement.disposition)")
            return schedule
        }
        #expect(schedule.materializations[id]?.hold == .pacing)
        return schedule
    }

    private func id(_ name: String, root: String = "/library") -> MediaAssetID {
        MediaAssetID(libraryRootPath: LibraryRootPath(rawValue: root), relativePath: MediaRelativePath(rawValue: name))
    }

    // MARK: - The schedule's transitions

    @Test func aPacedHoldEndsWhenTheStoreNoLongerHasItsRow() throws {
        let row = id("gone.mov")
        var schedule = try pacedHold(row)
        let claims = schedule.reconcile(sources: [:], checked: [row])
        #expect(claims == [row], "the hold's claim is given back")
        #expect(!schedule.hasDemand(for: row))
        #expect(schedule.nextWake(after: start) == nil, "nothing is left to wake for")
    }

    @Test func aPacedHoldStartsOverWhenItsSourceChanges() throws {
        let row = id("replaced.mov")
        var schedule = try pacedHold(row)
        let claims = schedule.reconcile(sources: [row: 250], checked: [row])
        #expect(claims.isEmpty)
        #expect(schedule.materializations[row]?.hold == .transferSlot)
        #expect(schedule.materializations[row]?.work.attemptCount == 0)
        let taken = schedule.takeSubmissions(globalLimit: 16, backgroundPerRoot: 16, viewport: [], now: start)
        #expect(taken.map(\.sourceSize) == [250], "other bytes are fetched at once, not after the pacing")
    }

    /// A demand made while the Store was read is no part of what the read reports.
    @Test func aDemandMadeAfterTheReadStartedIsLeftAlone() {
        var schedule = EnrichmentSchedule(retrySchedule: .production)
        let checked = id("checked.mov")
        let later = id("later.mov")
        schedule.demand(work(checked), ownsStoreClaim: true, outstandingLimit: 16)
        schedule.demand(work(later), ownsStoreClaim: true, outstandingLimit: 16)
        let claims = schedule.reconcile(sources: [:], checked: [checked])
        #expect(claims == [checked])
        #expect(schedule.hasDemand(for: later))
    }

    @Test func aTransferRunningWhenItsRowGoesEndsWithdrawn() throws {
        var schedule = EnrichmentSchedule(retrySchedule: .production)
        let row = id("running.mov")
        schedule.demand(work(row), ownsStoreClaim: true, outstandingLimit: 16)
        let running = try #require(schedule.takeSubmissions(
            globalLimit: 16, backgroundPerRoot: 16, viewport: [], now: start
        ).first)
        let withdrawn = schedule.withdraw { id, _ in id == row }
        #expect(withdrawn.dropped == 0 && withdrawn.claimsToRelease.isEmpty, "its slot is counted until it ends")
        #expect(schedule.inFlightCount == 1)
        let settlement = schedule.finish(running, outcome: .requestFailed, now: start)
        #expect(settlement == EnrichmentSchedule.Settlement(disposition: .withdrawn, releasesStoreClaim: true))
        #expect(!schedule.hasDemand(for: row), "a failure after the row went neither retries nor holds")
    }

    @Test func aDemandAtTheOutstandingLimitIsHeldForASlot() {
        var schedule = EnrichmentSchedule(retrySchedule: .production)
        let first = id("first.mov")
        let second = id("second.mov")
        let firstHeld = schedule.demand(work(first), ownsStoreClaim: true, outstandingLimit: 1)
        let secondHeld = schedule.demand(work(second), ownsStoreClaim: true, outstandingLimit: 1)
        #expect(!firstHeld)
        #expect(secondHeld)
        #expect(schedule.outstandingCount == 1)
        #expect(schedule.materializations[second]?.hold == .transferSlot)
    }

    // MARK: - The coordinator, at the facts the Store reports

    /// The user deletes a folder of cloud videos while one waits out its pacing. The Store's
    /// change for the deletion ends the hold: no transfer is spent on the row once the pacing
    /// passes, and its claim is given back.
    @Test func aRowDeletedWhileHeldIsNeverFetchedAgain() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Videos", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)
        let rel = MediaRelativePath(rawValue: "clip.mov")
        let row = MediaAssetID(libraryRootPath: rootPath, relativePath: rel)
        let present = HoldTestPresence()
        let (watcher, emit) = CatalogFilesystemWatcher.testing()
        let store = makeTestStore(location: .inMemory, scanner: presenceScanner(rel, present: present), filesystemWatcher: watcher)
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 1 }
        let coordinator = try EnrichmentCoordinator(
            store: store,
            enricher: MediaEnricher { _, _, _, _, _, _ in .transient },
            originalStatus: { _ in .dataless },
            schedule: pacedHold(row)
        )
        let changes = await store.changeNotifications()

        await present.set(false)
        emit(FilesystemEvent(path: root.appending(path: "clip.mov").path(percentEncoded: false), flags: 0))
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.isEmpty }
        // The coordinator hears the change that removed the row, as its consumer delivers it.
        for await change in changes {
            await coordinator.noteStoreChange(change)
            guard change.facts.contains(.membership) else {
                continue
            }
            if case let .named(rows) = change.rows, !rows.contains(row) {
                continue
            }
            break
        }

        let submitted = await coordinator.dequeueMaterializationSubmissions(now: start.advanced(by: pacing))
        #expect(submitted.isEmpty)
        #expect(await coordinator.schedule.hasDemand(for: row) == false)
        await coordinator.shutdown()
    }

    /// The user removes a library while one of its rows waits out its pacing: the next pass
    /// drops the hold, so nothing of the removed library is fetched again.
    @Test func aRemovedLibrarysHeldRowIsNeverFetchedAgain() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Videos", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = makeTestStore(location: .inMemory, scanner: fixedScanner(["clip.mov"]))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        let scanned = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 1 }
        let row = try #require(scanned.testAssets.first?.id)
        let coordinator = try EnrichmentCoordinator(
            store: store,
            enricher: MediaEnricher { _, _, _, _, _, _ in .transient },
            originalStatus: { _ in .dataless },
            schedule: pacedHold(row)
        )

        _ = try await store.removeLibrary(path: row.libraryRootPath)
        _ = await coordinator.dequeueEnrichmentWork(now: start.advanced(by: pacing))

        let submitted = await coordinator.dequeueMaterializationSubmissions(now: start.advanced(by: pacing))
        #expect(submitted.isEmpty)
        #expect(await coordinator.schedule.hasDemand(for: row) == false)
        await coordinator.shutdown()
    }

    /// A ready row whose read found it dataless becomes a demand like a routed one: at the
    /// outstanding limit it is held for a slot, never one more transfer promised.
    @Test func aRowFoundDatalessAtTheLimitIsHeld() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pics", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = makeTestStore(location: .inMemory, scanner: fixedScanner(["a.jpg"]))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 1 }
        var schedule = EnrichmentSchedule(retrySchedule: .production)
        schedule.demand(work(id("waiting.mov")), ownsStoreClaim: false, outstandingLimit: 1)
        let coordinator = EnrichmentCoordinator(
            store: store,
            enricher: MediaEnricher { _, _, _, _, _, _ in .notMaterialized },
            originalStatus: { _ in .materialized },
            schedule: schedule,
            handoffPolicy: EnrichmentMaterializationHandoffPolicy(globalOutstandingLimit: 1, backgroundOutstandingPerRoot: 1)
        )
        let reading = try #require(await coordinator.dequeueEnrichmentWork().first)

        await coordinator.finishEnrich(reading, .notMaterialized)

        #expect(await coordinator.schedule.outstandingCount == 1)
        #expect(await coordinator.schedule.materializations[reading.id]?.hold == .transferSlot)
        await coordinator.shutdown()
    }
}

private actor HoldTestPresence {
    private(set) var value = true

    func set(_ value: Bool) {
        self.value = value
    }
}

private func presenceScanner(_ rel: MediaRelativePath, present: HoldTestPresence) -> CatalogScanner {
    CatalogScanner { _, _, batchHandler in
        guard await present.value else {
            return .empty
        }
        try await batchHandler([
            ScannedMediaFile(
                relativePath: rel,
                name: rel.rawValue,
                contentTypeIdentifier: "com.apple.quicktime-movie",
                byteSize: 100,
                createdAt: nil,
                contentModifiedAt: Date(timeIntervalSince1970: 1000)
            ),
        ])
        return .mediaOnly([rel])
    }
}
