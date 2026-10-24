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
        case .notMaterialized:
            let pending = DownloadWork(
                id: id,
                url: work.url,
                sourceSize: work.sourceSize,
                captureDate: work.captureDate,
                isVideo: work.isVideo,
                isDeviceStaging: work.isDeviceStaging
            )
            readyClaims[id] = nil
            materializationDemands[id] = pending
            materializingIDs.remove(id)
            materializationClaimIDs.insert(id)
            await recordVisibleThumbnailLifecycle(
                phase: "notMaterialized",
                id: id,
                fields: ["sourceSize": "\(work.sourceSize ?? -1)"]
            )
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
    /// metadata, and QuickLook. Synthesize the same definitive empty stamp the
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
            contentHash: XXH3Digest128.empty
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
        guard materializationDemands[id] != nil else {
            return
        }
        let outcome = result.outcome
        let materialized = outcome.isMaterialized
        // Cancellation says nothing about the provider's ability to materialize the
        // asset: release the claim without consuming a retry attempt or pacing slot.
        if outcome == .cancelled {
            materializationDemands[id] = nil
            materializingIDs.remove(id)
            await releaseMaterializationClaimIfOwned(id)
        } else {
            let retry = retryWorkIfNeeded(work, outcome: outcome)
            if let retry {
                materializationDemands[id] = retry
                materializingIDs.remove(id)
                scheduleDownloadRetrySignal()
                await recordVisibleThumbnailLifecycle(
                    phase: "materializationRetryScheduled",
                    id: id,
                    fields: ["attemptCount": "\(retry.attemptCount)"]
                )
            } else {
                materializationDemands[id] = nil
                materializingIDs.remove(id)
                await releaseMaterializationClaimIfOwned(id)
                if materialized {
                    retryLedger[id] = nil
                } else if work.isDeviceStaging {
                    // Device staging has exhausted its attempts, so these bytes are not
                    // obtainable: the camera denied access, the cable went, the item is
                    // gone. That is the same situation as a source whose bytes cannot
                    // be opened, and it needs the same answer — because the naming gate
                    // withholds a camera's plan until every item is enriched, and an
                    // item that can never be staged can never be enriched. Without
                    // this the bar sits in "Checking the camera…" indefinitely with no
                    // stated cause (ARC-057).
                    //
                    // Observed on a Sony ILCE-6700 whose 875 items all failed staging
                    // with NSCocoaErrorDomain 257: enumeration succeeded, staging did
                    // not, and nothing said so.
                    await store.markSourceUnreadable(id)
                } else {
                    await recordRetryLedgerFailure(for: work)
                }
            }
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

    /// Background retries stay in-window through the full `[15, 60, 300, 900]`
    /// schedule; the fifth failure signals bound-exceeded (`nil`) so the caller
    /// releases the claim and hands pacing to `retryLedger` instead of holding a
    /// claim-window slot forever. Device retries are unaffected: they cap at 3
    /// in-window attempts (unbounded for `insufficientLocalSpace`, a waiting
    /// condition rather than a failure) and never enter the ledger, since staged
    /// device seeds hold no Store claim to begin with.
    private func retryWorkIfNeeded(_ work: DownloadWork, outcome: MaterializationOutcome) -> DownloadWork? {
        guard !outcome.isMaterialized else {
            return nil
        }
        let delay: Duration
        let attemptCount = work.attemptCount + 1
        if work.isDeviceStaging {
            switch outcome {
            case .insufficientLocalSpace:
                delay = .seconds(60)
            default:
                guard attemptCount < 3 else {
                    return nil
                }
                delay = writeFailureBackoff * attemptCount
            }
        } else {
            let delays: [Duration] = [.seconds(15), .seconds(60), .seconds(300), .seconds(900)]
            guard attemptCount <= delays.count else {
                return nil
            }
            delay = delays[attemptCount - 1]
        }
        return DownloadWork(
            id: work.id,
            url: work.url,
            sourceSize: work.sourceSize,
            captureDate: work.captureDate,
            isVideo: work.isVideo,
            isDeviceStaging: work.isDeviceStaging,
            attemptCount: attemptCount,
            retryNotBefore: .now.advanced(by: delay)
        )
    }

    private func recordRetryLedgerFailure(for work: DownloadWork) async {
        let previousAttempts = retryLedger[work.id]?.attemptCount ?? 0
        let entry = RetryLedgerEntry(
            notBefore: .now.advanced(by: .seconds(900)),
            attemptCount: previousAttempts + 1,
            sourceSize: work.sourceSize
        )
        retryLedger[work.id] = entry
        scheduleRetryLedgerSignal()
        await recordVisibleThumbnailLifecycle(
            phase: "retryLedgerPaced",
            id: work.id,
            fields: [
                "retryInMs": "\(DiagnosticsTiming.milliseconds(from: .now, to: entry.notBefore))",
                "attemptCount": "\(entry.attemptCount)",
            ]
        )
    }

    /// Mirrors `scheduleDownloadRetrySignal`: without an owned wake, a ledger-paced
    /// identity would sit past its `notBefore` forever once no other signal source
    /// (viewport change, scan, unrelated completion) happens to wake the loop.
    private func scheduleRetryLedgerSignal() {
        ledgerRetryTask?.cancel()
        guard let nextRetry = retryLedger.values.map(\.notBefore).min() else {
            ledgerRetryTask = nil
            return
        }
        ledgerRetryTask = Task { [weak self] in
            do {
                // time: backoff — the retry ledger paces a materialization the provider failed
                try await ContinuousClock().sleep(until: nextRetry)
            } catch {
                return
            }
            await self?.signal()
        }
    }

    private func releaseClaimIfOwned(_ record: ClaimedWorkRecord, id: MediaAssetID) async {
        guard record.ownsStoreClaim else { return }
        await releaseClaims([id], visibleID: id)
    }

    private func releaseMaterializationClaimIfOwned(_ id: MediaAssetID) async {
        guard materializationClaimIDs.remove(id) != nil else { return }
        await releaseClaims([id], visibleID: id)
    }

    private func scheduleDownloadRetrySignal() {
        downloadRetryTask?.cancel()
        let nextRetry = awaitingMaterializationWork.values
            .compactMap(\.retryNotBefore)
            .min()
        guard let nextRetry else {
            return
        }
        downloadRetryTask = Task { [weak self] in
            do {
                // time: backoff — a failed provider download retries on its schedule
                try await ContinuousClock().sleep(until: nextRetry)
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
        let claimedIDs = batchIDs.filter { pendingApplyClaimIDs.remove($0) != nil }
        for id in batchIDs {
            readyClaims[id] = nil
        }
        if let visibleID = claimedIDs.first, !claimedIDs.isEmpty {
            await releaseClaims(claimedIDs, visibleID: visibleID)
        }
        handleApplyOutcome(outcome, batchCount: batch.count)
        // Cleared only now, with no await before the reschedule: results that arrived
        // during the write are taken by the next apply, and none starts beside this one.
        applyFlushTask = nil
        scheduleApplyFlushIfNeeded()
    }

    func releaseOutstandingClaimsForShutdown() async {
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
                "hasThumbnail": "\(result.thumbnailPath != nil)",
                "hasStagedThumbnail": "\(result.generatedThumbnail != nil)",
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
            // time: backoff — after a failed catalog write
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
