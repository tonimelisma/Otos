import Foundation
@testable import Otos
import Testing

/// ARC-013 — Main-window catalog state naming.
struct CatalogStateNamingTests {
    @Test func catalogStateDistinguishesScopeDescriptorAndGrid() {
        let state = CatalogWindowState(
            title: "Test",
            libraries: [],
            removableSources: [],
            mediaGrid: CatalogMediaGridState(
                descriptor: CatalogQueryDescriptor(scope: .allMedia),
                orderedAssetIDs: [],
                detailRefreshGeneration: 1
            ),
            filterOptions: .empty,
            resolvedSidebarSelection: .allMedia,
            mediaEmptyState: .noMedia,
            deviceConnectionBanner: nil,
            queryGeneration: 1
        )
        // Precise names: sidebar scope, descriptor (scope+sort+filter),
        // ordered IDs, detail refresh generation.
        #expect(state.mediaGrid.descriptor.scope == .allMedia)
        #expect(state.mediaGrid.orderedAssetIDs.isEmpty)
        #expect(state.mediaGrid.detailRefreshGeneration == 1)
        #expect(state.resolvedSidebarSelection == .allMedia)
    }

    @Test func gridDetailRefreshIsSeparateFromOrderedIDs() {
        let desc = CatalogQueryDescriptor(scope: .allMedia)
        let grid1 = CatalogMediaGridState(descriptor: desc, orderedAssetIDs: [MediaAssetID(libraryRootPath: LibraryRootPath(rawValue: "/A"), relativePath: MediaRelativePath(rawValue: "a.jpg"))], detailRefreshGeneration: 1)
        let grid2 = CatalogMediaGridState(descriptor: desc, orderedAssetIDs: grid1.orderedAssetIDs, detailRefreshGeneration: 2)
        // Same ordered IDs, different detail generation — proves the two are separate.
        #expect(grid1.orderedAssetIDs == grid2.orderedAssetIDs)
        #expect(grid1.detailRefreshGeneration != grid2.detailRefreshGeneration)
    }
}
