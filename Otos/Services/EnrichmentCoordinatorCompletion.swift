import Foundation
import OSLog
import Synchronization

/// Completion/writeback extension for `EnrichmentCoordinator`.
///
/// Worker tasks return here after byte-reading or materialization. The actor then
/// updates only scheduler state, records bounded visible-thumbnail lifecycle
/// diagnostics, batches Store writes, and releases process-local SQLite claims on
/// success, retryable failure, or shutdown.
extension EnrichmentCoordinator {
    private nonisolated static let diagnosticTimestampFormatter = Mutex(ISO8601DateFormatter())

    func finishEnrich(_ work: EnrichWork, _ outcome: EnrichmentOutcome) async {
        let id = work.id
        guard !isShuttingDown else {
            return
        }
        guard var record = claimedWork[id] else {
            return
        }
        if work.isVideo {
            inFlightEnrichVideoCount = max(0, inFlightEnrichVideoCount - 1)
        }
        switch outcome {
        case let .complete(result):
            await recordCompletedEnrichment(result, id: id)
        case .notMaterialized:
            let pending = DownloadWork(
                id: id,
                url: work.url,
                sourceSize: work.sourceSize,
                captureDate: work.captureDate,
                isVideo: work.isVideo,
                isDeviceStaging: work.isDeviceStaging
            )
            record.state = .awaitingMaterialization(pending)
            claimedWork[id] = record
            var fields = ["sourceSize": "\(work.sourceSize ?? -1)"]
            if let leaseRefreshedUntil = await refreshClaims([id], visibleID: id) {
                fields["leaseRefreshedUntil"] = Self.diagnosticTimestamp(leaseRefreshedUntil)
            }
            await recordVisibleThumbnailLifecycle(
                phase: "notMaterialized",
                id: id,
                fields: fields
            )
        case .transient:
            await recordVisibleThumbnailLifecycle(phase: "transient", id: id)
            claimedWork[id] = nil
            if record.ownsStoreClaim {
                await releaseClaims([id], visibleID: id)
            }
        }
        signal()
    }

    /// Scanned `byteSize == 0`: no media bytes exist, so skip materialization,
    /// metadata, and QuickLook. Synthesize the same definitive empty stamp the
    /// enricher would produce for unreadable media and flush through the normal
    /// apply path (ENR-007 self-heals if real bytes appear later).
    func finishEmptySource(_ work: EnrichWork) async {
        let id = work.id
        guard !isShuttingDown else {
            return
        }
        guard var record = claimedWork[id] else {
            return
        }
        if work.isVideo {
            inFlightEnrichVideoCount = max(0, inFlightEnrichVideoCount - 1)
        }
        let result = EnrichmentResult(
            id: id,
            metadata: AssetMetadata(),
            thumbnailPath: nil,
            sourceSize: work.sourceSize,
            sourceMTimeSeconds: work.sourceMTimeSeconds
        )
        await recordVisibleThumbnailLifecycle(
            phase: "emptySource",
            id: id,
            fields: [
                "outcome": "emptySource",
                "sourceSize": "0",
                "hasThumbnail": "false",
            ]
        )
        pendingApply.append(result)
        record.state = .awaitingApply
        claimedWork[id] = record
        scheduleApplyFlushIfNeeded()
        signal()
    }

    func finishDownload(
        _ work: DownloadWork,
        result: MaterializationResult,
        attemptMs: Int
    ) async {
        let id = work.id
        guard !isShuttingDown else {
            return
        }
        guard var record = claimedWork[id] else {
            return
        }
        let outcome = result.outcome
        let materialized = outcome.isMaterialized
        let retry = retryWorkIfNeeded(work, outcome: outcome)
        if let retry {
            record.state = .awaitingMaterialization(retry)
            claimedWork[id] = record
            scheduleDownloadRetrySignal()
            if let leaseRefreshedUntil = await refreshClaims([id], visibleID: id) {
                await recordVisibleThumbnailLifecycle(
                    phase: "materializationRetryScheduled",
                    id: id,
                    fields: [
                        "leaseRefreshedUntil": Self.diagnosticTimestamp(leaseRefreshedUntil),
                        "attemptCount": "\(retry.attemptCount)",
                    ]
                )
            }
        } else {
            claimedWork[id] = nil
            if record.ownsStoreClaim {
                await releaseClaims([id], visibleID: id)
            }
        }
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

    private func retryWorkIfNeeded(_ work: DownloadWork, outcome: MaterializationOutcome) -> DownloadWork? {
        guard !outcome.isMaterialized else {
            return nil
        }
        let delay: TimeInterval
        let attemptCount = work.attemptCount + 1
        if work.isDeviceStaging {
            switch outcome {
            case .insufficientLocalSpace:
                delay = 60
            default:
                guard attemptCount < 3 else {
                    return nil
                }
                delay = Double(attemptCount) * writeFailureBackoff.timeInterval
            }
        } else {
            let delays: [TimeInterval] = [15, 60, 300, 900]
            delay = delays[min(attemptCount - 1, delays.count - 1)]
        }
        return DownloadWork(
            id: work.id,
            url: work.url,
            sourceSize: work.sourceSize,
            captureDate: work.captureDate,
            isVideo: work.isVideo,
            isDeviceStaging: work.isDeviceStaging,
            attemptCount: attemptCount,
            retryNotBefore: Date().addingTimeInterval(delay)
        )
    }

    private func scheduleDownloadRetrySignal() {
        downloadRetryTask?.cancel()
        let nextRetry = awaitingMaterializationWork.values
            .compactMap(\.retryNotBefore)
            .min()
        guard let nextRetry else {
            return
        }
        let delay = max(nextRetry.timeIntervalSinceNow, 0)
        downloadRetryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
            await self?.signal()
        }
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
        let batchIDs = batch.map(\.id)
        let diagnosedBatchIDs = batch.map(\.id).filter { diagnosedThumbnailLifecycleIDs.contains($0) }
        pendingApply.removeAll(keepingCapacity: true)
        let outcome = await store.applyEnrichmentBatch(batch)
        OtosLog.metadata.notice(
            "op=catalog.enrichment.coordinator phase=flush count=\(batch.count, privacy: .public) outcome=\(String(describing: outcome), privacy: .public)"
        )
        await recordVisibleThumbnailBatchOutcome(outcome, batchCount: batch.count, ids: diagnosedBatchIDs)
        let claimedIDs = batchIDs.filter { claimedWork[$0]?.ownsStoreClaim == true }
        for id in batchIDs {
            claimedWork[id] = nil
        }
        if let visibleID = claimedIDs.first, !claimedIDs.isEmpty {
            await releaseClaims(claimedIDs, visibleID: visibleID)
        }
        handleApplyOutcome(outcome, batchCount: batch.count)
        scheduleApplyFlushIfNeeded()
    }

    func releaseOutstandingClaimsForShutdown() async {
        let ids = Set(claimedWork.compactMap { id, record in
            record.ownsStoreClaim ? id : nil
        })
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
        OtosLog.metadata.notice(
            "op=catalog.thumbnails.visibleLifecycle phase=\(phase, privacy: .public) \(otosLogFields(diagnosticFields), privacy: .public)"
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

    private nonisolated static func diagnosticTimestamp(_ date: Date) -> String {
        diagnosticTimestampFormatter.withLock { formatter in
            formatter.string(from: date)
        }
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
        if var record = claimedWork[id] {
            record.state = .awaitingApply
            claimedWork[id] = record
        }
        scheduleApplyFlushIfNeeded()
    }

    func refreshOutstandingMaterializationClaims() async {
        guard !isShuttingDown else {
            return
        }
        let ids = claimedWork.compactMap { id, record -> MediaAssetID? in
            guard record.ownsStoreClaim else { return nil }
            switch record.state {
            case .awaitingMaterialization, .materializing:
                return id
            case .queuedEnrichment, .enriching, .awaitingApply:
                return nil
            }
        }
        guard let visibleID = ids.first, !ids.isEmpty else {
            return
        }
        _ = await refreshClaims(ids, visibleID: visibleID)
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
            OtosLog.metadata.notice(
                "op=catalog.enrichment.coordinator phase=shutdownRelease count=\(ids.count, privacy: .public)"
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

private extension Duration {
    nonisolated var timeInterval: TimeInterval {
        let value = components
        return TimeInterval(value.seconds) + TimeInterval(value.attoseconds) / 1_000_000_000_000_000_000
    }
}
