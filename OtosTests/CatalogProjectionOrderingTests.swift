import Foundation
@testable import Otos
import Testing

struct CatalogProjectionOrderingTests {
    @Test func unchangedRevisionReusesOrderAndRematerializesDetailValues() async {
        let root = orderingRoot()
        let projection = CatalogProjection(diagnostics: nil)
        let original = orderingAsset(root: root, relativePath: "one.jpg")
        let changed = MediaAsset(
            libraryRootPath: original.libraryRootPath,
            libraryDisplayName: original.libraryDisplayName,
            relativePath: original.relativePath,
            name: "renamed-detail.jpg",
            contentTypeIdentifier: original.contentTypeIdentifier,
            byteSize: 99,
            createdAt: original.createdAt,
            contentModifiedAt: original.contentModifiedAt
        )

        _ = await projection.windowState(
            snapshot: orderingSnapshot(root: root, assets: [original], revision: 4),
            sidebarSelection: .allMedia
        )
        let updated = await projection.windowState(
            snapshot: orderingSnapshot(root: root, assets: [changed], revision: 4),
            sidebarSelection: .allMedia
        )

        #expect(updated.mediaGrid.orderedAssetIDs == [original.id])
        #expect(updated.mediaGrid.assetsByID[original.id]?.name == "renamed-detail.jpg")
        #expect(updated.mediaGrid.assetsByID[original.id]?.byteSize == 99)
    }

    @Test func unchangedRevisionWithDifferentIdentitiesRecoversByRebuildingOrder() async {
        let root = orderingRoot()
        let projection = CatalogProjection(diagnostics: nil)
        let first = orderingAsset(root: root, relativePath: "z.jpg")
        let replacement = orderingAsset(root: root, relativePath: "a.jpg")

        _ = await projection.windowState(
            snapshot: orderingSnapshot(root: root, assets: [first], revision: 7),
            sidebarSelection: .allMedia
        )
        let recovered = await projection.windowState(
            snapshot: orderingSnapshot(root: root, assets: [replacement], revision: 7),
            sidebarSelection: .allMedia
        )

        #expect(recovered.mediaGrid.orderedAssetIDs == [replacement.id])
        #expect(recovered.mediaGrid.assetsByID[replacement.id] == replacement)
    }

    @Test func changedRevisionResortsAfterInsertionAndDeletion() async {
        let root = orderingRoot()
        let projection = CatalogProjection(diagnostics: nil)
        let first = await projection.windowState(
            snapshot: orderingSnapshot(
                root: root,
                assets: [
                    orderingAsset(root: root, relativePath: "b.jpg"),
                    orderingAsset(root: root, relativePath: "z.jpg"),
                ],
                revision: 1
            ),
            sidebarSelection: .allMedia
        )
        #expect(orderingAssets(in: first).map(\.relativePath.rawValue) == ["b.jpg", "z.jpg"])

        let changed = await projection.windowState(
            snapshot: orderingSnapshot(
                root: root,
                assets: [
                    orderingAsset(root: root, relativePath: "a.jpg"),
                    orderingAsset(root: root, relativePath: "c.jpg"),
                    orderingAsset(root: root, relativePath: "z.jpg"),
                ],
                revision: 2
            ),
            sidebarSelection: .allMedia
        )
        #expect(orderingAssets(in: changed).map(\.relativePath.rawValue) == ["a.jpg", "c.jpg", "z.jpg"])
    }

    @Test func sidebarFilteringPublishesFromCachedOrderWithoutSorting() async throws {
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
        let stream = await projection.states(store: store, initialSidebarSelection: .allMedia)
        let recordingTask = Task {
            for await _ in stream {}
        }
        defer { recordingTask.cancel() }

        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: rootURL)
        _ = try await waitForOrderingDiagnostic(outputURL) { event in
            event.operation == "catalog.projection.window"
                && event.fields["assetOrderSorted"] == "true"
                && event.fields["selectedScopeAssetCount"] == "1"
        }

        try await diagnostics.removeExistingDiagnosticsForTesting()
        let rootPath = try CatalogPath.normalizedDirectoryPath(for: rootURL)
        await projection.updateSidebarSelection(.library(rootPath))
        let filtered = try await waitForOrderingDiagnostic(outputURL) { event in
            event.operation == "catalog.projection.window"
                && event.fields["assetOrderCacheHit"] == "true"
                && event.fields["assetOrderSorted"] == "false"
                && event.fields["sidebarSelection"] == "library:\(rootPath.rawValue)"
        }

        #expect(filtered.fields["selectedScopeAssetCount"] == "1")
    }
}

private func orderingRoot() -> LibraryRoot {
    LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Pictures"))
}

private func orderingAsset(root: LibraryRoot, relativePath: String) -> MediaAsset {
    MediaAsset(
        libraryRootPath: root.path,
        libraryDisplayName: root.displayName,
        relativePath: MediaRelativePath(rawValue: relativePath),
        name: URL(fileURLWithPath: relativePath).lastPathComponent,
        contentTypeIdentifier: "public.jpeg",
        byteSize: 1,
        createdAt: nil,
        contentModifiedAt: nil
    )
}

private func orderingSnapshot(
    root: LibraryRoot,
    assets: [MediaAsset],
    revision: UInt64
) -> CatalogSnapshot {
    CatalogSnapshot(
        libraries: [CatalogLibraryState(root: root, availability: .available, activity: .idle)],
        assetsByID: Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) }),
        assetStructureRevision: revision
    )
}

private func orderingAssets(in state: CatalogWindowState) -> [MediaAsset] {
    state.mediaGrid.orderedAssetIDs.compactMap { state.mediaGrid.assetsByID[$0] }
}

private func waitForOrderingDiagnostic(
    _ url: URL,
    matching predicate: (CatalogDiagnosticEvent) -> Bool
) async throws -> CatalogDiagnosticEvent {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    for _ in 0 ..< 100 {
        if let data = try? Data(contentsOf: url) {
            let events = data.split(separator: 0x0A).compactMap { line in
                try? decoder.decode(CatalogDiagnosticEvent.self, from: Data(line))
            }
            if let event = events.first(where: predicate) {
                return event
            }
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw CatalogProjectionOrderingTestError.timedOut
}

private func orderingTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "OtosTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private enum CatalogProjectionOrderingTestError: Error {
    case timedOut
}
