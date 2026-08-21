import CoreGraphics
import Foundation

// Controller-owned tile content guide
//
// `TileContentStore` is the single source of truth for what any on-screen tile showing
// a given `MediaAssetID` must display, and the only decoded-image owner in the grid
// paint path. The monotonic rule lives here: `image` only advances to a newer decode
// for the same asset and never regresses to `nil` while the entry remains pinned.
// Unpinned images may be dropped under the byte budget (re-decoded on rebind — the
// allowed miss path); pinned (visible) images are never dropped. Tiles render a
// `TileContent` value idempotently and hold no asset-identity paint logic of their
// own — the no-blank grid invariant holds by construction.
//
// Entry count is bounded by scope via `prune(to:)`. Decoded-image memory is bounded by
// `imageByteBudget` via pin-aware `enforceImageBudget()`. Visible IDs are pinned
// against both prune and budget eviction so a painted thumbnail cannot disappear
// merely because an off-screen row was trimmed or the budget was under pressure.
// Pinning has two shapes: `pinVisible(_:)` replaces the whole set at pass boundaries
// (reconfigure, merge, structural-apply completion); `pin(_:)` additively pins one id
// while a tile is being bound mid-pass (dequeue / makeItem).

nonisolated struct TileContent: Equatable {
    var detail: MediaTileDetail
    var imageKey: String
    var image: CGImage?
    /// Cached `videoBadgeText` for the current detail; recomputed only when
    /// duration or kind changes so bind does not re-format every pass.
    var formattedDuration: String?

    static func == (lhs: TileContent, rhs: TileContent) -> Bool {
        lhs.detail == rhs.detail
            && lhs.imageKey == rhs.imageKey
            && lhs.image === rhs.image
            && lhs.formattedDuration == rhs.formattedDuration
    }
}

/// Classification returned by store mutations so the tile can fade only a first async
/// paint or a same-asset newer-thumbnail replacement — never a sync cache/store repaint.
nonisolated enum TileContentChange: Equatable {
    case unchanged
    case detailOnly
    case firstImage
    case replacedImage
    /// Detail's image key advanced; existing `image` (if any) stays until `applyDecoded`.
    case awaitingDecode(retainsImage: Bool)
}

@MainActor
final class TileContentStore {
    private struct Entry {
        var content: TileContent
        var accessStamp: UInt64
        /// Exact byte cost of `content.image` when non-nil; 0 when image is nil.
        var imageCost: Int
    }

    private var entries: [MediaAssetID: Entry] = [:]
    private var accessClock: UInt64 = 0
    private var pinnedIDs: Set<MediaAssetID> = []
    private(set) var imageBytes: Int = 0
    let imageByteBudget: Int

    init(imageByteBudget: Int = 256 * 1024 * 1024) {
        self.imageByteBudget = max(1, imageByteBudget)
    }

    var count: Int {
        entries.count
    }

    func content(for id: MediaAssetID) -> TileContent? {
        guard var entry = entries[id] else {
            return nil
        }
        entry.accessStamp = nextAccessStamp()
        entries[id] = entry
        return entry.content
    }

    /// Replaces the pinned set at a pass boundary so prune/budget cannot drop painted
    /// images for currently visible identities.
    func pinVisible(_ ids: Set<MediaAssetID>) {
        pinnedIDs = ids
    }

    /// Additively pins one id (a tile being bound mid-pass). `pinVisible(_:)` replaces
    /// the whole set at the next pass boundary.
    func pin(_ id: MediaAssetID) {
        pinnedIDs.insert(id)
    }

    @discardableResult
    func mergeDetail(_ detail: MediaTileDetail) -> TileContentChange {
        let id = detail.id
        let key = MediaAssetTilePresentation.imageContentKey(detail)
        let stamp = nextAccessStamp()

        guard var entry = entries[id] else {
            entries[id] = Entry(
                content: TileContent(
                    detail: detail,
                    imageKey: key,
                    image: nil,
                    formattedDuration: MediaAssetTilePresentation.videoBadgeText(detail)
                ),
                accessStamp: stamp,
                imageCost: 0
            )
            if detail.thumbnailPath != nil {
                return .awaitingDecode(retainsImage: false)
            }
            return .detailOnly
        }

        let previous = entry.content
        entry.content.detail = detail
        if previous.detail.durationSeconds != detail.durationSeconds
            || previous.detail.bestKind != detail.bestKind
        {
            entry.content.formattedDuration = MediaAssetTilePresentation.videoBadgeText(detail)
        }
        entry.accessStamp = stamp

        if key == previous.imageKey {
            entries[id] = entry
            return previous.detail == detail ? .unchanged : .detailOnly
        }

        // Key advanced: keep any painted image (monotonic) and ask the caller to decode.
        entry.content.imageKey = key
        entries[id] = entry
        if detail.thumbnailPath == nil {
            return .detailOnly
        }
        return .awaitingDecode(retainsImage: previous.image != nil)
    }

    @discardableResult
    func mergeDetails(_ details: [MediaAssetID: MediaTileDetail]) -> [MediaAssetID: TileContentChange] {
        var changes: [MediaAssetID: TileContentChange] = [:]
        for (id, detail) in details {
            precondition(detail.id == id)
            changes[id] = mergeDetail(detail)
        }
        return changes
    }

    /// Inserts a decoded image only when `key` still matches the store's current key for
    /// that asset — the stale-completion check that used to live on the tile.
    @discardableResult
    func applyDecoded(_ image: CGImage, key: String, for id: MediaAssetID) -> TileContentChange {
        guard var entry = entries[id] else {
            return .unchanged
        }
        guard entry.content.imageKey == key else {
            return .unchanged
        }
        let hadImage = entry.content.image != nil
        if hadImage, entry.content.image === image {
            entry.accessStamp = nextAccessStamp()
            entries[id] = entry
            return .unchanged
        }
        imageBytes -= entry.imageCost
        let cost = Self.byteCost(of: image)
        entry.content.image = image
        entry.imageCost = cost
        imageBytes += cost
        entry.accessStamp = nextAccessStamp()
        entries[id] = entry
        enforceImageBudget()
        return hadImage ? .replacedImage : .firstImage
    }

    /// Drops entries whose IDs are neither live nor pinned. Subtracts image bytes for
    /// any dropped images, then enforces the remaining budget.
    func prune(to liveIDs: Set<MediaAssetID>) {
        let keep = liveIDs.union(pinnedIDs)
        var next: [MediaAssetID: Entry] = [:]
        next.reserveCapacity(min(entries.count, keep.count))
        for (id, entry) in entries {
            if keep.contains(id) {
                next[id] = entry
            } else {
                imageBytes -= entry.imageCost
            }
        }
        entries = next
        enforceImageBudget()
    }

    /// Moves painted tile content from old identities to new ones before the grid
    /// publishes remapped ordered IDs (APP-015 never-blank invariant).
    func applyIdentityRemapBatch(_ batch: CatalogIdentityRemapBatch) {
        guard !batch.remaps.isEmpty else { return }
        var next = entries
        var nextPinned = pinnedIDs
        for remap in batch.remaps {
            if let entry = next.removeValue(forKey: remap.oldID) {
                var moved = entry
                moved.content.detail = MediaTileDetail(
                    libraryRootPath: remap.newID.libraryRootPath,
                    relativePath: remap.newID.relativePath,
                    byteSize: moved.content.detail.byteSize,
                    thumbnailPath: moved.content.detail.thumbnailPath,
                    bestKind: moved.content.detail.bestKind,
                    durationSeconds: moved.content.detail.durationSeconds,
                    enrichedSourceSize: moved.content.detail.enrichedSourceSize,
                    enrichedSourceMTimeSeconds: moved.content.detail.enrichedSourceMTimeSeconds,
                    mediaChoice: moved.content.detail.mediaChoice
                )
                // Keep imageKey/image so the painted thumbnail survives the identity change.
                next[remap.newID] = moved
            }
            if nextPinned.remove(remap.oldID) != nil {
                nextPinned.insert(remap.newID)
            }
        }
        entries = next
        pinnedIDs = nextPinned
    }

    /// While over budget, nils the LRU unpinned entry that still has an image (keeps
    /// detail + imageKey). Never touches a pinned entry's image.
    func enforceImageBudget() {
        while imageBytes > imageByteBudget {
            guard let evicted = entries
                .filter({ !pinnedIDs.contains($0.key) && $0.value.content.image != nil })
                .min(by: { $0.value.accessStamp < $1.value.accessStamp })
            else {
                return
            }
            var entry = evicted.value
            imageBytes -= entry.imageCost
            entry.content.image = nil
            entry.imageCost = 0
            entries[evicted.key] = entry
        }
    }

    private func nextAccessStamp() -> UInt64 {
        accessClock &+= 1
        return accessClock
    }

    /// Hit test for pane thumbnail: returns the decoded image if the store already
    /// holds one for this asset, without triggering a decode. Used by PaneThumbnailView
    /// to avoid re-decoding an image the filmstrip is already showing.
    func image(for id: MediaAssetID) -> CGImage? {
        content(for: id)?.image
    }

    /// Warm the store with a newly decoded image for the pane. The detail's imageKey
    /// must be current; callers should have merged the detail first if needed.
    func warm(id: MediaAssetID, image: CGImage, detail: MediaTileDetail) {
        let key = MediaAssetTilePresentation.imageContentKey(detail)
        // Ensure an entry exists for this detail; mergeDetail is idempotent.
        _ = mergeDetail(detail)
        _ = applyDecoded(image, key: key, for: id)
    }

    static func byteCost(of image: CGImage) -> Int {
        let rowCost = image.bytesPerRow * image.height
        if rowCost > 0 {
            return rowCost
        }
        return max(1, image.width * image.height * 4)
    }
}
