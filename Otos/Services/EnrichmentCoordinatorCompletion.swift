import Foundation
import OSLog

/// Completion/writeback extension for `EnrichmentCoordinator`.
///
/// Worker tasks return here after byte-reading or materialization. The actor then
/// updates only scheduler state, records bounded visible-thumbnail lifecycle
/// diagnostics, batches Store writes, and releases process-local SQLite claims on
/// success, retryable failure, or shutdown.
extension EnrichmentCoordinator {
    func finishEnrich(_ work: EnrichWork, _ outcome: EnrichmentOutcome) async {
        let id = work.id
        guard !isShuttingDown else {
            await releaseClaims([id], visibleID: id)
            return
        }
        inFlightEnrich.remove(id)
        switch outcome {
        case let .complete(result):
            await recordCompletedEnrichment(result, id: id)
        case .notMaterialized:
            datalessPending[id] = DownloadWork(
                id: id,
                url: work.url,
                sourceSize: work.sourceSize
            )
            var fields = ["sourceSize": "\(work.sourceSize ?? -1)"]
            if let leaseRefreshedUntil = await refreshClaims([id], visibleID: id) {
                fields["leaseRefreshedUntil"] = diagnosticTimestamp(leaseRefreshedUntil)
            }
            await recordVisibleThumbnailLifecycle(
                phase: "notMaterialized",
                id: id,
                fields: fields
            )
        case .transient:
            await recordVisibleThumbnailLifecycle(phase: "transient", id: id)
            await releaseClaims([id], visibleID: id)
        }
        signal()
    }

    func finishDownload(
        _ work: DownloadWork,
        result: MaterializationResult,
        attemptMs: Int
    ) async {
        let id = work.id
        guard !isShuttingDown else {
            await releaseClaims([id], visibleID: id)
            return
        }
        inFlightDownload.remove(id)
        datalessPending[id] = nil
        await releaseClaims([id], visibleID: id)
        let outcome = result.outcome
        let materialized = outcome.isMaterialized
        await recordVisibleThumbnailLifecycle(
            phase: materialized ? "materialized" : "materializationFailed",
            id: id,
            fields: [
                "outcome": outcome.diagnosticDescription,
                "attemptMs": "\(attemptMs)",
                "requestToCompleteMs": "\(result.elapsedMs)",
                "rerequestCount": "\(result.rerequestCount)",
                "sourceSize": "\(work.sourceSize ?? -1)",
            ]
        )
        if materialized {
            freshly.append(id)
        }
        signal()
    }

    func scheduleApplyFlushIfNeeded() {
        guard !isShuttingDown else {
            return
        }
        guard applyFlushTask == nil, !pendingApply.isEmpty else {
            return
        }
        let interval = applyFlushInterval
        let sleep = applyFlushSleep
        applyFlushTask = Task { [weak self, sleep] in
            await sleep(interval)
            guard !Task.isCancelled else {
                return
            }
            await self?.flushPendingApply()
        }
    }

    func flushPendingApply() async {
        guard !isShuttingDown else {
            return
        }
        applyFlushTask = nil
        guard !pendingApply.isEmpty else {
            return
        }
        let batch = pendingApply
        let diagnosedBatchIDs = batch.map(\.id).filter { diagnosedThumbnailLifecycleIDs.contains($0) }
        pendingApply.removeAll(keepingCapacity: true)
        pendingApplyIDs.removeAll(keepingCapacity: true)
        let outcome = await store.applyEnrichmentBatch(batch)
        await diagnostics?.record(
            operation: "catalog.enrichment.coordinator",
            phase: "flush",
            fields: ["count": "\(batch.count)", "outcome": "\(outcome)"]
        )
        await recordVisibleThumbnailBatchOutcome(outcome, batchCount: batch.count, ids: diagnosedBatchIDs)
        handleApplyOutcome(outcome, batchCount: batch.count)
        scheduleApplyFlushIfNeeded()
    }

    func releaseOutstandingClaimsForShutdown() async {
        var ids = Set<MediaAssetID>()
        ids.formUnion(claimedEnrichQueue.map(\.id))
        ids.formUnion(inFlightEnrich)
        ids.formUnion(inFlightDownload)
        ids.formUnion(datalessPending.keys)
        ids.formUnion(pendingApplyIDs)
        guard !ids.isEmpty else {
            return
        }
        await releaseShutdownClaims(ids)
    }

    func recordVisibleThumbnailLifecycle(
        phase: String,
        id: MediaAssetID,
        fields: [String: String] = [:]
    ) async {
        let shouldRecord = diagnosedThumbnailLifecycleIDs.contains(id) || viewport.contains(id)
        guard shouldRecord else {
            return
        }
        diagnosedThumbnailLifecycleIDs.insert(id)
        var diagnosticFields = fields
        diagnosticFields["rootPath"] = id.libraryRootPath.rawValue
        diagnosticFields["relativePath"] = id.relativePath.rawValue
        await diagnostics?.record(
            operation: "catalog.thumbnails.visibleLifecycle",
            phase: phase,
            fields: diagnosticFields
        )
    }

    private func releaseClaims(_ ids: [MediaAssetID], visibleID: MediaAssetID) async {
        do {
            try await store.releaseEnrichmentClaims(ids)
        } catch {
            await recordVisibleThumbnailLifecycle(
                phase: "claimReleaseFailed",
                id: visibleID,
                fields: ["error": String(describing: error)]
            )
            OtosLog.metadata.error(
                """
                Enrichment claim release failed count=\(ids.count, privacy: .public) \
                error=\(String(describing: error), privacy: .public)
                """
            )
        }
    }

    private func refreshClaims(_ ids: [MediaAssetID], visibleID: MediaAssetID) async -> Date? {
        do {
            return try await store.refreshEnrichmentClaims(ids)
        } catch {
            await recordVisibleThumbnailLifecycle(
                phase: "claimRefreshFailed",
                id: visibleID,
                fields: ["error": String(describing: error)]
            )
            OtosLog.metadata.error(
                """
                Enrichment claim refresh failed count=\(ids.count, privacy: .public) \
                error=\(String(describing: error), privacy: .public)
                """
            )
            return nil
        }
    }

    private func diagnosticTimestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func recordCompletedEnrichment(_ result: EnrichmentResult, id: MediaAssetID) async {
        await recordVisibleThumbnailLifecycle(
            phase: "generated",
            id: id,
            fields: [
                "hasThumbnail": "\(result.thumbnailPath != nil)",
                "hasStagedThumbnail": "\(result.generatedThumbnail != nil)",
            ]
        )
        pendingApply.append(result)
        pendingApplyIDs.insert(id)
        scheduleApplyFlushIfNeeded()
    }

    private func handleApplyOutcome(_ outcome: EnrichmentApplyOutcome, batchCount: Int) {
        switch outcome {
        case let .applied(count) where count < batchCount:
            markDirtyAndSignal()
        case .applied:
            break
        case .writeFailed:
            scheduleWriteFailureRetry()
        }
    }

    /// One pending backoff retry at a time. After the delay it re-wakes the loop, which
    /// re-dispatches any asset still `needsEnrichment`; persistent failure reschedules,
    /// pacing retries instead of tight-looping the read/generate/fail cycle.
    private func scheduleWriteFailureRetry() {
        guard writeRetryTask == nil else {
            return
        }
        let backoff = writeFailureBackoff
        writeRetryTask = Task { [weak self] in
            try? await Task.sleep(for: backoff)
            await self?.fireWriteFailureRetry()
        }
    }

    private func fireWriteFailureRetry() {
        writeRetryTask = nil
        guard !Task.isCancelled, !isShuttingDown else {
            return
        }
        markDirtyAndSignal()
    }

    private func releaseShutdownClaims(_ ids: Set<MediaAssetID>) async {
        do {
            try await store.releaseEnrichmentClaims(Array(ids))
            await diagnostics?.record(
                operation: "catalog.enrichment.coordinator",
                phase: "shutdownRelease",
                fields: ["count": "\(ids.count)"]
            )
        } catch {
            OtosLog.metadata.error(
                """
                Enrichment shutdown claim release failed count=\(ids.count, privacy: .public) \
                error=\(String(describing: error), privacy: .public)
                """
            )
        }
    }

    private func recordVisibleThumbnailBatchOutcome(
        _ outcome: EnrichmentApplyOutcome,
        batchCount: Int,
        ids: [MediaAssetID]
    ) async {
        guard !ids.isEmpty else {
            return
        }
        let (phase, fields) = visibleThumbnailBatchFields(outcome, batchCount: batchCount)
        for id in ids {
            await recordVisibleThumbnailLifecycle(phase: phase, id: id, fields: fields)
            diagnosedThumbnailLifecycleIDs.remove(id)
        }
    }

    private func visibleThumbnailBatchFields(
        _ outcome: EnrichmentApplyOutcome,
        batchCount: Int
    ) -> (phase: String, fields: [String: String]) {
        var fields = [
            "batchCount": "\(batchCount)",
            "outcome": "\(outcome)",
        ]
        switch outcome {
        case let .applied(count) where count == batchCount:
            fields["appliedCount"] = "\(count)"
            return ("batchAccepted", fields)
        case let .applied(count):
            fields["appliedCount"] = "\(count)"
            return ("batchPartiallyApplied", fields)
        case .writeFailed:
            return ("batchWriteFailed", fields)
        }
    }
}
