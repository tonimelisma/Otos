import Foundation
@testable import OtosKit
import Testing

/// ENR-035: a row the pacing ledger paces keeps its claim, held by the ledger, until its
/// pacing passes or a change may have resized it. No pass claims it only to give it back:
/// a paced row ahead of real work in the Store's order is claimed once per pacing, not once
/// per pass — and enrichment passes at every completion.
@Suite(.testScope)
struct PacedClaimsStayHeldTests {
    private let start = ContinuousClock.now
    private let pacing = EnrichmentRetrySchedule.production.ledgerPacing

    /// One library of one local photo, and a coordinator whose ledger paces it from `start`.
    private func pacedLibrary() async throws -> (CatalogStore, EnrichmentCoordinator, MediaAssetID) {
        let root = try makeTestDirectory().appending(path: "Pics", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = makeTestStore(location: .inMemory, scanner: fixedScanner(["paced.jpg"]))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        let scanned = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 1 }
        let asset = try #require(scanned.testAssets.first)
        var schedule = EnrichmentSchedule(retrySchedule: .production)
        schedule.pace(asset.id, sourceSize: asset.byteSize, cause: .serverDidNotAnswer, now: start)
        let coordinator = EnrichmentCoordinator(
            store: store,
            enricher: MediaEnricher { _, _, _, _, _, _ in .transient },
            originalStatus: { _ in .materialized },
            schedule: schedule
        )
        return (store, coordinator, asset.id)
    }

    @Test func aPacedRowIsClaimedOncePerPacingNotOncePerPass() async throws {
        let (store, coordinator, row) = try await pacedLibrary()
        for _ in 0 ..< 3 {
            #expect(await coordinator.dequeueEnrichmentWork(now: start).isEmpty)
        }
        let work = await coordinator.status.work
        #expect(work.rows == 1, "the row is read by one claim; later passes find it held")
        #expect(work.written == 0, "no claim is given back to be claimed again")
        #expect(await coordinator.schedule.pacedClaimIDs == [row])

        // The pacing passes: the claim goes back, and the next claim reads and admits the row.
        let due = await coordinator.dequeueEnrichmentWork(now: start.advanced(by: pacing))
        #expect(due.map(\.id) == [row])
        #expect(await coordinator.schedule.pacedClaimIDs.isEmpty)
        await coordinator.shutdown()
        await store.shutdown()
    }

    /// A change that may have resized the row gives its claim back, so the ledger compares its
    /// source at the next claim (ENR-007); found unchanged, it is held again, and stays held.
    @Test func aMembershipChangeNamingAPacedRowGivesItsClaimBackOnce() async throws {
        let (store, coordinator, row) = try await pacedLibrary()
        _ = await coordinator.dequeueEnrichmentWork(now: start)
        await coordinator.noteStoreChange(.changed(.membership, rows: .rows([row])))
        #expect(await coordinator.dequeueEnrichmentWork(now: start).isEmpty)
        #expect(await coordinator.dequeueEnrichmentWork(now: start).isEmpty)
        let work = await coordinator.status.work
        #expect(work.rows == 2, "claimed again once, after the change")
        #expect(work.written == 1, "the one claim given back is the change's")
        #expect(await coordinator.schedule.pacedClaimIDs == [row])
        await coordinator.shutdown()
        await store.shutdown()
    }

    /// The session's shape (2026-11-18): a video whose enrichment writes its products but cannot
    /// read its faces — written, still owing, and paced. Every pass after it, woken by each
    /// completion, finds the video held: it is read once, claimed once more to be held, and
    /// nothing is downloaded.
    @Test func aVideoWhoseFacesWentUnreadIsNotClaimedByEveryLaterPass() async throws {
        let root = try makeTestDirectory().appending(path: "Pics", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let files: [(relativeName: String, byteSize: Int64, contentTypeIdentifier: String)] =
            [("clip.mov", 100, "com.apple.quicktime-movie")]
        let store = makeTestStore(location: .inMemory, scanner: fixedScanner(files))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        let scanned = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 1 }
        let video = try #require(scanned.testAssets.first?.id)

        let downloads = PacedCounter()
        let videoReads = PacedCounter()
        let coordinator = EnrichmentCoordinator(
            store: store,
            enricher: MediaEnricher { id, _, size, mtime, _, _ in
                await videoReads.count()
                return .facesUnread(EnrichmentResult(
                    id: id,
                    metadata: EnrichedMetadata(metadata: AssetMetadata(), kind: nil, format: nil),
                    rendering: EnrichedRendering(thumbnailPath: "t.jpg"),
                    sourceSize: size, sourceMTimeSeconds: mtime,
                    contentHash: ContentDigest(data: Data(repeating: 3, count: ContentDigest.byteCount))
                ), .video)
            },
            materialize: { _ in
                await downloads.count()
                return .testMaterialized
            },
            originalStatus: { _ in .materialized }
        )
        await coordinator.start()
        try await waitUntil {
            let asset = try await store.windowReads.mediaAssets(for: [video])[video]
            return asset?.metadataStale == false && asset?.videoFacesStale == true
        }
        _ = try await coordinator.untilQuiescent()
        #expect(await coordinator.schedule.pacedClaimIDs == [video])
        let settled = await coordinator.status.work

        // Each completion wakes a pass; ring as many as a session's completions would.
        for _ in 0 ..< 5 {
            await coordinator.ringIdle()
            _ = try await coordinator.untilQuiescent()
        }

        let after = await coordinator.status.work
        #expect(after.rows == settled.rows, "no later pass claims the paced video, or any row")
        #expect(after.written == settled.written, "and none gives a claim back")
        #expect(await videoReads.total == 1, "the video is read once")
        #expect(await downloads.total == 0, "nothing is downloaded")
        await coordinator.shutdown()
        await store.shutdown()
    }
}

private actor PacedCounter {
    private(set) var total = 0

    func count() {
        total += 1
    }
}
