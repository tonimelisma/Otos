import AppKit
import Foundation
import OSLog

// Collection preheat guide
//
// AppKit prefetch callbacks and the scroll-driven look-ahead share one path:
// fault details by identity, merge them into the sticky detail map, and warm the
// decoded-image cache off the main actor when a thumbnail already exists.

extension MediaAssetCollectionViewController: NSCollectionViewPrefetching {
    func collectionView(
        _: NSCollectionView,
        prefetchItemsAt indexPaths: [IndexPath]
    ) {
        let ids = idsForPrefetch(indexPaths)
        guard !ids.isEmpty else {
            return
        }
        OtosSignpost.ui.emitEvent("MediaGridPrefetchRequested")
        OtosLog.ui.debug("Media grid prefetch requested count=\(ids.count, privacy: .public)")
        for id in ids where preheatTasks[id] == nil {
            startPreheat(for: id)
        }
    }

    func collectionView(
        _: NSCollectionView,
        cancelPrefetchingForItemsAt indexPaths: [IndexPath]
    ) {
        let ids = idsForPrefetch(indexPaths)
        for id in ids {
            preheatTasks[id]?.cancel()
            preheatTasks[id] = nil
        }
        guard !ids.isEmpty else {
            return
        }
        OtosSignpost.ui.emitEvent("MediaGridPrefetchCancelled")
        OtosLog.ui.debug("Media grid prefetch cancelled count=\(ids.count, privacy: .public)")
    }

    private func idsForPrefetch(_ indexPaths: [IndexPath]) -> [MediaAssetID] {
        indexPaths.compactMap { dataSource.itemIdentifier(for: $0) }
    }

    private func startPreheat(for id: MediaAssetID) {
        guard let detailReader else {
            return
        }
        let thumbnailDirectory = thumbnailDirectory
        let imageCache = imageCache
        preheatTasks[id] = Task.detached(priority: .utility) { [weak self, detailReader] in
            await self?.runPreheat(
                id: id,
                detailReader: detailReader,
                thumbnailDirectory: thumbnailDirectory,
                imageCache: imageCache
            )
        }
    }

    private nonisolated func runPreheat(
        id: MediaAssetID,
        detailReader: MediaTileDetailReader,
        thumbnailDirectory: URL?,
        imageCache: MediaTileImageCache?
    ) async {
        let assets = await detailReader.assets(for: [id])
        guard !Task.isCancelled, let asset = assets[id] else {
            await MainActor.run { self.finishPreheat(for: id) }
            return
        }
        await MainActor.run {
            self.mergeTileDetails([id: asset], reason: "prefetch")
        }
        await warmImageCache(asset: asset, thumbnailDirectory: thumbnailDirectory, imageCache: imageCache)
        await MainActor.run { self.finishPreheat(for: id) }
    }

    private nonisolated func warmImageCache(
        asset: MediaAsset,
        thumbnailDirectory: URL?,
        imageCache: MediaTileImageCache?
    ) async {
        guard !Task.isCancelled,
              let imageCache,
              asset.thumbnailPath != nil
        else {
            return
        }
        let key = MediaAssetTilePresentation.imageContentKey(asset)
        let cached = await MainActor.run {
            imageCache.image(for: key) != nil
        }
        guard !cached,
              let image = MediaAssetTilePresentation.decodedThumbnailImage(
                  asset: asset,
                  thumbnailDirectory: thumbnailDirectory
              ),
              !Task.isCancelled
        else {
            return
        }
        await MainActor.run {
            imageCache.insert(image, for: key)
        }
    }

    private func finishPreheat(for id: MediaAssetID) {
        preheatTasks[id] = nil
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
        for id in ids where preheatTasks[id] == nil {
            startPreheat(for: id)
        }
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
