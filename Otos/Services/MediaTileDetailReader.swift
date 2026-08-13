import Foundation
import OSLog

struct MediaTileDetailReader {
    private let store: CatalogStore

    init(store: CatalogStore) {
        self.store = store
    }

    func details(for ids: [MediaAssetID]) async -> [MediaAssetID: MediaTileDetail] {
        do {
            return try await store.mediaTileDetails(for: ids)
        } catch is CancellationError {
            return [:]
        } catch {
            OtosLog.catalog.error(
                "Media tile detail query failed error=\(String(describing: error), privacy: .public)"
            )
            return [:]
        }
    }
}
