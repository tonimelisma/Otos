import Foundation
@testable import OtosKit
import Synchronization
import Testing

/// A walk runs at the priority of whoever waits for it (`ScanLeaseController.ScanLane`): a
/// card's walk is user-initiated, since attaching it selects it and its import bar says
/// "Checking the card…" until the walk ends; a fixed library's is utility work.
@Suite(.testScope)
struct ScanLanePriorityTests {
    // Validates: APP-017
    @Test func aCardIsWalkedAtTheUsersPriorityAndALibraryInTheBackground() async throws {
        let temp = try makeTestDirectory()
        let libraryURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let cardURL = temp.appending(path: "Card", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cardURL, withIntermediateDirectories: true)
        let walked = Mutex<[LibraryRootPath: TaskPriority]>([:])
        let scanner = CatalogScanner(
            scanRoot: { root, cadence, batchHandler in
                walked.withLock { $0[root] = Task.currentPriority }
                return try await CatalogScanner.live.scanRoot(root, cadence, batchHandler)
            },
            scanSubtree: CatalogScanner.live.scanSubtree,
            observeFile: CatalogScanner.live.observeFile
        )
        let store = makeTestStore(location: .inMemory, scanner: scanner)
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: libraryURL)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning }
        try await store.attachRemovableVolume(
            mountURL: cardURL,
            identity: .volume(uuid: "scan-priority"),
            displayName: "Card",
            isEjectable: true,
            capabilities: .unknown
        )
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardURL)
        _ = try await waitForCatalogStoreState(store) { snapshot in
            snapshot.removableSources.contains { $0.path == cardPath && !$0.isScanning }
        }

        let libraryPath = try CatalogPath.normalizedDirectoryPath(for: libraryURL)
        let priorities = walked.withLock { $0 }
        #expect(priorities[cardPath] == .userInitiated)
        #expect(priorities[libraryPath] == .utility)
        await store.shutdown()
    }
}
