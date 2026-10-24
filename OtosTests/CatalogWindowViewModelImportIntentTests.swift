import Foundation
@testable import OtosKit
import Testing

/// Import intents reach the coordinator in the order the user made them. The view model
/// funnels them through one lossless stream with one consumer, because Swift does not order
/// separate `Task {}` blocks started from the main actor.
@Suite(.testDirectory)
@MainActor
struct CatalogWindowViewModelImportIntentTests {
    /// "Change the destination, then Import" — two synchronous calls, back to back — must
    /// import into the new destination, never the one the card started with.
    @Test func destinationThenImportImportsIntoTheNewDestination() async throws {
        let temp = try makeTestDirectory()
        let firstURL = temp.appending(path: "First", directoryHint: .isDirectory)
        let secondURL = temp.appending(path: "Second", directoryHint: .isDirectory)
        let cardURL = temp.appending(path: "Card", directoryHint: .isDirectory)
        for url in [firstURL, secondURL, cardURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try Data(repeating: 3, count: 4096).write(to: cardURL.appending(path: "f.jpg"))

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: firstURL)
        try await store.addLibrary(url: secondURL)
        try await store.attachRemovableVolume(
            mountURL: cardURL,
            identity: "volume:intent-order",
            displayName: "Card",
            isEjectable: true
        )
        let second = try CatalogPath.normalizedDirectoryPath(for: secondURL)
        let source = try CatalogPath.normalizedDirectoryPath(for: cardURL)
        _ = try await waitForCatalogStoreState(store) { state in
            !state.isScanning && state.removableSources.first?.activity == .idle
        }

        let domain = PreferencesDomain.suite(UUID().uuidString)
        var prefs = ImportPreferences.default
        prefs.destinationFolderPolicy = .none
        prefs.destinationNamePolicy = .original
        ImportPreferencesStore.save(prefs, defaults: domain.makeDefaults())

        let model = CatalogWindowViewModel(
            catalogStore: store,
            enrichmentCoordinator: nil,
            startsStallMonitor: false,
            startsEnrichment: false,
            startsSourceMonitoring: false,
            preferencesDomain: domain
        )
        let coordinator = MediaOperationCoordinator(store: store, preferencesDomain: domain)
        model.mediaOperationCoordinator = coordinator
        model.startImportIntentConsumer(coordinator: coordinator)
        await coordinator.start()
        await markEnrichmentLookedAtEveryRow(store, root: source)
        // The card is planned against the first library (the default) and Ready.
        for await presentations in await coordinator.presentationsStream() {
            if case .ready? = presentations.first(where: { $0.sourcePath == source })?.state {
                break
            }
        }

        model.setImportDestination(second, for: source)
        model.queueImport(for: source)

        try await waitUntil { try await store.importBatches().first?.assetCount == 1 }
        #expect(FileManager.default.fileExists(atPath: secondURL.appending(path: "f.jpg").path))
        #expect(!FileManager.default.fileExists(atPath: firstURL.appending(path: "f.jpg").path))
        await coordinator.shutdown()
    }
}
