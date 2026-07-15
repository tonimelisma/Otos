import Foundation
import OSLog

/// Cursorless work-selection extension for `EnrichmentCoordinator`.
///
/// Store remains the catalog truth owner: this file only asks for bounded claimed
/// candidates, stages them in the actor-local queue, and drains that queue into free
/// worker slots. The queue is process-local scheduling state; SQLite
/// `enrichment_claimed_until` is the cross-query lease. Admission uses
/// `EnrichmentAdmissionPolicy` so byte/video/viewport/root fairness bound the
/// 16/8 count maxima. Rejected candidates do not block later admissible work:
/// dispatch searches the bounded pending set and stops only after a full pass
/// admits nothing.
extension EnrichmentCoordinator {
    func dequeueEnrichmentWork() async -> [EnrichWork] {
        guard !isShuttingDown else {
            return []
        }
        let availableSlots = admissionPolicy.enrichConcurrency - inFlightEnrich.count
        guard availableSlots > 0 else {
            return []
        }

        var items = drainClaimedEnrichmentQueue(limit: availableSlots)
        guard items.count < availableSlots else {
            return items
        }

        do {
            let claimLimit = max(claimBatchSize, availableSlots - items.count)
            let priorityIDs = prioritizedEnrichmentIDs()
            let candidates = try await claimEnrichmentCandidates(prioritizing: priorityIDs, limit: claimLimit)
            enqueueClaimedCandidates(candidates, submittedPriorityIDs: priorityIDs, currentItems: items)
            items.append(contentsOf: drainClaimedEnrichmentQueue(limit: availableSlots - items.count))
            await recordDispatchedWork(items)
            logClaimBatch(claimedCount: candidates.count, dispatchedCount: items.count, limit: claimLimit)
            return items
        } catch {
            await recordCandidateQueryFailure(error)
            return []
        }
    }

    func dequeueDownloadWork() async -> [DownloadWork] {
        guard !isShuttingDown else {
            return []
        }
        var items: [DownloadWork] = []
        var submittedIDs: Set<MediaAssetID> = []
        lastDownloadCandidateEvaluationCount = 0
        while true {
            guard let work = nextDownloadWork(excluding: submittedIDs) else {
                break
            }
            lastDownloadCandidateEvaluationCount += 1
            submittedIDs.insert(work.id)
            submittedMaterializations.insert(work.id)
            items.append(work)
            await recordVisibleThumbnailLifecycle(
                phase: "materializationSubmitted",
                id: work.id,
                fields: [
                    "sourceSize": "\(work.sourceSize ?? -1)",
                    "priority": work.isDeviceStaging ? "device" : "background",
                ]
            )
        }
        return items
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

    func nextDownloadWork(excluding rejectedIDs: Set<MediaAssetID> = []) -> DownloadWork? {
        for id in viewport.reversed()
            where !submittedMaterializations.contains(id) && !rejectedIDs.contains(id)
        {
            if let work = datalessPending[id], work.isReadyForRetry {
                return work
            }
        }
        let deviceWork = datalessPending.values
            .filter { readyDownloadWork($0, excluding: rejectedIDs) && $0.isDeviceStaging }
            .min(by: downloadWorkPrecedes)
        if let deviceWork {
            return deviceWork
        }
        guard eagerMode else {
            return nil
        }
        return datalessPending.values
            .filter { readyDownloadWork($0, excluding: rejectedIDs) && !$0.isDeviceStaging }
            .min(by: downloadWorkPrecedes)
    }

    private func readyDownloadWork(_ work: DownloadWork, excluding rejectedIDs: Set<MediaAssetID>) -> Bool {
        !submittedMaterializations.contains(work.id) && !rejectedIDs.contains(work.id) && work.isReadyForRetry
    }

    private func downloadWorkPrecedes(_ left: DownloadWork, _ right: DownloadWork) -> Bool {
        if left.isVideo != right.isVideo {
            return !left.isVideo
        }
        switch (left.captureDate, right.captureDate) {
        case let (leftDate?, rightDate?) where leftDate != rightDate:
            return leftDate > rightDate
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        default:
            return left.id.relativePath.rawValue < right.id.relativePath.rawValue
        }
    }

    func hasEnrichmentWorkRemaining() -> Bool {
        !inFlightEnrich.isEmpty
    }

    private func claimEnrichmentCandidates(
        prioritizing priorityIDs: [MediaAssetID],
        limit: Int
    ) async throws -> [MediaAsset] {
        let candidates = try await store.enrichmentCandidates(
            prioritizing: priorityIDs,
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

    private func enqueueClaimedCandidates(
        _ candidates: [MediaAsset],
        submittedPriorityIDs: [MediaAssetID],
        currentItems: [EnrichWork]
    ) {
        if candidates.isEmpty, claimedEnrichQueue.isEmpty, currentItems.isEmpty {
            eagerMode = true
        }
        let submittedPriorityIDs = Set(submittedPriorityIDs)
        freshly.removeAll { submittedPriorityIDs.contains($0) }
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
        var deferred: [EnrichWork] = []
        var rejections: [EnrichmentAdmissionPolicy.Rejection: Int] = [:]
        while items.count < limit {
            if claimedEnrichQueue.isEmpty {
                // Full pass over the pending set admitted nothing further.
                break
            }
            let work = claimedEnrichQueue.removeFirst()
            guard !inFlightEnrich.contains(work.id) else {
                continue
            }
            let isViewport = viewport.contains(work.id)
            let candidate = EnrichmentAdmissionPolicy.Candidate(
                sourceSize: work.sourceSize,
                isVideo: work.isVideo,
                isViewportOrDevice: isViewport
            )
            let snapshot = EnrichmentAdmissionPolicy.InFlightSnapshot(
                enrichCount: inFlightEnrich.count,
                enrichBytes: inFlightEnrichBytes.values.reduce(0, +),
                videoEnrichCount: inFlightEnrichVideoCount
            )
            switch admissionPolicy.canDispatchEnrichment(candidate: candidate, inFlight: snapshot) {
            case .success:
                inFlightEnrich.insert(work.id)
                inFlightEnrichBytes[work.id] = admissionPolicy.estimatedBytes(work.sourceSize)
                if work.isVideo {
                    inFlightEnrichVideoCount += 1
                }
                items.append(work)
            case let .failure(reason):
                deferred.append(work)
                rejections[reason, default: 0] += 1
            }
        }
        // Preserve rejected candidates in stable order ahead of any remaining queue.
        if !deferred.isEmpty {
            claimedEnrichQueue = deferred + claimedEnrichQueue
        }
        recordEnrichmentAdmission(rejections: rejections, admitted: items.count)
        return items
    }

    func recordEnrichmentAdmission(
        rejections: [EnrichmentAdmissionPolicy.Rejection: Int],
        admitted: Int
    ) {
        guard !rejections.isEmpty else {
            if lastEnrichmentAdmissionSnapshot != nil {
                lastEnrichmentAdmissionSnapshot = nil
                enrichmentAdmissionTransitionCount += 1
                OtosLog.metadata.notice("op=catalog.enrichment.admission phase=unblocked")
            }
            return
        }
        let snapshot = AdmissionDiagnosticSnapshot(
            rejections: rejections,
            admitted: admitted,
            pending: claimedEnrichQueue.count,
            inFlight: inFlightEnrich.count,
            bytes: inFlightEnrichBytes.values.reduce(0, +),
            videoInFlight: inFlightEnrichVideoCount
        )
        guard snapshot != lastEnrichmentAdmissionSnapshot else {
            return
        }
        lastEnrichmentAdmissionSnapshot = snapshot
        enrichmentAdmissionTransitionCount += 1
        for (reason, count) in rejections.sorted(by: { $0.key.description < $1.key.description }) {
            OtosLog.metadata.notice(
                """
                op=catalog.enrichment.admission phase=blocked reason=\(reason.description, privacy: .public) \
                rejected=\(count, privacy: .public) admitted=\(admitted, privacy: .public) \
                pending=\(snapshot.pending, privacy: .public) inFlight=\(snapshot.inFlight, privacy: .public) \
                bytes=\(snapshot.bytes, privacy: .public) videoInFlight=\(snapshot.videoInFlight, privacy: .public)
                """
            )
        }
    }

    private func makeWork(_ asset: MediaAsset) -> EnrichWork {
        EnrichWork(
            id: asset.id,
            url: asset.id.fileURL,
            sourceSize: asset.byteSize,
            sourceMTimeSeconds: MediaAsset.mtimeSeconds(asset.contentModifiedAt),
            isVideo: asset.bestKind == .video
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
        OtosLog.metadata.error(
            "op=catalog.enrichment.coordinator phase=queryError error=\(String(describing: error), privacy: .public)"
        )
    }
}

private extension EnrichmentCoordinator.DownloadWork {
    nonisolated var isReadyForRetry: Bool {
        guard let retryNotBefore else {
            return true
        }
        return retryNotBefore <= Date()
    }
}
