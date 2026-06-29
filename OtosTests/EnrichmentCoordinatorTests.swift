import Foundation
@testable import Otos
import Testing

struct EnrichmentCoordinatorTests {
    @Test func enrichesMaterializedAndDownloadsThenEnrichesDataless() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Pics", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)
        let relativeNames = ["a.jpg", "b.jpg", "c.jpg"]

        let store = CatalogStore(
            location: .inMemory,
            scanner: fixedScanner(relativeNames),
            diagnostics: nil
        )
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreSnapshot(store) { !$0.isScanning && $0.testAssets.count == 3 }

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
                    captureDate: captureDate,
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
                return true
            },
            applyBatchSize: 1,
            diagnostics: nil
        )
        await coordinator.start()

        let enriched = try await waitForCatalogStoreSnapshot(store) { snapshot in
            snapshot.testAssets.count == 3 && snapshot.testAssets.allSatisfy { !$0.needsEnrichment }
        }
        await coordinator.shutdown()

        #expect(enriched.testAssets.allSatisfy { $0.thumbnailPath == "t.jpg" })
        #expect(enriched.testAssets.allSatisfy { $0.captureDate == captureDate })
        #expect(enriched.testAssets.allSatisfy { $0.bestCaptureDate == captureDate })
    }

    @Test func transientOutcomeIsRetriedUntilComplete() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Pics", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let store = CatalogStore(location: .inMemory, scanner: fixedScanner(["a.jpg"]), diagnostics: nil)
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreSnapshot(store) { !$0.isScanning && $0.testAssets.count == 1 }

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
                    captureDate: nil,
                    thumbnailPath: "t.jpg",
                    sourceSize: size,
                    sourceMTimeSeconds: mtime
                )
            )
        }
        let coordinator = EnrichmentCoordinator(
            store: store,
            enricher: enricher,
            materialize: { _ in true },
            applyBatchSize: 1,
            diagnostics: nil
        )
        await coordinator.start()

        let enriched = try await waitForCatalogStoreSnapshot(store) { snapshot in
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

        let store = CatalogStore(location: .inMemory, scanner: fixedScanner(["a.jpg"]), diagnostics: nil)
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreSnapshot(store) { !$0.isScanning && $0.testAssets.count == 1 }

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
                    captureDate: nil,
                    thumbnailPath: "t.jpg",
                    sourceSize: reportedSize,
                    sourceMTimeSeconds: mtime
                )
            )
        }
        let coordinator = EnrichmentCoordinator(
            store: store,
            enricher: enricher,
            materialize: { _ in true },
            applyBatchSize: 1,
            diagnostics: nil
        )
        await coordinator.start()

        let enriched = try await waitForCatalogStoreSnapshot(store) { snapshot in
            snapshot.testAssets.first?.needsEnrichment == false
        }
        await coordinator.shutdown()
        #expect(enriched.testAssets.first?.thumbnailPath == "t.jpg")
        #expect(await attempts.total >= 2)
    }
}

// MARK: - Helpers

private func fixedScanner(_ relativeNames: [String]) -> CatalogScanner {
    CatalogScanner { _, _, _, batchHandler in
        let files = relativeNames.map { name in
            ScannedMediaFile(
                relativePath: MediaRelativePath(rawValue: name),
                name: name,
                contentTypeIdentifier: "public.jpeg",
                byteSize: 100,
                createdAt: nil,
                contentModifiedAt: Date(timeIntervalSince1970: 1000)
            )
        }
        try await batchHandler(files)
        return Set(relativeNames.map { MediaRelativePath(rawValue: $0) })
    }
}

private actor FakeMaterialization {
    private var dataless: Set<String>

    init(dataless: Set<String>) {
        self.dataless = dataless
    }

    func isDataless(_ path: String) -> Bool {
        dataless.contains(path)
    }

    func materialize(_ path: String) {
        dataless.remove(path)
    }
}

private actor AttemptCounter {
    private(set) var total = 0

    func next() -> Int {
        defer { total += 1 }
        return total
    }
}
