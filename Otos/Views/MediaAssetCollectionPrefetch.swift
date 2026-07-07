import AppKit
import Foundation
import OSLog

private struct PreheatImageContext {
    let thumbnailDirectory: URL?
    let imageCache: MediaTileImageCache?
}

// Collection preheat guide
//
// AppKit prefetch callbacks and the scroll-driven look-ahead share one path:
// fault a burst of details by identity, merge it into the sticky detail map, and
// warm the decoded-image cache off the main actor when a thumbnail already
// exists. Bursts are newest-value work: obsolete look-ahead is cancelled instead
// of queued because only the next viewport is useful, while partial AppKit
// cancellation narrows the active ID set without throwing away still-useful IDs.

extension MediaAssetCollectionViewController: NSCollectionViewPrefetching {
    func collectionView(
        _: NSCollectionView,
        prefetchItemsAt indexPaths: [IndexPath]
    ) {
        let ids = idsForPrefetch(indexPaths)
        guard !ids.isEmpty else {
            return
        }
        GridTelemetry.recordAppKitPrefetchRequest(idCount: ids.count)
        OtosSignpost.ui.emitEvent("MediaGridPrefetchRequested")
        OtosLog.ui.debug("Media grid prefetch requested count=\(ids.count, privacy: .public)")
        startPreheat(for: ids, reason: "prefetch")
    }

    func collectionView(
        _: NSCollectionView,
        cancelPrefetchingForItemsAt indexPaths: [IndexPath]
    ) {
        let ids = idsForPrefetch(indexPaths)
        cancelPreheat(for: ids)
        guard !ids.isEmpty else {
            return
        }
        OtosSignpost.ui.emitEvent("MediaGridPrefetchCancelled")
        OtosLog.ui.debug("Media grid prefetch cancelled count=\(ids.count, privacy: .public)")
    }

    private func idsForPrefetch(_ indexPaths: [IndexPath]) -> [MediaAssetID] {
        uniqueIDs(indexPaths.compactMap { dataSource.itemIdentifier(for: $0) })
    }

    private func uniqueIDs(_ ids: [MediaAssetID]) -> [MediaAssetID] {
        var seen = Set<MediaAssetID>()
        return ids.filter { seen.insert($0).inserted }
    }

    private func startPreheat(for ids: [MediaAssetID], reason: String) {
        guard let detailReader else {
            return
        }
        let ids = uniqueIDs(ids)
        let requestedIDs = Set(ids)
        guard !requestedIDs.isEmpty else {
            return
        }
        guard !canReuseCurrentPreheat(for: requestedIDs) else {
            return
        }
        preheatGeneration += 1
        let generation = preheatGeneration
        preheatTask?.cancel()
        preheatIDs = requestedIDs
        let imageContext = PreheatImageContext(
            thumbnailDirectory: thumbnailDirectory,
            imageCache: imageCache
        )
        preheatTask = Task.detached(priority: .utility) { [weak self, detailReader] in
            await self?.runPreheat(
                ids: ids,
                generation: generation,
                reason: reason,
                detailReader: detailReader,
                imageContext: imageContext
            )
        }
    }

    private func canReuseCurrentPreheat(for requestedIDs: Set<MediaAssetID>) -> Bool {
        preheatTask != nil && requestedIDs.isSubset(of: preheatIDs)
    }

    private nonisolated func runPreheat(
        ids: [MediaAssetID],
        generation: Int,
        reason: String,
        detailReader: MediaTileDetailReader,
        imageContext: PreheatImageContext
    ) async {
        let details = await detailReader.details(for: ids)
        guard !Task.isCancelled else {
            await MainActor.run { self.finishPreheat(generation: generation) }
            return
        }
        GridTelemetry.recordPreheatedIDs(details.count)
        let detailsToWarm = await MainActor.run {
            guard self.preheatGeneration == generation else {
                return [] as [MediaTileDetail]
            }
            let activeDetails = details.filter { id, _ in
                self.preheatIDs.contains(id)
            }
            self.mergeTileDetails(activeDetails, reason: reason)
            return Array(activeDetails.values)
        }
        for detail in detailsToWarm where !Task.isCancelled {
            Self.warmImageCache(
                detail: detail,
                thumbnailDirectory: imageContext.thumbnailDirectory,
                imageCache: imageContext.imageCache
            )
        }
        await MainActor.run { self.finishPreheat(generation: generation) }
    }

    private nonisolated static func warmImageCache(
        detail: MediaTileDetail,
        thumbnailDirectory: URL?,
        imageCache: MediaTileImageCache?
    ) {
        guard !Task.isCancelled,
              let imageCache,
              detail.thumbnailPath != nil
        else {
            return
        }
        let key = MediaAssetTilePresentation.imageContentKey(detail)
        guard imageCache.image(for: key) == nil,
              let image = MediaAssetTilePresentation.decodedThumbnailImage(
                  detail: detail,
                  thumbnailDirectory: thumbnailDirectory
              ),
              !Task.isCancelled
        else {
            return
        }
        imageCache.insert(image, for: key)
    }

    private func cancelPreheat(for ids: [MediaAssetID]) {
        let cancelledIDs = Set(ids)
        guard !cancelledIDs.isEmpty,
              !preheatIDs.isDisjoint(with: cancelledIDs)
        else {
            return
        }
        preheatIDs.subtract(cancelledIDs)
        guard preheatIDs.isEmpty else {
            return
        }
        preheatGeneration += 1
        preheatTask?.cancel()
        preheatTask = nil
    }

    private func finishPreheat(generation: Int) {
        guard preheatGeneration == generation else {
            return
        }
        preheatTask = nil
        preheatIDs = []
    }

    @discardableResult
    func preheatLookahead(reason: String) -> Int {
        let visibleRect = scrollView.contentView.bounds
        guard visibleRect.width > 0, visibleRect.height > 0 else {
            return 0
        }
        let lookaheadRect = visibleRect.insetBy(dx: 0, dy: -visibleRect.height * 2)
        guard let attributes = collectionView.collectionViewLayout?.layoutAttributesForElements(in: lookaheadRect),
              !attributes.isEmpty
        else {
            return 0
        }
        let ids = idsForPrefetch(attributes.compactMap(\.indexPath))
        startPreheat(for: ids, reason: reason)
        GridTelemetry.recordManualPreheatRequest(idCount: ids.count)
        OtosSignpost.ui.emitEvent("MediaGridManualPreheat")
        OtosLog.ui.debug(
            """
            Media grid manual preheat requested count=\(ids.count, privacy: .public) \
            reason=\(reason, privacy: .public)
            """
        )
        return ids.count
    }
}
