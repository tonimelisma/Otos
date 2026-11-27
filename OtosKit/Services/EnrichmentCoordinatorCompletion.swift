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
        defer {
            resumeDrainedWaiters()
            settleQuiescence()
        }
        let id = work.id
        guard !isShuttingDown else {
            return
        }
        guard let record = readyClaims[id] else {
            return
        }
        switch outcome {
        case let .complete(result):
            // The read that the ledger paced the row for has landed: the row is no longer
            // held back, which the Activity board counts (`EnrichmentSchedule.parkedRows`).
            schedule.endPacing(id)
            await recordCompletedEnrichment(result, work: work)
        case let .facesUnread(result, unread):
            // The products are written; the faces stay owed, and are not read again until
            // the ledger's pacing passes, or for every video until the model's backoff does.
            // Not `.transient`: the bytes were read, and the row is no unreadable source.
            let now = ContinuousClock.now
            schedule.pace(
                id, sourceSize: work.sourceSize, cause: .facesUnread, now: now,
                purpose: .faces
            )
            if unread == .model {
                schedule.holdVideoFaces(now: now)
            }
            await recordCompletedEnrichment(result, work: work)
            await recordVisibleThumbnailLifecycle(phase: "videoFacesUnread", id: id, fields: ["unread": "\(unread)"])
        case let .hashed(result):
            // A digest alone changes nothing the user sees, so it is written at once rather
            // than batched with products; the write releases the row's claim.
            readyClaims[id] = nil
            schedule.endPacing(id)
            // The write gives the claim back, and a digest that moved nothing announces
            // nothing: the coordinator counts its own release.
            claimInputsRevision &+= 1
            let applied = await store.applyContentHash(result)
            if applied == .applied(count: 1) {
                finishedByPurpose[work.purpose, default: 0] += 1
            }
            await handleApplyOutcome(applied, batchCount: 1)
        case .notMaterialized:
            let locality = await materializationRequester.locality(of: id)
            // Read again after the await: a shutdown or another completion may have settled
            // the row meanwhile.
            guard !isShuttingDown, readyClaims[id] != nil else {
                return
            }
            readyClaims[id] = nil
            guard locality != .fetchableForUserWork else {
                // The read found no local file, and its source sends the whole original only
                // for the user's work: nothing is asked of it (ADR 0046 §4). The row waits
                // out the pacing ledger, holding its claim, as a ranged read its server did not
                // answer does.
                schedule.pace(
                    id, sourceSize: work.sourceSize, cause: .sentOnlyWhenOpened, now: ContinuousClock.now,
                    holdingClaim: record.ownsStoreClaim, purpose: work.purpose
                )
                await recordVisibleThumbnailLifecycle(phase: "userWorkOnly", id: id)
                return
            }
            let pending = DownloadWork(
                id: id,
                url: work.url,
                sourceSize: work.sourceSize,
                captureLocalTime: work.captureLocalTime,
                isVideo: work.isVideo,
                isDeviceStaging: work.isDeviceStaging,
                purpose: work.purpose
            )
            // The ready claim's Store claim passes to the demand, held like a routed row's when
            // the hand-off has no slot for it.
            schedule.demand(
                pending,
                ownsStoreClaim: record.ownsStoreClaim,
                outstandingLimit: handoffPolicy.globalOutstandingLimit
            )
            await recordVisibleThumbnailLifecycle(
                phase: "notMaterialized",
                id: id,
                fields: ["sourceSize": "\(work.sourceSize ?? -1)"]
            )
        case .unanswered:
            // A server that serves this row in ranges did not answer. The row waits out
            // the pacing ledger, which holds its claim, rather than being claimed again at
            // once; an outage stops claims through the root's answering fact
            // (`CatalogStore.setSourceAnswering`).
            readyClaims[id] = nil
            schedule.pace(
                id, sourceSize: work.sourceSize, cause: .serverDidNotAnswer, now: ContinuousClock.now,
                holdingClaim: record.ownsStoreClaim, purpose: work.purpose
            )
            await recordVisibleThumbnailLifecycle(phase: "unanswered", id: id)
        case .rawResourcesUnavailable:
            // Apple's support for the RAW's camera could not be fetched: no fact about the
            // file, which is neither undecodable nor unreadable. The row waits out the pacing
            // ledger, holding its claim, and is developed again after it.
            readyClaims[id] = nil
            schedule.pace(
                id, sourceSize: work.sourceSize, cause: .rawSupportUnavailable, now: ContinuousClock.now,
                holdingClaim: record.ownsStoreClaim, purpose: work.purpose
            )
            await recordVisibleThumbnailLifecycle(phase: "rawResourcesUnavailable", id: id)
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
    /// metadata, QuickLook and a video's faces. Synthesize the same definitive empty stamp the
    /// enricher would produce for unreadable media and flush through the normal
    /// apply path (ENR-007 self-heals if real bytes appear later).
    func finishEmptySource(_ work: EnrichWork) async {
        defer {
            resumeDrainedWaiters()
            settleQuiescence()
        }
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
            contentHash: ContentDigest.empty,
            videoFaces: work.scope.contains(.videoFaces) ? .noneFound : nil
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
        defer {
            resumeDrainedWaiters()
            settleQuiescence()
        }
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
        case .withdrawn:
            // The row or its root went while the transfer ran: nothing is enriched from it,
            // and its slot is free for another.
            await recordVisibleThumbnailLifecycle(phase: "materializationWithdrawn", id: id)
            admitPendingDeviceSeeds()
            signal()
            return
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
            settleQuiescence()
            return
        }
        let batch = pendingApply
        let batchIDs = batch.map(\.id)
        let diagnosedBatchIDs = batch.map(\.id).filter { diagnosedThumbnailLifecycleIDs.contains($0) }
        pendingApply.removeAll(keepingCapacity: true)
        // The apply gives every row's claim back.
        claimInputsRevision &+= 1
        // The purpose each row of the batch was claimed for; counted only when every result
        // applied, since a partial apply does not say which rows it left out and a row is
        // never counted done that was not (ADR 0058).
        let purposes = batchIDs.compactMap { pendingPurposes.removeValue(forKey: $0) }
        let outcome = await store.applyEnrichmentBatch(batch)
        activity.wrote(batch.count)
        if case let .applied(count) = outcome {
            activity.finished(count)
            if count == batch.count {
                for purpose in purposes {
                    finishedByPurpose[purpose, default: 0] += 1
                }
            }
        }
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
        settleQuiescence()
    }

    func releaseOutstandingClaimsForShutdown() async {
        let materializationClaimIDs = schedule.claimedIDs
        let ids = Set(readyClaims.compactMap { id, record in
            record.ownsStoreClaim ? id : nil
        }).union(materializationClaimIDs).union(pendingApplyClaimIDs).union(schedule.pacedClaimIDs)
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
        claimInputsRevision &+= 1
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

    private func recordCompletedEnrichment(_ result: EnrichmentResult, work: EnrichWork) async {
        let id = work.id
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
        pendingPurposes[id] = work.purpose
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
