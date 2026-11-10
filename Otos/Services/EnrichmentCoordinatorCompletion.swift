import Foundation
import OSLog

/// Completion/writeback extension for `EnrichmentCoordinator`.
///
/// Worker tasks return here after byte-reading or materialization. The actor then
/// updates only scheduler state, records bounded visible-thumbnail lifecycle
/// diagnostics, batches Store writes (each apply releases its rows' SQLite claims), and
/// releases the claims of work that ends without an apply: retryable failure or shutdown.
extension EnrichmentCoordinator {
    func finishEnrich(_ work: EnrichWork, _ outcome: EnrichmentOutcome) async {
        defer { resumeDrainedWaiters() }
        let id = work.id
        guard !isShuttingDown else {
            return
        }
        guard let record = readyClaims[id] else {
            return
        }
        switch outcome {
        case let .complete(result):
            await recordCompletedEnrichment(result, id: id)
        case let .hashed(result):
            // A digest alone changes nothing the user sees, so it is written at once rather
            // than batched with products; the write releases the row's claim.
            readyClaims[id] = nil
            await handleApplyOutcome(store.applyContentHash(result), batchCount: 1)
        case .notMaterialized:
            let pending = DownloadWork(
                id: id,
                url: work.url,
                sourceSize: work.sourceSize,
                captureLocalTime: work.captureLocalTime,
                isVideo: work.isVideo,
                isDeviceStaging: work.isDeviceStaging
            )
            readyClaims[id] = nil
            // The ready claim's Store claim passes to the demand.
            schedule.demand(pending, ownsStoreClaim: record.ownsStoreClaim)
            await recordVisibleThumbnailLifecycle(
                phase: "notMaterialized",
                id: id,
                fields: ["sourceSize": "\(work.sourceSize ?? -1)"]
            )
        case .unanswered:
            // A server that serves this row in ranges did not answer. The row waits out
            // the pacing ledger rather than being claimed again at once; an outage stops
            // claims through the root's answering fact (`CatalogStore.setSourceAnswering`).
            readyClaims[id] = nil
            await releaseClaimIfOwned(record, id: id)
            schedule.pace(id, sourceSize: work.sourceSize, now: ContinuousClock.now)
            await recordVisibleThumbnailLifecycle(phase: "unanswered", id: id)
        case .transient:
            // `.transient` means the byte source could not be opened. The metadata
            // package's `shouldRetry` is a generic contract, honest for a network byte
            // source and meaningless for a local one: on a removable volume the bytes
            // are local, so this is a failing card or a file that vanished. Silently
            // clearing the claim re-queued it immediately — an unbounded spin, and
            // under the naming gate it would hold the offer open forever. Record it
            // instead: the planner blocks the entry and the bar shows it (ARC-057).
            await recordVisibleThumbnailLifecycle(phase: "transient", id: id)
            readyClaims[id] = nil
            await releaseClaimIfOwned(record, id: id)
            await store.markSourceUnreadable(id)
        }
        signal()
    }

    /// Scanned `byteSize == 0`: no media bytes exist, so skip materialization,
    /// metadata, QuickLook and face analysis. Synthesize the same definitive empty stamp the
    /// enricher would produce for unreadable media and flush through the normal
    /// apply path (ENR-007 self-heals if real bytes appear later).
    func finishEmptySource(_ work: EnrichWork) async {
        defer { resumeDrainedWaiters() }
        let id = work.id
        guard !isShuttingDown else {
            return
        }
        guard readyClaims[id] != nil else {
            return
        }
        let result = EnrichmentResult(
            id: id,
            metadata: AssetMetadata(),
            thumbnailPath: nil,
            sourceSize: work.sourceSize,
            sourceMTimeSeconds: work.sourceMTimeSeconds,
            contentHash: XXH3Digest128.empty,
            faces: .noneFound
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
        readyClaims[id] = nil
        pendingApply.append(result)
        pendingApplyClaimIDs.insert(id)
        scheduleApplyFlushIfNeeded()
        signal()
    }

    func finishDownload(
        _ work: DownloadWork,
        result: MaterializationResult,
        attemptMs: Int
    ) async {
        defer { resumeDrainedWaiters() }
        let id = work.id
        guard !isShuttingDown else {
            return
        }
        let outcome = result.outcome
        let now = ContinuousClock.now
        guard let settlement = schedule.finish(work, outcome: outcome, now: now) else {
            return
        }
        if settlement.releasesStoreClaim {
            await releaseClaims([id], visibleID: id)
        }
        switch settlement.disposition {
        case .cancelled, .materialized:
            break
        case let .retrying(retry):
            await recordVisibleThumbnailLifecycle(
                phase: "materializationRetryScheduled",
                id: id,
                fields: ["attemptCount": "\(retry.attemptCount)"]
            )
        case .unobtainable:
            // Device staging has exhausted its attempts, so these bytes are not
            // obtainable: the camera denied access, the cable went, the item is gone.
            // That is the same situation as a source whose bytes cannot be opened, and it
            // needs the same answer — because the naming gate withholds a camera's plan
            // until every item is enriched, and an item that can never be staged can never
            // be enriched. Without this the bar sits in "Checking the camera…"
            // indefinitely with no stated cause (ARC-057).
            //
            // Observed on a Sony ILCE-6700 whose 875 items all failed staging with
            // NSCocoaErrorDomain 257: enumeration succeeded, staging did not, and nothing
            // said so.
            await store.markSourceUnreadable(id)
        case let .paced(entry):
            await recordVisibleThumbnailLifecycle(
                phase: "retryLedgerPaced",
                id: id,
                fields: [
                    "retryInMs": "\(DiagnosticsTiming.milliseconds(from: now, to: entry.notBefore))",
                    "attemptCount": "\(entry.attemptCount)",
                ]
            )
        }
        // Staging that cannot proceed for disk reasons retries every 60 s forever, and
        // the naming gate now holds a camera import until every item is enriched — so
        // this condition would otherwise be an indefinite, unexplained wait, and
        // importing would not free the space anyway (staging is separate from the
        // library copy). Name it in the log so the cause is legible rather than
        // inferred from a bar that never advances (ENR-011).
        if outcome == .insufficientLocalSpace, work.isDeviceStaging {
            let queuedSeeds = pendingDeviceSeeds.count
            OtosLog.fileAccess.notice(
                "op=enrichment.stageDevice phase=blocked reason=insufficientLocalSpace rootPath=\(id.libraryRootPath.rawValue, privacy: .public) queued=\(queuedSeeds, privacy: .public)"
            )
        }
        // A completed download frees an outstanding slot, which is the only moment a
        // queued device seed can be admitted. Without this the queue would fill once
        // and never drain, leaving a camera past the outstanding limit permanently
        // unstaged — the defect the queue exists to fix (ENR-011).
        admitPendingDeviceSeeds()
        await recordVisibleThumbnailLifecycle(
            phase: outcome.isMaterialized ? "materialized" : "materializationFailed",
            id: id,
            fields: [
                "outcome": outcome.diagnosticDescription,
                "attemptMs": "\(attemptMs)",
                "requestToCompleteMs": "\(result.elapsedMs)",
                "rerequestCount": "\(result.rerequestCount)",
                "sourceSize": "\(work.sourceSize ?? -1)",
            ]
        )
        if outcome.isMaterialized {
            freshly.append(id)
        }
        signal()
    }

    private func releaseClaimIfOwned(_ record: ClaimedWorkRecord, id: MediaAssetID) async {
        guard record.ownsStoreClaim else { return }
        await releaseClaims([id], visibleID: id)
    }

    func scheduleApplyFlushIfNeeded() {
        guard !isShuttingDown else {
            return
        }
        guard applyFlushTask == nil, !pendingApply.isEmpty else {
            return
        }
        applyFlushTask = Task { [weak self] in
            await self?.flushPendingApply()
        }
    }

    func flushPendingApply() async {
        guard !isShuttingDown else {
            return
        }
        guard !pendingApply.isEmpty else {
            applyFlushTask = nil
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
        // The apply released each row's Store claim, whatever its outcome. `readyClaims`
        // is not touched: these rows left it before they were queued, and once the apply
        // released them a pass during the write may have claimed one again — that entry
        // is the new claim's. A row with a newer result queued keeps its pending claim.
        let stillPending = Set(pendingApply.map(\.id))
        for id in batchIDs where !stillPending.contains(id) {
            pendingApplyClaimIDs.remove(id)
        }
        handleApplyOutcome(outcome, batchCount: batch.count)
        // Cleared only now, with no await before the reschedule: results that arrived
        // during the write are taken by the next apply, and none starts beside this one.
        applyFlushTask = nil
        scheduleApplyFlushIfNeeded()
    }

    func releaseOutstandingClaimsForShutdown() async {
        let materializationClaimIDs = schedule.materializations.compactMap { id, record in
            record.ownsStoreClaim ? id : nil
        }
        let ids = Set(readyClaims.compactMap { id, record in
            record.ownsStoreClaim ? id : nil
        }).union(materializationClaimIDs).union(pendingApplyClaimIDs)
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

    private func recordCompletedEnrichment(_ result: EnrichmentResult, id: MediaAssetID) async {
        await recordVisibleThumbnailLifecycle(
            phase: "generated",
            id: id,
            fields: [
                "hasThumbnail": "\(result.shownThumbnailPath != nil)",
                "hasStagedThumbnail": "\((result.rendering?.generatedThumbnail ?? result.provisionalThumbnail) != nil)",
            ]
        )
        readyClaims[id] = nil
        pendingApply.append(result)
        pendingApplyClaimIDs.insert(id)
        scheduleApplyFlushIfNeeded()
    }

    private func handleApplyOutcome(_ outcome: EnrichmentApplyOutcome, batchCount: Int) {
        switch outcome {
        case let .applied(count) where count < batchCount:
            markDirtyAndSignal()
        case .applied:
            break
        case .writeFailed:
            // The loop wakes once the backoff passes and re-dispatches any asset still
            // `needsEnrichment`; persistent failure schedules again, pacing retries instead
            // of tight-looping the read/generate/fail cycle.
            let now = ContinuousClock.now
            schedule.catalogWriteFailed(now: now)
            armWake(after: now)
        }
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
