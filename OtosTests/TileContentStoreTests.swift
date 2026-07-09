import CoreGraphics
@testable import Otos
import Testing

@MainActor
struct TileContentStoreTests {
    @Test func mergeDetailInsertsAndRequestsDecodeWhenThumbnailExists() throws {
        let store = TileContentStore(limit: 8)
        let detail = makeDetail(path: "a.jpg", thumbnailPath: "t.jpg")

        let change = store.mergeDetail(detail)

        #expect(change == .awaitingDecode(retainsImage: false))
        let content = try #require(store.content(for: detail.id))
        #expect(content.detail == detail)
        #expect(content.imageKey == MediaAssetTilePresentation.imageContentKey(detail))
        #expect(content.image == nil)
    }

    @Test func mergeDetailNeverClearsExistingImageWhenKeyAdvances() throws {
        let store = TileContentStore(limit: 8)
        let first = makeDetail(path: "a.jpg", thumbnailPath: "t1.jpg", size: 10, mtime: 1)
        let second = makeDetail(path: "a.jpg", thumbnailPath: "t2.jpg", size: 20, mtime: 2)
        _ = store.mergeDetail(first)
        let image = makeImage()
        #expect(store.applyDecoded(image, key: MediaAssetTilePresentation.imageContentKey(first), for: first.id) == .firstImage)

        let change = store.mergeDetail(second)

        #expect(change == .awaitingDecode(retainsImage: true))
        let content = try #require(store.content(for: first.id))
        #expect(content.image === image)
        #expect(content.imageKey == MediaAssetTilePresentation.imageContentKey(second))
        #expect(content.detail.thumbnailPath == "t2.jpg")
    }

    @Test func mergeDetailSameKeyUpdatesBadgeFieldsAsDetailOnly() {
        let store = TileContentStore(limit: 8)
        let first = makeDetail(path: "a.jpg", thumbnailPath: "t.jpg", kind: .video, duration: nil)
        let second = makeDetail(path: "a.jpg", thumbnailPath: "t.jpg", kind: .video, duration: 12)
        _ = store.mergeDetail(first)

        let change = store.mergeDetail(second)

        #expect(change == .detailOnly)
        #expect(store.content(for: first.id)?.detail.durationSeconds == 12)
    }

    @Test func applyDecodedRejectsStaleKey() {
        let store = TileContentStore(limit: 8)
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
        let store = TileContentStore(limit: 8)
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
        let store = TileContentStore(limit: 8)
        let keep = makeDetail(path: "keep.jpg", thumbnailPath: "k.jpg")
        let drop = makeDetail(path: "drop.jpg", thumbnailPath: "d.jpg")
        let pinned = makeDetail(path: "pin.jpg", thumbnailPath: "p.jpg")
        _ = store.mergeDetail(keep)
        _ = store.mergeDetail(drop)
        _ = store.mergeDetail(pinned)
        store.pinVisible([pinned.id])

        store.prune(to: [keep.id])

        #expect(store.content(for: keep.id) != nil)
        #expect(store.content(for: pinned.id) != nil)
        #expect(store.content(for: drop.id) == nil)
    }

    @Test func lruEvictionSkipsPinnedEntries() {
        let store = TileContentStore(limit: 2)
        let a = makeDetail(path: "a.jpg", thumbnailPath: "a.jpg")
        let b = makeDetail(path: "b.jpg", thumbnailPath: "b.jpg")
        let c = makeDetail(path: "c.jpg", thumbnailPath: "c.jpg")
        _ = store.mergeDetail(a)
        _ = store.mergeDetail(b)
        store.pinVisible([a.id])
        // Touch b so a is older among unpinned… a is pinned so b should leave when c arrives.
        _ = store.content(for: b.id)
        _ = store.mergeDetail(c)

        #expect(store.content(for: a.id) != nil)
        #expect(store.content(for: c.id) != nil)
        #expect(store.count == 2)
        #expect(store.content(for: b.id) == nil)
    }

    @Test func nilThumbnailMergeDoesNotRequestDecode() {
        let store = TileContentStore(limit: 8)
        let detail = makeDetail(path: "a.jpg", thumbnailPath: nil)

        let change = store.mergeDetail(detail)

        #expect(change == .detailOnly)
        #expect(store.content(for: detail.id)?.image == nil)
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
        enrichedSourceSize: thumbnailPath == nil ? nil : size,
        enrichedSourceMTimeSeconds: thumbnailPath == nil ? nil : mtime
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
