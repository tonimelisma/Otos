import CoreGraphics
import Foundation

// Controller-owned tile content guide
//
// `TileContentStore` is the single source of truth for what any on-screen tile showing
// a given `MediaAssetID` must display. The monotonic rule lives here: `image` only
// advances to a newer decode for the same asset and never regresses to `nil` while the
// entry remains. Tiles render a `TileContent` value idempotently and hold no asset-
// identity paint logic of their own — the no-blank grid invariant holds by construction.
//
// `MediaTileImageCache` remains the decoded-byte LRU; store entries reference the same
// `CGImage` instances. Visible IDs are pinned against prune eviction so a painted
// thumbnail cannot disappear merely because the sticky map trimmed an off-screen row.

nonisolated struct TileContent: Equatable {
    var detail: MediaTileDetail
    var imageKey: String
    var image: CGImage?

    static func == (lhs: TileContent, rhs: TileContent) -> Bool {
        lhs.detail == rhs.detail
            && lhs.imageKey == rhs.imageKey
            && lhs.image === rhs.image
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
    }

    private var entries: [MediaAssetID: Entry] = [:]
    private var accessClock: UInt64 = 0
    private var pinnedIDs: Set<MediaAssetID> = []
    let limit: Int

    init(limit: Int = 4096) {
        self.limit = limit
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

    /// Pins currently visible identities so prune/LRU cannot drop their painted images.
    func pinVisible(_ ids: Set<MediaAssetID>) {
        pinnedIDs = ids
    }

    @discardableResult
    func mergeDetail(_ detail: MediaTileDetail) -> TileContentChange {
        let id = detail.id
        let key = MediaAssetTilePresentation.imageContentKey(detail)
        let stamp = nextAccessStamp()

        guard var entry = entries[id] else {
            entries[id] = Entry(
                content: TileContent(detail: detail, imageKey: key, image: nil),
                accessStamp: stamp
            )
            evictIfNeeded()
            if detail.thumbnailPath != nil {
                return .awaitingDecode(retainsImage: false)
            }
            return .detailOnly
        }

        let previous = entry.content
        entry.content.detail = detail
        entry.accessStamp = stamp

        if key == previous.imageKey {
            entries[id] = entry
            return previous.detail == detail ? .unchanged : .detailOnly
        }

        // Key advanced: keep any painted image (monotonic) and ask the caller to decode.
        entry.content.imageKey = key
        entries[id] = entry
        evictIfNeeded()
        if detail.thumbnailPath == nil {
            return previous.image == nil ? .detailOnly : .detailOnly
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
        entry.content.image = image
        entry.accessStamp = nextAccessStamp()
        entries[id] = entry
        return hadImage ? .replacedImage : .firstImage
    }

    /// Drops entries whose IDs are neither live nor pinned, then LRU-trims to `limit`
    /// without evicting pinned IDs.
    func prune(to liveIDs: Set<MediaAssetID>) {
        let keep = liveIDs.union(pinnedIDs)
        entries = entries.filter { keep.contains($0.key) }
        evictIfNeeded()
    }

    private func nextAccessStamp() -> UInt64 {
        accessClock &+= 1
        return accessClock
    }

    private func evictIfNeeded() {
        while entries.count > limit {
            guard let evicted = entries
                .filter({ !pinnedIDs.contains($0.key) })
                .min(by: { $0.value.accessStamp < $1.value.accessStamp })?
                .key
            else {
                return
            }
            entries[evicted] = nil
        }
    }
}
