import CoreGraphics
@testable import OtosKit
import Testing

@MainActor
struct TileContentStoreTests {
    // Validates: ENR-002, ENR-010
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

    // Validates: APP-015
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

    // Validates: APP-093
    /// The grid tile keeps painting its older thumbnail until the new one decodes, but no
    /// other surface is handed that older one as the photo's picture: an edited photo's
    /// pre-edit thumbnail showed in the loupe until its full decode landed.
    @Test func anOlderThumbnailIsNeverHandedOutAsTheCurrentOne() throws {
        let store = TileContentStore()
        let unedited = makeDetail(path: "a.jpg", thumbnailPath: "t.jpg", size: 10, mtime: 1)
        let edited = makeDetail(path: "a.jpg", thumbnailPath: "t.jpg", size: 20, mtime: 2)
        _ = store.mergeDetail(unedited)
        let before = makeImage()
        _ = store.applyDecoded(before, key: MediaAssetTilePresentation.imageContentKey(unedited), for: unedited.id)
        #expect(store.currentImage(for: unedited.id) === before)

        _ = store.mergeDetail(edited)
        #expect(try #require(store.content(for: edited.id)).image === before, "the tile keeps painting")
        #expect(store.currentImage(for: edited.id) == nil)

        let after = makeImage()
        _ = store.applyDecoded(after, key: MediaAssetTilePresentation.imageContentKey(edited), for: edited.id)
        #expect(store.currentImage(for: edited.id) === after)
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

    // Validates: APP-015, ENR-010
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

    // Validates: APP-015
    /// Off screen the store keeps `offscreenLimit` tiles, the most recently used, entry and
    /// image: tiles scrolled further away are dropped, the visible ones never.
    @Test func offScreenTilesBeyondTheLimitAreDroppedLeastRecentFirst() {
        let image = makeImage(width: 8)
        let store = TileContentStore()
        let visible = (0 ..< 100).map { makeDetail(path: "v\($0).jpg", thumbnailPath: "v\($0).t") }
        for detail in visible {
            store.mergeDetail(detail)
            store.applyDecoded(image, key: MediaAssetTilePresentation.imageContentKey(detail), for: detail.id)
        }
        store.pinVisible(Set(visible.map(\.id)))
        #expect(store.offscreenLimit == TileContentStore.offscreenScreens * 100)
        let scrolledPast = (0 ..< 3000).map { makeDetail(path: "s\($0).jpg", thumbnailPath: "s\($0).t") }
        for detail in scrolledPast {
            store.mergeDetail(detail)
            store.applyDecoded(image, key: MediaAssetTilePresentation.imageContentKey(detail), for: detail.id)
        }

        #expect(store.count >= 100 + store.offscreenLimit)
        #expect(store.count <= 100 + store.offscreenLimit * 5 / 4)
        #expect(visible.allSatisfy { store.content(for: $0.id)?.image != nil })
        #expect(store.content(for: scrolledPast[0].id) == nil)
        #expect(store.content(for: scrolledPast[scrolledPast.count - 1].id)?.image != nil)
        #expect(store.imageBytes == store.count * TileContentStore.byteCost(of: image))
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

    /// A new visible set reports once every one of its tiles holds a thumbnail; repinning the
    /// same set keeps its wait, and a set already painted reports at once.
    @Test func aVisibleSetReportsWhenEveryTileHoldsAThumbnail() {
        let store = TileContentStore()
        var reports: [VisibleThumbnailsReport] = []
        store.onVisibleThumbnailsComplete = { reports.append($0) }
        let first = makeDetail(path: "a.jpg", thumbnailPath: "a-t.jpg")
        let second = makeDetail(path: "b.jpg", thumbnailPath: "b-t.jpg")
        _ = store.mergeDetail(first)
        _ = store.mergeDetail(second)

        store.pinVisible([first.id, second.id])
        _ = store.applyDecoded(makeImage(), key: MediaAssetTilePresentation.imageContentKey(first), for: first.id)
        store.pinVisible([first.id, second.id])
        #expect(reports.isEmpty)
        _ = store.applyDecoded(makeImage(), key: MediaAssetTilePresentation.imageContentKey(second), for: second.id)
        #expect(reports.map(\.revision) == [1])
        #expect(reports.first?.visible == 2)

        store.pinVisible([first.id])
        #expect(reports.map(\.revision) == [1, 2])
    }

    /// A tile whose asset has no thumbnail yet settles once its detail is read, and the report
    /// counts it; a stub bound before any read never settles a set.
    @Test func aTileWithNoThumbnailYetSettlesOnceItsDetailIsRead() {
        let store = TileContentStore()
        var reports: [VisibleThumbnailsReport] = []
        store.onVisibleThumbnailsComplete = { reports.append($0) }
        let painted = makeDetail(path: "a.jpg", thumbnailPath: "a-t.jpg")
        let unrendered = makeDetail(path: "b.mp4", thumbnailPath: nil, kind: .video)
        _ = store.mergeDetail(painted)
        store.holdUnreadDetail(for: unrendered.id)

        store.pinVisible([painted.id, unrendered.id])
        _ = store.applyDecoded(makeImage(), key: MediaAssetTilePresentation.imageContentKey(painted), for: painted.id)
        #expect(reports.isEmpty)
        #expect(store.settledVisible == nil)

        _ = store.mergeDetail(unrendered)
        #expect(reports.count == 1)
        #expect(reports.first?.ids == [painted.id, unrendered.id])
        #expect(reports.first?.withoutThumbnail == 1)
        #expect(store.settledVisible == reports.first)

        // The same set repinned keeps the report that settled it; a new set clears it.
        store.pinVisible([painted.id, unrendered.id])
        #expect(store.settledVisible == reports.first)
        store.pinVisible([painted.id])
        #expect(store.settledVisible?.ids == [painted.id])
        #expect(reports.count == 2)
    }

    /// A thumbnail whose decode found no image settles its tile until a newer key arrives.
    @Test func anUndecodableThumbnailSettlesItsTile() {
        let store = TileContentStore()
        var reports: [VisibleThumbnailsReport] = []
        store.onVisibleThumbnailsComplete = { reports.append($0) }
        let broken = makeDetail(path: "c.jpg", thumbnailPath: "c-t.jpg")
        _ = store.mergeDetail(broken)
        store.pinVisible([broken.id])
        #expect(reports.isEmpty)

        store.noteUndecodable(key: "an older key", for: broken.id)
        #expect(reports.isEmpty)
        store.noteUndecodable(key: MediaAssetTilePresentation.imageContentKey(broken), for: broken.id)
        #expect(reports.map(\.withoutThumbnail) == [1])
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
private func makeImage(width: Int = 8) -> DisplayImage {
    DisplayImage.fixture(width: width)
}
