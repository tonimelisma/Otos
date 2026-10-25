import AppKit
import Foundation
import OSLog

private struct PreheatImageContext {
    let thumbnailDirectory: URL?
}

// Collection preheat guide
//
// AppKit prefetch callbacks and the scroll-driven look-ahead share one path:
// fault a burst of details by identity, merge it into the sticky detail map, and
// decode thumbnails in a `Task.detached` straight into `TileContentStore`. Bursts
// are newest-value work: obsolete look-ahead is cancelled instead of queued
// because only the next viewport is useful, while partial AppKit cancellation
// narrows the active ID set without throwing away still-useful IDs.

extension MediaGridViewController: NSCollectionViewPrefetching {
    enum PreheatLookaheadOutcome {
        case started(count: Int)
        case reused
        case skipped
    }

    func collectionView(
        _: NSCollectionView,
        prefetchItemsAt indexPaths: [IndexPath]
    ) {
        let ids = idsForPrefetch(indexPaths)
        guard !ids.isEmpty else {
            return
        }
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
        OtosLog.ui.debug("Media grid prefetch cancelled count=\(ids.count, privacy: .public)")
    }

    private func idsForPrefetch(_ indexPaths: [IndexPath]) -> [MediaAssetID] {
        uniqueIDs(indexPaths.compactMap { dataSource.itemIdentifier(for: $0) })
    }

    private func uniqueIDs(_ ids: [MediaAssetID]) -> [MediaAssetID] {
        var seen = Set<MediaAssetID>()
        return ids.filter { seen.insert($0).inserted }
    }

    private enum PreheatStartOutcome {
        case started
        case reused
        case skipped
    }

    @discardableResult
    private func startPreheat(for ids: [MediaAssetID], reason: String) -> PreheatStartOutcome {
        guard let detailReader else {
            return .skipped
        }
        let ids = uniqueIDs(ids)
        let requestedIDs = Set(ids)
        guard !requestedIDs.isEmpty else {
            return .skipped
        }
        guard !canReuseCurrentPreheat(for: requestedIDs) else {
            return .reused
        }
        preheatGeneration += 1
        let generation = preheatGeneration
        preheatTask?.cancel()
        preheatIDs = requestedIDs
        let imageContext = PreheatImageContext(thumbnailDirectory: thumbnailDirectory)
        preheatTask = Task.detached(priority: .utility) { [weak self, detailReader] in
            await self?.runPreheat(
                ids: ids,
                generation: generation,
                reason: reason,
                detailReader: detailReader,
                imageContext: imageContext
            )
        }
        return .started
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
        let details: [MediaAssetID: MediaTileDetail]
        do {
            details = try await detailReader.details(for: ids)
        } catch {
            // Nothing is merged or warmed. Finishing the preheat forgets its IDs, so the
            // next lookahead asks again.
            await MainActor.run { self.finishPreheat(generation: generation) }
            return
        }
        guard !Task.isCancelled else {
            await MainActor.run { self.finishPreheat(generation: generation) }
            return
        }
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
        var warmed: [(MediaAssetID, String, CGImage)] = []
        for detail in detailsToWarm where !Task.isCancelled {
            if let result = Self.decodePreheatImage(
                detail: detail,
                thumbnailDirectory: imageContext.thumbnailDirectory
            ) {
                warmed.append(result)
            }
        }
        await MainActor.run {
            for (id, key, image) in warmed {
                let change = self.tileContents.applyDecoded(image, key: key, for: id)
                if change == .firstImage || change == .replacedImage {
                    self.renderVisibleItem(id: id, change: change)
                }
            }
            self.finishPreheat(generation: generation)
        }
    }

    private nonisolated static func decodePreheatImage(
        detail: MediaTileDetail,
        thumbnailDirectory: URL?
    ) -> (MediaAssetID, String, CGImage)? {
        guard !Task.isCancelled,
              detail.thumbnailPath != nil
        else {
            return nil
        }
        let key = MediaAssetTilePresentation.imageContentKey(detail)
        guard let image = MediaAssetTilePresentation.decodedThumbnailImage(
            detail: detail,
            thumbnailDirectory: thumbnailDirectory
        ), !Task.isCancelled else {
            return nil
        }
        return (detail.id, key, image)
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
    func preheatLookahead(reason: String) -> PreheatLookaheadOutcome {
        let visibleRect = scrollView.contentView.bounds
        guard visibleRect.width > 0, visibleRect.height > 0 else {
            return .skipped
        }
        let lookaheadRect = visibleRect.insetBy(dx: 0, dy: -visibleRect.height * 2)
        guard let attributes = collectionView.collectionViewLayout?.layoutAttributesForElements(in: lookaheadRect),
              !attributes.isEmpty
        else {
            return .skipped
        }
        let ids = idsForPrefetch(attributes.compactMap(\.indexPath))
        let outcome = startPreheat(for: ids, reason: reason)
        OtosLog.ui.debug(
            """
            Media grid manual preheat requested count=\(ids.count, privacy: .public) \
            reason=\(reason, privacy: .public)
            """
        )
        switch outcome {
        case .started:
            return .started(count: ids.count)
        case .reused:
            return .reused
        case .skipped:
            return .skipped
        }
    }
}
