import CoreGraphics
@testable import OtosKit
import Testing

@MainActor
struct TileContentStoreTests {
    @Test func mergeDetailInsertsAndRequestsDecodeWhenThumbnailExists() throws {
        let store = TileContentStore()
        let detail = makeDetail(path: "a.jpg", thumbnailPath: "t.jpg")

        let change = store.mergeDetail(detail)

        #expect(change == .awaitingDecode(retainsImage: false))
        let content = try #require(store.content(for: detail.id))
        #expect(content.detail == detail)
        #expect(content.imageKey == MediaAssetTilePresentation.imageContentKey(detail))
        #expect(content.image == nil)
    }

    @Test func mergeDetailNeverClearsExistingImageWhenKeyAdvances() throws {
        let store = TileContentStore()
        let first = makeDetail(path: "a.jpg", thumbnailPath: "t1.jpg", size: 10, mtime: 1)
        let second = makeDetail(path: "a.jpg", thumbnailPath: "t2.jpg", size: 20, mtime: 2)
        _ = store.mergeDetail(first)
        let image = makeImage()
        let firstKey = MediaAssetTilePresentation.imageContentKey(first)
        #expect(store.applyDecoded(image, key: firstKey, for: first.id) == .firstImage)

        let change = store.mergeDetail(second)

        #expect(change == .awaitingDecode(retainsImage: true))
        let content = try #require(store.content(for: first.id))
        #expect(content.image === image)
        #expect(content.imageKey == MediaAssetTilePresentation.imageContentKey(second))
        #expect(content.detail.thumbnailPath == "t2.jpg")
    }

    @Test func mergeDetailSameKeyUpdatesBadgeFieldsAsDetailOnly() {
        let store = TileContentStore()
        let first = makeDetail(path: "a.jpg", thumbnailPath: "t.jpg", kind: .video, duration: nil)
        let second = makeDetail(path: "a.jpg", thumbnailPath: "t.jpg", kind: .video, duration: 12)
        _ = store.mergeDetail(first)

        let change = store.mergeDetail(second)

        #expect(change == .detailOnly)
        #expect(store.content(for: first.id)?.detail.durationSeconds == 12)
    }

    @Test func mergeDetailNilThumbnailAfterPaintedImageReturnsDetailOnly() throws {
        let store = TileContentStore()
        let first = makeDetail(path: "a.jpg", thumbnailPath: "t.jpg")
        let second = makeDetail(path: "a.jpg", thumbnailPath: nil)
        _ = store.mergeDetail(first)
        let image = makeImage()
        _ = store.applyDecoded(image, key: MediaAssetTilePresentation.imageContentKey(first), for: first.id)

        let change = store.mergeDetail(second)

        #expect(change == .detailOnly)
        let content = try #require(store.content(for: first.id))
        #expect(content.image === image)
    }

    @Test func applyDecodedRejectsStaleKey() {
        let store = TileContentStore()
        let first = makeDetail(path: "a.jpg", thumbnailPath: "t1.jpg", size: 1, mtime: 1)
        let second = makeDetail(path: "a.jpg", thumbnailPath: "t2.jpg", size: 2, mtime: 2)
        _ = store.mergeDetail(first)
        _ = store.mergeDetail(second)
        let stale = makeImage()

        let change = store.applyDecoded(
            stale,
            key: MediaAssetTilePresentation.imageContentKey(first),
            for: first.id
        )

        #expect(change == .unchanged)
        #expect(store.content(for: first.id)?.image == nil)
    }

    @Test func applyDecodedClassifiesFirstAndReplacement() {
        let store = TileContentStore()
        let detail = makeDetail(path: "a.jpg", thumbnailPath: "t.jpg")
        let key = MediaAssetTilePresentation.imageContentKey(detail)
        _ = store.mergeDetail(detail)
        let firstImage = makeImage(width: 10)
        let secondImage = makeImage(width: 20)

        #expect(store.applyDecoded(firstImage, key: key, for: detail.id) == .firstImage)
        #expect(store.applyDecoded(secondImage, key: key, for: detail.id) == .replacedImage)
        #expect(store.content(for: detail.id)?.image === secondImage)
    }

    @Test func pruneRemovesNonLiveNonPinnedAndPreservesPinned() {
        let store = TileContentStore()
        let keep = makeDetail(path: "keep.jpg", thumbnailPath: "k.jpg")
        let drop = makeDetail(path: "drop.jpg", thumbnailPath: "d.jpg")
        let pinned = makeDetail(path: "pin.jpg", thumbnailPath: "p.jpg")
        _ = store.mergeDetail(keep)
        _ = store.mergeDetail(drop)
        _ = store.mergeDetail(pinned)
        store.pinVisible([pinned.id])

        store.prune { $0 == keep.id }

        #expect(store.content(for: keep.id) != nil)
        #expect(store.content(for: pinned.id) != nil)
        #expect(store.content(for: drop.id) == nil)
    }

    @Test func imageBudgetDropsLRUUnpinnedImagesButNeverPinned() {
        let small = makeImage(width: 8)
        let cost = TileContentStore.byteCost(of: small)
        let store = TileContentStore(imageByteBudget: cost * 2)
        let pinned = makeDetail(path: "pin.jpg", thumbnailPath: "p.jpg")
        let older = makeDetail(path: "older.jpg", thumbnailPath: "o.jpg")
        let newer = makeDetail(path: "newer.jpg", thumbnailPath: "n.jpg")
        _ = store.mergeDetail(pinned)
        _ = store.mergeDetail(older)
        _ = store.mergeDetail(newer)
        store.pinVisible([pinned.id])
        _ = store.applyDecoded(small, key: MediaAssetTilePresentation.imageContentKey(pinned), for: pinned.id)
        _ = store.applyDecoded(small, key: MediaAssetTilePresentation.imageContentKey(older), for: older.id)
        // Touch older so it is LRU among unpinned when newer arrives over budget.
        _ = store.content(for: older.id)
        _ = store.applyDecoded(small, key: MediaAssetTilePresentation.imageContentKey(newer), for: newer.id)

        #expect(store.content(for: pinned.id)?.image != nil)
        #expect(store.content(for: older.id)?.image == nil)
        #expect(store.content(for: older.id)?.detail.thumbnailPath == "o.jpg")
        #expect(store.content(for: newer.id)?.image != nil)
        #expect(store.imageBytes == cost * 2)
    }

    @Test func additivePinProtectsImageFromBudgetEvictionAndPrune() {
        let image = makeImage(width: 8)
        let cost = TileContentStore.byteCost(of: image)
        let store = TileContentStore(imageByteBudget: cost)
        let additive = makeDetail(path: "additive.jpg", thumbnailPath: "a.jpg")
        let pressure = makeDetail(path: "pressure.jpg", thumbnailPath: "p.jpg")
        _ = store.mergeDetail(additive)
        _ = store.mergeDetail(pressure)
        store.pin(additive.id)
        _ = store.applyDecoded(image, key: MediaAssetTilePresentation.imageContentKey(additive), for: additive.id)
        _ = store.applyDecoded(image, key: MediaAssetTilePresentation.imageContentKey(pressure), for: pressure.id)

        #expect(store.content(for: additive.id)?.image != nil)
        #expect(store.content(for: pressure.id)?.image == nil)

        store.prune { $0 == pressure.id }
        #expect(store.content(for: additive.id)?.image != nil)
    }

    @Test func pinVisibleReplacementMakesPreviouslyAdditiveIdEvictable() {
        let image = makeImage(width: 8)
        let cost = TileContentStore.byteCost(of: image)
        let store = TileContentStore(imageByteBudget: cost)
        let wasAdditive = makeDetail(path: "was.jpg", thumbnailPath: "w.jpg")
        let keep = makeDetail(path: "keep.jpg", thumbnailPath: "k.jpg")
        _ = store.mergeDetail(wasAdditive)
        _ = store.mergeDetail(keep)
        store.pin(wasAdditive.id)
        _ = store.applyDecoded(image, key: MediaAssetTilePresentation.imageContentKey(wasAdditive), for: wasAdditive.id)
        store.pinVisible([keep.id])
        _ = store.applyDecoded(image, key: MediaAssetTilePresentation.imageContentKey(keep), for: keep.id)

        #expect(store.content(for: keep.id)?.image != nil)
        #expect(store.content(for: wasAdditive.id)?.image == nil)

        store.prune { $0 == keep.id }
        #expect(store.content(for: wasAdditive.id) == nil)
        #expect(store.content(for: keep.id) != nil)
    }
}

@MainActor
private func makeDetail(
    path: String,
    thumbnailPath: String?,
    kind: MediaKind? = .image,
    duration: Double? = nil,
    size: Int64 = 100,
    mtime: Int = 1
) -> MediaTileDetail {
    MediaTileDetail(
        libraryRootPath: LibraryRootPath(rawValue: "/Pictures"),
        relativePath: MediaRelativePath(rawValue: path),
        thumbnailPath: thumbnailPath,
        bestKind: kind,
        durationSeconds: duration,
        renderedSourceSize: thumbnailPath == nil ? nil : size,
        renderedSourceMTimeSeconds: thumbnailPath == nil ? nil : mtime
    )
}

@MainActor
private func makeImage(width: Int = 8) -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
        data: nil,
        width: width,
        height: width,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    return context.makeImage()!
}
