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
    private struct CachedAsset {
        var asset: MediaAsset
        var accessStamp: UInt64
    }

    private var assetsByID: [MediaAssetID: CachedAsset] = [:]
    private var accessClock: UInt64 = 0
    let limit: Int

    init(limit: Int = 4096) {
        self.limit = limit
    }

    var count: Int {
        assetsByID.count
    }

    mutating func merge(_ assets: [MediaAssetID: MediaAsset]) {
        for (id, asset) in assets {
            let stamp = nextAccessStamp()
            assetsByID[id] = CachedAsset(asset: asset, accessStamp: stamp)
        }
        evictIfNeeded()
    }

    mutating func asset(for id: MediaAssetID) -> MediaAsset? {
        guard var cached = assetsByID[id] else {
            return nil
        }
        cached.accessStamp = nextAccessStamp()
        assetsByID[id] = cached
        return cached.asset
    }

    private mutating func nextAccessStamp() -> UInt64 {
        accessClock &+= 1
        return accessClock
    }

    private mutating func evictIfNeeded() {
        while assetsByID.count > limit {
            guard let evicted = assetsByID.min(by: { lhs, rhs in
                lhs.value.accessStamp < rhs.value.accessStamp
            })?.key else {
                return
            }
            assetsByID[evicted] = nil
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
