@testable import Otos

extension CatalogSnapshot {
    /// Store tests inspect values rather than ordering. Production ordering is
    /// deliberately owned by CatalogProjection, so this helper stays test-only.
    var testAssets: [MediaAsset] {
        Array(assetsByID.values)
    }
}
