import CoreGraphics
import Foundation
@testable import OtosKit
import Testing

@Suite(.testScope)
struct IdentityRemapUITests {
    @Test func gridSelectionRemapsSelectionAnchorAndBase() {
        let root = LibraryRootPath(rawValue: "/Library")
        let oldA = MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: "a.jpg"))
        let oldB = MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: "b.jpg"))
        let newA = MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: "A.jpg"))
        let newB = MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: "B.jpg"))
        let selection = GridSelection(selection: [oldA, oldB], anchor: oldA, base: [oldA])
        let batch = CatalogIdentityRemapBatch(
            id: 1,
            libraryRootPath: root,
            remaps: [
                CatalogIdentityRemap(oldID: oldA, newID: newA),
                CatalogIdentityRemap(oldID: oldB, newID: newB),
            ]
        )
        let remapped = selection.remapped(by: batch)
        #expect(remapped.selection == [newA, newB])
        #expect(remapped.anchor == newA)
        #expect(remapped.base == [newA])
    }

    /// A published state that shows a remapped identity carries the batch that made it.
    /// Applying that state moves selection, focus, the compare pair and the painted tile
    /// to the new identity before the new order is compared with the old one, so none of
    /// them is pruned or blanked; a later state still carrying the batch changes nothing.
    @MainActor
    @Test func aStateCarryingARemapMovesSelectionFocusAndTilesOnce() {
        let root = LibraryRootPath(rawValue: "/Library")
        let oldID = MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: "old.jpg"))
        let newID = MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: "new.jpg"))
        let other = MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: "other.jpg"))
        let viewModel = CatalogWindowViewModel(
            catalogStore: makeTestStore(location: .inMemory, scanCadence: .milliseconds(10)),
            startsSourceMonitoring: false,
            preferencesDomain: PreferencesDomain.suite(UUID().uuidString),
            volumeCapacity: ampleVolumeCapacity,
            trashFiles: .refusing
        )
        viewModel.applyState(Self.state(orderedIDs: [oldID, other], pending: []))
        viewModel.gridSelection = GridSelection(selection: [oldID], anchor: oldID, base: [oldID])
        viewModel.focusedAssetID = oldID
        viewModel.comparePair = ComparePair(left: oldID, right: nil)
        let detail = MediaTileDetail(libraryRootPath: root, relativePath: oldID.relativePath, thumbnailPath: "t", bestKind: .image)
        _ = viewModel.tileContentStore.mergeDetail(detail)
        let image = makeTestCGImage()
        _ = viewModel.tileContentStore.applyDecoded(
            image,
            key: MediaAssetTilePresentation.imageContentKey(detail),
            for: oldID
        )

        let batch = CatalogIdentityRemapBatch(
            id: 7,
            libraryRootPath: root,
            remaps: [CatalogIdentityRemap(oldID: oldID, newID: newID)]
        )
        viewModel.applyState(Self.state(orderedIDs: [newID, other], pending: [batch]))
        #expect(viewModel.gridSelection.selection == [newID])
        #expect(viewModel.focusedAssetID == newID)
        #expect(viewModel.comparePair.left == newID)
        #expect(viewModel.tileContentStore.content(for: newID)?.image === image)
        #expect(viewModel.tileContentStore.content(for: oldID) == nil)

        // The same batch again (the Store has not deleted it yet) is not applied twice:
        // a selection made since stays as the user made it.
        viewModel.gridSelection = GridSelection(selection: [other], anchor: other, base: [other])
        viewModel.applyState(Self.state(orderedIDs: [newID, other], pending: [batch]))
        #expect(viewModel.gridSelection.selection == [other])
        #expect(viewModel.appliedIdentityRemapBatchIDs == [7])
    }

    private static func state(orderedIDs: [MediaAssetID], pending: [CatalogIdentityRemapBatch]) -> CatalogWindowState {
        var state = CatalogWindowState(
            title: "Test",
            libraries: [],
            removableSources: [],
            mediaGrid: CatalogMediaGridState(scope: .allMedia, orderedAssetIDs: orderedIDs),
            filterOptions: .empty,
            resolvedSidebarSelection: .allMedia,
            mediaEmptyState: .noMedia,
            deviceConnectionBanner: nil,
            queryGeneration: 0
        )
        state.pendingIdentityRemaps = pending
        return state
    }

    private func makeTestCGImage() -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 8,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }
}
