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

        let remainingClaimCapacity = max(claimWindowLimit - readyClaims.count, 0)
        guard remainingClaimCapacity > 0 else {
            return items
        }

        do {
            var readinessCounts: [String: Int] = [:]
            var totalExamined = 0
            var totalDeferred = 0
            var lastClaimLimit = 0
            for _ in 0 ..< Self.maxReadinessRoutingPasses {
                let currentReadyCapacity = max(availableSlots - items.count, 0)
                let currentClaimCapacity = max(claimWindowLimit - readyClaims.count, 0)
                guard currentClaimCapacity > 0 else { break }
                let claimLimit = min(max(claimBatchSize, currentReadyCapacity), currentClaimCapacity)
                lastClaimLimit = claimLimit
                let priorityIDs = prioritizedEnrichmentIDs()
                let claimed = try await claimSkippingLedgerDeferrals(
                    prioritizing: priorityIDs,
                    limit: claimLimit
                )
                totalExamined += claimed.totalExamined
                totalDeferred += claimed.deferredIDs.count
                if !claimed.deferredIDs.isEmpty {
                    await releaseDeferredLedgerClaims(claimed.deferredIDs)
                }
                var releasedIDs: [MediaAssetID] = []
                for candidate in claimed.ready {
                    let asset = candidate.asset
                    if let retryAt = readinessRetryNotBefore[asset.id], retryAt > Date() {
                        releasedIDs.append(asset.id)
                        continue
                    }
                    readinessRetryNotBefore[asset.id] = nil
                    switch readinessChecker.status(of: asset.id.fileURL) {
                    case .materialized:
                        enqueueReadyCandidate(candidate)
                        readinessCounts["ready", default: 0] += 1
                    case .dataless:
                        guard materializationDemands.count < handoffPolicy.globalOutstandingLimit else {
                            releasedIDs.append(asset.id)
                            readinessCounts["materializationBound", default: 0] += 1
                            continue
                        }
                        materializationDemands[asset.id] = DownloadWork(
                            id: asset.id,
                            url: asset.id.fileURL,
                            sourceSize: asset.byteSize,
                            captureDate: asset.bestCaptureDate,
                            isVideo: asset.bestKind == .video,
                            isDeviceStaging: deviceRootPaths.contains(asset.id.libraryRootPath)
                        )
                        materializationClaimIDs.insert(asset.id)
                        readinessCounts["needsMaterialization", default: 0] += 1
                    case .unknown:
                        readinessRetryNotBefore[asset.id] = Date().addingTimeInterval(1)
                        releasedIDs.append(asset.id)
                        readinessCounts["retryReadiness", default: 0] += 1
                    }
                }
                if !releasedIDs.isEmpty {
                    await releaseDeferredLedgerClaims(releasedIDs)
                }
                items.append(contentsOf: drainQueuedEnrichment(limit: availableSlots - items.count))
                if items.count >= availableSlots || claimed.ready.isEmpty || claimed.totalExamined == 0 {
                    break
                }
                if materializationDemands.count >= handoffPolicy.globalOutstandingLimit {
                    break
                }
            }
            await recordDispatchedWork(items)
            if !readinessCounts.isEmpty {
                OtosLog.metadata.notice(
                    // swiftlint:disable:next line_length
                    "op=catalog.enrichment.readiness phase=route probes=\(totalExamined, privacy: .public) ready=\(readinessCounts["ready", default: 0], privacy: .public) needsMaterialization=\(readinessCounts["needsMaterialization", default: 0], privacy: .public) retryReadiness=\(readinessCounts["retryReadiness", default: 0], privacy: .public) materializationBound=\(readinessCounts["materializationBound", default: 0], privacy: .public)"
                )
            }
            scheduleReadinessRetrySignal()
            logClaimBatch(
                claimedCount: totalExamined,
                dispatchedCount: items.count,
                limit: lastClaimLimit,
                deferredCount: totalDeferred
            )
            return items
        } catch {
            await recordCandidateQueryFailure(error)
            return []
        }
    }

    /// Wakes the coordinator when the earliest deferred readiness probe comes due.
    ///
    /// Past-deadline entries are dropped first, and that prune is the whole point. An
    /// entry is set when a row reads `.unknown` and cleared when that row is re-examined,
    /// so an entry whose deadline has passed means the row was never reached — and it
    /// never will be by waiting, because nothing happens at a deadline that is already
    /// behind us. Left in the map such an entry makes `min()` a past date, `delay`
    /// computes to zero, and the loop becomes sleep(0) -> signal -> pass -> schedule ->
    /// sleep(0) forever.
    ///
    /// Device staging guarantees the condition rather than merely allowing it: while a
    /// camera is staging, `materializationDemands` sits saturated at the outstanding
    /// limit, so every pass takes the early exit in `makeWork` before reaching most rows.
    /// This spun the scheduler for the whole of the 2026-08-30 session, produced the log
    /// flood that lost ~836 download events, and showed up as main-thread stalls in
    /// `reconfigureVisibleItems`.
    ///
    /// A minimum-delay floor would hide this instead of fixing it: the zero delay is a
    /// symptom of state that should have been removed, not of a cadence that is too fast.
    /// Scheduling nothing when the map empties is safe because readiness is not the only
    /// wake source — a completed download admits queued seeds and signals directly.
    private func scheduleReadinessRetrySignal() {
        readinessRetryTask?.cancel()
        let now = Date()
        readinessRetryNotBefore = readinessRetryNotBefore.filter { $0.value > now }
        guard let nextRetry = readinessRetryNotBefore.values.min() else {
            readinessRetryTask = nil
            return
        }
        let delay = max(nextRetry.timeIntervalSince(now), 0)
        readinessRetryTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
            await self?.signal()
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
        prioritizing priorityIDs: [MediaAssetID],
        limit: Int
    ) async throws -> (ready: [ClaimedEnrichmentCandidate], deferredIDs: [MediaAssetID], totalExamined: Int) {
        var ready: [ClaimedEnrichmentCandidate] = []
        var deferredIDs: [MediaAssetID] = []
        var totalExamined = 0
        for _ in 0 ..< Self.maxLedgerSkipPasses {
            let batch = try await claimEnrichmentCandidates(prioritizing: priorityIDs, limit: limit)
            guard !batch.isEmpty else {
                break
            }
            totalExamined += batch.count
            let (batchReady, batchDeferred) = partitionByRetryLedger(batch)
            ready.append(contentsOf: batchReady)
            deferredIDs.append(contentsOf: batchDeferred)
            if !batchReady.isEmpty || batch.count < limit {
                break
            }
        }
        return (ready, deferredIDs, totalExamined)
    }

    /// Consults the pacing ledger a bound-exceeded background retry left behind: a
    /// candidate Store just claimed is deferred back if its earliest reclaim time
    /// has not arrived, unless its `(sourceSize)` fragment of the `(size, mtime)`
    /// source signature (ENR-007) changed since the ledger entry was recorded,
    /// which resets pacing immediately.
    private func partitionByRetryLedger(
        _ candidates: [ClaimedEnrichmentCandidate]
    ) -> (ready: [ClaimedEnrichmentCandidate], deferred: [MediaAssetID]) {
        guard !retryLedger.isEmpty else {
            return (candidates, [])
        }
        var ready: [ClaimedEnrichmentCandidate] = []
        var deferred: [MediaAssetID] = []
        let now = Date()
        for candidate in candidates {
            let asset = candidate.asset
            guard let entry = retryLedger[asset.id] else {
                ready.append(candidate)
                continue
            }
            if entry.sourceSize != asset.byteSize {
                retryLedger[asset.id] = nil
                ready.append(candidate)
            } else if entry.notBefore <= now {
                ready.append(candidate)
            } else {
                deferred.append(asset.id)
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
            guard materializationDemands[work.id] != nil else {
                continue
            }
            materializingIDs.insert(work.id)
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
        for id in viewport where seen.insert(id).inserted {
            ids.append(id)
        }
        for id in freshly.reversed() where seen.insert(id).inserted {
            ids.append(id)
        }
        return ids
    }

    func nextMaterializationWork(excluding excluded: Set<MediaAssetID> = []) -> DownloadWork? {
        let pending = awaitingMaterializationWork
        for id in viewport where !excluded.contains(id) {
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
        return pending.values
            .filter { !excluded.contains($0.id) && !$0.isDeviceStaging && $0.isReadyForRetry }
            .min(by: downloadWorkPrecedes)
    }

    func hasEnrichmentWorkRemaining() -> Bool {
        !readyClaims.isEmpty || !materializationDemands.isEmpty || !pendingApply.isEmpty
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

    var materializingCount: Int {
        materializingIDs.count
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

    var awaitingMaterializationWork: [MediaAssetID: DownloadWork] {
        materializationDemands.filter { !materializingIDs.contains($0.key) }
    }

    private func materializingBackgroundCount(under root: LibraryRootPath) -> Int {
        materializingIDs.count { id in
            materializationDemands[id]?.isDeviceStaging == false && id.libraryRootPath == root
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
    ) async throws -> [ClaimedEnrichmentCandidate] {
        let candidates = try await store.enrichmentCandidates(prioritizing: priorityIDs, limit: limit)
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
            shouldHash: candidate.hashRequired
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
        let materializationInFlightCount = materializingIDs.count
        let facts = SchedulerRouteFacts(
            claimed: claimedCount,
            readyQueued: queuedEnrichmentCount,
            enriching: enrichingCount,
            materializationPending: max(materializationDemands.count - materializationInFlightCount, 0),
            materializationInFlight: materializationInFlightCount,
            pendingApply: pendingApply.count,
            dispatched: dispatchedCount,
            limit: limit,
            deferred: deferredCount
        )
        guard facts != lastSchedulerRoute else {
            suppressedSchedulerRoutes += 1
            return
        }
        var fields = facts.logFields
        fields["suppressedPasses"] = "\(suppressedSchedulerRoutes)"
        lastSchedulerRoute = facts
        suppressedSchedulerRoutes = 0
        OtosLog.metadata.noticeOperation("catalog.enrichment.scheduler", phase: "route", fields: fields)
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
