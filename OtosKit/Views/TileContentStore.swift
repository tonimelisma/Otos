import CoreGraphics
import Foundation
import OSLog

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
// What the store keeps is what it is designed to keep: the visible tiles (pinned) and, off
// screen, `offscreenScreens` screens of the visible set's size, the most recently used: the
// preheat look-ahead's four (two either way) and twelve scrolled back (`enforceRetention`).
// A tile that scrolled or moved further away than that is dropped, entry and image, and is
// read and decoded again if it comes back: placeholder content before its first paint *on
// screen again*, never on a tile that is on screen. `prune(keeping:)` drops what left the
// scope after a whole apply, and `imageByteBudget` caps the decoded images when the kept
// tiles' pixels add up past it (`enforceImageBudget()`). Visible IDs are pinned against all
// three, so a painted thumbnail cannot disappear while its tile is on screen.
// Pinning has two shapes: `pinVisible(_:)` replaces the whole set at pass boundaries
// (reconfigure, merge, structural-apply completion); `pin(_:)` additively pins one id
// while a tile is being bound mid-pass (dequeue / makeItem).

nonisolated struct TileContent: Equatable {
    var detail: MediaTileDetail
    var imageKey: String
    /// The thumbnail the tile paints: the decode of `imageKey`, or an older one it keeps until
    /// that decode lands, as a painted tile never blanks.
    var image: DisplayImage?
    /// The key `image` was decoded for; `imageKey` when it is current.
    var imageDecodedKey: String?
    /// Cached `videoBadgeText` for the current detail; recomputed only when
    /// duration or kind changes so bind does not re-format every pass.
    var formattedDuration: String?

    static func == (lhs: TileContent, rhs: TileContent) -> Bool {
        lhs.detail == rhs.detail
            && lhs.imageKey == rhs.imageKey
            && lhs.image?.cgImage === rhs.image?.cgImage
            && lhs.imageDecodedKey == rhs.imageDecodedKey
            && lhs.formattedDuration == rhs.formattedDuration
    }
}

/// Every visible tile shows what the catalog holds for it now: its detail has been read, and it
/// holds a thumbnail or its asset has none yet. `revision` counts these reports, `ids` is the
/// visible set they settle, `withoutThumbnail` how many of its tiles have no thumbnail to show
/// yet (not rendered, or its file would not decode), and `milliseconds` runs from the pass
/// boundary that made this set visible.
nonisolated struct VisibleThumbnailsReport: Equatable, Sendable {
    let revision: UInt64
    let ids: Set<MediaAssetID>
    let withoutThumbnail: Int
    let milliseconds: Int

    var visible: Int {
        ids.count
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
        /// The detail came from a catalog read, not the stub a tile is bound with before one.
        var detailRead: Bool
        /// The image key whose decode found no image, so the tile has nothing newer to show.
        var undecodableKey: String?

        /// The tile shows what the catalog holds now: an image, or the fact that none is
        /// there to show yet.
        var isSettled: Bool {
            guard detailRead else {
                return false
            }
            return content.image != nil || content.detail.thumbnailPath == nil
                || undecodableKey == content.imageKey
        }
    }

    /// The visible tiles not yet settled since the visible set last changed.
    private struct VisibleWait {
        let ids: Set<MediaAssetID>
        var unsettled: Set<MediaAssetID>
        let since: ContinuousClock.Instant
    }

    private var entries: [MediaAssetID: Entry] = [:]
    private var accessClock: UInt64 = 0
    private var pinnedIDs: Set<MediaAssetID> = []
    private(set) var imageBytes: Int = 0
    let imageByteBudget: Int
    /// The visible set the last pass boundary pinned, and what of it still has no image.
    private var trackedVisible: Set<MediaAssetID> = []
    private var visibleWait: VisibleWait?
    private var visibleReports: UInt64 = 0
    /// The last report, while the visible set it settled is still the visible set.
    private(set) var settledVisible: VisibleThumbnailsReport?
    /// Told each time every visible tile is settled, once per visible set: the fact a scroll
    /// waits for (`op=ui.mediaGrid.visibleThumbnails`).
    var onVisibleThumbnailsComplete: ((VisibleThumbnailsReport) -> Void)?
    /// The identity table the tiles' IDs are places in, which their paths are read back from:
    /// the process's, or a test's own that counts what a bind pays (`countingSteps`).
    private let identities: MediaAssetIdentityTable

    /// Off-screen tiles the store keeps, in screens of the visible set's size: the preheat
    /// look-ahead decodes two screens either way of the visible one (`preheatLookahead`), and
    /// twelve more keep what was scrolled past, so a scroll back over them paints from the store.
    /// With 256-pixel thumbnails the two bounds keep about as many tiles, 1,000 to 1,300.
    static let offscreenScreens = 16
    /// The visible set's size the limit counts with when fewer tiles are pinned: a grid not yet
    /// laid out, or a pane's filmstrip, which pins none.
    static let minimumScreenTiles = 64

    init(imageByteBudget: Int = 256 * 1024 * 1024, identities: MediaAssetIdentityTable = .shared) {
        self.imageByteBudget = max(1, imageByteBudget)
        self.identities = identities
    }

    var count: Int {
        entries.count
    }

    /// The off-screen tiles the store keeps at most: `offscreenScreens` screens of the visible
    /// set's size.
    var offscreenLimit: Int {
        Self.offscreenScreens * max(pinnedIDs.count, Self.minimumScreenTiles)
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
        trackVisible(ids)
    }

    /// A new visible set starts a wait for its tiles to settle; the same set repinned at
    /// another pass boundary keeps the wait it has, or the report it already settled. A tile
    /// waits only for what the catalog can answer now — its detail read, and the decode of a
    /// thumbnail it names — never for a thumbnail not yet rendered, which the report counts.
    private func trackVisible(_ ids: Set<MediaAssetID>) {
        guard ids != trackedVisible else {
            return
        }
        trackedVisible = ids
        settledVisible = nil
        if let visibleWait, !visibleWait.unsettled.isEmpty {
            OtosLog.ui.debugOperation("ui.mediaGrid.visibleThumbnails", phase: "superseded", fields: [
                "visible": "\(visibleWait.ids.count)",
                "unsettled": "\(visibleWait.unsettled.count)",
                "ms": "\(DiagnosticsTiming.milliseconds(since: visibleWait.since))",
            ])
        }
        guard !ids.isEmpty else {
            visibleWait = nil
            return
        }
        visibleWait = VisibleWait(
            ids: ids,
            unsettled: ids.filter { entries[$0]?.isSettled != true },
            since: .now
        )
        completeVisibleWaitIfSettled()
    }

    /// Takes `id` off the visible wait when its tile has settled.
    private func noteSettlement(of id: MediaAssetID) {
        guard visibleWait?.unsettled.contains(id) == true, entries[id]?.isSettled == true else {
            return
        }
        visibleWait?.unsettled.remove(id)
        completeVisibleWaitIfSettled()
    }

    private func completeVisibleWaitIfSettled() {
        guard let wait = visibleWait, wait.unsettled.isEmpty else {
            return
        }
        visibleWait = nil
        visibleReports &+= 1
        let report = VisibleThumbnailsReport(
            revision: visibleReports,
            ids: wait.ids,
            withoutThumbnail: wait.ids.count { entries[$0]?.content.image == nil },
            milliseconds: DiagnosticsTiming.milliseconds(since: wait.since)
        )
        settledVisible = report
        OtosLog.ui.debugOperation("ui.mediaGrid.visibleThumbnails", phase: "complete", fields: [
            "visible": "\(report.visible)",
            "withoutThumbnail": "\(report.withoutThumbnail)",
            "ms": "\(report.milliseconds)",
        ])
        onVisibleThumbnailsComplete?(report)
    }

    /// Additively pins one id (a tile being bound mid-pass). `pinVisible(_:)` replaces
    /// the whole set at the next pass boundary.
    func pin(_ id: MediaAssetID) {
        pinnedIDs.insert(id)
    }

    /// Merges a detail the catalog returned: the tile now knows what it should show.
    @discardableResult
    func mergeDetail(_ detail: MediaTileDetail) -> TileContentChange {
        let change = merge(detail, read: true)
        noteSettlement(of: id(of: detail))
        return change
    }

    /// Holds the stub a tile is bound with before its detail is read. It never settles the
    /// tile: only a catalog read says whether a thumbnail exists.
    func holdUnreadDetail(for id: MediaAssetID) {
        guard entries[id] == nil else {
            return
        }
        _ = merge(MediaTileDetail(libraryRootPath: identities.libraryRootPath(of: id), relativePath: identities.relativePath(of: id)), read: false)
    }

    /// The ID `detail` names, in this store's table.
    private func id(of detail: MediaTileDetail) -> MediaAssetID {
        identities.id(detail.libraryRootPath, detail.relativePath)
    }

    private func merge(_ detail: MediaTileDetail, read: Bool) -> TileContentChange {
        let id = id(of: detail)
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
                imageCost: 0,
                detailRead: read,
                undecodableKey: nil
            )
            enforceRetention()
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
        entry.detailRead = entry.detailRead || read

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
            precondition(self.id(of: detail) == id)
            changes[id] = mergeDetail(detail)
        }
        return changes
    }

    /// The held tiles that are copies of a photo (ADR 0054) with one of `keys`, each with
    /// its key: a walk of the entries held, which the scope bounds.
    func copies(among keys: Set<PhotoCopyKey>) -> [MediaAssetID: PhotoCopyKey] {
        var copies: [MediaAssetID: PhotoCopyKey] = [:]
        for (id, entry) in entries {
            if let key = entry.content.detail.copyKey, keys.contains(key) {
                copies[id] = key
            }
        }
        return copies
    }

    /// Shows `choice` on the tile of `id`, if one is held, without touching its image: a
    /// choice is not part of the image key. True when the tile's choice changed.
    @discardableResult
    func setMediaChoice(_ choice: MediaChoice, for id: MediaAssetID) -> Bool {
        guard var entry = entries[id], entry.content.detail.mediaChoice != choice else {
            return false
        }
        entry.content.detail = entry.content.detail.with(mediaChoice: choice)
        entries[id] = entry
        return true
    }

    /// Inserts a decoded image only when `key` still matches the store's current key for
    /// that asset. The store, not the tile, owns this stale-completion check.
    @discardableResult
    func applyDecoded(_ image: DisplayImage, key: String, for id: MediaAssetID) -> TileContentChange {
        guard var entry = entries[id] else {
            return .unchanged
        }
        guard entry.content.imageKey == key else {
            return .unchanged
        }
        let hadImage = entry.content.image != nil
        if hadImage, entry.content.image?.cgImage === image.cgImage {
            entry.accessStamp = nextAccessStamp()
            entries[id] = entry
            return .unchanged
        }
        imageBytes -= entry.imageCost
        let cost = Self.byteCost(of: image)
        entry.content.image = image
        entry.content.imageDecodedKey = key
        entry.imageCost = cost
        imageBytes += cost
        entry.accessStamp = nextAccessStamp()
        entries[id] = entry
        enforceImageBudget()
        noteSettlement(of: id)
        return hadImage ? .replacedImage : .firstImage
    }

    /// Records that the decode of `key` found no image for `id`: until a newer key arrives
    /// the tile has nothing newer to show, so it no longer holds the visible wait open.
    func noteUndecodable(key: String, for id: MediaAssetID) {
        guard var entry = entries[id], entry.content.imageKey == key else {
            return
        }
        entry.undecodableKey = key
        entries[id] = entry
        noteSettlement(of: id)
    }

    /// Drops entries whose IDs are neither live nor pinned. Subtracts image bytes for
    /// any dropped images, then enforces the remaining budget.
    ///
    /// Liveness is a question asked per stored entry, not a set handed in: the grid answers
    /// it from its structure's identity index, so a prune costs the entries held, not a
    /// copy of every identity in the library.
    func prune(keeping isLive: (MediaAssetID) -> Bool) {
        var next: [MediaAssetID: Entry] = [:]
        next.reserveCapacity(entries.count)
        for (id, entry) in entries {
            if isLive(id) || pinnedIDs.contains(id) {
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
                    libraryRootPath: identities.libraryRootPath(of: remap.newID),
                    relativePath: identities.relativePath(of: remap.newID),
                    byteSize: moved.content.detail.byteSize,
                    thumbnailPath: moved.content.detail.thumbnailPath,
                    bestKind: moved.content.detail.bestKind,
                    durationSeconds: moved.content.detail.durationSeconds,
                    renderedSourceSize: moved.content.detail.renderedSourceSize,
                    renderedSourceMTimeSeconds: moved.content.detail.renderedSourceMTimeSeconds,
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

    /// While over budget, nils the least recently used unpinned entries that still have an
    /// image (keeping detail + imageKey), oldest first. Never touches a pinned entry's image.
    /// One sort of the held entries, which `enforceRetention` bounds.
    func enforceImageBudget() {
        guard imageBytes > imageByteBudget else {
            return
        }
        let candidates = entries
            .filter { !pinnedIDs.contains($0.key) && $0.value.content.image != nil }
            .sorted { $0.value.accessStamp < $1.value.accessStamp }
        for (id, candidate) in candidates {
            guard imageBytes > imageByteBudget else {
                return
            }
            var entry = candidate
            imageBytes -= entry.imageCost
            entry.content.image = nil
            entry.content.imageDecodedKey = nil
            entry.imageCost = 0
            entries[id] = entry
        }
    }

    /// Drops the least recently used off-screen entries, image and all, once more than
    /// `offscreenLimit` are held, down to the limit. Run when an entry is added; it lets a
    /// quarter of the limit gather first, so the one sort of the held entries it costs is
    /// shared by that many additions. Never drops a pinned (visible) entry.
    private func enforceRetention() {
        let limit = offscreenLimit
        guard entries.count > pinnedIDs.count + limit + limit / 4 else {
            return
        }
        let offscreen = entries
            .filter { !pinnedIDs.contains($0.key) }
            .sorted { $0.value.accessStamp < $1.value.accessStamp }
        for (id, entry) in offscreen.prefix(max(0, offscreen.count - limit)) {
            imageBytes -= entry.imageCost
            entries[id] = nil
        }
    }

    private func nextAccessStamp() -> UInt64 {
        accessClock &+= 1
        return accessClock
    }

    /// The asset's current thumbnail, for a surface other than its grid tile (the loupe's
    /// placeholder, a cover, a duplicate), so it is not decoded again: nil while the store
    /// holds none, or only an older one its tile keeps painted until the current decode lands.
    /// An edited photo's pre-edit thumbnail is never handed out as its picture (owner,
    /// 2026-11-19: "it shows in the loupe the unedited version for a subsecond").
    func currentImage(for id: MediaAssetID) -> DisplayImage? {
        guard let content = content(for: id), content.imageDecodedKey == content.imageKey else { return nil }
        return content.image
    }

    /// Warm the store with a newly decoded image for the pane. The detail's imageKey
    /// must be current; callers should have merged the detail first if needed.
    func warm(id: MediaAssetID, image: DisplayImage, detail: MediaTileDetail) {
        let key = MediaAssetTilePresentation.imageContentKey(detail)
        // Ensure an entry exists for this detail; mergeDetail is idempotent.
        _ = mergeDetail(detail)
        _ = applyDecoded(image, key: key, for: id)
    }

    static func byteCost(of image: DisplayImage) -> Int {
        max(1, image.byteCount)
    }
}
