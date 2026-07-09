import Foundation
import OSLog

// Collection support guide
//
// These value helpers back the AppKit collection bridge without belonging to the
// bridge's view-controller lifecycle. Sticky paint truth lives in `TileContentStore`;
// this file keeps the detail reader and structural-apply policy.

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

nonisolated struct MediaGridStructuralApplyPolicy: Equatable {
    static let reloadDataFallbackItemCountThreshold = 1000

    let insertedCount: Int
    let removedCount: Int
    let reorderOnly: Bool
    let largeApply: Bool
    let animatingDifferences: Bool
    let usesReloadDataFallback: Bool

    static func summarize(
        previousOrderedIDs: [MediaAssetID],
        nextOrderedIDs: [MediaAssetID]
    ) -> MediaGridStructuralApplyPolicy {
        let previousIDs = Set(previousOrderedIDs)
        let retainedCount = nextOrderedIDs.reduce(into: 0) { count, id in
            if previousIDs.contains(id) {
                count += 1
            }
        }
        let insertedCount = nextOrderedIDs.count - retainedCount
        let removedCount = previousOrderedIDs.count - retainedCount
        let reorderOnly = insertedCount == 0
            && removedCount == 0
            && previousOrderedIDs != nextOrderedIDs
        let largeApply = nextOrderedIDs.count >= reloadDataFallbackItemCountThreshold
        let usesReloadDataFallback = reorderOnly || largeApply
        return MediaGridStructuralApplyPolicy(
            insertedCount: insertedCount,
            removedCount: removedCount,
            reorderOnly: reorderOnly,
            largeApply: largeApply,
            animatingDifferences: !usesReloadDataFallback,
            usesReloadDataFallback: usesReloadDataFallback
        )
    }
}
