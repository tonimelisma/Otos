import Foundation
@testable import Otos
import Testing

struct DownloadLifecycleContext {
    let outputURL: URL
    let store: CatalogStore
    let coordinator: EnrichmentCoordinator
    let id: MediaAssetID
}

func makeDownloadLifecycleContext() async throws -> DownloadLifecycleContext {
    let temp = try makeCatalogStoreTemporaryDirectory()
    let outputURL = temp.appending(path: "download-lifecycle.jsonl")
    let diagnostics = CatalogDiagnostics(outputURL: outputURL, isEnabled: true)
    let root = temp.appending(path: "Pics", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)
    let store = CatalogStore(location: .inMemory, scanner: fixedScanner(["a.jpg"]), diagnostics: nil)
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
        applyFlushInterval: .milliseconds(1),
        diagnostics: diagnostics
    )
    return DownloadLifecycleContext(outputURL: outputURL, store: store, coordinator: coordinator, id: id)
}

private func datalessLifecycleEnricher(state: FakeMaterialization) -> MediaEnricher {
    MediaEnricher { id, url, size, mtime in
        if await state.isDataless(url.path(percentEncoded: false)) {
            return .notMaterialized
        }
        return .complete(
            EnrichmentResult(
                id: id,
                metadata: AssetMetadata(cameraModel: "Cam"),
                thumbnailPath: "t.jpg",
                sourceSize: size,
                sourceMTimeSeconds: mtime
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

func assertDownloadLifecycleDiagnostics(at outputURL: URL) throws {
    let lifecycleEvents = try diagnosticEvents(at: outputURL).filter {
        $0.operation == "catalog.thumbnails.visibleLifecycle"
            && $0.fields["relativePath"] == "a.jpg"
    }
    let phases = lifecycleEvents.map(\.phase)
    let notMaterialized = try #require(lifecycleEvents.first { $0.phase == "notMaterialized" })
    let materialized = try #require(lifecycleEvents.first { $0.phase == "materialized" })
    let materializedIndex = try #require(phases.firstIndex(of: "materialized"))
    let laterClaimIndex = try #require(phases[(materializedIndex + 1)...].firstIndex(of: "claimed"))

    #expect(notMaterialized.fields["leaseRefreshedUntil"] != nil)
    #expect(materialized.fields["outcome"] == "materialized")
    #expect(materialized.fields["rerequestCount"] == "2")
    #expect(materialized.fields["requestToCompleteMs"] == "123")
    #expect(materialized.fields["sourceSize"] == "100")
    #expect(laterClaimIndex > materializedIndex)
    #expect(phases.contains("generated"))
    #expect(phases.contains("batchAccepted"))
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

func diagnosticEvents(at url: URL) throws -> [CatalogDiagnosticEvent] {
    let data = try Data(contentsOf: url)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return data.split(separator: 0x0A).compactMap { line in
        try? decoder.decode(CatalogDiagnosticEvent.self, from: Data(line))
    }
}
