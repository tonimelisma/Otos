import Foundation
@testable import OtosKit
import Testing

struct DownloadLifecycleContext {
    let store: CatalogStore
    let coordinator: EnrichmentCoordinator
    let id: MediaAssetID
}

func makeDownloadLifecycleContext() async throws -> DownloadLifecycleContext {
    let temp = try makeTestDirectory()
    let root = temp.appending(path: "Pics", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)
    let store = CatalogStore(location: .inMemory, scanner: fixedScanner(["a.jpg"]))
    try await store.start(scansSavedLibraries: false)
    try await store.addLibrary(url: root)
    let scanned = try await waitForCatalogStoreState(store) {
        !$0.isScanning && $0.testAssets.count == 1
    }
    let id = try #require(scanned.testAssets.first?.id)
    let datalessPath = rootPath.url.appending(path: "a.jpg", directoryHint: .notDirectory)
        .path(percentEncoded: false)
    let state = FakeMaterialization(dataless: [datalessPath])
    let coordinator = EnrichmentCoordinator(
        store: store,
        enricher: datalessLifecycleEnricher(state: state),
        materialize: datalessLifecycleMaterializer(state: state),
        readinessChecker: TestEnrichmentReadinessChecker(result: .materialized)
    )
    return DownloadLifecycleContext(store: store, coordinator: coordinator, id: id)
}

private func datalessLifecycleEnricher(state: FakeMaterialization) -> MediaEnricher {
    MediaEnricher { id, access, size, mtime, _ in
        let url = access.localURL ?? id.fileURL
        if await state.isDataless(url.path(percentEncoded: false)) {
            return .notMaterialized
        }
        return .complete(
            EnrichmentResult(
                id: id,
                metadata: AssetMetadata(cameraModel: "Cam"),
                thumbnailPath: "t.jpg",
                sourceSize: size,
                sourceMTimeSeconds: mtime,
                contentHash: .empty
            )
        )
    }
}

private func datalessLifecycleMaterializer(
    state: FakeMaterialization
) -> @Sendable (URL) async -> MaterializationResult {
    { url in
        await state.materialize(url.path(percentEncoded: false))
        return MaterializationResult(outcome: .materialized, rerequestCount: 2, elapsedMs: 123)
    }
}

actor FakeMaterialization {
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
