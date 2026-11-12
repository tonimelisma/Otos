import Foundation
@testable import OtosKit
import Testing

/// The single `PreferencesDomain` value is the only way to
/// select a preference domain. Every construction site requires it; there is
/// no default that can silently select `.standard`. This suite proves that a
/// temporary domain persists and isolates, and that reconstructing actors from the
/// same domain observes the same persisted state while a distinct control suite
/// remains unchanged.
@Suite(.testDirectory)
@MainActor
struct PreferencesDomainTests {
    @Test func temporaryDomainPersistsViewModelStateAndIsolatesControl() {
        let temp = PreferencesDomain.suite(UUID().uuidString)
        let control = PreferencesDomain.suite(UUID().uuidString)

        // First ViewModel persists grid column count and ImportPreferences into temp.
        let first = CatalogWindowViewModel(
            catalogStore: CatalogStore(location: .inMemory),
            startsStallMonitor: false,
            startsEnrichment: false,
            startsSourceMonitoring: false,
            preferencesDomain: temp,
            volumeCapacity: ampleVolumeCapacity,
            trashFiles: .refusing
        )
        first.setGridColumnCount(9)
        first.setStripTileEdge(150)
        first.setImportPreferences(ImportPreferences(
            importSidecarFiles: true,
            deleteSourceAfterImport: true,
            autoEjectAfterImport: true,
            destinationFolderPolicy: .yearMonth,
            destinationNamePolicy: .original
        ))

        // Control suite remains at defaults.
        let controlDefaults = control.makeDefaults()
        #expect(controlDefaults.integer(forKey: "mediaGridColumnCount") == 0)
        #expect(controlDefaults.object(forKey: "mediaStripTileEdge") == nil)

        // Reconstructing from the same domain observes the persisted values.
        let second = CatalogWindowViewModel(
            catalogStore: CatalogStore(location: .inMemory),
            startsStallMonitor: false,
            startsEnrichment: false,
            startsSourceMonitoring: false,
            preferencesDomain: temp,
            volumeCapacity: ampleVolumeCapacity,
            trashFiles: .refusing
        )
        #expect(second.gridColumnCount == 9)
        #expect(second.stripTileEdge == 150)
        #expect(second.importPreferences.importSidecarFiles == true)
        #expect(second.importPreferences.deleteSourceAfterImport == true)

        // A direct read of the domain's store proves the suite was written.
        let tempDefaults = temp.makeDefaults()
        #expect(tempDefaults.integer(forKey: "mediaGridColumnCount") == 9)
        #expect(tempDefaults.object(forKey: CatalogWindowViewModel.stripTileEdgeDefaultsKey) as? Double == 150)
    }
}
