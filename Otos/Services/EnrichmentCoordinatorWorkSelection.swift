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
        await dropClaimedWork(outside: store.enrichableRootPaths())
        let availableSlots = admissionPolicy.enrichConcurrency - enrichingCount
        guard availableSlots > 0 else {
            return []
        }

        do {
            var routing = ClaimRouting()
            // While the face model cannot be loaded, every claim this pass makes leaves a
            // video's faces out, so a video that owes only them is never claimed (ADR 0047).
            let videoFaces = schedule.videoFaces(at: now)
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
                let claimed = try await store.priorityEnrichmentCandidates(unclaimedPriority, videoFaces: videoFaces)
                for candidate in claimed {
                    await recordClaimedCandidate(candidate.asset)
                }
                let (ready, deferred) = partitionByWaits(claimed, now: now)
                routing.examined += claimed.count
                routing.deferred += deferred.count
                if !deferred.isEmpty {
                    await releaseClaims(deferred)
                }
                await route(ready, now: now, into: &routing)
            }

            var items = drainQueuedEnrichment(limit: availableSlots)
            var lastClaimLimit = 0
            for _ in 0 ..< Self.maxReadinessRoutingPasses {
                guard items.count < availableSlots else { break }
                let currentReadyCapacity = max(availableSlots - items.count, 0)
                // A demand waiting for a slot or a retry is claimed work not started, as a
                // queued one is: it takes a place in the window, so a full hand-off stops the
                // claims.
                let currentClaimCapacity = claimWindowRoom
                guard currentClaimCapacity > 0 else { break }
                let claimLimit = min(max(claimBatchSize, currentReadyCapacity), currentClaimCapacity)
                lastClaimLimit = claimLimit
                let claimed = try await claimSkippingLedgerDeferrals(limit: claimLimit, videoFaces: videoFaces, now: now)
                routing.examined += claimed.totalExamined
                routing.deferred += claimed.deferredIDs.count
                if !claimed.deferredIDs.isEmpty {
                    await releaseClaims(claimed.deferredIDs)
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
                    "op=catalog.enrichment.readiness phase=route probes=\(routing.examined, privacy: .public) ready=\(routing.readinessCounts["ready", default: 0], privacy: .public) needsMaterialization=\(routing.readinessCounts["needsMaterialization", default: 0], privacy: .public) rangedReady=\(routing.readinessCounts["rangedReady", default: 0], privacy: .public) remoteReady=\(routing.readinessCounts["remoteReady", default: 0], privacy: .public) userWorkOnly=\(routing.readinessCounts["userWorkOnly", default: 0], privacy: .public) notDue=\(routing.readinessCounts["notDue", default: 0], privacy: .public) retryReadiness=\(routing.readinessCounts["retryReadiness", default: 0], privacy: .public) materializationBound=\(routing.readinessCounts["materializationBound", default: 0], privacy: .public)"
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
    /// rows become materialization demand — held, with their claim, when the hand-off has no
    /// slot for them now — and rows whose readiness is unknown, or whose source sends the
    /// original only for the user's work, are released back to the Store.
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
                routing.readinessCounts["notDue", default: 0] += 1
                continue
            }

            // A row on a device that answers ranged reads is reachable without a
            // local file, so the filesystem is not the right thing to ask about it.
            //
            // Checked *before* locality: a staged row not yet copied is fetchable, and
            // fetching it would copy the whole file from the device, where ranged reads
            // need only the bytes the read touches. This is the "route, not a bypass"
            // the design called for: the row is genuinely ready, by a different route
            // to its bytes.
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

            // Where the original is has one owner (`MaterializationRequesting.locality`, ADR
            // 0046 §4): a folder's file by its `SF_DATALESS` status, a staged source's by
            // whether its staging folder holds it. The enricher re-checks the file itself
            // right before it reads.
            switch await materializationRequester.locality(of: asset.id) {
            case .local:
                enqueueReadyCandidate(candidate)
                routing.readinessCounts["ready", default: 0] += 1
            case .fetchable:
                let work = DownloadWork(
                    id: asset.id,
                    url: asset.id.fileURL,
                    sourceSize: asset.byteSize,
                    captureLocalTime: asset.captureLocalTime,
                    isVideo: asset.bestKind == .video,
                    isDeviceStaging: deviceRootPaths.contains(asset.id.libraryRootPath)
                )
                // With no slot for it, the row keeps its claim and waits held, handed off when
                // a slot frees; given back, the next pass would claim it again to find the
                // same full hand-off (plan 0116).
                let held = schedule.demand(
                    work, ownsStoreClaim: true, outstandingLimit: handoffPolicy.globalOutstandingLimit
                )
                routing.readinessCounts[held ? "materializationBound" : "needsMaterialization", default: 0] += 1
            case .fetchableForUserWork:
                // Its source sends the whole original only for the user's work, and its
                // ranges are not served now: nothing is asked of it. The row waits out the
                // pacing ledger, like a ranged read its server did not answer; an outage
                // stops claims through the root's answering fact.
                schedule.pace(asset.id, sourceSize: asset.byteSize, now: now)
                releasedIDs.append(asset.id)
                routing.readinessCounts["userWorkOnly", default: 0] += 1
            case .unreachable:
                schedule.deferReadinessProbe(asset.id, now: now)
                releasedIDs.append(asset.id)
                routing.readinessCounts["retryReadiness", default: 0] += 1
            }
        }
        if !releasedIDs.isEmpty {
            await releaseClaims(releasedIDs)
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
        videoFaces: VideoFacesAdmission,
        now: ContinuousClock.Instant
    ) async throws -> (ready: [ClaimedEnrichmentCandidate], deferredIDs: [MediaAssetID], totalExamined: Int) {
        var ready: [ClaimedEnrichmentCandidate] = []
        var deferredIDs: [MediaAssetID] = []
        var totalExamined = 0
        for _ in 0 ..< Self.maxLedgerSkipPasses {
            let batch = try await claimEnrichmentCandidates(limit: limit, videoFaces: videoFaces)
            guard !batch.isEmpty else {
                break
            }
            totalExamined += batch.count
            let (batchReady, batchDeferred) = partitionByWaits(batch, now: now)
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
    private func partitionByWaits(
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

    /// Gives claims back to the Store: rows a pass will not work on now, and rows whose demand ended.
    func releaseClaims(_ ids: [MediaAssetID]) async {
        claimInputsRevision &+= 1
        do {
            try await store.releaseEnrichmentClaims(ids)
        } catch {
            OtosLog.metadata.error(
                """
                op=catalog.enrichment.coordinator phase=claimReleaseFailed \
                count=\(ids.count, privacy: .public) error=\(String(describing: error), privacy: .public)
                """
            )
        }
    }

    func dequeueMaterializationSubmissions(now: ContinuousClock.Instant = .now) async -> [DownloadWork] {
        guard !isShuttingDown else {
            return []
        }
        // Parked demands whose deadline passed come back as the window has room, and are
        // asked of the Store with the rest: a row deleted while it was parked ends here.
        demandRowsToCheck.formUnion(schedule.unparkDue(now: now, room: claimWindowRoom))
        // A demand whose row went is ended before a transfer is spent on it.
        await reconcileDemandSources()
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

    /// The claim window's free places: its limit less the claimed work not yet started,
    /// queued enrichment and the demands waiting for a slot or a retry.
    var claimWindowRoom: Int {
        max(claimWindowLimit - readyClaims.count - schedule.claimedWaitingCount, 0)
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
    private func claimEnrichmentCandidates(
        limit: Int,
        videoFaces: VideoFacesAdmission
    ) async throws -> [ClaimedEnrichmentCandidate] {
        if let exhausted = exhaustedClaims, exhausted.revision == claimInputsRevision, exhausted.videoFaces == videoFaces {
            return []
        }
        let startedFrom = claimInputsRevision
        let candidates = try await store.enrichmentCandidates(limit: limit, videoFaces: videoFaces)
        // A claim that found nothing at a revision finds nothing again until a Store change or
        // a claim given back moves it; one that found rows says nothing of the next.
        exhaustedClaims = candidates.isEmpty ? (startedFrom, videoFaces) : nil
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

    /// Drops the claimed work whose root the Store has stopped offering — a library removed
    /// or gone unreachable, a card being imported, a source quiesced for eject: queued
    /// enrichment, and every materialization demand that holds a Store claim, held or not.
    /// Neither has started reading, so the claim window and the transfer slots they held are
    /// free for rows enrichment may read; a transfer already running ends withdrawn
    /// (`EnrichmentSchedule.withdraw`). Their claims are given back here: the Store releases a
    /// root's claims when it quiesces or detaches it, not when a library goes unreachable, and
    /// a removed library's rows are gone. A device seed holds no claim and keeps its demand: a
    /// camera paused for an import resumes, and nothing would offer the seed again.
    private func dropClaimedWork(outside enrichableRoots: Set<LibraryRootPath>) async {
        var dropped: [LibraryRootPath: Int] = [:]
        var claims: [MediaAssetID] = []
        for (id, record) in readyClaims where !enrichableRoots.contains(id.libraryRootPath) {
            if case .queuedEnrichment = record.state {
                readyClaims[id] = nil
                dropped[id.libraryRootPath, default: 0] += 1
                if record.ownsStoreClaim {
                    claims.append(id)
                }
            }
        }
        // Parked demands are asked only when the roots changed: no pass reads them.
        let rootsChanged = lastEnrichableRoots != enrichableRoots
        lastEnrichableRoots = enrichableRoots
        let withdrawn = schedule.withdraw(includingParked: rootsChanged) { id, record in
            record.ownsStoreClaim && !enrichableRoots.contains(id.libraryRootPath)
        }
        for id in withdrawn.claimsToRelease {
            dropped[id.libraryRootPath, default: 0] += 1
        }
        claims += withdrawn.claimsToRelease
        for (rootPath, count) in dropped {
            OtosLog.metadata.notice(
                "op=catalog.enrichment.coordinator phase=dropUnofferedRoot rootPath=\(rootPath.rawValue, privacy: .public) dropped=\(count, privacy: .public)"
            )
        }
        if !claims.isEmpty {
            await releaseClaims(claims)
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
            captureLocalTime: asset.captureLocalTime,
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
