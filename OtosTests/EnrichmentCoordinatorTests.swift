import Foundation
@testable import OtosKit
import Testing

struct EnrichmentCoordinatorTests {
    @Test func unchangedAdmissionRejectionsEmitOneTransitionAcrossOneHundredWakes() async {
        let coordinator = EnrichmentCoordinator(
            store: CatalogStore(location: .inMemory),
            enricher: MediaEnricher { _, _, _, _, _ in .transient }
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
        let temp = try makeCatalogStoreTemporaryDirectory()
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
            applyFlushInterval: .seconds(60),
            admissionPolicy: policy
        )
        await coordinator.start()
        try await blocker.waitForStartedCount(3)

        #expect(await coordinator.inFlightEnrichVideoCount == 2)
        let started = await blocker.startedRelativePaths()
        #expect(started.filter { $0.hasSuffix(".mov") }.count == 2)
        #expect(started.contains("still.jpg"))

        await blocker.release()
        await coordinator.shutdown()
    }

    @Test func eagerDeviceStagingDownloadsStillItemsBeforeVideos() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let rootPath = LibraryRootPath(
            rawValue: temp.appending(path: "DeviceStaging/Camera").path(percentEncoded: false)
        )
        let store = CatalogStore(location: .inMemory)
        let coordinator = EnrichmentCoordinator(
            store: store,
            enricher: MediaEnricher { _, _, _, _, _ in .transient },
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
        let temp = try makeCatalogStoreTemporaryDirectory()
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
            claimBatchSize: 3,
            applyFlushInterval: .seconds(60)
        )
        await coordinator.start()
        try await blocker.waitForStarted()

        await blocker.release()
        await coordinator.shutdown()
        let reclaimed = try await store.enrichmentCandidates(prioritizing: [], limit: 3)

        #expect(Set(reclaimed.map(\.asset.relativePath.rawValue)) == Set(relativeNames))
        try await store.releaseEnrichmentClaims(reclaimed.map(\.asset.id))
    }

    @Test func visibleThumbnailLifecycleEnrichesViewportPriorityAssets() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
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
        let temp = try makeCatalogStoreTemporaryDirectory()
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
        let enricher = MediaEnricher { id, url, size, mtime, _ in
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
            readinessChecker: TestEnrichmentReadinessChecker(result: .materialized),
            applyFlushInterval: .milliseconds(1)
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
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Pics", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let store = CatalogStore(location: .inMemory, scanner: fixedScanner(["a.jpg"]))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 1 }

        // Fail transiently the first two attempts, then succeed.
        let attempts = AttemptCounter()
        let enricher = MediaEnricher { id, _, size, mtime, _ in
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
            readinessChecker: TestEnrichmentReadinessChecker(result: .materialized),
            applyFlushInterval: .milliseconds(1)
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
        let temp = try makeCatalogStoreTemporaryDirectory()
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
        let enricher = MediaEnricher { id, _, size, mtime, _ in
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
            readinessChecker: TestEnrichmentReadinessChecker(result: .materialized),
            applyFlushInterval: .milliseconds(1)
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
        let root = try makeCatalogStoreTemporaryDirectory().appending(path: "Pics", directoryHint: .isDirectory)
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
        let enricher = MediaEnricher { id, _, size, mtime, _ in
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
            readinessChecker: TestEnrichmentReadinessChecker(result: .materialized),
            applyFlushInterval: .milliseconds(1)
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
        let temp = try makeCatalogStoreTemporaryDirectory()
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
            executor: { await executor.run($0) }
        )
        let coordinator = EnrichmentCoordinator(
            store: store,
            enricher: MediaEnricher { _, _, _, _, _ in .notMaterialized },
            materializationRequester: materializer,
            readinessChecker: TestEnrichmentReadinessChecker(result: .dataless),
            claimBatchSize: 32,
            applyFlushInterval: .seconds(60)
        )
        await materializer.start()
        await coordinator.start()
        try await executor.waitForStarts(1)

        try await withTestTimeout("two materializations in flight") {
            while await coordinator.workStateSnapshot().materializing < 2 {
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        let state = await coordinator.workStateSnapshot()
        #expect(state.claimed <= 32)
        #expect(state.materializing == 2)
        #expect(await materializer.stateSnapshot().inFlight == 1)

        try await withTestTimeout("coordinator shutdown") {
            await coordinator.shutdown()
        }
        #expect(await materializer.stateSnapshot().waiters == 0)
        await materializer.shutdown()
    }

    // MARK: - Plan 0059 review fixes

    @Test func exhaustedBackgroundRetriesReleaseClaimWindowForFreshCandidate() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Pics", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = CatalogStore(location: .inMemory, scanner: fixedScanner(["fresh.jpg"]))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        let scanned = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 1 }
        let freshID = try #require(scanned.testAssets.first?.id)

        let coordinator = EnrichmentCoordinator(
            store: store,
            enricher: MediaEnricher { _, _, _, _, _ in .transient },
            materialize: { _ in .testMaterialized },
            readinessChecker: TestEnrichmentReadinessChecker(result: .materialized),
            claimBatchSize: 8,
            claimWindowLimit: 32
        )

        // Fill the claim window with 32 synthetic permanently-failing background
        // records already at the in-window retry bound. They hold no real Store row,
        // isolating the window-capacity behavior from Store bookkeeping.
        let badRoot = LibraryRootPath(rawValue: temp.appending(path: "Bad").path(percentEncoded: false))
        var badIDs: [MediaAssetID] = []
        for index in 0 ..< 32 {
            let badID = MediaAssetID(
                libraryRootPath: badRoot,
                relativePath: MediaRelativePath(rawValue: "bad-\(index).jpg")
            )
            let work = EnrichmentCoordinator.DownloadWork(
                id: badID, url: badID.fileURL, sourceSize: 100, captureDate: nil,
                isVideo: false, isDeviceStaging: false, attemptCount: 4, retryNotBefore: nil
            )
            await coordinator.testSeedMaterialization(work)
            badIDs.append(badID)
        }
        #expect(await coordinator.workStateSnapshot().materializationPending == 32)

        // Materialization demands do not consume ready-enrichment capacity, so a
        // fresh materialized candidate can still enter the enrichment pool.
        let admittedWork = await coordinator.dequeueEnrichmentWork()
        #expect(admittedWork.map(\.id) == [freshID])

        // Each of the 32 exceeds its retry bound on this failure: the fix releases
        // the claim-window slot and hands pacing to the ledger instead of holding it.
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
        for badID in badIDs {
            #expect(await coordinator.testRetryLedgerEntry(for: badID) != nil)
        }

        // The ready candidate remains in the independent ready pool; the exhausted
        // materialization demands no longer occupy a ready-enrichment slot.
        #expect(await coordinator.workStateSnapshot().readyQueued == 0)
        #expect(await coordinator.workStateSnapshot().enriching == 1)
    }

    @Test func retryLedgerDefersMatchingSignatureAndResetsOnChange() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Pics", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = CatalogStore(location: .inMemory, scanner: fixedScanner([("a.jpg", 100)]))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        let scanned = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 1 }
        let id = try #require(scanned.testAssets.first?.id)

        let coordinator = EnrichmentCoordinator(
            store: store,
            enricher: MediaEnricher { _, _, _, _, _ in .transient },
            materialize: { _ in .testMaterialized },
            readinessChecker: TestEnrichmentReadinessChecker(result: .materialized)
        )

        // Matching source signature, notBefore in the future: must defer rather than
        // re-claim and immediately re-fail.
        await coordinator.testSeedRetryLedger(
            id: id,
            entry: EnrichmentCoordinator.RetryLedgerEntry(
                notBefore: Date().addingTimeInterval(900), attemptCount: 1, sourceSize: 100
            )
        )
        let deferred = await coordinator.dequeueEnrichmentWork()
        #expect(deferred.isEmpty)
        #expect(await coordinator.workStateSnapshot().claimed == 0)

        // A changed source signature resets pacing immediately even though
        // notBefore has not arrived.
        await coordinator.testSeedRetryLedger(
            id: id,
            entry: EnrichmentCoordinator.RetryLedgerEntry(
                notBefore: Date().addingTimeInterval(900), attemptCount: 1, sourceSize: 999
            )
        )
        let claimed = await coordinator.dequeueEnrichmentWork()
        #expect(claimed.map(\.id) == [id])
        #expect(await coordinator.testRetryLedgerEntry(for: id) == nil)
    }

    @Test func retryLedgerSkipsPastBlockedCandidatesWithinBoundedPasses() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
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

        // A small claim batch (2) against 4 blocked candidates forces multiple
        // claim/defer passes before "fresh" is ever reached.
        let coordinator = EnrichmentCoordinator(
            store: store,
            enricher: MediaEnricher { _, _, _, _, _ in .transient },
            materialize: { _ in .testMaterialized },
            readinessChecker: TestEnrichmentReadinessChecker(result: .materialized),
            enrichConcurrency: 2,
            claimBatchSize: 2
        )
        for asset in scanned.testAssets where asset.relativePath.rawValue != "fresh.jpg" {
            await coordinator.testSeedRetryLedger(
                id: asset.id,
                entry: EnrichmentCoordinator.RetryLedgerEntry(
                    notBefore: Date().addingTimeInterval(900), attemptCount: 1, sourceSize: asset.byteSize
                )
            )
        }

        let claimed = await coordinator.dequeueEnrichmentWork()
        #expect(claimed.map(\.id) == [freshID])
    }

    @Test func materializationSuccessClearsRetryLedgerEntry() async {
        let id = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/library"),
            relativePath: MediaRelativePath(rawValue: "a.jpg")
        )
        let coordinator = EnrichmentCoordinator(
            store: CatalogStore(location: .inMemory),
            enricher: MediaEnricher { _, _, _, _, _ in .transient },
            materialize: { _ in .testMaterialized },
            readinessChecker: TestEnrichmentReadinessChecker(result: .materialized)
        )
        await coordinator.testSeedRetryLedger(
            id: id,
            entry: EnrichmentCoordinator.RetryLedgerEntry(
                notBefore: Date().addingTimeInterval(900), attemptCount: 3, sourceSize: 100
            )
        )
        let work = EnrichmentCoordinator.DownloadWork(
            id: id, url: id.fileURL, sourceSize: 100, captureDate: nil, isVideo: false, isDeviceStaging: false
        )
        await coordinator.testSeedMaterialization(work)
        await coordinator.finishDownload(work, result: .testMaterialized, attemptMs: 1)
        #expect(await coordinator.testRetryLedgerEntry(for: id) == nil)
    }

    @Test func cancelledMaterializationReleasesClaimWithoutRetry() async {
        let id = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/library"),
            relativePath: MediaRelativePath(rawValue: "a.jpg")
        )
        let coordinator = EnrichmentCoordinator(
            store: CatalogStore(location: .inMemory),
            enricher: MediaEnricher { _, _, _, _, _ in .transient },
            materialize: { _ in .testMaterialized },
            readinessChecker: TestEnrichmentReadinessChecker(result: .materialized)
        )
        let work = EnrichmentCoordinator.DownloadWork(
            id: id, url: id.fileURL, sourceSize: 100, captureDate: nil, isVideo: false, isDeviceStaging: false
        )
        await coordinator.testSeedMaterialization(work)
        await coordinator.finishDownload(
            work,
            result: MaterializationResult(outcome: .cancelled, rerequestCount: 0, elapsedMs: 1),
            attemptMs: 1
        )
        #expect(await coordinator.workStateSnapshot().materializationPending == 0)
        #expect(await coordinator.testRetryLedgerEntry(for: id) == nil)
    }

    @Test func stageDeviceSkipsSeedAlreadyMaterializing() async throws {
        let coordinator = EnrichmentCoordinator(
            store: CatalogStore(location: .inMemory),
            enricher: MediaEnricher { _, _, _, _, _ in .transient },
            materialize: { _ in .testMaterialized },
            readinessChecker: TestEnrichmentReadinessChecker(result: .materialized)
        )
        let rootPath = LibraryRootPath(rawValue: "/DeviceStaging/Camera")
        let id = MediaAssetID(libraryRootPath: rootPath, relativePath: MediaRelativePath(rawValue: "video.mov"))
        let activeWork = EnrichmentCoordinator.DownloadWork(
            id: id, url: id.fileURL, sourceSize: 100, captureDate: Date(timeIntervalSince1970: 50),
            isVideo: true, isDeviceStaging: true
        )
        await coordinator.testSeedMaterialization(activeWork, inFlight: true)

        let seeds = [
            EnrichmentCoordinator.DeviceStagingSeed(
                id: id, sourceSize: 100, captureDate: Date(timeIntervalSince1970: 50), isVideo: true
            ),
        ]
        await coordinator.stageDevice(seeds)

        let record = try #require(await coordinator.testMaterializationWork(for: id))
        #expect(record.id == id)
        #expect(await coordinator.workStateSnapshot().materializationInFlight == 1)
    }

    @Test func ejectDrainIgnoresPureInteractivePreviewTraffic() async throws {
        let store = CatalogStore(location: .inMemory)
        let executor = HeldMaterializationExecutor()
        let materializer = MaterializationCoordinator(store: store, executor: { await executor.run($0) })
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
            enricher: MediaEnricher { _, _, _, _, _ in .transient },
            materializationRequester: materializer,
            readinessChecker: TestEnrichmentReadinessChecker(result: .dataless)
        )

        let drained = await coordinator.drainWork(under: rootPath, timeout: .milliseconds(300))
        #expect(drained)
        // Load-independent check: drain returned while the interactive request is still held.
        // If drain had incorrectly waited on interactive traffic, it would have timed out
        // and returned false, or the materializer would have no in-flight work.
        #expect(await executor.startedCount() == 1)
        #expect(await materializer.stateSnapshot().inFlight == 1)

        previewTask.cancel()
        _ = await previewTask.value
        await materializer.shutdown()
    }

    /// Plan 0065 Stage 2b: `EnrichWork.shouldHash` must be the value Store's claim
    /// predicate decided (`ClaimedEnrichmentCandidate.hashRequired`), not a value the
    /// coordinator re-derives from its own notion of root kind. Before this fix, the
    /// coordinator refreshed a `removableRootPaths` cache once per dequeue cycle and
    /// re-derived `shouldHash` from it at dispatch time — two independent owners of the
    /// same fact that could disagree if a root's kind changed between them. That cache
    /// no longer exists: this test claims one asset from a `.library` root (hash
    /// required) and one from a `.removableVolume` root (hash not required) in the same
    /// coordinator, and confirms each dispatched `EnrichWork.shouldHash` matches its own
    /// claim rather than a single shared coordinator-wide value.
    @Test func dispatchedWorkCarriesClaimTimeHashRequiredPerRoot() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
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
            identity: "volume:hash-required-claim",
            displayName: "Card",
            isEjectable: false
        )
        _ = try await waitForCatalogStoreState(store) { snapshot in
            !snapshot.isScanning
                && snapshot.removableSources.first?.path.rawValue == removableRawPath
                && snapshot.removableSources.first?.availability == .available
        }

        let recorder = ShouldHashRecorder()
        let enricher = MediaEnricher { id, url, size, mtime, shouldHash in
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
            readinessChecker: TestEnrichmentReadinessChecker(result: .materialized),
            applyFlushInterval: .milliseconds(1)
        )
        await coordinator.start()

        // Not `needsEnrichment(hashRequired: true)`: the removable asset never gets a
        // hash by design (ADR 0018), so that check would never clear for it. Wait on
        // the enricher-recorded outcome instead.
        try await withTestTimeout("both roots dispatched to the enricher") {
            _ = await recorder.waitForBoth()
        }
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

    func waitForBoth() async {
        while valuesByName["fixed.jpg"] == nil || valuesByName["card.jpg"] == nil {
            try? await Task.sleep(for: .milliseconds(20))
        }
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
        do {
            try await Task.sleep(for: .seconds(60))
            return .testMaterialized
        } catch {
            return .cancelled
        }
    }

    func waitForStarts(_ expected: Int) async throws {
        try await withTestTimeout("held materialization starts") {
            while await self.startedCount() < expected {
                await Task.yield()
            }
        }
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
        MediaEnricher { _, _, _, _, _ in
            await self.waitUntilReleased()
            return .transient
        }
    }

    func waitForStarted() async throws {
        try await withTestTimeout("blocking enrichment started") {
            await self.waitForStartedUnbounded()
        }
    }

    private func waitForStartedUnbounded() async {
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
        MediaEnricher { id, _, _, _, _ in
            await self.markStarted(id.relativePath.rawValue)
            await self.waitUntilReleased()
            return .transient
        }
    }

    func waitForStartedCount(_ expected: Int) async throws {
        try await withTestTimeout("counting blocking enrichment started") {
            await self.waitForStartedCountUnbounded(expected)
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

    private func waitForStartedCountUnbounded(_ expected: Int) async {
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
        claimBatchSize: 2,
        applyFlushInterval: .milliseconds(1)
    )
}

private func visibleLifecycleEnricher() -> MediaEnricher {
    MediaEnricher { id, _, size, mtime, _ in
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
