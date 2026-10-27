import Foundation
@testable import OtosKit
import Synchronization
import Testing

@Suite(.testDirectory)
struct EnrichmentCoordinatorTests {
    @Test func unchangedAdmissionRejectionsEmitOneTransitionAcrossOneHundredWakes() async {
        let coordinator = EnrichmentCoordinator(
            store: CatalogStore(location: .inMemory),
            enricher: MediaEnricher { _, _, _, _, _, _ in .transient }
        )
        for _ in 0 ..< 100 {
            await coordinator.recordEnrichmentAdmission(
                rejections: [.videoEnrichCap: 25],
                admitted: 0
            )
        }
        #expect(await coordinator.enrichmentAdmissionTransitionCount == 1)
        await coordinator.recordEnrichmentAdmission(rejections: [:], admitted: 1)
        #expect(await coordinator.enrichmentAdmissionTransitionCount == 2)
    }

    @Test func enrichmentCoordinatorCapsVideosAndSkipsRejectedQueueHead() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pics", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let store = CatalogStore(
            location: .inMemory,
            scanner: fixedScanner([
                ("v1.mov", 100, "public.mpeg-4"),
                ("v2.mov", 100, "public.mpeg-4"),
                ("v3.mov", 100, "public.mpeg-4"),
                ("still.jpg", 100, "public.jpeg"),
            ])
        )
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 4 }

        var policy = EnrichmentAdmissionPolicy.production
        policy.videoEnrichCap = 2
        policy.enrichConcurrency = 8
        let blocker = CountingBlockingEnrichment()
        let coordinator = EnrichmentCoordinator(
            store: store,
            enricher: blocker.enricher(),
            materialize: { _ in .testMaterialized },
            readinessChecker: TestEnrichmentReadinessChecker(result: .materialized),
            enrichConcurrency: 8,
            claimBatchSize: 8,
            admissionPolicy: policy
        )
        await coordinator.start()
        await blocker.waitForStartedCount(3)

        #expect(await coordinator.inFlightEnrichVideoCount == 2)
        let started = await blocker.startedRelativePaths()
        #expect(started.filter { $0.hasSuffix(".mov") }.count == 2)
        #expect(started.contains("still.jpg"))

        await blocker.release()
        await coordinator.shutdown()
    }

    @Test func eagerDeviceStagingDownloadsStillItemsBeforeVideos() async throws {
        let temp = try makeTestDirectory()
        let rootPath = LibraryRootPath(
            rawValue: temp.appending(path: "DeviceStaging/Camera").path(percentEncoded: false)
        )
        let store = CatalogStore(location: .inMemory)
        let coordinator = EnrichmentCoordinator(
            store: store,
            enricher: MediaEnricher { _, _, _, _, _, _ in .transient },
            materialize: { _ in .testMaterialized },
            readinessChecker: TestEnrichmentReadinessChecker(result: .materialized)
        )
        let seeds = [
            deviceStagingSeed(rootPath: rootPath, relativePath: "video.mov", captureDate: 50, isVideo: true),
            deviceStagingSeed(rootPath: rootPath, relativePath: "still-b.jpg", captureDate: 200, isVideo: false),
            deviceStagingSeed(rootPath: rootPath, relativePath: "still-a.jpg", captureDate: 100, isVideo: false),
        ]

        await coordinator.stageDevice(seeds)
        let work = await coordinator.dequeueMaterializationSubmissions()

        #expect(work.map(\.id.relativePath.rawValue) == ["still-b.jpg", "still-a.jpg", "video.mov"])
    }

    @Test func shutdownReleasesQueuedAndInFlightClaims() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pics", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let relativeNames = ["a.jpg", "b.jpg", "c.jpg"]

        let store = CatalogStore(
            location: .inMemory,
            scanner: fixedScanner(relativeNames)
        )
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 3 }

        let blocker = BlockingEnrichment()
        let coordinator = EnrichmentCoordinator(
            store: store,
            enricher: blocker.enricher(),
            materialize: { _ in .testMaterialized },
            readinessChecker: TestEnrichmentReadinessChecker(result: .materialized),
            enrichConcurrency: 1,
            claimBatchSize: 3
        )
        await coordinator.start()
        await blocker.waitForStarted()

        await blocker.release()
        await coordinator.shutdown()
        let reclaimed = try await store.enrichmentCandidates(limit: 3)

        #expect(Set(reclaimed.map(\.asset.relativePath.rawValue)) == Set(relativeNames))
        try await store.releaseEnrichmentClaims(reclaimed.map(\.asset.id))
    }

    /// The eject drain drops work that was claimed but not started, and returns when the
    /// work that was running finishes — not after an interval.
    @Test func drainDropsQueuedWorkAndReturnsWhenRunningWorkFinishes() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Card", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let relativeNames = ["a.jpg", "b.jpg", "c.jpg"]
        let store = CatalogStore(location: .inMemory, scanner: fixedScanner(relativeNames))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 3 }
        let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)

        let enrichment = CountingBlockingEnrichment()
        let coordinator = EnrichmentCoordinator(
            store: store,
            enricher: enrichment.enricher(),
            materialize: { _ in .testMaterialized },
            readinessChecker: TestEnrichmentReadinessChecker(result: .materialized),
            enrichConcurrency: 1,
            claimBatchSize: 3
        )
        await coordinator.start()
        await enrichment.waitForStartedCount(1)
        let running = try #require(await enrichment.startedRelativePaths().first)

        let returned = Mutex(false)
        let drain = Task {
            await coordinator.drainWork(under: rootPath)
            returned.withLock { $0 = true }
        }
        try await waitUntil { await coordinator.drainWaiterCount == 1 }
        #expect(!returned.withLock { $0 }, "the drain returned while enrichment was still running")

        await enrichment.release()
        await drain.value
        #expect(
            await Set(enrichment.startedRelativePaths()) == [running],
            "work the drain dropped started anyway"
        )
        await coordinator.shutdown()
    }

    /// ENR-018: a row the user is looking at is claimed ahead of queued background work and
    /// outside the claim window. With the window full of slow background claims, the next
    /// free slot goes to the visible row, not to the next queued one.
    @Test func aVisibleRowStartsBeforeQueuedBackgroundWork() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pics", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let names = ["a.jpg", "b.jpg", "c.jpg", "d.jpg", "e.jpg", "f.jpg"]
        let store = CatalogStore(location: .inMemory, scanner: fixedScanner(names))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        let scanned = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 6 }
        let visibleID = try #require(scanned.testAssets.first { $0.relativePath.rawValue == "f.jpg" }?.id)

        let gate = PathGateEnrichment()
        let coordinator = EnrichmentCoordinator(
            store: store,
            enricher: gate.enricher(),
            materialize: { _ in .testMaterialized },
            readinessChecker: TestEnrichmentReadinessChecker(result: .materialized),
            enrichConcurrency: 1,
            claimBatchSize: 3,
            claimWindowLimit: 3
        )
        await coordinator.start()
        await gate.waitForStartedCount(1)
        // Equal capture dates claim in path order: "a.jpg" runs, "b.jpg" and "c.jpg" fill
        // the rest of the window.
        #expect(await gate.startedRelativePaths() == ["a.jpg"])
        #expect(await coordinator.readyClaims.count == 3)

        await coordinator.updateViewport([visibleID])
        await gate.release("a.jpg")
        await gate.waitForStartedCount(2)

        #expect(await gate.startedRelativePaths() == ["a.jpg", "f.jpg"])
        await gate.releaseAll()
        await coordinator.shutdown()
    }

    /// ENR-017: once an import starts copying from a card, the work queued on the card is
    /// dropped and nothing new starts there; the work already reading finishes. When the
    /// import ends the card enriches again.
    @Test func queuedCardWorkIsDroppedWhileTheCardIsImported() async throws {
        let temp = try makeTestDirectory()
        let card = temp.appending(path: "CARD", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        let store = CatalogStore(location: .inMemory, scanner: fixedScanner(["a.jpg", "b.jpg", "c.jpg"]))
        try await store.start(scansSavedLibraries: false)
        try await store.attachRemovableVolume(
            mountURL: card,
            identity: .volume(uuid: "test-card"),
            displayName: "CARD",
            isEjectable: true
        )
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: card)
        _ = try await waitForCatalogStoreState(store) { state in
            state.removableSources.contains { $0.path == cardPath && !$0.isScanning }
        }

        let gate = PathGateEnrichment()
        let coordinator = EnrichmentCoordinator(
            store: store,
            enricher: gate.enricher(),
            materialize: { _ in .testMaterialized },
            readinessChecker: TestEnrichmentReadinessChecker(result: .materialized),
            enrichConcurrency: 1,
            claimBatchSize: 3,
            claimWindowLimit: 3
        )
        await coordinator.start()
        await gate.waitForStartedCount(1)
        #expect(await coordinator.readyClaims.count == 3)

        let batch = ImportBatchID()
        await store.beginImportSourceRead(batch, source: cardPath)
        try await waitUntil { await coordinator.readyClaims.count == 1 }
        await gate.release("a.jpg")
        try await waitUntil { await coordinator.readyClaims.isEmpty }
        #expect(await gate.startedRelativePaths() == ["a.jpg"])

        // The card is offered again, so a second card row starts; which one is the retry
        // ledger's to decide and not this test's.
        await store.endImportSourceRead(batch, source: cardPath)
        await gate.waitForStartedCount(2)
        await gate.releaseAll()
        await coordinator.shutdown()
    }

    @Test func visibleThumbnailLifecycleEnrichesViewportPriorityAssets() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pics", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let store = CatalogStore(
            location: .inMemory,
            scanner: fixedScanner(["a.jpg", "b.jpg"])
        )
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        let scanned = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 2 }
        let visibleID = try #require(scanned.testAssets.first { $0.relativePath.rawValue == "a.jpg" }?.id)

        let coordinator = visibleLifecycleCoordinator(store: store)
        await coordinator.updateViewport([visibleID])
        await coordinator.start()

        let enriched = try await waitForCatalogStoreState(store) { snapshot in
            snapshot.testAssets.count == 2 && snapshot.testAssets.allSatisfy { !$0.needsEnrichment(hashRequired: true) }
        }
        await coordinator.shutdown()

        let visible = try #require(enriched.testAssets.first { $0.relativePath.rawValue == "a.jpg" })
        #expect(visible.thumbnailPath?.hasPrefix("thumb-") == true)
        #expect(enriched.testAssets.allSatisfy { !$0.needsEnrichment(hashRequired: true) })
    }

    @Test func enrichesMaterializedAndDownloadsThenEnrichesDataless() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pics", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)
        let relativeNames = ["a.jpg", "b.jpg", "c.jpg"]

        let store = CatalogStore(
            location: .inMemory,
            scanner: fixedScanner(relativeNames)
        )
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 3 }

        // "b.jpg" begins dataless; the others materialized. The enricher discovers dataless
        // via the fake status; the materializer flips it to materialized.
        let datalessPath = rootPath.url.appending(path: "b.jpg", directoryHint: .notDirectory)
            .path(percentEncoded: false)
        let state = FakeMaterialization(dataless: [datalessPath])
        let captureDate = Date(timeIntervalSince1970: 700)
        let enricher = MediaEnricher { id, access, size, mtime, _, _ in
            let url = access.localURL ?? id.fileURL
            if await state.isDataless(url.path(percentEncoded: false)) {
                return .notMaterialized
            }
            return .complete(
                EnrichmentResult(
                    id: id,
                    metadata: AssetMetadata(timestamps: [.absolute(instant: captureDate)], cameraModel: "Cam"),
                    thumbnailPath: "t.jpg",
                    sourceSize: size,
                    sourceMTimeSeconds: mtime,
                    contentHash: .empty
                )
            )
        }
        let coordinator = EnrichmentCoordinator(
            store: store,
            enricher: enricher,
            materialize: { url in
                await state.materialize(url.path(percentEncoded: false))
                return .testMaterialized
            },
            readinessChecker: TestEnrichmentReadinessChecker(result: .materialized)
        )
        await coordinator.start()

        let enriched = try await waitForCatalogStoreState(store) { snapshot in
            snapshot.testAssets.count == 3 && snapshot.testAssets.allSatisfy { !$0.needsEnrichment(hashRequired: true) }
        }
        await coordinator.shutdown()

        #expect(enriched.testAssets.allSatisfy { $0.thumbnailPath == "t.jpg" })
        #expect(enriched.testAssets.allSatisfy { $0.bestCaptureDate == captureDate })
    }

    @Test func downloadLifecycleMaterializesThenEnrichesDatalessAsset() async throws {
        let context = try await makeDownloadLifecycleContext()
        await context.coordinator.updateViewport([context.id])
        await context.coordinator.start()

        let enriched = try await waitForCatalogStoreState(context.store) { snapshot in
            snapshot.testAssets.first?.needsEnrichment(hashRequired: true) == false
        }
        await context.coordinator.shutdown()

        let asset = try #require(enriched.testAssets.first)
        #expect(asset.thumbnailPath == "t.jpg")
        #expect(asset.needsEnrichment(hashRequired: true) == false)
    }

    @Test func transientOutcomeIsRetriedUntilComplete() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pics", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let store = CatalogStore(location: .inMemory, scanner: fixedScanner(["a.jpg"]))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 1 }

        // Fail transiently the first two attempts, then succeed.
        let attempts = AttemptCounter()
        let enricher = MediaEnricher { id, _, size, mtime, _, _ in
            if await attempts.next() < 2 {
                return .transient
            }
            return .complete(
                EnrichmentResult(
                    id: id,
                    metadata: AssetMetadata(),
                    thumbnailPath: "t.jpg",
                    sourceSize: size,
                    sourceMTimeSeconds: mtime,
                    contentHash: .empty
                )
            )
        }
        let coordinator = EnrichmentCoordinator(
            store: store,
            enricher: enricher,
            materialize: { _ in .testMaterialized },
            readinessChecker: TestEnrichmentReadinessChecker(result: .materialized)
        )
        await coordinator.start()

        let enriched = try await waitForCatalogStoreState(store) { snapshot in
            snapshot.testAssets.first?.needsEnrichment(hashRequired: true) == false
        }
        await coordinator.shutdown()
        #expect(enriched.testAssets.first?.thumbnailPath == "t.jpg")
        #expect(await attempts.total >= 3)
    }

    @Test func droppedStaleResultReWakesAndReEnriches() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pics", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let store = CatalogStore(location: .inMemory, scanner: fixedScanner(["a.jpg"]))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 1 }

        // The first completion reports a stale source size (the scanner's asset is 100
        // bytes), so the store drops it. Without a re-wake the asset would stay
        // needsEnrichment forever; with it, the coordinator retries with a matching result.
        let attempts = AttemptCounter()
        let enricher = MediaEnricher { id, _, size, mtime, _, _ in
            let attempt = await attempts.next()
            let reportedSize: Int64 = attempt == 0 ? (size ?? 0) + 1000 : (size ?? -1)
            return .complete(
                EnrichmentResult(
                    id: id,
                    metadata: AssetMetadata(),
                    thumbnailPath: "t.jpg",
                    sourceSize: reportedSize,
                    sourceMTimeSeconds: mtime,
                    contentHash: .empty
                )
            )
        }
        let coordinator = EnrichmentCoordinator(
            store: store,
            enricher: enricher,
            materialize: { _ in .testMaterialized },
            readinessChecker: TestEnrichmentReadinessChecker(result: .materialized)
        )
        await coordinator.start()

        let enriched = try await waitForCatalogStoreState(store) { snapshot in
            snapshot.testAssets.first?.needsEnrichment(hashRequired: true) == false
        }
        await coordinator.shutdown()
        #expect(enriched.testAssets.first?.thumbnailPath == "t.jpg")
        #expect(await attempts.total >= 2)
    }

    @Test func zeroByteClaimedAssetShortCircuitsWithoutMaterializeOrEnricher() async throws {
        let root = try makeTestDirectory().appending(path: "Pics", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = CatalogStore(
            location: .inMemory,
            scanner: fixedScanner([("empty.jpg", 0), ("ok.jpg", 100)])
        )
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 2 }

        let enrichCalls = AttemptCounter()
        let materializeCalls = AttemptCounter()
        let enricher = MediaEnricher { id, _, size, mtime, _, _ in
            _ = await enrichCalls.next()
            #expect(id.relativePath.rawValue == "ok.jpg")
            return .complete(EnrichmentResult(
                id: id, metadata: AssetMetadata(), thumbnailPath: "t.jpg",
                sourceSize: size, sourceMTimeSeconds: mtime, contentHash: .empty
            ))
        }
        let coordinator = EnrichmentCoordinator(
            store: store,
            enricher: enricher,
            materialize: { _ in
                _ = await materializeCalls.next()
                Issue.record("materialize must not run for zero-byte short-circuit")
                return .testMaterialized
            },
            readinessChecker: TestEnrichmentReadinessChecker(result: .materialized)
        )
        await coordinator.start()
        let enriched = try await waitForCatalogStoreState(store) {
            $0.testAssets.count == 2 && $0.testAssets.allSatisfy { !$0.needsEnrichment(hashRequired: true) }
        }
        await coordinator.shutdown()

        let empty = try #require(enriched.testAssets.first { $0.relativePath.rawValue == "empty.jpg" })
        let ok = try #require(enriched.testAssets.first { $0.relativePath.rawValue == "ok.jpg" })
        #expect(empty.byteSize == 0)
        #expect(empty.thumbnailPath == nil)
        #expect(empty.enrichedSourceSize == 0)
        #expect(empty.enrichedSourceMTimeSeconds == 1000)
        #expect(!empty.needsEnrichment(hashRequired: true))
        #expect(ok.thumbnailPath == "t.jpg")
        #expect(!ok.needsEnrichment(hashRequired: true))
        #expect(await enrichCalls.total == 1)
        #expect(await materializeCalls.total == 0)
    }

    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["OTOS_SCALE_TEST"] == "1")
    )
    func largeDatalessLibraryKeepsClaimAndMaterializationHandoffBounded() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pics", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let names = (0 ..< 25000).map { "asset-\($0).jpg" }
        let store = CatalogStore(location: .inMemory, scanner: fixedScanner(names))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) {
            !$0.isScanning && $0.testAssets.count == names.count
        }

        let executor = HeldMaterializationExecutor()
        let materializer = MaterializationCoordinator(
            store: store,
            executor: { await executor.run($0.id.fileURL) }
        )
        let coordinator = EnrichmentCoordinator(
            store: store,
            enricher: MediaEnricher { _, _, _, _, _, _ in .notMaterialized },
            materializationRequester: materializer,
            readinessChecker: TestEnrichmentReadinessChecker(result: .dataless),
            claimBatchSize: 32
        )
        await materializer.start()
        await coordinator.start()
        try await executor.waitForStarts(1)

        try await waitUntil(every: .milliseconds(10)) {
            await coordinator.workStateSnapshot().materializing >= 2
        }

        let state = await coordinator.workStateSnapshot()
        #expect(state.claimed <= 32)
        #expect(state.materializing == 2)
        #expect(await materializer.stateSnapshot().inFlight == 1)

        await coordinator.shutdown()
        #expect(await materializer.stateSnapshot().waiters == 0)
        await materializer.shutdown()
    }

    // MARK: - Claim-window release and retry exhaustion

    @Test func exhaustedBackgroundRetriesReleaseClaimWindowForFreshCandidate() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pics", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = CatalogStore(location: .inMemory, scanner: fixedScanner(["fresh.jpg"]))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        let scanned = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 1 }
        let freshID = try #require(scanned.testAssets.first?.id)

        // The coordinator starts with 32 permanently-failing background demands already
        // at the in-window retry bound. They hold no real Store row, isolating the
        // window-capacity behavior from Store bookkeeping.
        let badRoot = LibraryRootPath(rawValue: temp.appending(path: "Bad").path(percentEncoded: false))
        var schedule = EnrichmentSchedule(retrySchedule: .production)
        var badIDs: [MediaAssetID] = []
        for index in 0 ..< 32 {
            let badID = MediaAssetID(
                libraryRootPath: badRoot,
                relativePath: MediaRelativePath(rawValue: "bad-\(index).jpg")
            )
            schedule.demand(
                EnrichmentCoordinator.DownloadWork(
                    id: badID, url: badID.fileURL, sourceSize: 100, captureDate: nil,
                    isVideo: false, isDeviceStaging: false, attemptCount: 4, retryNotBefore: nil
                ),
                ownsStoreClaim: true
            )
            badIDs.append(badID)
        }
        let coordinator = EnrichmentCoordinator(
            store: store,
            enricher: MediaEnricher { _, _, _, _, _, _ in .transient },
            materialize: { _ in .testMaterialized },
            readinessChecker: TestEnrichmentReadinessChecker(result: .materialized),
            claimBatchSize: 8,
            schedule: schedule,
            claimWindowLimit: 32
        )
        #expect(await coordinator.workStateSnapshot().materializationPending == 32)

        // Materialization demands do not consume ready-enrichment capacity, so a
        // fresh materialized candidate can still enter the enrichment pool.
        let admittedWork = await coordinator.dequeueEnrichmentWork()
        #expect(admittedWork.map(\.id) == [freshID])

        // Each of the 32 exceeds its retry bound on this failure, which releases its
        // claim-window slot and hands pacing to the ledger instead of holding the slot
        // (the ledger side is `EnrichmentScheduleTests`).
        for badID in badIDs {
            let work = EnrichmentCoordinator.DownloadWork(
                id: badID, url: badID.fileURL, sourceSize: 100, captureDate: nil,
                isVideo: false, isDeviceStaging: false, attemptCount: 4, retryNotBefore: nil
            )
            await coordinator.finishDownload(
                work,
                result: MaterializationResult(outcome: .requestFailed, rerequestCount: 0, elapsedMs: 1),
                attemptMs: 1
            )
        }

        #expect(await coordinator.workStateSnapshot().materializationPending == 0)

        // The ready candidate remains in the independent ready pool; the exhausted
        // materialization demands no longer occupy a ready-enrichment slot.
        #expect(await coordinator.workStateSnapshot().readyQueued == 0)
        #expect(await coordinator.workStateSnapshot().enriching == 1)
    }

    /// ENR-009: a claimed row the ledger paces is deferred back to the Store while its
    /// source signature matches, and claimed at once when the source changed since the
    /// ledger entry was written.
    @Test func retryLedgerDefersMatchingSignatureAndResetsOnChange() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pics", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = CatalogStore(location: .inMemory, scanner: fixedScanner([("a.jpg", 100)]))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        let scanned = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 1 }
        let id = try #require(scanned.testAssets.first?.id)

        let paced = pacedSchedule([(id, 100)])
        let deferring = EnrichmentCoordinator(
            store: store,
            enricher: MediaEnricher { _, _, _, _, _, _ in .transient },
            materialize: { _ in .testMaterialized },
            readinessChecker: TestEnrichmentReadinessChecker(result: .materialized),
            schedule: paced
        )
        let deferred = await deferring.dequeueEnrichmentWork()
        #expect(deferred.isEmpty)
        #expect(await deferring.workStateSnapshot().claimed == 0)
        await deferring.shutdown()

        // The ledger saw a 999-byte source; the row is 100 bytes now.
        let changed = EnrichmentCoordinator(
            store: store,
            enricher: MediaEnricher { _, _, _, _, _, _ in .transient },
            materialize: { _ in .testMaterialized },
            readinessChecker: TestEnrichmentReadinessChecker(result: .materialized),
            schedule: pacedSchedule([(id, 999)])
        )
        let claimed = await changed.dequeueEnrichmentWork()
        #expect(claimed.map(\.id) == [id])
        await changed.shutdown()
    }

    @Test func retryLedgerSkipsPastBlockedCandidatesWithinBoundedPasses() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pics", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // "blocked-*" sorts before "fresh" so Store's deterministic ordering
        // (same capture date, tie-broken by relative path) ranks every blocked
        // candidate ahead of the one real candidate.
        let names = (0 ..< 4).map { "blocked-\($0).jpg" } + ["fresh.jpg"]
        let store = CatalogStore(location: .inMemory, scanner: fixedScanner(names))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        let scanned = try await waitForCatalogStoreState(store) {
            !$0.isScanning && $0.testAssets.count == names.count
        }
        let freshID = try #require(scanned.testAssets.first { $0.relativePath.rawValue == "fresh.jpg" }?.id)

        // A small claim batch (2) against 4 ledger-paced candidates forces multiple
        // claim/defer passes before "fresh" is ever reached.
        let blocked = scanned.testAssets.filter { $0.relativePath.rawValue != "fresh.jpg" }
        let coordinator = EnrichmentCoordinator(
            store: store,
            enricher: MediaEnricher { _, _, _, _, _, _ in .transient },
            materialize: { _ in .testMaterialized },
            readinessChecker: TestEnrichmentReadinessChecker(result: .materialized),
            enrichConcurrency: 2,
            claimBatchSize: 2,
            schedule: pacedSchedule(blocked.map { ($0.id, $0.byteSize) })
        )

        let claimed = await coordinator.dequeueEnrichmentWork()
        #expect(claimed.map(\.id) == [freshID])
    }

    /// A camera attach offers every catalog item at once, while only
    /// `globalOutstandingLimit` may be outstanding. `stageDevice` must queue the
    /// overflow rather than take `seeds.prefix(available)` and discard the rest,
    /// because nothing would recover them: the catalog flow runs once per attach, and
    /// an unstaged device file fails `lstat`, so readiness routing answers `.unknown`
    /// and retries readiness rather than creating a demand. A camera with more items
    /// than the limit would never fully stage, and so never fully enrich — while
    /// ENR-011 says every connected-source item is staged.
    @Test func stageDeviceQueuesEverySeedPastTheOutstandingLimit() async {
        let coordinator = EnrichmentCoordinator(
            store: CatalogStore(location: .inMemory),
            enricher: MediaEnricher { _, _, _, _, _, _ in .transient },
            materialize: { _ in .testMaterialized },
            readinessChecker: TestEnrichmentReadinessChecker(result: .materialized)
        )
        let rootPath = LibraryRootPath(rawValue: "/DeviceStaging/BigCamera")
        let limit = EnrichmentMaterializationHandoffPolicy.production().globalOutstandingLimit
        let total = limit * 3
        let seeds = (0 ..< total).map { index in
            deviceStagingSeed(
                rootPath: rootPath,
                relativePath: "IMG_\(index).jpg",
                captureDate: TimeInterval(index),
                isVideo: false
            )
        }

        await coordinator.stageDevice(seeds)

        let snapshot = await coordinator.workStateSnapshot()
        // Nothing is discarded: everything offered is either an outstanding demand or
        // still queued for one.
        let accounted = snapshot.materializationPending + snapshot.materializationInFlight + snapshot.deviceSeedsQueued
        #expect(accounted == total)
        #expect(snapshot.deviceSeedsQueued > 0, "a camera larger than the limit must leave seeds queued, not dropped")
        await coordinator.shutdown()
    }

    /// D1's whole point, as observable behaviour. A camera that answers ranged reads is
    /// not seeded for download at all: its rows enrich from a few kilobytes each, so
    /// transferring them first would be moving the entire card to read a date that sits a
    /// few kilobytes into each file. On the measured session that was 36.5 GB and ~45
    /// minutes before the Import button could appear.
    @Test func aRangeCapableDeviceIsNotSeededForDownload() async {
        let coordinator = EnrichmentCoordinator(
            store: CatalogStore(location: .inMemory),
            enricher: MediaEnricher { _, _, _, _, _, _ in .transient },
            materialize: { _ in .testMaterialized },
            readinessChecker: TestEnrichmentReadinessChecker(result: .materialized)
        )
        let rootPath = LibraryRootPath(rawValue: "/DeviceStaging/RangedCamera")
        await coordinator.markRangeCapable(rootPath)

        await coordinator.stageDevice((0 ..< 40).map { index in
            deviceStagingSeed(
                rootPath: rootPath,
                relativePath: "IMG_\(index).arw",
                captureDate: TimeInterval(index),
                isVideo: false
            )
        })

        let snapshot = await coordinator.workStateSnapshot()
        #expect(snapshot.materializationPending == 0)
        #expect(snapshot.materializationInFlight == 0)
        #expect(
            snapshot.deviceSeedsQueued == 0,
            "a device that can be read by range must transfer nothing to be planned"
        )
        await coordinator.shutdown()
    }

    /// The fallback that keeps D1 safe. A device that fails its capability probe is never
    /// marked, and stages exactly as every device did before this path existed —
    /// `GetPartialObject` is optional in MTP, so this is the normal case for some hardware
    /// rather than an error path.
    @Test func aDeviceThatCannotServeRangesStillStagesEverything() async {
        let coordinator = EnrichmentCoordinator(
            store: CatalogStore(location: .inMemory),
            enricher: MediaEnricher { _, _, _, _, _, _ in .transient },
            materialize: { _ in .testMaterialized },
            readinessChecker: TestEnrichmentReadinessChecker(result: .materialized)
        )
        let rootPath = LibraryRootPath(rawValue: "/DeviceStaging/OldCamera")
        let total = 40

        await coordinator.stageDevice((0 ..< total).map { index in
            deviceStagingSeed(
                rootPath: rootPath,
                relativePath: "IMG_\(index).jpg",
                captureDate: TimeInterval(index),
                isVideo: false
            )
        })

        let snapshot = await coordinator.workStateSnapshot()
        #expect(
            snapshot.materializationPending + snapshot.materializationInFlight
                + snapshot.deviceSeedsQueued == total,
            "without a proven ranged read, every item must still be staged"
        )
        await coordinator.shutdown()
    }

    /// Without a resolvable session, a row falls back to its local file — so a camera that
    /// detaches between seeding and enriching degrades to the staging path rather than
    /// reading from a session that is gone.
    @Test func aRowWithoutALiveSessionFallsBackToItsLocalFile() async {
        let coordinator = EnrichmentCoordinator(
            store: CatalogStore(location: .inMemory),
            enricher: MediaEnricher { _, _, _, _, _, _ in .transient },
            materialize: { _ in .testMaterialized },
            readinessChecker: TestEnrichmentReadinessChecker(result: .materialized)
        )
        let rootPath = LibraryRootPath(rawValue: "/DeviceStaging/GoneCamera")
        await coordinator.markRangeCapable(rootPath)
        let id = MediaAssetID(libraryRootPath: rootPath, relativePath: MediaRelativePath(rawValue: "a.arw"))
        let work = EnrichmentCoordinator.EnrichWork(
            id: id,
            url: id.fileURL,
            sourceSize: 1024,
            sourceMTimeSeconds: nil,
            isVideo: false,
            captureDate: nil,
            isDeviceStaging: true,
            shouldHash: false
        )

        let access = await coordinator.byteAccess(for: work)

        #expect(access.localURL == id.fileURL, "no live session means no ranged read")
        await coordinator.shutdown()
    }

    /// The defect a live 991-item card found, which no unit test had caught.
    ///
    /// Not seeding a range-capable device is only half the change: the rows must then be
    /// *routed* to enrichment. They were not. `LiveEnrichmentReadinessChecker` asks the
    /// filesystem, a camera row has no file, `lstat` answers `.unknown`, and `.unknown`
    /// routes to a readiness retry — one that can never succeed, because nothing is going
    /// to create that file. Every camera row was deferred, re-probed and deferred again:
    /// `probes=128 ready=0 retryReadiness=32 dispatched=0`, forever, with no enrichment.
    ///
    /// The bug was invisible in the catalog because a re-attached camera keeps the overlay
    /// it already had, so rows still looked enriched from a previous session. It only showed
    /// once that overlay was cleared.
    @Test func rowsOnARangeCapableDeviceAreDispatchedDespiteHavingNoLocalFile() async throws {
        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        let rootPath = try await store.attachDeviceMTP(
            stagingRootURL: URL(fileURLWithPath: "/tmp/RangedCameraRoute", isDirectory: true),
            identity: .camera(id: "ranged-route"),
            displayName: "Camera"
        )
        let scan = try await store.beginDeviceCatalogEnumeration(rootPath: rootPath)
        try await store.recordDeviceCatalogBatch([
            ScannedMediaFile(
                relativePath: MediaRelativePath(rawValue: "DSC00001.ARW"),
                name: "DSC00001.ARW",
                contentTypeIdentifier: "com.sony.arw-raw-image",
                byteSize: 42_680_320,
                createdAt: nil,
                contentModifiedAt: nil
            ),
        ], scan: scan)

        let coordinator = EnrichmentCoordinator(
            store: store,
            // `.unknown` is what the filesystem really answers for a camera row: no file
            // exists at the staging path, so `lstat` fails.
            enricher: MediaEnricher { _, _, _, _, _, _ in .transient },
            materialize: { _ in .testMaterialized },
            readinessChecker: TestEnrichmentReadinessChecker(result: .unknown)
        )
        await coordinator.markRangeCapable(rootPath)

        let work = await coordinator.dequeueEnrichmentWork()

        #expect(
            work.contains { $0.id.libraryRootPath == rootPath },
            "a row whose bytes are reachable by range must be dispatched, not parked on a retry that cannot resolve"
        )
        await coordinator.shutdown()
    }

    /// The other half: a device that is *not* range-capable must still be governed by the
    /// filesystem, so a row with no local bytes routes to materialization rather than being
    /// handed to an enricher that has nothing to read.
    @Test func rowsOnADeviceWithoutRangedReadsStillFollowTheFilesystem() async {
        let coordinator = EnrichmentCoordinator(
            store: CatalogStore(location: .inMemory),
            enricher: MediaEnricher { _, _, _, _, _, _ in .transient },
            materialize: { _ in .testMaterialized },
            readinessChecker: TestEnrichmentReadinessChecker(result: .unknown)
        )
        let rootPath = LibraryRootPath(rawValue: "/DeviceStaging/PlainCamera")
        let id = MediaAssetID(libraryRootPath: rootPath, relativePath: MediaRelativePath(rawValue: "a.arw"))
        let work = EnrichmentCoordinator.EnrichWork(
            id: id, url: id.fileURL, sourceSize: 1024, sourceMTimeSeconds: nil,
            isVideo: false, captureDate: nil, isDeviceStaging: true, shouldHash: false
        )

        #expect(await coordinator.byteAccess(for: work).localURL == id.fileURL)
        await coordinator.shutdown()
    }

    @Test func stageDeviceSkipsSeedAlreadyMaterializing() async {
        let coordinator = EnrichmentCoordinator(
            store: CatalogStore(location: .inMemory),
            enricher: MediaEnricher { _, _, _, _, _, _ in .transient },
            materialize: { _ in .testMaterialized },
            readinessChecker: TestEnrichmentReadinessChecker(result: .materialized)
        )
        let rootPath = LibraryRootPath(rawValue: "/DeviceStaging/Camera")
        let id = MediaAssetID(libraryRootPath: rootPath, relativePath: MediaRelativePath(rawValue: "video.mov"))
        await coordinator.stageDevice([
            EnrichmentCoordinator.DeviceStagingSeed(
                id: id, sourceSize: 100, captureDate: Date(timeIntervalSince1970: 50), isVideo: true
            ),
        ])
        #expect(await coordinator.dequeueMaterializationSubmissions().map(\.id) == [id])

        let seeds = [
            EnrichmentCoordinator.DeviceStagingSeed(
                id: id, sourceSize: 100, captureDate: Date(timeIntervalSince1970: 50), isVideo: true
            ),
        ]
        await coordinator.stageDevice(seeds)

        let state = await coordinator.workStateSnapshot()
        #expect(state.materializationInFlight == 1)
        #expect(state.materializationPending == 0, "the seed already in flight is not demanded twice")
        #expect(state.deviceSeedsQueued == 0)
    }

    @Test func ejectDrainIgnoresPureInteractivePreviewTraffic() async throws {
        let store = CatalogStore(location: .inMemory)
        let executor = HeldMaterializationExecutor()
        let materializer = MaterializationCoordinator(store: store, executor: { await executor.run($0.id.fileURL) })
        await materializer.start()

        let rootPath = LibraryRootPath(rawValue: "/library")
        let previewID = MediaAssetID(
            libraryRootPath: rootPath,
            relativePath: MediaRelativePath(rawValue: "preview.jpg")
        )
        let previewTask = Task {
            await materializer.materialize(
                MaterializationCoordinator.Request(
                    id: previewID, sourceSize: 100, isVideo: false, priority: .interactive
                )
            )
        }
        try await executor.waitForStarts(1)

        let coordinator = EnrichmentCoordinator(
            store: store,
            enricher: MediaEnricher { _, _, _, _, _, _ in .transient },
            materializationRequester: materializer,
            readinessChecker: TestEnrichmentReadinessChecker(result: .dataless)
        )

        // The drain returns while the interactive request is still held: had it waited on
        // interactive traffic, it would not return until that request ended.
        await coordinator.drainWork(under: rootPath)
        #expect(await executor.startedCount() == 1)
        #expect(await materializer.stateSnapshot().inFlight == 1)

        previewTask.cancel()
        _ = await previewTask.value
        await materializer.shutdown()
    }

    /// `EnrichWork.shouldHash` must be the value Store's claim predicate decided
    /// (`ClaimedEnrichmentCandidate.hashRequired`), not a value the coordinator
    /// re-derives from its own notion of root kind — a coordinator-side cache of root
    /// kinds would be a second owner of the same fact, able to disagree if a root's
    /// kind changed between claim and dispatch. This test claims one asset from a `.library` root (hash
    /// required) and one from a `.removableVolume` root (hash not required) in the same
    /// coordinator, and confirms each dispatched `EnrichWork.shouldHash` matches its own
    /// claim rather than a single shared coordinator-wide value.
    @Test func dispatchedWorkCarriesClaimTimeHashRequiredPerRoot() async throws {
        let temp = try makeTestDirectory()
        let fixedRoot = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let removableRoot = temp.appending(path: "Card", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fixedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: removableRoot, withIntermediateDirectories: true)
        let removableRawPath = try CatalogPath.normalizedDirectoryPath(for: removableRoot).rawValue
        let scanner = CatalogScanner { rootPath, _, batchHandler in
            let name = rootPath.rawValue == removableRawPath ? "card.jpg" : "fixed.jpg"
            let file = ScannedMediaFile(
                relativePath: MediaRelativePath(rawValue: name),
                name: name,
                contentTypeIdentifier: "public.jpeg",
                byteSize: 100,
                createdAt: Date(timeIntervalSince1970: 1000),
                contentModifiedAt: Date(timeIntervalSince1970: 1000)
            )
            try await batchHandler([file])
            return .mediaOnly([file.relativePath])
        }
        let store = CatalogStore(location: .inMemory, scanner: scanner, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: fixedRoot)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 1 }
        try await store.attachRemovableVolume(
            mountURL: removableRoot,
            identity: .volume(uuid: "hash-required-claim"),
            displayName: "Card",
            isEjectable: false
        )
        _ = try await waitForCatalogStoreState(store) { snapshot in
            !snapshot.isScanning
                && snapshot.removableSources.first?.path.rawValue == removableRawPath
                && snapshot.removableSources.first?.availability == .available
        }

        let recorder = ShouldHashRecorder()
        let enricher = MediaEnricher { id, access, size, mtime, shouldHash, _ in
            let url = access.localURL ?? id.fileURL
            await recorder.record(name: url.lastPathComponent, shouldHash: shouldHash)
            return .complete(
                EnrichmentResult(
                    id: id,
                    metadata: AssetMetadata(),
                    thumbnailPath: "t.jpg",
                    sourceSize: size,
                    sourceMTimeSeconds: mtime,
                    contentHash: shouldHash ? .empty : nil
                )
            )
        }
        let coordinator = EnrichmentCoordinator(
            store: store,
            enricher: enricher,
            readinessChecker: TestEnrichmentReadinessChecker(result: .materialized)
        )
        await coordinator.start()

        // Not `needsEnrichment(hashRequired: true)`: the removable asset never gets a
        // hash by design (ADR 0018), so that check would never clear for it. Wait on
        // the enricher-recorded outcome instead.
        try await recorder.waitForBoth()
        await coordinator.shutdown()

        #expect(await recorder.shouldHash(name: "fixed.jpg") == true)
        #expect(await recorder.shouldHash(name: "card.jpg") == false)
    }
}

private actor ShouldHashRecorder {
    private var valuesByName: [String: Bool] = [:]

    func record(name: String, shouldHash: Bool) {
        valuesByName[name] = shouldHash
    }

    func shouldHash(name: String) -> Bool? {
        valuesByName[name]
    }

    func waitForBoth() async throws {
        try await waitUntil { valuesByName["fixed.jpg"] != nil && valuesByName["card.jpg"] != nil }
    }
}

// MARK: - Helpers

func fixedScanner(_ relativeNames: [String]) -> CatalogScanner {
    fixedScanner(relativeNames.map { ($0, 100, "public.jpeg") })
}

func fixedScanner(_ files: [(relativeName: String, byteSize: Int64)]) -> CatalogScanner {
    fixedScanner(files.map { ($0.relativeName, $0.byteSize, "public.jpeg") })
}

func fixedScanner(
    _ files: [(relativeName: String, byteSize: Int64, contentTypeIdentifier: String)]
) -> CatalogScanner {
    CatalogScanner { _, _, batchHandler in
        let scanned = files.map { file in
            ScannedMediaFile(
                relativePath: MediaRelativePath(rawValue: file.relativeName),
                name: file.relativeName,
                contentTypeIdentifier: file.contentTypeIdentifier,
                byteSize: file.byteSize,
                createdAt: nil,
                contentModifiedAt: Date(timeIntervalSince1970: 1000)
            )
        }
        try await batchHandler(scanned)
        return .mediaOnly(Set(files.map { MediaRelativePath(rawValue: $0.relativeName) }))
    }
}

private func deviceStagingSeed(
    rootPath: LibraryRootPath,
    relativePath: String,
    captureDate: TimeInterval,
    isVideo: Bool
) -> EnrichmentCoordinator.DeviceStagingSeed {
    EnrichmentCoordinator.DeviceStagingSeed(
        id: MediaAssetID(
            libraryRootPath: rootPath,
            relativePath: MediaRelativePath(rawValue: relativePath)
        ),
        sourceSize: 100,
        captureDate: Date(timeIntervalSince1970: captureDate),
        isVideo: isVideo
    )
}

private actor AttemptCounter {
    private(set) var total = 0

    func next() -> Int {
        defer { total += 1 }
        return total
    }
}

private actor HeldMaterializationExecutor {
    private var starts = 0

    func run(_ url: URL) async -> MaterializationResult {
        _ = url
        starts += 1
        await suspendUntilCancelled()
        return .cancelled
    }

    func waitForStarts(_ expected: Int) async throws {
        try await waitUntil { startedCount() >= expected }
    }

    func startedCount() -> Int {
        starts
    }
}

private actor BlockingEnrichment {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    nonisolated func enricher() -> MediaEnricher {
        MediaEnricher { _, _, _, _, _, _ in
            await self.waitUntilReleased()
            return .transient
        }
    }

    func waitForStarted() async {
        if started {
            return
        }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
            resumeStartWaiters()
        }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    private func waitUntilReleased() async {
        started = true
        resumeStartWaiters()
        if released {
            return
        }
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    private func resumeStartWaiters() {
        guard started else {
            return
        }
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private actor CountingBlockingEnrichment {
    private var startedPaths: [String] = []
    private var released = false
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    nonisolated func enricher() -> MediaEnricher {
        MediaEnricher { id, _, _, _, _, _ in
            await self.markStarted(id.relativePath.rawValue)
            await self.waitUntilReleased()
            return .transient
        }
    }

    func startedRelativePaths() -> [String] {
        startedPaths
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func markStarted(_ relativePath: String) {
        startedPaths.append(relativePath)
        resumeCountWaiters()
    }

    func waitForStartedCount(_ expected: Int) async {
        if startedPaths.count >= expected {
            return
        }
        await withCheckedContinuation { continuation in
            countWaiters.append((expected, continuation))
            resumeCountWaiters()
        }
    }

    private func waitUntilReleased() async {
        if released {
            return
        }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    private func resumeCountWaiters() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in countWaiters {
            if startedPaths.count >= waiter.0 {
                waiter.1.resume()
            } else {
                remaining.append(waiter)
            }
        }
        countWaiters = remaining
    }
}

private func visibleLifecycleCoordinator(
    store: CatalogStore
) -> EnrichmentCoordinator {
    EnrichmentCoordinator(
        store: store,
        enricher: visibleLifecycleEnricher(),
        materialize: { _ in .testMaterialized },
        readinessChecker: TestEnrichmentReadinessChecker(result: .materialized),
        enrichConcurrency: 2,
        claimBatchSize: 2
    )
}

private func visibleLifecycleEnricher() -> MediaEnricher {
    MediaEnricher { id, _, size, mtime, _, _ in
        .complete(
            EnrichmentResult(
                id: id,
                metadata: AssetMetadata(),
                thumbnailPath: "thumb-\(id.relativePath.rawValue)",
                sourceSize: size,
                sourceMTimeSeconds: mtime,
                contentHash: .empty
            )
        )
    }
}

private extension Result where Failure == EnrichmentAdmissionPolicy.Rejection {
    var isSuccess: Bool {
        if case .success = self {
            return true
        }
        return false
    }

    var rejection: EnrichmentAdmissionPolicy.Rejection? {
        if case let .failure(reason) = self {
            return reason
        }
        return nil
    }
}

/// Holds each enrichment until its path is released, so a test decides exactly which
/// slot frees when.
private actor PathGateEnrichment {
    private var startedPaths: [String] = []
    private var releasedPaths: Set<String> = []
    private var releasedAll = false
    private var pathWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    nonisolated func enricher() -> MediaEnricher {
        MediaEnricher { id, _, _, _, _, _ in
            await self.run(id.relativePath.rawValue)
            return .transient
        }
    }

    func startedRelativePaths() -> [String] {
        startedPaths
    }

    func release(_ path: String) {
        releasedPaths.insert(path)
        for waiter in pathWaiters.removeValue(forKey: path) ?? [] {
            waiter.resume()
        }
    }

    func releaseAll() {
        releasedAll = true
        let waiters = pathWaiters.values.flatMap(\.self)
        pathWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitForStartedCount(_ expected: Int) async {
        if startedPaths.count >= expected {
            return
        }
        await withCheckedContinuation { continuation in
            countWaiters.append((expected, continuation))
        }
    }

    private func run(_ path: String) async {
        startedPaths.append(path)
        let ready = countWaiters.filter { startedPaths.count >= $0.0 }
        countWaiters.removeAll { startedPaths.count >= $0.0 }
        for waiter in ready {
            waiter.1.resume()
        }
        guard !releasedAll, !releasedPaths.contains(path) else {
            return
        }
        await withCheckedContinuation { continuation in
            pathWaiters[path, default: []].append(continuation)
        }
    }
}
