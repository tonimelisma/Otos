import Foundation
@testable import OtosKit
import Testing

/// DES-117, APP-076: a RAW+JPEG pair has one `JPG`/`RAW` switch on screen at a time — the
/// loupe's while the loupe shows the pair alone, the edit panel's while it shows.
@Suite(.testScope)
@MainActor
struct PairSwitchPlacementTests {
    @Test func theLoupesSwitchLeavesWhileTheEditPanelShows() async throws {
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
            try await waitUntil { model.shownPair == pair }
            #expect(model.loupePair == pair)

            model.toggleInspector(.edit)
            #expect(model.isEditPanelPresented)
            #expect(model.shownPair == pair)
            #expect(model.loupePair == nil)

            model.toggleInspector(.edit)
            #expect(model.loupePair == pair)
        } catch {
            await models.finish()
            await store.shutdown()
            throw error
        }
        await models.finish()
        await store.shutdown()
    }
}
