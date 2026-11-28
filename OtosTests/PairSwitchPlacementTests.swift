import Foundation
@testable import OtosKit
import Testing

/// DES-117, APP-076: a RAW+JPEG pair's `JPG`/`RAW` switch is in the inspector's header, Info's
/// and Edit's alike, for the file shown; the loupe carries none.
@Suite(.testScope)
@MainActor
struct PairSwitchPlacementTests {
    // Validates: APP-076
    @Test func theInspectorsSwitchIsForThePairShown() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Photos", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for file in ["DSC1.ARW", "DSC1.JPG"] {
            try Data(file.utf8).write(to: root.appending(path: file))
        }
        let databaseURL = temp.appending(path: "Catalog/catalog.sqlite")
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let store = makeTestStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(5))
        let models = EditModels()
        do {
            try await store.addLibrary(url: root)
            _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 2 }
            let rootPath = try CatalogPath.normalizedExistingDirectoryPath(for: root)
            let jpeg = MediaAssetID(libraryRootPath: rootPath, relativePath: MediaRelativePath(rawValue: "DSC1.JPG"))
            let ordered = try await store.windowReads.orderedAssetIDs(
                for: CatalogQueryDescriptor(scope: .library(rootPath)),
                availableLibraryPaths: [rootPath]
            )
            let collapsed = PhotoStackCollapse.collapse(
                ids: ordered.ids, dayBuckets: [], coordinates: [], stacks: ordered.stacks, expanded: []
            )
            let pair = try #require(collapsed.grid.pair(shownBy: jpeg))

            let model = models.make(store: store, ids: collapsed.ids)
            model.applyState(CatalogWindowState(
                title: "Pair",
                libraries: [],
                removableSources: [],
                mediaGrid: CatalogMediaGridState(
                    descriptor: CatalogQueryDescriptor(scope: .allMedia),
                    orderedAssetIDs: collapsed.ids,
                    stacks: collapsed.grid
                ),
                filterOptions: .empty,
                resolvedSidebarSelection: .allMedia,
                mediaEmptyState: .noMedia,
                deviceConnectionBanner: nil
            ))
            model.openLoupe(id: jpeg)
            model.toggleInspector(.info)
            try await waitUntil { model.pairSwitch == PairSwitchTarget(pair: pair, shown: jpeg) }

            model.toggleInspector(.edit)
            #expect(model.isEditPanelPresented)
            #expect(model.pairSwitch == PairSwitchTarget(pair: pair, shown: jpeg))
        } catch {
            await models.finish()
            await store.shutdown()
            throw error
        }
        await models.finish()
        await store.shutdown()
    }
}
