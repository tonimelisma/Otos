import Foundation
@testable import OtosKit
import Testing

@Suite(.testScope)
struct CatalogProjectionOrderingTests {
    @Test func detailOnlyStoreChangePublishesRefreshAndChecksOrder() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "jpeg".write(to: root.appending(path: "one.jpg"), atomically: true, encoding: .utf8)

        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10))
        let projection = CatalogProjection(cadence: .milliseconds(10))
        let recorder = OrderingStateRecorder()
        let stream = await projection.states(store: store, initialDescriptor: .default)
        let recordingTask = Task {
            for await state in stream {
                await recorder.append(state)
            }
        }
        defer { recordingTask.cancel() }

        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)
        let id = MediaAssetID(libraryRootPath: rootPath, relativePath: MediaRelativePath(rawValue: "one.jpg"))
        _ = try await waitForCatalogStoreState(store) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.map(\.id) == [id]
        }
        let initialStates = await recorder.waitForState { states in
            states.last { state in
                state.mediaGrid.orderedAssetIDs == [id]
                    && state.libraries.allSatisfy { $0.activity == .idle }
            }
        }
        let initialState = try #require(initialStates.last { state in
            state.mediaGrid.orderedAssetIDs == [id]
                && state.libraries.allSatisfy { $0.activity == .idle }
        })

        let asset = try #require(try await store.mediaAssets(for: [id])[id])
        let sourceMTime = try #require(asset.contentModifiedAt.map { Int($0.timeIntervalSince1970) })
        let enrichment = EnrichmentResult(
            id: id,
            metadata: AssetMetadata(
                timestamps: [.absolute(instant: Date(timeIntervalSince1970: 700))],
                cameraModel: "Cam"
            ),
            thumbnailPath: "thumb.jpg",
            sourceSize: asset.byteSize,
            sourceMTimeSeconds: sourceMTime,
            contentHash: .empty
        )
        _ = await store.applyEnrichmentBatch([enrichment])
        let detailState = await recorder.waitForState { states in
            states.last { state in
                state.mediaGrid.orderedAssetIDs == [id]
                    && state.mediaGrid.detailRefreshGeneration > initialState.mediaGrid.detailRefreshGeneration
            }
        }
        let detailGeneration = try #require(detailState.last?.mediaGrid.detailRefreshGeneration)
        #expect(detailGeneration > initialState.mediaGrid.detailRefreshGeneration)
    }
}

private typealias OrderingStateRecorder = AsyncValueRecorder<CatalogWindowState>

private extension AsyncValueRecorder where Value == CatalogWindowState {
    func waitForState(
        matching predicate: @escaping @Sendable ([CatalogWindowState]) -> CatalogWindowState?
    ) async -> [CatalogWindowState] {
        await waitForValues { states in
            predicate(states) != nil
        }
    }
}
