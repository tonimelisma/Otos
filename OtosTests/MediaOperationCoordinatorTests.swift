import Foundation
@testable import Otos
import Testing

struct MediaOperationCoordinatorTests {
    @Test func queueImportSurfacesExecutionUnavailableOrQueuedState() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let fixedRoot = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let cardRoot = temp.appending(path: "Card", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fixedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cardRoot, withIntermediateDirectories: true)
        try writeCatalogStoreFile(fixedRoot.appending(path: "fixed.jpg"), contents: "jpeg")
        try writeCatalogStoreFile(cardRoot.appending(path: "card.jpg"), contents: "jpeg")

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: fixedRoot)
        let fixedPath = try CatalogPath.normalizedDirectoryPath(for: fixedRoot)
        _ = try await waitForCatalogStoreState(store) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.map(\.relativePath.rawValue) == ["fixed.jpg"]
        }

        try await store.attachRemovableVolume(
            mountURL: cardRoot,
            identity: "volume:import-plan-card",
            displayName: "Card",
            isEjectable: true
        )
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardRoot)
        _ = try await waitForCatalogStoreState(store) { snapshot in
            snapshot.removableSources.contains {
                $0.path == cardPath && $0.availability == .available && !$0.isScanning
            }
        }

        let coordinator = MediaOperationCoordinator(store: store, authorizeMaterialization: false)
        await coordinator.start()
        defer {
            Task { await coordinator.shutdown() }
        }

        await coordinator.setDestination(fixedPath, for: cardPath)
        try await Task.sleep(for: .milliseconds(250))
        await coordinator.queueImport(for: cardPath)
        try await Task.sleep(for: .milliseconds(400))

        let presentations = await coordinator.currentPresentations()
        let card = try #require(presentations.first { $0.sourcePath == cardPath })
        switch card.state {
        case .executionUnavailable, .queuedForReadiness, .waitingForMetadata, .ready, .planning:
            break
        default:
            Issue.record("Unexpected import presentation state \(card.state)")
        }
    }
}

struct ImportBatchSidebarPolicyTests {
    @Test func missingBatchFallsBackToDefaultSelection() {
        let pictures = CatalogLibraryState(
            root: LibraryRoot(path: LibraryRootPath(rawValue: "/Users/example/Pictures")),
            availability: .available,
            activity: .idle
        )
        let resolved = CatalogWindowPolicy.resolvedSidebarSelection(
            .importBatch(ImportBatchID(unixMilliseconds: 1)),
            libraries: [pictures],
            removableSources: [],
            importBatches: []
        )
        #expect(resolved == .library(pictures.path))
    }

    @Test func existingBatchIsPreserved() {
        let batch = ImportBatchSummary(
            batchID: ImportBatchID(unixMilliseconds: 42),
            assetCount: 3
        )
        let resolved = CatalogWindowPolicy.resolvedSidebarSelection(
            .importBatch(batch.batchID),
            libraries: [],
            removableSources: [],
            importBatches: [batch]
        )
        #expect(resolved == .importBatch(batch.batchID))
    }
}
