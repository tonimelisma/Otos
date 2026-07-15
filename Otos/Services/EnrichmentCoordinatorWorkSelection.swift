import Foundation
import OSLog

/// Bounded cursorless work selection for `EnrichmentCoordinator`.
///
/// Store remains durable backlog truth. `claimedWork` is the sole process-local owner
/// of each claim's state and sequence; the views below are derived on demand from that
/// bounded dictionary. Local enrichment and shared-materializer handoff have separate
/// limits because they answer different resource questions.
extension EnrichmentCoordinator {
    func dequeueEnrichmentWork() async -> [EnrichWork] {
        guard !isShuttingDown else {
            return []
        }
        let availableSlots = admissionPolicy.enrichConcurrency - enrichingCount
        guard availableSlots > 0 else {
            return []
        }

        var items = drainQueuedEnrichment(limit: availableSlots)
        guard items.count < availableSlots else {
            return items
        }

        let remainingClaimCapacity = max(claimWindowLimit - claimedWork.count, 0)
        guard remainingClaimCapacity > 0 else {
            return items
        }

        do {
            let desired = max(claimBatchSize, availableSlots - items.count)
            let claimLimit = min(desired, remainingClaimCapacity)
            let priorityIDs = prioritizedEnrichmentIDs()
            let candidates = try await claimEnrichmentCandidates(
                prioritizing: priorityIDs,
                limit: claimLimit
            )
            enqueueClaimedCandidates(candidates, submittedPriorityIDs: priorityIDs, currentItems: items)
            items.append(contentsOf: drainQueuedEnrichment(limit: availableSlots - items.count))
            await recordDispatchedWork(items)
            logClaimBatch(claimedCount: candidates.count, dispatchedCount: items.count, limit: claimLimit)
            return items
        } catch {
            await recordCandidateQueryFailure(error)
            return []
        }
    }

    func dequeueMaterializationSubmissions() async -> [DownloadWork] {
        guard !isShuttingDown else {
            return []
        }
        var available = max(handoffPolicy.globalOutstandingLimit - materializingCount, 0)
        guard available > 0 else {
            return []
        }

        var selected: [DownloadWork] = []
        var excluded: Set<MediaAssetID> = []
        lastDownloadCandidateEvaluationCount = 0
        while available > 0, let work = nextMaterializationWork(excluding: excluded) {
            lastDownloadCandidateEvaluationCount += 1
            excluded.insert(work.id)
            if !work.isDeviceStaging {
                let rootCount = materializingBackgroundCount(under: work.id.libraryRootPath)
                guard rootCount < handoffPolicy.backgroundOutstandingPerRoot else {
                    continue
                }
            }
            guard var record = claimedWork[work.id] else {
                continue
            }
            record.state = .materializing(work)
            claimedWork[work.id] = record
            selected.append(work)
            available -= 1
            await recordVisibleThumbnailLifecycle(
                phase: "materializationSubmitted",
                id: work.id,
                fields: [
                    "sourceSize": "\(work.sourceSize ?? -1)",
                    "priority": work.isDeviceStaging ? "device" : "background",
                ]
            )
        }
        return selected
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

    func nextMaterializationWork(excluding excluded: Set<MediaAssetID> = []) -> DownloadWork? {
        let pending = awaitingMaterializationWork
        for id in viewport.reversed() where !excluded.contains(id) {
            if let work = pending[id], work.isReadyForRetry {
                return work
            }
        }
        let device = pending.values
            .filter { !excluded.contains($0.id) && $0.isDeviceStaging && $0.isReadyForRetry }
            .min(by: downloadWorkPrecedes)
        if let device {
            return device
        }
        // A full bounded claim window of dataless work cannot query far enough to
        // observe Store exhaustion. Treat that backpressure boundary as the point
        // where eager materialization must open slots, or the window deadlocks.
        guard eagerMode || claimedWork.count >= claimWindowLimit else {
            return nil
        }
        return pending.values
            .filter { !excluded.contains($0.id) && !$0.isDeviceStaging && $0.isReadyForRetry }
            .min(by: downloadWorkPrecedes)
    }

    func hasEnrichmentWorkRemaining() -> Bool {
        enrichingCount > 0
    }

    var enrichingCount: Int {
        claimedWork.values.count {
            if case .enriching = $0.state {
                true
            } else {
                false
            }
        }
    }

    var materializingCount: Int {
        claimedWork.values.count {
            if case .materializing = $0.state {
                true
            } else {
                false
            }
        }
    }

    var enrichingBytes: Int64 {
        claimedWork.values.reduce(0) { total, record in
            if case let .enriching(_, estimatedBytes) = record.state {
                total + estimatedBytes
            } else {
                total
            }
        }
    }

    var awaitingMaterializationWork: [MediaAssetID: DownloadWork] {
        claimedWork.reduce(into: [:]) { result, item in
            if case let .awaitingMaterialization(work) = item.value.state {
                result[item.key] = work
            }
        }
    }

    private func materializingBackgroundCount(under root: LibraryRootPath) -> Int {
        claimedWork.values.count { record in
            if case let .materializing(work) = record.state {
                !work.isDeviceStaging && work.id.libraryRootPath == root
            } else {
                false
            }
        }
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

    private func claimEnrichmentCandidates(
        prioritizing priorityIDs: [MediaAssetID],
        limit: Int
    ) async throws -> [MediaAsset] {
        let candidates = try await store.enrichmentCandidates(prioritizing: priorityIDs, limit: limit)
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
        if candidates.isEmpty, queuedEnrichmentCount == 0, currentItems.isEmpty {
            eagerMode = true
        }
        let submittedPriorityIDs = Set(submittedPriorityIDs)
        freshly.removeAll { submittedPriorityIDs.contains($0) }
        for asset in candidates where claimedWork[asset.id] == nil {
            nextClaimSequence &+= 1
            claimedWork[asset.id] = ClaimedWorkRecord(
                state: .queuedEnrichment(makeWork(asset)),
                sequence: nextClaimSequence,
                ownsStoreClaim: true
            )
        }
    }

    private var queuedEnrichmentCount: Int {
        claimedWork.values.count {
            if case .queuedEnrichment = $0.state {
                true
            } else {
                false
            }
        }
    }

    private func drainQueuedEnrichment(limit: Int) -> [EnrichWork] {
        guard limit > 0 else {
            return []
        }
        let candidates = claimedWork
            .compactMap { id, record -> (MediaAssetID, ClaimedWorkRecord, EnrichWork)? in
                guard case let .queuedEnrichment(work) = record.state else { return nil }
                return (id, record, work)
            }
            .sorted { $0.1.sequence < $1.1.sequence }

        var items: [EnrichWork] = []
        var rejections: [EnrichmentAdmissionPolicy.Rejection: Int] = [:]
        for (id, var record, work) in candidates where items.count < limit {
            let candidate = EnrichmentAdmissionPolicy.Candidate(
                sourceSize: work.sourceSize,
                isVideo: work.isVideo,
                isViewportOrDevice: viewport.contains(id)
            )
            let snapshot = EnrichmentAdmissionPolicy.InFlightSnapshot(
                enrichCount: enrichingCount,
                enrichBytes: enrichingBytes,
                videoEnrichCount: inFlightEnrichVideoCount
            )
            switch admissionPolicy.canDispatchEnrichment(candidate: candidate, inFlight: snapshot) {
            case .success:
                let estimated = admissionPolicy.estimatedBytes(work.sourceSize)
                record.state = .enriching(work, estimatedBytes: estimated)
                claimedWork[id] = record
                if work.isVideo {
                    inFlightEnrichVideoCount += 1
                }
                items.append(work)
            case let .failure(reason):
                rejections[reason, default: 0] += 1
            }
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
            pending: queuedEnrichmentCount,
            inFlight: enrichingCount,
            bytes: enrichingBytes,
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
            isVideo: asset.bestKind == .video,
            captureDate: asset.bestCaptureDate,
            isDeviceStaging: deviceRootPaths.contains(asset.id.libraryRootPath)
        )
    }

    private func recordDispatchedWork(_ items: [EnrichWork]) async {
        for item in items {
            await recordVisibleThumbnailLifecycle(phase: "dispatched", id: item.id)
        }
    }

    private func logClaimBatch(claimedCount: Int, dispatchedCount: Int, limit: Int) {
        let queuedCount = queuedEnrichmentCount
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
