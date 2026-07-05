import Foundation
import OSLog

// Collection support guide
//
// These value helpers back the AppKit collection bridge without belonging to the
// bridge's view-controller lifecycle. Keeping them separate lets tests cover sticky
// detail caching and structural-apply policy directly.

struct MediaTileDetailReader {
    private let store: CatalogStore

    init(store: CatalogStore) {
        self.store = store
    }

    func assets(for ids: [MediaAssetID]) async -> [MediaAssetID: MediaAsset] {
        do {
            return try await store.mediaAssets(for: ids)
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

nonisolated struct MediaTileDetailCache {
    private var assetsByID: [MediaAssetID: MediaAsset] = [:]
    private var recency: [MediaAssetID] = []
    let limit: Int

    init(limit: Int = 4096) {
        self.limit = limit
    }

    var count: Int {
        assetsByID.count
    }

    mutating func merge(_ assets: [MediaAssetID: MediaAsset]) {
        for (id, asset) in assets {
            assetsByID[id] = asset
            markRecent(id)
        }
        evictIfNeeded()
    }

    mutating func asset(for id: MediaAssetID) -> MediaAsset? {
        guard let asset = assetsByID[id] else {
            return nil
        }
        markRecent(id)
        return asset
    }

    private mutating func markRecent(_ id: MediaAssetID) {
        recency.removeAll { $0 == id }
        recency.append(id)
    }

    private mutating func evictIfNeeded() {
        guard assetsByID.count > limit else {
            return
        }
        while assetsByID.count > limit, !recency.isEmpty {
            let evicted = recency.removeFirst()
            assetsByID[evicted] = nil
        }
    }
}

nonisolated struct MediaGridStructuralApplyPolicy: Equatable {
    static let zeroDurationItemCountThreshold = 1000

    let insertedCount: Int
    let removedCount: Int
    let reorderOnly: Bool
    let largeApply: Bool
    let animatingDifferences = true
    let usesZeroDurationAnimation: Bool

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
        let largeApply = nextOrderedIDs.count >= zeroDurationItemCountThreshold
        return MediaGridStructuralApplyPolicy(
            insertedCount: insertedCount,
            removedCount: removedCount,
            reorderOnly: reorderOnly,
            largeApply: largeApply,
            usesZeroDurationAnimation: reorderOnly || largeApply
        )
    }
}
