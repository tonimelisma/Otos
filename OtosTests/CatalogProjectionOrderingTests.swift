import Foundation
@testable import Otos
import Testing

struct CatalogProjectionOrderingTests {
    @Test func detailChangeKeepsOrder() async {
        let root = orderingRoot()
        let projection = CatalogProjection(diagnostics: nil)
        let original = orderingAsset(root: root, relativePath: "one.jpg")
        let changed = MediaAsset(
            libraryRootPath: original.libraryRootPath,
            relativePath: original.relativePath,
            name: "renamed-detail.jpg",
            contentTypeIdentifier: original.contentTypeIdentifier,
            byteSize: 99,
            createdAt: original.createdAt,
            contentModifiedAt: original.contentModifiedAt
        )

        _ = await projection.windowState(
            fixture: orderingFixture(root: root, assets: [original]),
            sidebarSelection: .allMedia
        )
        let updated = await projection.windowState(
            fixture: orderingFixture(root: root, assets: [changed]),
            sidebarSelection: .allMedia
        )

        #expect(updated.mediaGrid.orderedAssetIDs == [original.id])
    }

    @Test func sameCountIdentityReplacementRebuildsOrder() async {
        let root = orderingRoot()
        let projection = CatalogProjection(diagnostics: nil)
        let first = orderingAsset(root: root, relativePath: "z.jpg")
        let replacement = orderingAsset(root: root, relativePath: "a.jpg")

        _ = await projection.windowState(
            fixture: orderingFixture(root: root, assets: [first]),
            sidebarSelection: .allMedia
        )
        let recovered = await projection.windowState(
            fixture: orderingFixture(root: root, assets: [replacement]),
            sidebarSelection: .allMedia
        )

        #expect(recovered.mediaGrid.orderedAssetIDs == [replacement.id])
    }

    @Test func changedMembershipResortsAfterInsertionAndDeletion() async {
        let root = orderingRoot()
        let projection = CatalogProjection(diagnostics: nil)
        let first = await projection.windowState(
            fixture: orderingFixture(
                root: root,
                assets: [
                    orderingAsset(root: root, relativePath: "b.jpg"),
                    orderingAsset(root: root, relativePath: "z.jpg"),
                ]
            ),
            sidebarSelection: .allMedia
        )
        #expect(first.mediaGrid.orderedAssetIDs.map(\.relativePath.rawValue) == ["b.jpg", "z.jpg"])

        let changed = await projection.windowState(
            fixture: orderingFixture(
                root: root,
                assets: [
                    orderingAsset(root: root, relativePath: "a.jpg"),
                    orderingAsset(root: root, relativePath: "c.jpg"),
                    orderingAsset(root: root, relativePath: "z.jpg"),
                ]
            ),
            sidebarSelection: .allMedia
        )
        #expect(changed.mediaGrid.orderedAssetIDs.map(\.relativePath.rawValue) == ["a.jpg", "c.jpg", "z.jpg"])
    }

    @Test func sidebarFilteringPublishesSelectedScope() async throws {
        let temp = try orderingTemporaryDirectory()
        let outputURL = temp.appending(path: "catalog-diagnostics.jsonl")
        let diagnostics = CatalogDiagnostics(outputURL: outputURL, isEnabled: true)
        let rootURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: rootURL.appending(path: "a.jpg"))

        let store = CatalogStore(
            location: .inMemory,
            scanCadence: .milliseconds(10),
            diagnostics: nil
        )
        let projection = CatalogProjection(cadence: .milliseconds(10), diagnostics: diagnostics)
        let stream = await projection.states(store: store, initialDescriptor: .default)
        let recordingTask = Task {
            for await _ in stream {}
        }
        defer { recordingTask.cancel() }

        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: rootURL)
        _ = try await waitForOrderingDiagnostic(outputURL) { event in
            event.operation == "catalog.projection.window"
                && event.fields["sidebarSelection"] == "allMedia"
                && event.fields["selectedScopeAssetCount"] == "1"
        }

        try await diagnostics.removeExistingDiagnosticsForTesting()
        let rootPath = try CatalogPath.normalizedDirectoryPath(for: rootURL)
        await projection.updateSidebarSelection(.library(rootPath))
        let filtered = try await waitForOrderingDiagnostic(outputURL) { event in
            event.operation == "catalog.projection.window"
                && event.fields["sidebarSelection"] == "library:\(rootPath.rawValue)"
                && event.fields["selectedScopeAssetCount"] == "1"
        }

        #expect(filtered.fields["selectedScopeAssetCount"] == "1")
    }

    // swiftlint:disable:next function_body_length
    @Test func detailOnlyStoreChangePublishesRefreshAndChecksOrder() async throws {
        let temp = try orderingTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "jpeg".write(to: root.appending(path: "one.jpg"), atomically: true, encoding: .utf8)

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10), diagnostics: nil)
        let outputURL = temp.appending(path: "projection-order-skip.jsonl")
        let diagnostics = CatalogDiagnostics(outputURL: outputURL, isEnabled: true)
        let projection = CatalogProjection(cadence: .milliseconds(10), diagnostics: diagnostics)
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
        let initialStates = try await recorder.waitForState(timeout: .initialStateTimedOut) { states in
            states.last { state in
                state.mediaGrid.orderedAssetIDs == [id]
                    && state.libraries.allSatisfy { $0.activity == .idle }
            }
        }
        let initialState = try #require(initialStates.last { state in
            state.mediaGrid.orderedAssetIDs == [id]
                && state.libraries.allSatisfy { $0.activity == .idle }
        })
        try await diagnostics.removeExistingDiagnosticsForTesting()

        let asset = try #require(try await store.mediaAssets(for: [id])[id])
        let sourceMTime = try #require(asset.contentModifiedAt.map { Int($0.timeIntervalSince1970) })
        let enrichment = EnrichmentResult(
            id: id,
            metadata: AssetMetadata(cameraModel: "Cam"),
            timestampFacts: EnrichmentTimestampFacts(original: Date(timeIntervalSince1970: 700)),
            thumbnailPath: "thumb.jpg",
            sourceSize: asset.byteSize,
            sourceMTimeSeconds: sourceMTime
        )
        _ = await store.applyEnrichmentBatch([enrichment])
        let detailState = try await recorder.waitForState(timeout: .detailStateTimedOut) { states in
            states.last { state in
                state.mediaGrid.orderedAssetIDs == [id]
                    && state.mediaGrid.detailRefreshGeneration > initialState.mediaGrid.detailRefreshGeneration
            }
        }
        let detailGeneration = try #require(detailState.last?.mediaGrid.detailRefreshGeneration)
        let detailOnly = try await waitForOrderingDiagnostic(outputURL) { event in
            event.operation == "catalog.projection.window"
                && event.fields["detailRefreshChanged"] == "true"
                && event.fields["detailRefreshGeneration"] == "\(detailGeneration)"
        }
        #expect(detailOnly.fields["assetOrderQueryMs"] != nil)
    }
}

private func orderingRoot() -> LibraryRoot {
    LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Pictures"))
}

private func orderingAsset(root: LibraryRoot, relativePath: String) -> MediaAsset {
    MediaAsset(
        libraryRootPath: root.path,
        relativePath: MediaRelativePath(rawValue: relativePath),
        name: URL(fileURLWithPath: relativePath).lastPathComponent,
        contentTypeIdentifier: "public.jpeg",
        byteSize: 1,
        createdAt: nil,
        contentModifiedAt: nil
    )
}

private func orderingFixture(
    root: LibraryRoot,
    assets: [MediaAsset]
) -> ProjectionFixture {
    ProjectionFixture(
        libraries: [CatalogLibraryState(root: root, availability: .available, activity: .idle)],
        orderedAssetIDs: orderedAssetIDs(for: assets)
    )
}

private func waitForOrderingDiagnostic(
    _ url: URL,
    matching predicate: @escaping @Sendable (CatalogDiagnosticEvent) -> Bool
) async throws -> CatalogDiagnosticEvent {
    try await withTestTimeout("ordering diagnostic") {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        while !Task.isCancelled {
            if let data = try? Data(contentsOf: url) {
                let events = data.split(separator: 0x0A).compactMap { line in
                    try? decoder.decode(CatalogDiagnosticEvent.self, from: Data(line))
                }
                if let event = events.first(where: predicate) {
                    return event
                }
            }
            await Task.yield()
        }
        throw CancellationError()
    }
}

private func orderingTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "OtosTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private enum CatalogProjectionOrderingTestError: Error {
    case initialStateTimedOut
    case detailStateTimedOut
}

private typealias OrderingStateRecorder = AsyncValueRecorder<CatalogWindowState>

private extension AsyncValueRecorder where Value == CatalogWindowState {
    func waitForState(
        timeout: CatalogProjectionOrderingTestError,
        matching predicate: @escaping @Sendable ([CatalogWindowState]) -> CatalogWindowState?
    ) async throws -> [CatalogWindowState] {
        do {
            return try await withTestTimeout("ordering state", timeout: .seconds(15)) {
                await self.waitForValues { states in
                    predicate(states) != nil
                }
            }
        } catch {
            throw timeout
        }
    }
}
