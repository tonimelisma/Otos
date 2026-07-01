@testable import Otos

struct CatalogStoreTestState: Equatable {
    var libraries: [CatalogLibraryState]
    var assetsByID: [MediaAssetID: MediaAsset]

    /// Store tests inspect values rather than ordering. Production ordering is
    /// deliberately owned by CatalogProjection, so this helper stays test-only.
    var testAssets: [MediaAsset] {
        Array(assetsByID.values)
    }

    var isScanning: Bool {
        libraries.contains { $0.isScanning }
    }
}

func catalogStoreTestState(_ store: CatalogStore) async throws -> CatalogStoreTestState {
    let libraries = await store.currentLibraries()
    let allLibraryPaths = Set(libraries.map(\.path))
    let ids = try await store.orderedAssetIDs(for: .allMedia, availableLibraryPaths: allLibraryPaths)
    let assetsByID = try await store.mediaAssets(for: ids)
    return CatalogStoreTestState(libraries: libraries, assetsByID: assetsByID)
}

struct ProjectionTestState {
    var libraries: [CatalogLibraryState]
    var assetsByID: [MediaAssetID: MediaAsset]
}
