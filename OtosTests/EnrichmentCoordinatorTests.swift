import Foundation
@testable import Otos
import Testing

struct EnrichmentCoordinatorTests {
    @Test func downloadSchedulingReservesFinalSlotForViewportWork() {
        #expect(!EnrichmentDownloadSchedulingPolicy.canDispatchDownload(
            isViewportWork: false,
            inFlightDownloadCount: 0,
            downloadConcurrency: 1
        ))
        #expect(EnrichmentDownloadSchedulingPolicy.canDispatchDownload(
            isViewportWork: true,
            inFlightDownloadCount: 0,
            downloadConcurrency: 1
        ))
        #expect(EnrichmentDownloadSchedulingPolicy.canDispatchDownload(
            isViewportWork: false,
            inFlightDownloadCount: 2,
            downloadConcurrency: 4
        ))
        #expect(!EnrichmentDownloadSchedulingPolicy.canDispatchDownload(
            isViewportWork: false,
            inFlightDownloadCount: 3,
            downloadConcurrency: 4
        ))
        #expect(EnrichmentDownloadSchedulingPolicy.canDispatchDownload(
            isViewportWork: true,
            inFlightDownloadCount: 3,
            downloadConcurrency: 4
        ))
    }

    @Test func admissionBlocksMultiLargeVideoFloodAndAllowsOversizedSolo() {
        let policy = EnrichmentAdmissionPolicy.production
        let root = LibraryRootPath(rawValue: "/library")
        let largeVideo = EnrichmentAdmissionPolicy.Candidate(
            sourceSize: 2 * 1024 * 1024 * 1024,
            isVideo: true,
            isViewportOrDevice: false,
            rootPath: root,
            isEagerBackground: true
        )
        var inFlight = EnrichmentAdmissionPolicy.InFlightSnapshot.empty
        #expect(policy.canDispatchDownload(candidate: largeVideo, inFlight: inFlight).isSuccess)
        inFlight.downloadCount = 2
        inFlight.downloadBytes = 4 * 1024 * 1024 * 1024
        inFlight.largeVideoDownloadCount = 2
        #expect(policy.canDispatchDownload(candidate: largeVideo, inFlight: inFlight).rejection == .largeVideoDownloadCap)

        let solo = EnrichmentAdmissionPolicy.InFlightSnapshot.empty
        let huge = EnrichmentAdmissionPolicy.Candidate(
            sourceSize: 7 * 1024 * 1024 * 1024,
            isVideo: true,
            isViewportOrDevice: false,
            rootPath: root,
            isEagerBackground: true
        )
        #expect(policy.canDispatchDownload(candidate: huge, inFlight: solo).isSuccess)

        let unknown = EnrichmentAdmissionPolicy.Candidate(
            sourceSize: nil,
            isVideo: false,
            isViewportOrDevice: false,
            rootPath: root,
            isEagerBackground: true
        )
        inFlight = .empty
        inFlight.downloadCount = 14
        inFlight.downloadBytes = 100
        #expect(policy.canDispatchDownload(candidate: unknown, inFlight: inFlight).isSuccess)
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
            enricher: MediaEnricher { _, _, _, _ in .transient },
            materialize: { _ in .testMaterialized },
            downloadConcurrency: 4
        )
        let seeds = [
            deviceStagingSeed(rootPath: rootPath, relativePath: "video.mov", captureDate: 50, isVideo: true),
            deviceStagingSeed(rootPath: rootPath, relativePath: "still-b.jpg", captureDate: 200, isVideo: false),
            deviceStagingSeed(rootPath: rootPath, relativePath: "still-a.jpg", captureDate: 100, isVideo: false),
        ]

        await coordinator.stageDevice(seeds)
        let work = await coordinator.dequeueDownloadWork()

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
            enrichConcurrency: 1,
            downloadConcurrency: 1,
            claimBatchSize: 3,
            applyFlushInterval: .seconds(60)
        )
        await coordinator.start()
        try await blocker.waitForStarted()

        await coordinator.shutdown()
        let reclaimed = try await store.enrichmentCandidates(prioritizing: [], limit: 3)
        await blocker.release()

        #expect(Set(reclaimed.map(\.relativePath.rawValue)) == Set(relativeNames))
        try await store.releaseEnrichmentClaims(reclaimed.map(\.id))
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
            snapshot.testAssets.count == 2 && snapshot.testAssets.allSatisfy { !$0.needsEnrichment }
        }
        await coordinator.shutdown()

        let visible = try #require(enriched.testAssets.first { $0.relativePath.rawValue == "a.jpg" })
        #expect(visible.thumbnailPath?.hasPrefix("thumb-") == true)
        #expect(enriched.testAssets.allSatisfy { !$0.needsEnrichment })
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
        let enricher = MediaEnricher { id, url, size, mtime in
            if await state.isDataless(url.path(percentEncoded: false)) {
                return .notMaterialized
            }
            return .complete(
                EnrichmentResult(
                    id: id,
                    metadata: AssetMetadata(cameraModel: "Cam"),
                    timestampFacts: EnrichmentTimestampFacts(original: captureDate),
                    thumbnailPath: "t.jpg",
                    sourceSize: size,
                    sourceMTimeSeconds: mtime
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
            applyFlushInterval: .milliseconds(1)
        )
        await coordinator.start()

        let enriched = try await waitForCatalogStoreState(store) { snapshot in
            snapshot.testAssets.count == 3 && snapshot.testAssets.allSatisfy { !$0.needsEnrichment }
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
            snapshot.testAssets.first?.needsEnrichment == false
        }
        await context.coordinator.shutdown()

        let asset = try #require(enriched.testAssets.first)
        #expect(asset.thumbnailPath == "t.jpg")
        #expect(asset.needsEnrichment == false)
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
        let enricher = MediaEnricher { id, _, size, mtime in
            if await attempts.next() < 2 {
                return .transient
            }
            return .complete(
                EnrichmentResult(
                    id: id,
                    metadata: AssetMetadata(),
                    thumbnailPath: "t.jpg",
                    sourceSize: size,
                    sourceMTimeSeconds: mtime
                )
            )
        }
        let coordinator = EnrichmentCoordinator(
            store: store,
            enricher: enricher,
            materialize: { _ in .testMaterialized },
            applyFlushInterval: .milliseconds(1)
        )
        await coordinator.start()

        let enriched = try await waitForCatalogStoreState(store) { snapshot in
            snapshot.testAssets.first?.needsEnrichment == false
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
        let enricher = MediaEnricher { id, _, size, mtime in
            let attempt = await attempts.next()
            let reportedSize: Int64 = attempt == 0 ? (size ?? 0) + 1000 : (size ?? -1)
            return .complete(
                EnrichmentResult(
                    id: id,
                    metadata: AssetMetadata(),
                    thumbnailPath: "t.jpg",
                    sourceSize: reportedSize,
                    sourceMTimeSeconds: mtime
                )
            )
        }
        let coordinator = EnrichmentCoordinator(
            store: store,
            enricher: enricher,
            materialize: { _ in .testMaterialized },
            applyFlushInterval: .milliseconds(1)
        )
        await coordinator.start()

        let enriched = try await waitForCatalogStoreState(store) { snapshot in
            snapshot.testAssets.first?.needsEnrichment == false
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
        let enricher = MediaEnricher { id, _, size, mtime in
            _ = await enrichCalls.next()
            #expect(id.relativePath.rawValue == "ok.jpg")
            return .complete(EnrichmentResult(
                id: id, metadata: AssetMetadata(), thumbnailPath: "t.jpg",
                sourceSize: size, sourceMTimeSeconds: mtime
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
            applyFlushInterval: .milliseconds(1)
        )
        await coordinator.start()
        let enriched = try await waitForCatalogStoreState(store) {
            $0.testAssets.count == 2 && $0.testAssets.allSatisfy { !$0.needsEnrichment }
        }
        await coordinator.shutdown()

        let empty = try #require(enriched.testAssets.first { $0.relativePath.rawValue == "empty.jpg" })
        let ok = try #require(enriched.testAssets.first { $0.relativePath.rawValue == "ok.jpg" })
        #expect(empty.byteSize == 0)
        #expect(empty.thumbnailPath == nil)
        #expect(empty.enrichedSourceSize == 0)
        #expect(empty.enrichedSourceMTimeSeconds == 1000)
        #expect(!empty.needsEnrichment)
        #expect(ok.thumbnailPath == "t.jpg")
        #expect(!ok.needsEnrichment)
        #expect(await enrichCalls.total == 1)
        #expect(await materializeCalls.total == 0)
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

private actor BlockingEnrichment {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    nonisolated func enricher() -> MediaEnricher {
        MediaEnricher { _, _, _, _ in
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
        MediaEnricher { id, _, _, _ in
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
        enrichConcurrency: 2,
        downloadConcurrency: 1,
        claimBatchSize: 2,
        applyFlushInterval: .milliseconds(1)
    )
}

private func visibleLifecycleEnricher() -> MediaEnricher {
    MediaEnricher { id, _, size, mtime in
        .complete(
            EnrichmentResult(
                id: id,
                metadata: AssetMetadata(),
                thumbnailPath: "thumb-\(id.relativePath.rawValue)",
                sourceSize: size,
                sourceMTimeSeconds: mtime
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
