import Foundation
import OSLog

/// Cursorless work-selection extension for `EnrichmentCoordinator`.
///
/// Store remains the catalog truth owner: this file only asks for bounded claimed
/// candidates, stages them in the actor-local queue, and drains that queue into free
/// worker slots. The queue is process-local scheduling state; SQLite
/// `enrichment_claimed_until` is the cross-query lease.
extension EnrichmentCoordinator {
    func dequeueEnrichmentWork() async -> [EnrichWork] {
        guard !isShuttingDown else {
            return []
        }
        let availableSlots = enrichConcurrency - inFlightEnrich.count
        guard availableSlots > 0 else {
            return []
        }

        var items = drainClaimedEnrichmentQueue(limit: availableSlots)
        guard items.count < availableSlots else {
            return items
        }

        do {
            let claimLimit = max(claimBatchSize, availableSlots - items.count)
            let candidates = try await claimEnrichmentCandidates(limit: claimLimit)
            enqueueClaimedCandidates(candidates, currentItems: items)
            items.append(contentsOf: drainClaimedEnrichmentQueue(limit: availableSlots - items.count))
            await recordDispatchedWork(items)
            logClaimBatch(claimedCount: candidates.count, dispatchedCount: items.count, limit: claimLimit)
            return items
        } catch {
            await recordCandidateQueryFailure(error)
            return []
        }
    }

    func dequeueDownloadWork() -> [MediaAssetID] {
        guard !isShuttingDown else {
            return []
        }
        var ids: [MediaAssetID] = []
        while inFlightDownload.count < downloadConcurrency, let id = nextDownloadID() {
            inFlightDownload.insert(id)
            ids.append(id)
        }
        return ids
    }

    func prioritizedEnrichmentIDs() -> [MediaAssetID] {
        var ids: [MediaAssetID] = []
        var seen: Set<MediaAssetID> = []
        ids.reserveCapacity(viewport.count + freshly.count)
        for id in viewport.reversed() where seen.insert(id).inserted {
            ids.append(id)
        }
        for id in freshly.reversed() where seen.insert(id).inserted {
            ids.append(id)
        }
        return ids
    }

    func nextDownloadID() -> MediaAssetID? {
        for id in viewport.reversed() where datalessPending.contains(id) && !inFlightDownload.contains(id) {
            return id
        }
        guard eagerMode else {
            return nil
        }
        return datalessPending.first { !inFlightDownload.contains($0) }
    }

    func hasEnrichmentWorkRemaining() -> Bool {
        !inFlightEnrich.isEmpty
    }

    private func claimEnrichmentCandidates(limit: Int) async throws -> [MediaAsset] {
        let candidates = try await store.enrichmentCandidates(
            prioritizing: prioritizedEnrichmentIDs(),
            limit: limit
        )
        for asset in candidates {
            await recordClaimedCandidate(asset)
        }
        return candidates
    }

    private func recordClaimedCandidate(_ asset: MediaAsset) async {
        await recordVisibleThumbnailLifecycle(
            phase: "claimed",
            id: asset.id,
            fields: [
                "sourceSize": "\(asset.byteSize ?? -1)",
                "sourceMTimeSeconds": "\(MediaAsset.mtimeSeconds(asset.contentModifiedAt))",
            ]
        )
    }

    private func enqueueClaimedCandidates(_ candidates: [MediaAsset], currentItems: [EnrichWork]) {
        if candidates.isEmpty, claimedEnrichQueue.isEmpty, currentItems.isEmpty {
            eagerMode = true
        }
        let claimedIDs = Set(candidates.map(\.id))
        freshly.removeAll { claimedIDs.contains($0) }
        for asset in candidates where !inFlightEnrich.contains(asset.id) {
            claimedEnrichQueue.append(makeWork(asset))
        }
    }

    private func drainClaimedEnrichmentQueue(limit: Int) -> [EnrichWork] {
        guard limit > 0, !claimedEnrichQueue.isEmpty else {
            return []
        }
        var items: [EnrichWork] = []
        items.reserveCapacity(limit)
        while items.count < limit, !claimedEnrichQueue.isEmpty {
            let work = claimedEnrichQueue.removeFirst()
            guard !inFlightEnrich.contains(work.id) else {
                continue
            }
            inFlightEnrich.insert(work.id)
            items.append(work)
        }
        return items
    }

    private func makeWork(_ asset: MediaAsset) -> EnrichWork {
        EnrichWork(
            id: asset.id,
            url: asset.id.fileURL,
            sourceSize: asset.byteSize,
            sourceMTimeSeconds: MediaAsset.mtimeSeconds(asset.contentModifiedAt)
        )
    }

    private func recordDispatchedWork(_ items: [EnrichWork]) async {
        for item in items {
            await recordVisibleThumbnailLifecycle(phase: "dispatched", id: item.id)
        }
    }

    private func logClaimBatch(claimedCount: Int, dispatchedCount: Int, limit: Int) {
        let queuedCount = claimedEnrichQueue.count
        OtosLog.metadata.debug(
            """
            Enrichment claim batch claimed=\(claimedCount, privacy: .public) \
            queued=\(queuedCount, privacy: .public) \
            dispatched=\(dispatchedCount, privacy: .public) limit=\(limit, privacy: .public)
            """
        )
    }

    private func recordCandidateQueryFailure(_ error: any Error) async {
        OtosLog.metadata.error(
            "Enrichment candidate query failed error=\(String(describing: error), privacy: .public)"
        )
        await diagnostics?.record(
            operation: "catalog.enrichment.coordinator",
            phase: "queryError",
            fields: ["error": String(describing: error)]
        )
    }
}
