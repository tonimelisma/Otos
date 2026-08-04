import CoreGraphics
import Foundation
@testable import Otos
import Testing

struct IdentityRemapUITests {
    @Test func gridSelectionRemapsSelectionAnchorAndBase() {
        let root = LibraryRootPath(rawValue: "/Library")
        let oldA = MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: "a.jpg"))
        let oldB = MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: "b.jpg"))
        let newA = MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: "A.jpg"))
        let newB = MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: "B.jpg"))
        let selection = GridSelection(selection: [oldA, oldB], anchor: oldA, base: [oldA])
        let batch = CatalogIdentityRemapBatch(
            libraryRootPath: root,
            remaps: [
                CatalogIdentityRemap(oldID: oldA, newID: newA),
                CatalogIdentityRemap(oldID: oldB, newID: newB),
            ],
            rootRevision: 1
        )
        let remapped = selection.remapped(by: batch)
        #expect(remapped.selection == [newA, newB])
        #expect(remapped.anchor == newA)
        #expect(remapped.base == [newA])
    }

    @MainActor
    @Test func tileContentStorePreservesPaintedImageAcrossRemap() {
        let root = LibraryRootPath(rawValue: "/Library")
        let oldID = MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: "old.jpg"))
        let newID = MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: "new.jpg"))
        let store = TileContentStore()
        let detail = MediaTileDetail(
            libraryRootPath: root,
            relativePath: oldID.relativePath,
            thumbnailPath: "thumb",
            bestKind: .image
        )
        _ = store.mergeDetail(detail)
        let image = makeTestCGImage()
        let key = MediaAssetTilePresentation.imageContentKey(detail)
        _ = store.applyDecoded(image, key: key, for: oldID)
        #expect(store.content(for: oldID)?.image != nil)

        store.applyIdentityRemapBatch(
            CatalogIdentityRemapBatch(
                libraryRootPath: root,
                remaps: [CatalogIdentityRemap(oldID: oldID, newID: newID)],
                rootRevision: 1
            )
        )
        #expect(store.content(for: oldID) == nil)
        #expect(store.content(for: newID)?.image === image)
    }

    @MainActor
    @Test func viewModelAppliesRemapToSelectionAndFocus() {
        let root = LibraryRootPath(rawValue: "/Library")
        let oldID = MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: "old.jpg"))
        let newID = MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: "new.jpg"))
        let viewModel = CatalogWindowViewModel(
            catalogStore: CatalogStore(location: .inMemory, scanCadence: .milliseconds(10)),
            startsSourceMonitoring: false
        )
        viewModel.gridSelection = GridSelection(selection: [oldID], anchor: oldID, base: [oldID])
        viewModel.focusedAssetID = oldID
        viewModel.comparePair = ComparePair(left: oldID, right: nil)
        viewModel.applyIdentityRemapBatch(
            CatalogIdentityRemapBatch(
                libraryRootPath: root,
                remaps: [CatalogIdentityRemap(oldID: oldID, newID: newID)],
                rootRevision: 2
            )
        )
        #expect(viewModel.gridSelection.selection == [newID])
        #expect(viewModel.focusedAssetID == newID)
        #expect(viewModel.comparePair.left == newID)
        #expect(viewModel.identityRemapEpoch == 1)
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
