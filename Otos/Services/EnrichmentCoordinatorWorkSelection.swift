import Foundation
import OSLog

/// Bounded cursorless work selection for `EnrichmentCoordinator`.
///
/// Store remains durable backlog truth. Ready/enriching claims, materialization demands,
/// and pending apply results are separate process-local state sets because their
/// capacities answer different resource questions.
/// The scheduler-route levels B1 logs on change.
///
/// Equatable is the whole contract: two passes that describe the same scheduler state
/// produce one line and a suppressed count, not two lines. Kept as a value rather than a
/// formatted string so "did this change" is a typed comparison instead of string equality
/// over a rendered log line.
nonisolated struct SchedulerRouteFacts: Equatable, Sendable {
    let claimed: Int
    let readyQueued: Int
    let enriching: Int
    let materializationPending: Int
    let materializationInFlight: Int
    let pendingApply: Int
    let dispatched: Int
    let limit: Int
    let deferred: Int

    var logFields: [String: String] {
        [
            "claimed": "\(claimed)",
            "readyQueued": "\(readyQueued)",
            "enriching": "\(enriching)",
            "materializationPending": "\(materializationPending)",
            "materializationInFlight": "\(materializationInFlight)",
            "pendingApply": "\(pendingApply)",
            "dispatched": "\(dispatched)",
            "limit": "\(limit)",
            "deferred": "\(deferred)",
        ]
    }
}

extension EnrichmentCoordinator {
    private static let maxReadinessRoutingPasses = 4

    func dequeueEnrichmentWork(now: ContinuousClock.Instant = .now) async -> [EnrichWork] {
        guard !isShuttingDown else {
            return []
        }
        await dropQueuedClaims(outside: store.enrichableRootPaths())
        let availableSlots = admissionPolicy.enrichConcurrency - enrichingCount
        guard availableSlots > 0 else {
            return []
        }

        do {
            var routing = ClaimRouting()
            // Rows the user is looking at (and rows a download just made local) are claimed
            // before queued work is drained, and outside the claim window. The window bounds
            // look-ahead, and a row on screen is not look-ahead: when the window is full of
            // background work — a card whose reads crawl behind an import, a slow cloud
            // root — a visible row would otherwise wait behind every queued claim, because a
            // freed slot drains the queue first and claims nothing (ENR-018). The priority
            // list is bounded by the viewport and the materialization hand-off.
            let unclaimedPriority = prioritizedEnrichmentIDs().filter {
                readyClaims[$0] == nil && !schedule.hasDemand(for: $0)
            }
            if !unclaimedPriority.isEmpty {
                let claimed = try await store.priorityEnrichmentCandidates(unclaimedPriority)
                for candidate in claimed {
                    await recordClaimedCandidate(candidate.asset)
                }
                let (ready, deferred) = partitionByRetryLedger(claimed, now: now)
                routing.examined += claimed.count
                routing.deferred += deferred.count
                if !deferred.isEmpty {
                    await releaseDeferredLedgerClaims(deferred)
                }
                await route(ready, now: now, into: &routing)
            }

            var items = drainQueuedEnrichment(limit: availableSlots)
            var lastClaimLimit = 0
            for _ in 0 ..< Self.maxReadinessRoutingPasses {
                guard items.count < availableSlots else { break }
                let currentReadyCapacity = max(availableSlots - items.count, 0)
                let currentClaimCapacity = max(claimWindowLimit - readyClaims.count, 0)
                guard currentClaimCapacity > 0 else { break }
                let claimLimit = min(max(claimBatchSize, currentReadyCapacity), currentClaimCapacity)
                lastClaimLimit = claimLimit
                let claimed = try await claimSkippingLedgerDeferrals(limit: claimLimit, now: now)
                routing.examined += claimed.totalExamined
                routing.deferred += claimed.deferredIDs.count
                if !claimed.deferredIDs.isEmpty {
                    await releaseDeferredLedgerClaims(claimed.deferredIDs)
                }
                await route(claimed.ready, now: now, into: &routing)
                items.append(contentsOf: drainQueuedEnrichment(limit: availableSlots - items.count))
                if items.count >= availableSlots || claimed.ready.isEmpty || claimed.totalExamined == 0 {
                    break
                }
                if schedule.outstandingCount >= handoffPolicy.globalOutstandingLimit {
                    break
                }
            }
            await recordDispatchedWork(items)
            if !routing.readinessCounts.isEmpty {
                OtosLog.metadata.notice(
                    "op=catalog.enrichment.readiness phase=route probes=\(routing.examined, privacy: .public) ready=\(routing.readinessCounts["ready", default: 0], privacy: .public) needsMaterialization=\(routing.readinessCounts["needsMaterialization", default: 0], privacy: .public) rangedReady=\(routing.readinessCounts["rangedReady", default: 0], privacy: .public) retryReadiness=\(routing.readinessCounts["retryReadiness", default: 0], privacy: .public) materializationBound=\(routing.readinessCounts["materializationBound", default: 0], privacy: .public)"
                )
            }
            logClaimBatch(
                claimedCount: routing.examined,
                dispatchedCount: items.count,
                limit: lastClaimLimit,
                deferredCount: routing.deferred
            )
            return items
        } catch {
            await recordCandidateQueryFailure(error)
            return []
        }
    }

    /// What one pass's claims came to, for its readiness and scheduler-route lines.
    private struct ClaimRouting {
        var readinessCounts: [String: Int] = [:]
        var examined = 0
        var deferred = 0
    }

    /// Routes claimed rows by where their bytes are: ready rows join the queue, dataless
    /// rows become materialization demand, and rows whose readiness is unknown or that
    /// the hand-off cannot take now are released back to the Store.
    private func route(
        _ candidates: [ClaimedEnrichmentCandidate],
        now: ContinuousClock.Instant,
        into routing: inout ClaimRouting
    ) async {
        var releasedIDs: [MediaAssetID] = []
        for candidate in candidates {
            let asset = candidate.asset
            guard schedule.readinessProbeIsDue(asset.id, now: now) else {
                releasedIDs.append(asset.id)
                continue
            }

            // A row on a device that answers ranged reads is reachable without a
            // local file, so the filesystem is not the right thing to ask about it.
            //
            // Checked *before* the readiness probe rather than as a fallback after
            // it, because `lstat` on a staging path that was never written answers
            // `.unknown`, which routes to a readiness retry — and that retry can
            // never succeed, because nothing is ever going to create the file. Every
            // camera row would be deferred, re-probed, and deferred again forever,
            // which is exactly what a live 991-item card did: `probes=128 ready=0
            // retryReadiness=32 dispatched=0`, on repeat, with no enrichment at all.
            //
            // This is the "route, not a bypass" the design called for: the row is
            // genuinely ready, by a different route to its bytes.
            if rangeCapableRootPaths.contains(asset.id.libraryRootPath) {
                enqueueReadyCandidate(candidate)
                routing.readinessCounts["rangedReady", default: 0] += 1
                continue
            }
            // An account row's bytes are its server's, read in ranges while it answers; the
            // filesystem has no file for it, so asking it would defer the row forever.
            if candidate.scope.isReadableInRanges,
               await remoteRangeAccess?.serves(asset.id.libraryRootPath) == true
            {
                enqueueReadyCandidate(candidate)
                routing.readinessCounts["remoteReady", default: 0] += 1
                continue
            }

            switch readinessChecker.status(of: asset.id.fileURL) {
            case .materialized:
                enqueueReadyCandidate(candidate)
                routing.readinessCounts["ready", default: 0] += 1
            case .dataless:
                guard schedule.outstandingCount < handoffPolicy.globalOutstandingLimit else {
                    releasedIDs.append(asset.id)
                    routing.readinessCounts["materializationBound", default: 0] += 1
                    continue
                }
                schedule.demand(
                    DownloadWork(
                        id: asset.id,
                        url: asset.id.fileURL,
                        sourceSize: asset.byteSize,
                        captureDate: asset.bestCaptureDate,
                        isVideo: asset.bestKind == .video,
                        isDeviceStaging: deviceRootPaths.contains(asset.id.libraryRootPath)
                    ),
                    ownsStoreClaim: true
                )
                routing.readinessCounts["needsMaterialization", default: 0] += 1
            case .unknown:
                schedule.deferReadinessProbe(asset.id, now: now)
                releasedIDs.append(asset.id)
                routing.readinessCounts["retryReadiness", default: 0] += 1
            }
        }
        if !releasedIDs.isEmpty {
            await releaseDeferredLedgerClaims(releasedIDs)
        }
    }

    /// Bounds how many extra claim passes a wake will spend stepping past
    /// ledger-paced candidates (below) before giving up for this wake. Store orders
    /// candidates deterministically and has no knowledge of the ledger, so without
    /// this a permanently-failing population ranked ahead of real work would
    /// re-claim-and-defer the same rows every wake instead of ever reaching a fresh
    /// candidate ranked behind them.
    private static let maxLedgerSkipPasses = 4

    /// Repeatedly claims from Store until a pass yields a ready (non-deferred)
    /// candidate, Store runs out of unclaimed rows, or the pass bound is reached.
    /// Each pass releases only ledger-deferred rows after the bounded probe; rows
    /// routed to materialization remain independently claimed so the next pass's
    /// query naturally skips past them and surfaces different rows.
    private func claimSkippingLedgerDeferrals(
        limit: Int,
        now: ContinuousClock.Instant
    ) async throws -> (ready: [ClaimedEnrichmentCandidate], deferredIDs: [MediaAssetID], totalExamined: Int) {
        var ready: [ClaimedEnrichmentCandidate] = []
        var deferredIDs: [MediaAssetID] = []
        var totalExamined = 0
        for _ in 0 ..< Self.maxLedgerSkipPasses {
            let batch = try await claimEnrichmentCandidates(limit: limit)
            guard !batch.isEmpty else {
                break
            }
            totalExamined += batch.count
            let (batchReady, batchDeferred) = partitionByRetryLedger(batch, now: now)
            ready.append(contentsOf: batchReady)
            deferredIDs.append(contentsOf: batchDeferred)
            if !batchReady.isEmpty || batch.count < limit {
                break
            }
        }
        return (ready, deferredIDs, totalExamined)
    }

    /// Splits a claimed batch into the rows the pacing ledger lets through at `now` and
    /// the rows it defers back to the Store (`EnrichmentSchedule.ledgerAdmits`).
    private func partitionByRetryLedger(
        _ candidates: [ClaimedEnrichmentCandidate],
        now: ContinuousClock.Instant
    ) -> (ready: [ClaimedEnrichmentCandidate], deferred: [MediaAssetID]) {
        var ready: [ClaimedEnrichmentCandidate] = []
        var deferred: [MediaAssetID] = []
        for candidate in candidates {
            if schedule.ledgerAdmits(candidate.asset.id, sourceSize: candidate.asset.byteSize, now: now) {
                ready.append(candidate)
            } else {
                deferred.append(candidate.asset.id)
            }
        }
        return (ready, deferred)
    }

    private func releaseDeferredLedgerClaims(_ ids: [MediaAssetID]) async {
        do {
            try await store.releaseEnrichmentClaims(ids)
        } catch {
            OtosLog.metadata.error(
                """
                op=catalog.enrichment.coordinator phase=ledgerDeferredReleaseFailed \
                count=\(ids.count, privacy: .public) error=\(String(describing: error), privacy: .public)
                """
            )
        }
    }

    func dequeueMaterializationSubmissions(now: ContinuousClock.Instant = .now) async -> [DownloadWork] {
        guard !isShuttingDown else {
            return []
        }
        let selected = schedule.takeSubmissions(
            globalLimit: handoffPolicy.globalOutstandingLimit,
            backgroundPerRoot: handoffPolicy.backgroundOutstandingPerRoot,
            viewport: viewport,
            now: now
        )
        for work in selected {
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
        for id in viewport where seen.insert(id).inserted {
            ids.append(id)
        }
        for id in freshly.reversed() where seen.insert(id).inserted {
            ids.append(id)
        }
        return ids
    }

    var enrichingCount: Int {
        readyClaims.values.count {
            if case .enriching = $0.state {
                true
            } else {
                false
            }
        }
    }

    var enrichingBytes: Int64 {
        readyClaims.values.reduce(0) { total, record in
            if case let .enriching(_, estimatedBytes) = record.state {
                total + estimatedBytes
            } else {
                total
            }
        }
    }

    var inFlightEnrichVideoCount: Int {
        readyClaims.values.count {
            if case let .enriching(work, _) = $0.state {
                work.isVideo
            } else {
                false
            }
        }
    }

    /// Background claims, in Store order. Priority rows were claimed first, outside the
    /// window, by `dequeueEnrichmentWork`.
    private func claimEnrichmentCandidates(limit: Int) async throws -> [ClaimedEnrichmentCandidate] {
        let candidates = try await store.enrichmentCandidates(limit: limit)
        for candidate in candidates {
            await recordClaimedCandidate(candidate.asset)
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

    private func enqueueReadyCandidate(_ candidate: ClaimedEnrichmentCandidate) {
        if readyClaims[candidate.asset.id] == nil {
            nextClaimSequence &+= 1
            readyClaims[candidate.asset.id] = ClaimedWorkRecord(
                state: .queuedEnrichment(makeWork(candidate)),
                sequence: nextClaimSequence,
                ownsStoreClaim: true
            )
        }
    }

    private var queuedEnrichmentCount: Int {
        readyClaims.values.count {
            if case .queuedEnrichment = $0.state {
                true
            } else {
                false
            }
        }
    }

    /// Drops queued work whose root the Store has stopped offering — a card being
    /// imported, a source quiesced for eject. A queued record is a Store claim that has
    /// not started reading; the Store released those claims when it stopped offering the
    /// root, so dropping them owes nothing, and the claim window they held is free for
    /// rows enrichment may read. Work already reading is left to finish.
    private func dropQueuedClaims(outside enrichableRoots: Set<LibraryRootPath>) {
        var dropped: [LibraryRootPath: Int] = [:]
        for (id, record) in readyClaims where !enrichableRoots.contains(id.libraryRootPath) {
            if case .queuedEnrichment = record.state {
                readyClaims[id] = nil
                dropped[id.libraryRootPath, default: 0] += 1
            }
        }
        for (rootPath, count) in dropped {
            OtosLog.metadata.notice(
                "op=catalog.enrichment.coordinator phase=dropUnofferedRoot rootPath=\(rootPath.rawValue, privacy: .public) dropped=\(count, privacy: .public)"
            )
        }
    }

    private func drainQueuedEnrichment(limit: Int) -> [EnrichWork] {
        guard limit > 0 else {
            return []
        }
        let candidates = readyClaims
            .compactMap { id, record -> (MediaAssetID, ClaimedWorkRecord, EnrichWork)? in
                guard case let .queuedEnrichment(work) = record.state else { return nil }
                return (id, record, work)
            }
            .sorted { left, right in
                let leftPriority = readyPriorityIndex(left.0)
                let rightPriority = readyPriorityIndex(right.0)
                if leftPriority != rightPriority {
                    return leftPriority < rightPriority
                }
                return left.1.sequence < right.1.sequence
            }

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
                readyClaims[id] = record
                freshly.removeAll { $0 == id }
                items.append(work)
            case let .failure(reason):
                rejections[reason, default: 0] += 1
            }
        }
        recordEnrichmentAdmission(rejections: rejections, admitted: items.count)
        return items
    }

    private func readyPriorityIndex(_ id: MediaAssetID) -> Int {
        if let index = viewport.firstIndex(of: id) {
            return index
        }
        if let index = freshly.lastIndex(of: id) {
            return viewport.count + (freshly.count - index)
        }
        return viewport.count + freshly.count + 1
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

    private func makeWork(_ candidate: ClaimedEnrichmentCandidate) -> EnrichWork {
        let asset = candidate.asset
        return EnrichWork(
            id: asset.id,
            url: asset.id.fileURL,
            sourceSize: asset.byteSize,
            sourceMTimeSeconds: MediaAsset.mtimeSeconds(asset.contentModifiedAt),
            isVideo: asset.bestKind == .video,
            captureDate: asset.bestCaptureDate,
            isDeviceStaging: deviceRootPaths.contains(asset.id.libraryRootPath),
            scope: candidate.scope
        )
    }

    private func recordDispatchedWork(_ items: [EnrichWork]) async {
        for item in items {
            await recordVisibleThumbnailLifecycle(phase: "dispatched", id: item.id)
        }
    }

    /// Emits the scheduler-route line only when the facts change, carrying how many
    /// identical passes were collapsed into it (B1).
    ///
    /// Every field here is a level, not an event: "how much work is claimed, queued,
    /// enriching, materializing, pending". Re-emitting an unchanged level teaches the
    /// reader nothing and costs a line, and at the rate a spinning scheduler produces
    /// them it costs *other* messages too — the unified log drops under load, which is
    /// how a fully working download pipeline read as dead for 40 minutes. A transition
    /// is always logged, including the transition to all-zero, so the quiet state is
    /// visible rather than merely inferred from silence.
    private func logClaimBatch(claimedCount: Int, dispatchedCount: Int, limit: Int, deferredCount: Int) {
        let facts = SchedulerRouteFacts(
            claimed: claimedCount,
            readyQueued: queuedEnrichmentCount,
            enriching: enrichingCount,
            materializationPending: schedule.waitingCount,
            materializationInFlight: schedule.inFlightCount,
            pendingApply: pendingApply.count,
            dispatched: dispatchedCount,
            limit: limit,
            deferred: deferredCount
        )
        guard let suppressed = schedule.routeLine(for: facts) else {
            return
        }
        var fields = facts.logFields
        fields["suppressedPasses"] = "\(suppressed)"
        OtosLog.metadata.noticeOperation("catalog.enrichment.scheduler", phase: "route", fields: fields)
    }

    private func recordCandidateQueryFailure(_ error: any Error) async {
        OtosLog.metadata.error(
            "op=catalog.enrichment.coordinator phase=queryError error=\(String(describing: error), privacy: .public)"
        )
    }
}
