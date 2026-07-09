import CoreGraphics
import Foundation
import OSLog
import Synchronization

/// Decoded-thumbnail cache guide
///
/// This is rendering state, not catalog truth. Durable thumbnail overlay stays in
/// `ThumbnailStore` as app-owned JPEG files; the catalog stores only relative file
/// names. The grid keeps this bounded process-memory cache so a recreated or reused
/// tile can synchronously repaint a thumbnail that already decoded in this process,
/// which enforces the no-blank grid invariant from spec 0038.
///
/// Keys are the tile image-content key: thumbnail path plus the source size and mtime
/// enrichment stamp. A new enrichment result naturally gets a new key, so stale
/// decoded entries age out by cost/count pressure instead of needing explicit
/// invalidation. The cache never answers whether an asset exists or is current.
///
/// The cache is deliberately thread-safe and non-main-actor isolated. Tiles still
/// paint on the main actor, but preheaters and decode tasks can insert decoded
/// images without adding a main-actor hop to the hot scroll path.
final nonisolated class MediaTileImageCache: Sendable {
    private struct CachedImage {
        let image: CGImage
        let cost: Int
        var accessStamp: UInt64
    }

    private struct Storage {
        var imagesByKey: [String: CachedImage] = [:]
        var totalCost = 0
        var accessClock: UInt64 = 0
    }

    private let totalCostLimit: Int
    private let countLimit: Int
    private let storage = Mutex(Storage())

    init(totalCostLimit: Int = 128 * 1024 * 1024, countLimit: Int = 700) {
        self.totalCostLimit = max(1, totalCostLimit)
        self.countLimit = max(1, countLimit)
    }

    func image(for key: String) -> CGImage? {
        let image = storage.withLock { storage in
            guard var cached = storage.imagesByKey[key] else {
                return nil as CGImage?
            }
            storage.accessClock &+= 1
            cached.accessStamp = storage.accessClock
            storage.imagesByKey[key] = cached
            return cached.image
        }
        guard let image else {
            return nil
        }
        return image
    }

    func insert(_ image: CGImage, for key: String) {
        let cost = max(1, image.bytesPerRow * image.height)
        storage.withLock { storage in
            storage.accessClock &+= 1
            if let existing = storage.imagesByKey[key] {
                storage.totalCost -= existing.cost
            }
            storage.imagesByKey[key] = CachedImage(
                image: image,
                cost: cost,
                accessStamp: storage.accessClock
            )
            storage.totalCost += cost
            evictIfNeeded(from: &storage)
        }
    }

    private func evictIfNeeded(from storage: inout Storage) {
        while storage.imagesByKey.count > countLimit || storage.totalCost > totalCostLimit {
            guard let evictedKey = storage.imagesByKey.min(by: { lhs, rhs in
                lhs.value.accessStamp < rhs.value.accessStamp
            })?.key else {
                storage.totalCost = 0
                return
            }
            if let evicted = storage.imagesByKey.removeValue(forKey: evictedKey) {
                storage.totalCost -= evicted.cost
            }
        }
    }
}
