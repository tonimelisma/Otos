import CoreGraphics
import Foundation
import OSLog

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
@MainActor
final class MediaTileImageCache {
    private final class CachedImage {
        let image: CGImage

        init(_ image: CGImage) {
            self.image = image
        }
    }

    private let cache = NSCache<NSString, CachedImage>()

    init(totalCostLimit: Int = 128 * 1024 * 1024, countLimit: Int = 700) {
        cache.totalCostLimit = totalCostLimit
        cache.countLimit = countLimit
    }

    func image(for key: String) -> CGImage? {
        guard let image = cache.object(forKey: key as NSString)?.image else {
            OtosSignpost.ui.emitEvent("MediaTileImageCacheMiss")
            return nil
        }
        OtosSignpost.ui.emitEvent("MediaTileImageCacheHit")
        return image
    }

    func insert(_ image: CGImage, for key: String) {
        let cost = max(1, image.bytesPerRow * image.height)
        cache.setObject(CachedImage(image), forKey: key as NSString, cost: cost)
        OtosSignpost.ui.emitEvent("MediaTileImageCacheInsert")
    }
}
