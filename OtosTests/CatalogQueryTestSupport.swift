@testable import Otos

struct CatalogStoreTestState: Equatable {
    var libraries: [CatalogLibraryState]
    var assets: [MediaAsset]

    /// Store tests inspect values rather than ordering. Production ordering is
    /// deliberately owned by CatalogProjection, so this helper stays test-only.
    var testAssets: [MediaAsset] {
        assets
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
    return CatalogStoreTestState(libraries: libraries, assets: Array(assetsByID.values))
}

struct ProjectionFixture {
    var libraries: [CatalogLibraryState]
    var orderedAssetIDs: [MediaAssetID]
}

func orderedAssetIDs(for assets: [MediaAsset]) -> [MediaAssetID] {
    assets
        .sorted { left, right in
            if left.sortKey != right.sortKey {
                return left.sortKey < right.sortKey
            }
            if left.libraryRootPath.rawValue != right.libraryRootPath.rawValue {
                return left.libraryRootPath.rawValue < right.libraryRootPath.rawValue
            }
            return left.relativePath.rawValue < right.relativePath.rawValue
        }
        .map(\.id)
}
