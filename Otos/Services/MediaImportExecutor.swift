import Foundation
import OSLog
import Synchronization
import UniformTypeIdentifiers

/// Sole owner of destructive source deletion. Import execution and journal
/// recovery may request deletion, but they cannot implement a second delete
/// path. Library roots are intentionally read-only.
/// What one erase attempt did. `deleted` and `alreadyGone` both mean the file is
/// no longer on the source, which is the only thing a journal needs to settle.
nonisolated enum SourceEraseOutcome: Equatable, Sendable {
    case deleted
    /// Not present. The outcome the caller wanted is already true.
    case alreadyGone
    /// This root kind or provider does not permit deletion at all.
    case refused
    /// Present and permitted, and the delete did not succeed.
    case failed

    /// Whether the source no longer holds the file.
    var isSettled: Bool {
        switch self {
        case .deleted, .alreadyGone: true
        case .refused, .failed: false
        }
    }
}

/// The sole owner of destructive source deletion, in fact and not only in a
/// comment: import execution, the erase sweep, and journal recovery all route
/// here, and none of them implements a second delete. Library roots are
/// read-only, so there is exactly one place that decides it.
/// Frees cached camera bytes once an item is durably in the library.
///
/// Deliberately separate from `SourceEraser`, which deletes the user's original off the
/// card when they asked for it. This deletes Otos's own transfer cache and is never a user
/// decision -- confusing the two would be deleting someone's photos.
nonisolated enum StagedSourceReleaser {
    /// Synchronous, and that matters. Settlement runs inside the executor actor for every
    /// copied entry, and `MediaImportRecovery` runs it again for every interrupted one at
    /// `MediaOperationCoordinator.start()`. An `await` here would add a suspension to both
    /// hot paths to delete a file that needs no actor at all.
    static func releaseIfCached(kind: LibraryRootKind, sourceURL: URL) {
        // Only a device root has a cache to release. A removable volume's "source" is the
        // user's own card, and a library's is the user's own file; neither is ours to
        // remove, which is why this switches on kind rather than testing for a file.
        guard kind == .deviceMTP else {
            return
        }
        DeviceStagingLocation.releaseStagedFile(at: sourceURL)
    }
}

nonisolated enum SourceEraser {
    static func erase(
        kind: LibraryRootKind,
        identity: String?,
        relativePath: MediaRelativePath,
        filesystemURL: URL,
        cameraImport: CameraImportAccess?
    ) async -> SourceEraseOutcome {
        switch kind {
        case .library:
            OtosLog.mediaIO.notice(
                "op=source.erase phase=refused reason=libraryReadOnly path=\(relativePath.rawValue, privacy: .public)"
            )
            return .refused
        case .removableVolume:
            guard FileManager.default.fileExists(atPath: filesystemURL.path(percentEncoded: false)) else {
                return .alreadyGone
            }
            do {
                try FileManager.default.removeItem(at: filesystemURL)
                return .deleted
            } catch {
                OtosLog.mediaIO.errorOperation("source.erase", phase: "failed", fields: [
                    "path": relativePath.rawValue,
                    "error": String(describing: error),
                ])
                return .failed
            }
        case .deviceMTP:
            guard let identity, let cameraImport,
                  await cameraImport.canDelete(identity: identity)
            else {
                OtosLog.mediaIO.notice(
                    "op=source.erase phase=refused reason=providerUnsupported path=\(relativePath.rawValue, privacy: .public)"
                )
                return .refused
            }
            guard await cameraImport.deleteItem(identity: identity, relativePath: relativePath) else {
                OtosLog.mediaIO.errorOperation("source.erase", phase: "failed", fields: [
                    "provider": "mtp",
                    "path": relativePath.rawValue,
                ])
                return .failed
            }
            return .deleted
        }
    }
}

/// Filesystem import executor (ARC-048).
///
/// Runs bounded copy lanes for one ready plan: journal → copyfile/camera staging →
/// exclusive publish → durable settlement. Camera downloads reuse enrichment
/// staging when present, revalidate `ICCameraFile` facts, and stamp
/// `destination_modified_at`. Cancellation aborts the in-flight transfer, removes
/// staging, settles any already-published entries, and stops scheduling new ones.
actor MediaImportExecutor {
    static let workerCount = 8
    /// Suffix of the hidden adjacent staging file Otos writes into the destination
    /// root while copying (`.\(UUID().uuidString).otos-import-staging`). Shared with
    /// `CatalogStore`'s filesystem-event path so these Otos-owned transient files
    /// never schedule reconciliation or occupancy bumps.
    static let destinationTempSuffix = ".otos-import-staging"
    private let store: CatalogStore
    private let cameraImport: CameraImportAccess?
    private let materializationRequester: MaterializationRequesting?
    private let cancelFlag = CancelFlag()

    private struct OverlayReuseSummary: Sendable {
        var metadataCloned = 0
        var thumbnailCopied = 0
        var misses: [String: Int] = [:]

        mutating func record(_ result: ImportOverlayReuseResult) {
            if result.metadataCloned {
                metadataCloned += 1
            }
            if result.thumbnailCopied {
                thumbnailCopied += 1
            }
            if let miss = result.miss {
                misses[miss.rawValue, default: 0] += 1
            }
        }

        var missDescription: String {
            misses.keys.sorted().map { "\($0):\(misses[$0] ?? 0)" }.joined(separator: ",")
        }
    }

    /// The floor stop's one fact for the bar: the capacity read when the
    /// run stopped (ADR 0027).
    private struct SpaceStop: Sendable {
        let bytesFree: Int64
    }

    /// What erasing landed entries one by one, as they settled, did. A path it erased or
    /// found already gone is handled, and the end-of-run sweep leaves it alone; a path it
    /// could not erase (another owner held the card, the delete failed) is not, so the
    /// sweep tries it again and counts the outcome.
    private struct LandedEraseTally: Sendable {
        var deleted = 0
        var alreadyGone = 0
        var notErased = 0
        var handled: Set<MediaRelativePath> = []

        mutating func record(_ outcome: SourceEraseOutcome?, path: MediaRelativePath) {
            switch outcome {
            case .deleted:
                deleted += 1
                handled.insert(path)
            case .alreadyGone:
                alreadyGone += 1
                handled.insert(path)
            case .refused, .failed, nil:
                notErased += 1
            }
        }
    }

    private struct EntryTotals: Sendable {
        let publishedCount: Int
        let publishedBytes: Int64
        let failedCount: Int
        let skippedForeignCount: Int
        /// Source (card-side) identities of entries that started this run but
        /// did not land whole — failed, skipped as foreign, or published without a
        /// planned companion — for state F's
        /// "couldn't be copied · Show them" (`import-bar.md` state F). The bar
        /// is drawn only on the card's row, and an item that did not land
        /// exists only there, so the reveal selects the card's own asset —
        /// the same identity state D's attention items use. Blocked entries never reach
        /// execution, so they are not included; they carry their own reveal
        /// via `MediaOperationPlan.attentionItems`.
        let incompleteItems: [MediaAssetID]
        let overlayReuse: OverlayReuseSummary
        /// Set when the run stopped at the disk floor — the first entry that
        /// would have breached it was never submitted (or a write refused for
        /// space first) and nothing after it was attempted. Entries already in
        /// flight finished; the erase sweep did not run.
        let spaceStop: SpaceStop?
        /// Every failed entry's reason, in encounter order — lets `execute()`
        /// tell a systemic failure (every attempted entry failed the same
        /// non-per-file way) from an ordinary per-file one.
        let failureReasons: [EntryFailure]
        let eraseOutcome: EraseOutcome
    }

    private struct EntryExecutionContext: Sendable {
        let plan: MediaOperationPlan
        let batch: ImportBatchID
        let runID: String
        let sourceKind: LibraryRootKind
        let sourceDeviceIdentity: String?
        let allowSourceDeletion: Bool
        let namespaceLease: RootNamespaceMutationLease?
        /// The library the run copies into, for the disk-floor capacity reads.
        /// `execute()` is the one place that already proved `plan.mode` is
        /// `.import` and extracted this; re-deriving it here would just re-run
        /// an already-answered guard.
        let destinationRoot: LibraryRootPath
    }

    /// Copies one removable-volume file into its staging path. The OS copy is
    /// a real substitution boundary: a test that needs a write to refuse for
    /// space (`ENOSPC`) cannot fill a real volume, so it substitutes here.
    typealias VolumeTransfer = @Sendable (
        _ source: URL,
        _ destination: URL,
        _ onProgress: @escaping @Sendable (CopyfileTransfer.Progress) -> Void,
        _ shouldContinue: @escaping @Sendable () -> Bool
    ) -> CopyfileTransfer.Outcome

    /// Reads the destination volume's available capacity for the per-entry
    /// floor check (ADR 0027). Injected for the same reason as
    /// `VolumeTransfer`: the floor is otherwise untestable. The production
    /// reader is `importantUsageCapacity(at:)`.
    private let volumeCapacity: @Sendable (URL) -> Int64?
    private let transfer: VolumeTransfer

    init(
        store: CatalogStore,
        cameraImport: CameraImportAccess? = nil,
        materializationRequester: MaterializationRequesting? = nil,
        volumeCapacity: @escaping @Sendable (URL) -> Int64? = MediaImportExecutor.importantUsageCapacity,
        transfer: @escaping VolumeTransfer = CopyfileTransfer.copy
    ) {
        self.store = store
        self.cameraImport = cameraImport
        self.materializationRequester = materializationRequester
        self.volumeCapacity = volumeCapacity
        self.transfer = transfer
    }

    /// CacheDelete's figure for important usage: it counts purgeable space and
    /// can lag the truth in either direction (research 2026-09-09, finding 4),
    /// which the floor check tolerates in the conservative direction only —
    /// a stale-low figure stops a little early and the remainder is offered
    /// again; a stale-high one is caught by `ENOSPC` one entry later. `nil`
    /// when the volume does not answer, which admits the entry.
    nonisolated static func importantUsageCapacity(at url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    func cancel() {
        cancelFlag.cancel()
    }

    func execute(
        plan: MediaOperationPlan,
        batch: ImportBatchID,
        sourceKind: LibraryRootKind,
        sourceDeviceIdentity: String?,
        deleteSourceRequested: Bool,
        runID: String,
        onProgress: @escaping @Sendable (MediaOperationProgress) -> Void
    ) async -> MediaImportExecutionResult {
        cancelFlag.reset()
        guard case let .import(_, destination, _) = plan.mode else {
            return .failed(.unexpected(detail: "notAnImportPlan"), publishedCount: 0)
        }
        let copyEntries = plan.entries.filter {
            if case .copy = $0.disposition {
                return true
            }
            return false
        }
        // Only sizes the plan knows. An entry whose primary size is unknown is refused
        // before it copies a byte (`missingPlannedByteSize`), so it adds nothing here.
        let totalBytes = copyEntries.compactMap(\.source.byteSize).reduce(0, +)
        // No run-level free-space check: an import that cannot fit whole is
        // copied up to the floor and stopped as a designed outcome (ADR 0027).
        // The check is per entry, inside `runPlanEntries`.
        let hasBlockedEntries = plan.entries.contains {
            if case .blocked = $0.disposition {
                return true
            }
            return false
        }
        let allowSourceDeletion = deleteSourceRequested && !hasBlockedEntries
        let namespaceLease: RootNamespaceMutationLease?
        if copyEntries.isEmpty {
            namespaceLease = nil
        } else {
            switch await store.acquireNamespaceMutationLease(
                for: destination,
                owner: .importPublication
            ) {
            case let .acquired(lease):
                namespaceLease = lease
            case .rootNotRegistered:
                return .failed(.destinationUnavailable, publishedCount: 0)
            case .catalogUnavailable:
                // Not `.destinationUnavailable`: the catalog never loaded, so
                // whether the library is there is unknown.
                return .failed(.unexpected(detail: "catalogUnavailable"), publishedCount: 0)
            case let .busy(owner):
                // The library *is* available; another namespace mutation owns it.
                // Saying "isn't available" would be false, and the bar has no
                // vocabulary for "busy" — `.unexpected`'s detail is for the log
                // only (`MediaOperationModels.swift`), which is exactly right here.
                return .failed(.unexpected(detail: "destinationNamespaceBusy:\(owner.rawValue)"), publishedCount: 0)
            }
        }
        // The erase lease is deliberately *not* taken here. It is only needed by
        // `eraseSourceFiles`, which runs after every copy completes; holding it
        // across a full card's copy suppressed the source root's filesystem
        // reconcile and scan scheduling for the whole batch, and a momentarily
        // busy source aborted the import before a single byte moved.
        let started = ContinuousClock().now
        let batchSignpost = OtosSignpost.mediaIO.beginInterval("MediaImportBatch")
        OtosLog.mediaIO.noticeOperation("mediaOperation.batch", phase: "start", fields: [
            "batch": "\(batch.unixMilliseconds)",
            "run": runID,
            "bytes": "\(totalBytes)",
            "files": "\(copyEntries.count)",
            "workers": "\(Self.workerCount)",
        ])
        let executionContext = EntryExecutionContext(
            plan: plan,
            batch: batch,
            runID: runID,
            sourceKind: sourceKind,
            sourceDeviceIdentity: sourceDeviceIdentity,
            allowSourceDeletion: allowSourceDeletion,
            namespaceLease: namespaceLease,
            destinationRoot: destination
        )
        let entryTotals = await runPlanEntries(
            context: executionContext,
            totalCount: copyEntries.count,
            totalBytes: totalBytes,
            onProgress: onProgress
        )
        if let namespaceLease {
            _ = await store.releaseNamespaceMutationLease(namespaceLease)
        }
        // The catalog's own count of the batch checks the run's: a mismatch is a fault. A
        // count that could not be read proves nothing either way, so it is logged and the
        // run's outcome stands on what the run itself observed.
        let batchIntegrityMismatch: Bool
        do {
            let storedBatchCount = try await store.importBatchAssetCount(batch)
            batchIntegrityMismatch = storedBatchCount != entryTotals.publishedCount
            OtosLog.catalog.notice(
                "op=mediaOperation.batch phase=verified run=\(runID, privacy: .public) batch=\(batch.unixMilliseconds, privacy: .public) expectedPublished=\(entryTotals.publishedCount, privacy: .public) storedBatchCount=\(storedBatchCount, privacy: .public) skippedPreexisting=\(plan.totals.skipCount, privacy: .public) skippedForeign=\(entryTotals.skippedForeignCount, privacy: .public) failed=\(entryTotals.failedCount, privacy: .public) blocked=\(plan.totals.blockedCount, privacy: .public)"
            )
            if batchIntegrityMismatch {
                OtosLog.catalog.fault(
                    "op=mediaOperation.batch phase=integrityMismatch run=\(runID, privacy: .public) batch=\(batch.unixMilliseconds, privacy: .public) expectedPublished=\(entryTotals.publishedCount, privacy: .public) storedBatchCount=\(storedBatchCount, privacy: .public)"
                )
            }
        } catch {
            batchIntegrityMismatch = false
            OtosLog.catalog.errorOperation("mediaOperation.batch", phase: "verificationUnavailable", fields: [
                "run": runID,
                "batch": "\(batch.unixMilliseconds)",
                "error": String(describing: error),
            ])
        }
        OtosLog.catalog.notice(
            "op=mediaOperation.batch phase=overlayReuse run=\(runID, privacy: .public) batch=\(batch.unixMilliseconds, privacy: .public) metadataCloned=\(entryTotals.overlayReuse.metadataCloned, privacy: .public) thumbnailCopied=\(entryTotals.overlayReuse.thumbnailCopied, privacy: .public) misses=\(entryTotals.overlayReuse.missDescription, privacy: .public)"
        )
        OtosSignpost.mediaIO.endInterval("MediaImportBatch", batchSignpost)
        let elapsedMs = max(DiagnosticsTiming.milliseconds(from: started, to: .now), 1)
        OtosLog.mediaIO.noticeOperation("mediaOperation.batch", phase: "finish", fields: [
            "batch": "\(batch.unixMilliseconds)",
            "run": runID,
            "bytes": "\(entryTotals.publishedBytes)",
            "elapsedMs": "\(elapsedMs)",
            "files": "\(copyEntries.count)",
            "mbps": throughputMBps(bytes: entryTotals.publishedBytes, elapsedMs: elapsedMs),
            "workers": "\(Self.workerCount)",
        ])
        let tally = MediaImportRunTally(
            publishedCount: entryTotals.publishedCount,
            hasBlockedEntries: hasBlockedEntries,
            hasEntryFailures: entryTotals.failedCount > 0 || batchIntegrityMismatch,
            skippedForeignCount: entryTotals.skippedForeignCount,
            failedCount: entryTotals.failedCount
        )
        if cancelFlag.isCancelled {
            return .stopped(.user, tally)
        }
        if let spaceStop = entryTotals.spaceStop {
            return .stopped(.diskFloor(bytesFree: spaceStop.bytesFree), tally)
        }
        // Every attempted entry failing the same non-per-file way means the source
        // itself wasn't ready — a systemic cause, not per-file damage. Report it as
        // a run failure rather than the misleading "N of N files failed" shape of
        // `.completed(failedCount:)`. `ImportSourceReadiness` (ADR 0024) should
        // make this unreachable in normal operation; this is a backstop so a
        // gate miss still produces a true statement instead of "Done".
        let allFailedWithSourceNotReady = !copyEntries.isEmpty
            && entryTotals.publishedCount == 0
            && entryTotals.skippedForeignCount == 0
            && entryTotals.failedCount == copyEntries.count
            && entryTotals.failureReasons.allSatisfy { $0 == .sourceNotReady }
        if allFailedWithSourceNotReady {
            return .failed(.sourceNotReady, publishedCount: entryTotals.publishedCount)
        }
        return .completed(
            tally,
            incompleteItems: entryTotals.incompleteItems,
            erase: deleteSourceRequested ? entryTotals.eraseOutcome : nil
        )
    }

    private func runPlanEntries(
        context: EntryExecutionContext,
        totalCount: Int,
        totalBytes: Int64,
        onProgress: @escaping @Sendable (MediaOperationProgress) -> Void
    ) async -> EntryTotals {
        var publishedCount = 0
        var publishedBytes: Int64 = 0
        var failedCount = 0
        var skippedForeignCount = 0
        var incompleteItems: [MediaAssetID] = []
        // The source paths whose bytes are proven in the library: each published
        // primary and the companions that were copied with it. Erase deletes no other.
        var erasableSourcePaths: Set<MediaRelativePath> = []
        var overlayReuse = OverlayReuseSummary()
        var failureReasons: [EntryFailure] = []
        let copyEntries = context.plan.entries.filter {
            if case .copy = $0.disposition {
                true
            } else {
                false
            }
        }
        let byteProgress = ByteProgressTracker(totalCount: totalCount, totalBytes: totalBytes)
        let destinationURL = URL(fileURLWithPath: context.destinationRoot.rawValue, isDirectory: true)
        // ADR 0027: a landed entry's source is erased on its own settle, so a floor stop
        // still erases what landed. One consumer takes them in settle order, each under
        // the card's namespace lease and journaled; the run waits for it before the sweep.
        let (landedSources, landedSink) = AsyncStream<MediaOperationPlanEntry>.makeStream(bufferingPolicy: .unbounded)
        let landedEraser: Task<LandedEraseTally, Never>? = context.allowSourceDeletion
            ? Task { [weak self] in
                var tally = LandedEraseTally()
                for await entry in landedSources {
                    guard let self else { break }
                    let outcome = await eraseLandedSource(entry, context: context)
                    tally.record(outcome, path: entry.source.relativePath)
                }
                return tally
            }
            : nil
        // ADR 0027: an entry is admitted only while the destination volume
        // keeps the floor after it *and every entry still in flight* lands.
        // With `workerCount` entries in flight, a check that looked only at
        // the next one could overshoot the floor by that many items.
        // The stop is the group body's result rather than a captured variable
        // read after it: region isolation would otherwise see a value written
        // inside the actor-isolated closure and read after it as a race.
        let spaceStop: SpaceStop? = await withTaskGroup(of: EntryResult.self, returning: SpaceStop?.self) { group in
            var nextIndex = 0
            var inFlightBytes: Int64 = 0
            var inFlightByIndex: [Int: Int64] = [:]
            var spaceStop: SpaceStop?
            /// The entry's bytes the plan knows, and how many of its files it has no size
            /// for. Unknown is not zero: such a file is admitted on the known bytes alone,
            /// with `ENOSPC` as the backstop — the same rule as a volume that reports no
            /// capacity — and the admission says so.
            func plannedBytes(_ index: Int) -> (known: Int64, unknownCount: Int) {
                let source = copyEntries[index].source
                let sizes = [source.byteSize] + source.companions.map(\.byteSize)
                return (sizes.compactMap(\.self).reduce(0, +), sizes.count { $0 == nil })
            }
            /// Whether the entry at `index` fits above the floor. Refusing one
            /// entry ends admission for the run; entries already in flight were
            /// admitted with their bytes counted and are left to land.
            func admits(_ index: Int) -> Bool {
                guard spaceStop == nil else {
                    return false
                }
                guard let capacity = self.volumeCapacity(destinationURL) else {
                    // The volume does not answer: admit, and let `ENOSPC` be the backstop.
                    return true
                }
                let (entryBytes, unknownCount) = plannedBytes(index)
                if unknownCount > 0 {
                    OtosLog.mediaIO.noticeOperation("mediaOperation.batch", phase: "admitUnknownSize", fields: [
                        "run": context.runID,
                        "index": "\(index)",
                        "knownBytes": "\(entryBytes)",
                        "unknownSizeCount": "\(unknownCount)",
                    ])
                }
                guard capacity - inFlightBytes - entryBytes >= FreeSpaceFloor.bytes else {
                    spaceStop = SpaceStop(bytesFree: capacity)
                    OtosLog.mediaIO.noticeOperation("mediaOperation.batch", phase: "diskFloor", fields: [
                        "run": context.runID,
                        "batch": "\(context.batch.unixMilliseconds)",
                        "nextIndex": "\(index)",
                        "entryBytes": "\(entryBytes)",
                        "inFlightBytes": "\(inFlightBytes)",
                        "capacity": "\(capacity)",
                        "floor": "\(FreeSpaceFloor.bytes)",
                    ])
                    return false
                }
                return true
            }
            func submit(_ index: Int) {
                let entry = copyEntries[index]
                let bytes = plannedBytes(index).known
                inFlightBytes += bytes
                inFlightByIndex[index] = bytes
                group.addTask {
                    guard !self.cancelFlag.isCancelled else {
                        return EntryResult(index: index, outcome: .cancelled)
                    }
                    let outcome = await self.copyEntry(
                        entry,
                        context: context,
                        workerID: index % Self.workerCount,
                        onByteProgress: { offset in
                            // Worker-thread callback: the tracker gates emissions so
                            // a fast copy cannot flood the coordinator stream.
                            if let snapshot = byteProgress.inFlightUpdate(index: index, offset: offset) {
                                onProgress(snapshot)
                            }
                        }
                    )
                    return EntryResult(index: index, outcome: outcome)
                }
            }
            while nextIndex < min(Self.workerCount, copyEntries.count), admits(nextIndex) {
                submit(nextIndex)
                nextIndex += 1
            }
            while let result = await group.next() {
                inFlightBytes -= inFlightByIndex.removeValue(forKey: result.index) ?? 0
                switch result.outcome {
                case let .published(reuseResult, bytes, companionsNotCopied):
                    let entry = copyEntries[result.index]
                    let notCopied = Set(companionsNotCopied)
                    erasableSourcePaths.insert(entry.source.relativePath)
                    landedSink.yield(entry)
                    for companion in entry.companionDestinations.keys where !notCopied.contains(companion) {
                        erasableSourcePaths.insert(companion)
                    }
                    if notCopied.isEmpty {
                        publishedCount += 1
                    } else {
                        failedCount += 1
                        failureReasons.append(.companionNotCopied)
                        incompleteItems.append(entry.source.id)
                    }
                    publishedBytes += bytes
                    overlayReuse.record(reuseResult)
                    byteProgress.finish(index: result.index, resolvedItem: true, publishedBytes: bytes)
                case .cancelled:
                    cancelFlag.cancel()
                    byteProgress.finish(index: result.index, resolvedItem: false, publishedBytes: 0)
                case .skippedForeign:
                    skippedForeignCount += 1
                    incompleteItems.append(copyEntries[result.index].source.id)
                    byteProgress.finish(index: result.index, resolvedItem: true, publishedBytes: 0)
                case .failed(.outOfSpace):
                    // The floor reached the hard way. Not a failed entry — it
                    // never landed and the re-plan offers it again — so it is
                    // neither counted nor revealed; it ends admission.
                    if spaceStop == nil {
                        spaceStop = SpaceStop(bytesFree: self.volumeCapacity(destinationURL) ?? 0)
                        OtosLog.mediaIO.noticeOperation("mediaOperation.batch", phase: "diskFloor", fields: [
                            "run": context.runID,
                            "batch": "\(context.batch.unixMilliseconds)",
                            "reason": "enospc",
                            "index": "\(result.index)",
                        ])
                    }
                    byteProgress.finish(index: result.index, resolvedItem: false, publishedBytes: 0)
                case let .failed(failure):
                    failedCount += 1
                    failureReasons.append(failure)
                    incompleteItems.append(copyEntries[result.index].source.id)
                    byteProgress.finish(index: result.index, resolvedItem: true, publishedBytes: 0)
                }
                onProgress(byteProgress.current())
                if nextIndex < copyEntries.count, !cancelFlag.isCancelled, admits(nextIndex) {
                    submit(nextIndex)
                    nextIndex += 1
                }
            }
            return spaceStop
        }
        landedSink.finish()
        let landed = await landedEraser?.value ?? LandedEraseTally()
        // A floor stop is never fully clean: the un-copied entries exist only
        // on the card, so the erase sweep does not run (ADR 0027); what it reports is
        // what erasing landed entries did.
        if context.allowSourceDeletion, spaceStop == nil {
            let sweep = await eraseSourceFiles(
                context: context,
                erasableSourcePaths: erasableSourcePaths.subtracting(landed.handled)
            )
            let eraseOutcome = EraseOutcome(
                deletedCount: landed.deleted + sweep.deletedCount,
                skippedCount: landed.alreadyGone + sweep.skippedCount,
                failedCount: sweep.failedCount
            )
            logEraseOutcome(eraseOutcome, landed: landed, context: context)
            return EntryTotals(
                publishedCount: publishedCount,
                publishedBytes: publishedBytes,
                failedCount: failedCount,
                skippedForeignCount: skippedForeignCount,
                incompleteItems: incompleteItems,
                overlayReuse: overlayReuse,
                spaceStop: nil,
                failureReasons: failureReasons,
                eraseOutcome: eraseOutcome
            )
        }
        return EntryTotals(
            publishedCount: publishedCount,
            publishedBytes: publishedBytes,
            failedCount: failedCount,
            skippedForeignCount: skippedForeignCount,
            incompleteItems: incompleteItems,
            overlayReuse: overlayReuse,
            spaceStop: spaceStop,
            failureReasons: failureReasons,
            eraseOutcome: landedOnlyOutcome(landed, context: context)
        )
    }

    /// The erase outcome of a run whose sweep did not run: what erasing landed entries did,
    /// with every landed entry it could not erase counted as failed, since nothing retries it.
    private func landedOnlyOutcome(_ landed: LandedEraseTally, context: EntryExecutionContext) -> EraseOutcome {
        let outcome = EraseOutcome(
            deletedCount: landed.deleted,
            skippedCount: landed.alreadyGone,
            failedCount: landed.notErased
        )
        if context.allowSourceDeletion {
            logEraseOutcome(outcome, landed: landed, context: context)
        }
        return outcome
    }

    private func logEraseOutcome(_ outcome: EraseOutcome, landed: LandedEraseTally, context: EntryExecutionContext) {
        OtosLog.mediaIO.noticeOperation("import.erase", phase: "outcome", fields: [
            "run": context.runID,
            "deleted": "\(outcome.deletedCount)",
            "skipped": "\(outcome.skippedCount)",
            "failed": "\(outcome.failedCount)",
            "landedDeleted": "\(landed.deleted)",
            "landedAlreadyGone": "\(landed.alreadyGone)",
            "landedNotErased": "\(landed.notErased)",
        ])
    }

    private func eraseSourceFiles(
        context: EntryExecutionContext,
        erasableSourcePaths: Set<MediaRelativePath>
    ) async -> EraseOutcome {
        guard case let .import(sourceRoot, _, _) = context.plan.mode else {
            return EraseOutcome(deletedCount: 0, skippedCount: 0, failedCount: 0)
        }
        let candidates = sourceDeletionCandidates(plan: context.plan, erasableSourcePaths: erasableSourcePaths)
        // Acquired here, not in `execute()`: the copy phase has already finished,
        // so this holds the source root's namespace for the erase sweep only. A
        // denial leaves every candidate un-erased and is reported as an incomplete
        // erase — the copies stand, and `import-bar.md` already specifies that
        // state. It must never fail the import, and must never claim the card is
        // gone when another owner merely holds the lease.
        let sourceNamespaceLease: RootNamespaceMutationLease
        let acquisition = await store.acquireNamespaceMutationLease(for: sourceRoot, owner: .sourceErase)
        switch acquisition {
        case let .acquired(lease):
            sourceNamespaceLease = lease
        case let .busy(owner):
            OtosLog.mediaIO.errorOperation("import.erase", phase: "blocked", fields: [
                "run": context.runID,
                "reason": "namespaceBusy",
                "heldBy": owner.rawValue,
                "rootPath": sourceRoot.rawValue,
                "unerasedCount": "\(candidates.count)",
            ])
            return EraseOutcome(
                deletedCount: 0,
                skippedCount: 0,
                failedCount: candidates.count
            )
        case .rootNotRegistered, .catalogUnavailable:
            OtosLog.mediaIO.errorOperation("import.erase", phase: "blocked", fields: [
                "run": context.runID,
                "reason": acquisition.logReason,
                "rootPath": sourceRoot.rawValue,
                "unerasedCount": "\(candidates.count)",
            ])
            return EraseOutcome(
                deletedCount: 0,
                skippedCount: 0,
                failedCount: candidates.count
            )
        }
        OtosLog.mediaIO.noticeOperation("import.erase", phase: "start", fields: [
            "run": context.runID,
            "rootPath": sourceRoot.rawValue,
            "plannedCount": "\(candidates.count)",
        ])
        var deleted = 0
        // What the plan recorded for each deleted entry. The delete itself reports no
        // size (a camera says only that it succeeded), so this is the plan's fact, and
        // an entry whose size the plan never had is counted rather than taken as zero.
        var plannedBytes: Int64 = 0
        var unknownSizeCount = 0
        var skipped = 0
        var failed = 0
        var logged = 0
        for candidate in candidates {
            guard !cancelFlag.isCancelled else { break }
            let journal = ActiveSourceEraseOperation(
                key: .make(),
                sourceKind: context.sourceKind,
                sourceDeviceIdentity: context.sourceDeviceIdentity,
                sourceRootPath: sourceRoot,
                sourceRelativePath: candidate.relativePath,
                sourceByteSize: candidate.byteSize,
                updatedAt: Date()
            )
            do {
                try await store.beginSourceEraseOperation(journal)
            } catch {
                failed += 1
                continue
            }
            let result = await eraseSourceFile(
                candidate: candidate,
                sourceRoot: sourceRoot,
                sourceKind: context.sourceKind,
                sourceDeviceIdentity: context.sourceDeviceIdentity
            )
            switch result {
            case .deleted:
                deleted += 1
                if let byteSize = candidate.byteSize {
                    plannedBytes += byteSize
                } else {
                    unknownSizeCount += 1
                }
                if logged < 20 {
                    OtosLog.mediaIO.noticeOperation("import.erase", phase: "deleted", fields: [
                        "run": context.runID,
                        "relativePath": candidate.relativePath.rawValue,
                        "plannedBytes": candidate.byteSize.map { "\($0)" } ?? "unknown",
                    ])
                    logged += 1
                }
                await ImportStaging.completeEraseJournal(journal.key, store: store)
            case .alreadyGone:
                skipped += 1
                await ImportStaging.completeEraseJournal(journal.key, store: store)
            case .refused, .failed:
                failed += 1
            }
        }
        let message = "op=import.erase phase=finish "
            + "run=\(context.runID) "
            + "rootPath=\(sourceRoot.rawValue) "
            + "manifestCount=\(context.plan.eraseManifest.count) "
            + "deleted=\(deleted) "
            + "skipped=\(skipped) "
            + "failed=\(failed) "
            + "plannedBytes=\(plannedBytes) "
            + "unknownSizeCount=\(unknownSizeCount) "
            + "logged=\(logged)"
        OtosLog.mediaIO.notice("\(message, privacy: .public)")
        _ = await store.releaseNamespaceMutationLease(sourceNamespaceLease)
        return EraseOutcome(
            deletedCount: deleted,
            skippedCount: skipped,
            failedCount: failed
        )
    }

    private func sourceDeletionCandidates(
        plan: MediaOperationPlan,
        erasableSourcePaths publishedPaths: Set<MediaRelativePath>
    ) -> [EraseManifestEntry] {
        let retainedPaths = Set(plan.entries.compactMap { entry -> MediaRelativePath? in
            switch entry.disposition {
            case .skipPreexisting, .excluded:
                entry.source.relativePath
            case .copy, .blocked:
                nil
            }
        })
        return plan.eraseManifest.entries.filter {
            publishedPaths.contains($0.relativePath) || retainedPaths.contains($0.relativePath)
        }
    }

    /// Validates containment, then delegates. There is no second delete here:
    /// this once carried its own `FileManager.removeItem` for `.removableVolume`
    /// *and* `.library`, which contradicted `SourceEraser`'s own read-only rule
    /// for library roots.
    /// Erases one landed entry's source as soon as it settled (ADR 0027), under the
    /// card's namespace lease and journaled exactly as the sweep journals, so a crash
    /// between the two is recovered. A card another owner holds keeps the file; the
    /// end-of-run sweep tries again under its own lease.
    /// Returns what the erase did, or `nil` when it was not attempted: another owner held
    /// the card, or the journal could not record it.
    private func eraseLandedSource(
        _ entry: MediaOperationPlanEntry,
        context: EntryExecutionContext
    ) async -> SourceEraseOutcome? {
        guard case let .import(sourceRoot, _, _) = context.plan.mode else { return nil }
        let acquisition = await store.acquireNamespaceMutationLease(for: sourceRoot, owner: .sourceErase)
        guard case let .acquired(lease) = acquisition else {
            OtosLog.mediaIO.noticeOperation("import.erase", phase: "landedDeferred", fields: [
                "run": context.runID,
                "reason": acquisition.logReason,
                "relativePath": entry.source.relativePath.rawValue,
            ])
            return nil
        }
        let journal = ActiveSourceEraseOperation(
            key: .make(),
            sourceKind: context.sourceKind,
            sourceDeviceIdentity: context.sourceDeviceIdentity,
            sourceRootPath: sourceRoot,
            sourceRelativePath: entry.source.relativePath,
            sourceByteSize: entry.source.byteSize,
            updatedAt: Date()
        )
        let outcome: SourceEraseOutcome?
        do {
            try await store.beginSourceEraseOperation(journal)
            let erased = await eraseSourceFile(
                candidate: EraseManifestEntry(
                    relativePath: entry.source.relativePath,
                    byteSize: entry.source.byteSize,
                    fileClass: .classify(relativePath: entry.source.relativePath)
                ),
                sourceRoot: sourceRoot,
                sourceKind: context.sourceKind,
                sourceDeviceIdentity: context.sourceDeviceIdentity
            )
            switch erased {
            case .deleted, .alreadyGone:
                await ImportStaging.completeEraseJournal(journal.key, store: store)
            case .refused, .failed:
                OtosLog.mediaIO.errorOperation("import.erase", phase: "landedNotErased", fields: [
                    "run": context.runID,
                    "relativePath": entry.source.relativePath.rawValue,
                ])
            }
            outcome = erased
        } catch {
            OtosLog.mediaIO.errorOperation("import.erase", phase: "landedJournalFailed", fields: [
                "run": context.runID,
                "relativePath": entry.source.relativePath.rawValue,
                "error": String(describing: error),
            ])
            outcome = nil
        }
        _ = await store.releaseNamespaceMutationLease(lease)
        return outcome
    }

    private func eraseSourceFile(
        candidate: EraseManifestEntry,
        sourceRoot: LibraryRootPath,
        sourceKind: LibraryRootKind,
        sourceDeviceIdentity: String?
    ) async -> SourceEraseOutcome {
        let relativePath = candidate.relativePath
        guard !relativePath.rawValue.split(separator: "/").contains("..") else { return .failed }
        let url = sourceRoot.url.appending(path: relativePath.rawValue).standardizedFileURL
        guard CatalogPath.relativePath(rootPath: sourceRoot, fileURL: url) == relativePath else {
            return .failed
        }
        return await SourceEraser.erase(
            kind: sourceKind,
            identity: sourceDeviceIdentity,
            relativePath: relativePath,
            filesystemURL: url,
            cameraImport: cameraImport
        )
    }

    /// Why one plan entry failed to copy. `.sourceNotReady` is the only
    /// systemic reason — `execute()` classifies a run as `.failed` rather than
    /// `.completed(failedCount:)` when every attempted entry failed with this
    /// same reason; every other case is inherently per-file and never
    /// drives that classification.
    private enum EntryFailure: Equatable, Sendable {
        case sourceNotReady
        case sourceChanged(ChangedFact)
        case sourceAbsent
        /// The write refused for space (`ENOSPC`). Not a per-file fault: the
        /// entry never landed and the re-plan offers it again, so it is not
        /// counted as failed — it stops the run at the floor instead
        /// (ADR 0027, the backstop for a capacity figure that lied).
        case outOfSpace
        /// The primary landed but a planned companion did not: the item is not whole in
        /// the library, so it is not counted as copied, and the re-plan offers the
        /// companion again.
        case companionNotCopied
        case other

        init(_ validation: SourceValidation) {
            switch validation {
            case .matches: self = .other // unreachable: callers only convert a non-match.
            case .sourceNotReady: self = .sourceNotReady
            case let .changed(fact): self = .sourceChanged(fact)
            case .absent: self = .sourceAbsent
            }
        }
    }

    private enum EntryOutcome: Sendable {
        /// The primary is published, `bytes` long as it settled. `companionsNotCopied` are
        /// the source paths of companions that did not reach the library: they are not
        /// recorded, and their sources are never erased.
        case published(ImportOverlayReuseResult, bytes: Int64, companionsNotCopied: [MediaRelativePath])
        case skippedForeign
        case cancelled
        case failed(EntryFailure)
    }

    private struct EntryResult: Sendable {
        let index: Int
        let outcome: EntryOutcome
    }

    private nonisolated func sourceStillMatches(
        entry: MediaOperationPlanEntry,
        sourceKind: LibraryRootKind,
        sourceDeviceIdentity: String?,
        sourceURL: URL,
        sourceByteSize: Int64,
        sourceModified: Date?
    ) async -> SourceValidation {
        switch sourceKind {
        case .removableVolume:
            guard let sourceModified else {
                return .changed(.date)
            }
            return Self.fileValidation(url: sourceURL, byteSize: sourceByteSize, modifiedAt: sourceModified)
        case .deviceMTP:
            guard let identity = sourceDeviceIdentity, let cameraImport else {
                return .sourceNotReady
            }
            return await cameraImport.revalidateItem(
                identity: identity,
                relativePath: entry.source.relativePath,
                byteSize: sourceByteSize,
                modifiedAt: sourceModified
            )
        case .library:
            guard let sourceModified else {
                return .changed(.date)
            }
            return Self.fileValidation(url: sourceURL, byteSize: sourceByteSize, modifiedAt: sourceModified)
        }
    }

    private nonisolated func transferBytesToStaging(
        entry: MediaOperationPlanEntry,
        sourceKind: LibraryRootKind,
        sourceDeviceIdentity: String?,
        sourceURL: URL,
        stagingURL: URL,
        operationKey: ActiveFileOperationKey,
        onByteProgress: @escaping @Sendable (Int64) -> Void
    ) async -> EntryOutcome? {
        switch sourceKind {
        case .removableVolume:
            return await transferVolumeBytes(
                from: sourceURL,
                to: stagingURL,
                operationKey: operationKey,
                onByteProgress: onByteProgress
            )
        case .deviceMTP:
            return await transferCameraBytes(
                entry: entry,
                identity: sourceDeviceIdentity,
                enrichmentURL: sourceURL,
                stagingURL: stagingURL,
                operationKey: operationKey,
                onByteProgress: onByteProgress
            )
        case .library:
            await Self.abandonEntry(operationKey, stagingFiles: [], store: store, reason: "libraryAsSource")
            return .failed(.other)
        }
    }

    private nonisolated func transferVolumeBytes(
        from sourceURL: URL,
        to stagingURL: URL,
        operationKey: ActiveFileOperationKey,
        onByteProgress: @escaping @Sendable (Int64) -> Void
    ) async -> EntryOutcome? {
        let copyOutcome = await copyOffActor(from: sourceURL, to: stagingURL, onByteProgress: onByteProgress)
        if cancelFlag.isCancelled || copyOutcome == .cancelled {
            await Self.abandonEntry(operationKey, stagingFiles: [stagingURL], store: store, reason: "cancelled")
            return .cancelled
        }
        if case let .failed(code) = copyOutcome {
            await Self.abandonEntry(operationKey, stagingFiles: [stagingURL], store: store, reason: "transferFailed")
            OtosLog.catalog.error(
                "op=mediaOperation.copy phase=failed errno=\(code, privacy: .public)"
            )
            return .failed(code == ENOSPC ? .outOfSpace : .other)
        }
        return nil
    }

    /// The injected `transfer` blocks for the whole copy, so it runs on a detached task
    /// rather than on a cooperative-pool thread or the executor actor.
    private nonisolated func copyOffActor(
        from sourceURL: URL,
        to stagingURL: URL,
        onByteProgress: @escaping @Sendable (Int64) -> Void
    ) async -> CopyfileTransfer.Outcome {
        let sharedCancel = cancelFlag
        let transfer = transfer
        return await withCheckedContinuation { continuation in
            Task.detached {
                continuation.resume(returning: transfer(
                    sourceURL,
                    stagingURL,
                    { progress in onByteProgress(progress.completedBytes) },
                    { !sharedCancel.isCancelled }
                ))
            }
        }
    }

    private nonisolated func transferCameraBytes(
        entry: MediaOperationPlanEntry,
        identity: String?,
        enrichmentURL: URL,
        stagingURL: URL,
        operationKey: ActiveFileOperationKey,
        onByteProgress: @escaping @Sendable (Int64) -> Void
    ) async -> EntryOutcome? {
        guard let identity, let cameraImport else {
            await Self.abandonEntry(operationKey, stagingFiles: [], store: store, reason: "cameraUnavailable")
            return .failed(.other)
        }
        if cancelFlag.isCancelled {
            await Self.abandonEntry(operationKey, stagingFiles: [stagingURL], store: store, reason: "cancelled")
            return .cancelled
        }
        switch await cameraImport.ensureImportBytes(
            identity: identity,
            relativePath: entry.source.relativePath,
            enrichmentURL: enrichmentURL,
            destinationTempURL: stagingURL
        ) {
        case .completed:
            if let size = try? stagingURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                onByteProgress(Int64(size))
            }
            return nil
        case .cancelled:
            await Self.abandonEntry(operationKey, stagingFiles: [stagingURL], store: store, reason: "cancelled")
            return .cancelled
        case .failed(.outOfSpace):
            // The staging write refused for space: the floor, reached the hard
            // way, on a camera — the same stop as a refused `copyfile` on a card.
            await Self.abandonEntry(operationKey, stagingFiles: [stagingURL], store: store, reason: "outOfSpace")
            return .failed(.outOfSpace)
        case let .failed(.other(message)):
            await Self.abandonEntry(operationKey, stagingFiles: [stagingURL], store: store, reason: "transferFailed")
            OtosLog.catalog.error(
                "op=mediaOperation.camera phase=failed detail=\(message, privacy: .public)"
            )
            return .failed(.other)
        }
    }

    /// A companion copied into a hidden staging file beside its own final path. It is
    /// published after its primary, exclusively, and recorded only once it is there.
    private struct StagedCompanion: Sendable {
        let source: MediaCompanion
        let destinationRelative: MediaRelativePath
        let stagingURL: URL
        let finalURL: URL
    }

    private enum CompanionStaging: Sendable {
        /// `notCopied` are planned companions whose bytes did not reach staging: the
        /// primary still imports, and the item is reported incomplete.
        case staged([StagedCompanion], notCopied: [MediaRelativePath])
        /// A cancel or a full volume stops the whole entry, as it would for the primary.
        case stop(EntryOutcome)
    }

    /// Copies each planned companion into staging beside its final destination, through
    /// the same byte path as the primary. A failed companion is reported, never recorded.
    /// Copies each planned companion to a staging file beside its destination. Every
    /// staging path is journaled on the entry before the file is created, so a process
    /// that ends mid-companion leaves nothing recovery cannot find. On `.stop` the
    /// caller abandons the entry, which removes every staging file the journal names.
    private nonisolated func stageCompanions(
        entry: MediaOperationPlanEntry,
        operation: inout ActiveFileOperation,
        sourceKind: LibraryRootKind,
        sourceDeviceIdentity: String?,
        destinationRoot: LibraryRootPath
    ) async -> CompanionStaging {
        var staged: [StagedCompanion] = []
        var notCopied: [MediaRelativePath] = []
        for companion in entry.source.companions {
            guard let destinationRelative = entry.companionDestinations[companion.relativePath] else {
                continue
            }
            if cancelFlag.isCancelled {
                return .stop(.cancelled)
            }
            let finalURL = destinationRoot.url.appendingPathComponent(destinationRelative.rawValue)
            let stagingURL = Self.stagingURL(adjacentTo: finalURL)
            let sourceURL = entry.source.sourceURL
                .deletingLastPathComponent()
                .appendingPathComponent(companion.relativePath.fileName)
            operation.companionStagingURLs.append(stagingURL)
            operation.updatedAt = Date()
            do {
                try await store.recordImportOperationProgress(operation)
                try FileManager.default.createDirectory(
                    at: stagingURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
            } catch {
                OtosLog.mediaIO.errorOperation("mediaOperation.companion", phase: "stagingUnavailable", fields: [
                    "relativePath": companion.relativePath.rawValue,
                    "error": String(describing: error),
                ])
                return .stop(.failed(.other))
            }
            let result = await companionBytes(
                companion: companion,
                sourceKind: sourceKind,
                sourceDeviceIdentity: sourceDeviceIdentity,
                sourceURL: sourceURL,
                stagingURL: stagingURL
            )
            switch result {
            case .copied:
                if let modified = companion.contentModifiedAt {
                    Self.stampModificationDate(modified, at: stagingURL)
                }
                staged.append(StagedCompanion(
                    source: companion,
                    destinationRelative: destinationRelative,
                    stagingURL: stagingURL,
                    finalURL: finalURL
                ))
            case .cancelled:
                return .stop(.cancelled)
            case .outOfSpace:
                return .stop(.failed(.outOfSpace))
            case let .failed(detail):
                ImportStaging.remove([stagingURL], key: operation.operationKey, reason: "companionNotCopied")
                notCopied.append(companion.relativePath)
                OtosLog.mediaIO.errorOperation("mediaOperation.companion", phase: "notCopied", fields: [
                    "relativePath": companion.relativePath.rawValue,
                    "reason": detail,
                ])
            }
        }
        return .staged(staged, notCopied: notCopied)
    }

    private enum CompanionByteOutcome: Sendable {
        case copied
        case cancelled
        case outOfSpace
        case failed(String)
    }

    private nonisolated func companionBytes(
        companion: MediaCompanion,
        sourceKind: LibraryRootKind,
        sourceDeviceIdentity: String?,
        sourceURL: URL,
        stagingURL: URL
    ) async -> CompanionByteOutcome {
        switch sourceKind {
        case .removableVolume:
            switch await copyOffActor(from: sourceURL, to: stagingURL, onByteProgress: { _ in }) {
            case .completed:
                return cancelFlag.isCancelled ? .cancelled : .copied
            case .cancelled:
                return .cancelled
            case let .failed(code):
                return code == ENOSPC ? .outOfSpace : .failed("errno=\(code)")
            }
        case .deviceMTP:
            guard let identity = sourceDeviceIdentity, let cameraImport else {
                return .failed("cameraSessionMissing")
            }
            switch await cameraImport.ensureImportBytes(
                identity: identity,
                relativePath: companion.relativePath,
                enrichmentURL: sourceURL,
                destinationTempURL: stagingURL
            ) {
            case .completed:
                return .copied
            case .cancelled:
                return .cancelled
            case .failed(.outOfSpace):
                return .outOfSpace
            case let .failed(.other(message)):
                return .failed(message)
            }
        case .library:
            return .failed("librarySource")
        }
    }

    // The cohesive entry transaction deliberately keeps revalidation, journal,
    // transfer, and publish handoff visible in one crash-recovery boundary.
    // swiftlint:disable:next function_body_length
    private nonisolated func copyEntry(
        _ entry: MediaOperationPlanEntry,
        context: EntryExecutionContext,
        workerID: Int,
        onByteProgress: @escaping @Sendable (Int64) -> Void
    ) async -> EntryOutcome {
        guard case let .import(sourceRoot, destinationRoot, _) = context.plan.mode,
              case let .copy(destinationRelative) = entry.disposition
        else {
            return .failed(.other)
        }
        guard let namespaceLease = context.namespaceLease else {
            return .failed(.other)
        }
        let sourceURL = entry.source.sourceURL
        let started = ContinuousClock().now
        let signpost = OtosSignpost.mediaIO.beginInterval("MediaImportFileCopy")
        defer { OtosSignpost.mediaIO.endInterval("MediaImportFileCopy", signpost) }
        func logSkipped(reason: String, extra: [String: String] = [:]) {
            var fields = [
                "batch": "\(context.batch.unixMilliseconds)",
                "bytes": "0",
                "reason": reason,
                "worker": "\(workerID)",
            ]
            fields.merge(extra) { _, new in new }
            OtosLog.mediaIO.noticeOperation("mediaOperation.copy", phase: "skipped", fields: fields)
        }
        let finalURL = destinationRoot.url.appendingPathComponent(destinationRelative.rawValue)
        guard let sourceByteSize = entry.source.byteSize else {
            logSkipped(reason: "missingPlannedByteSize")
            return .failed(.other)
        }
        let sourceModified = entry.source.contentModifiedAt
        let validation = await sourceStillMatches(
            entry: entry,
            sourceKind: context.sourceKind,
            sourceDeviceIdentity: context.sourceDeviceIdentity,
            sourceURL: sourceURL,
            sourceByteSize: sourceByteSize,
            sourceModified: sourceModified
        )
        guard case .matches = validation else {
            logSkipped(
                reason: "staleSource",
                extra: ["path": sourceURL.path, "validation": String(describing: validation)]
            )
            return .failed(EntryFailure(validation))
        }
        if FileManager.default.fileExists(atPath: finalURL.path) {
            logSkipped(reason: "destinationExists")
            return .skippedForeign
        }

        let stagingURL = Self.stagingURL(adjacentTo: finalURL)
        guard let destinationModified = ImportDestinationDate.expected(for: entry.source)
        else {
            logSkipped(reason: "missingDestinationDate")
            return .failed(.other)
        }
        let operationSourceModified = sourceModified ?? destinationModified
        var operation = ActiveFileOperation(
            operationKey: .make(),
            sourceKind: context.sourceKind,
            sourceDeviceIdentity: context.sourceDeviceIdentity,
            sourceRootPath: sourceRoot,
            sourceRelativePath: entry.source.relativePath,
            destinationRootPath: destinationRoot,
            destinationRelativePath: destinationRelative,
            stagingURL: stagingURL,
            companionStagingURLs: [],
            importBatch: context.batch,
            sourceByteSize: sourceByteSize,
            sourceModifiedAt: operationSourceModified,
            destinationModifiedAt: destinationModified,
            phase: .copying,
            updatedAt: Date()
        )
        do {
            try await store.beginImportOperation(operation)
        } catch {
            logSkipped(reason: "journalBeginFailed")
            return .failed(.other)
        }

        do {
            try FileManager.default.createDirectory(
                at: stagingURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            logSkipped(reason: "destinationFolderUnavailable", extra: ["error": String(describing: error)])
            await Self.abandonEntry(operation.operationKey, stagingFiles: [], store: store, reason: "destinationFolderUnavailable")
            return .failed(.other)
        }
        if let early = await transferBytesToStaging(
            entry: entry,
            sourceKind: context.sourceKind,
            sourceDeviceIdentity: context.sourceDeviceIdentity,
            sourceURL: sourceURL,
            stagingURL: stagingURL,
            operationKey: operation.operationKey,
            onByteProgress: onByteProgress
        ) {
            if case .cancelled = early {
                logSkipped(reason: "cancelled")
            } else {
                logSkipped(reason: "transferFailed")
            }
            return early
        }

        guard !cancelFlag.isCancelled else {
            await Self.abandonEntry(operation.operationKey, stagingFiles: [stagingURL], store: store, reason: "cancelled")
            logSkipped(reason: "cancelled")
            return .cancelled
        }
        let copyFinished = ContinuousClock().now
        let hashStart = ContinuousClock.now
        let hashSignpost = OtosSignpost.mediaIO.beginInterval("ContentHash")
        let hashOutcome = ContentHasher().hashMaterializedFile(
            at: stagingURL,
            shouldContinue: { !cancelFlag.isCancelled }
        )
        OtosSignpost.mediaIO.endInterval("ContentHash", hashSignpost)
        let hashMs = DiagnosticsTiming.milliseconds(since: hashStart)
        var hashFinished: ContinuousClock.Instant?
        switch hashOutcome {
        case let .complete(contentHash):
            operation.contentHash = contentHash
            hashFinished = ContinuousClock().now
            OtosLog.mediaIO.noticeOperation(
                "contentHash",
                phase: "finish",
                fields: [
                    "owner": "import",
                    "rootPath": operation.sourceRootPath.rawValue,
                    "relativePath": operation.sourceRelativePath.rawValue,
                    "batch": "\(context.batch.unixMilliseconds)",
                    "worker": "\(workerID)",
                    "bytes": "\(sourceByteSize)",
                    "elapsedMs": "\(hashMs)",
                    "mbps": throughputMBps(bytes: sourceByteSize, elapsedMs: hashMs),
                ]
            )
        case .cancelled:
            await Self.abandonEntry(operation.operationKey, stagingFiles: [stagingURL], store: store, reason: "hashCancelled")
            OtosLog.mediaIO.noticeOperation(
                "contentHash",
                phase: "cancelled",
                fields: [
                    "owner": "import",
                    "rootPath": operation.sourceRootPath.rawValue,
                    "relativePath": operation.sourceRelativePath.rawValue,
                    "batch": "\(context.batch.unixMilliseconds)",
                    "worker": "\(workerID)",
                ]
            )
            logSkipped(reason: "cancelled")
            return .cancelled
        case let .failed(category):
            await Self.abandonEntry(operation.operationKey, stagingFiles: [stagingURL], store: store, reason: "hashFailed")
            OtosLog.mediaIO.errorOperation(
                "contentHash",
                phase: "failed",
                fields: [
                    "owner": "import",
                    "rootPath": operation.sourceRootPath.rawValue,
                    "relativePath": operation.sourceRelativePath.rawValue,
                    "batch": "\(context.batch.unixMilliseconds)",
                    "worker": "\(workerID)",
                    "category": category.rawValue,
                ]
            )
            logSkipped(reason: "hashFailed", extra: ["category": category.rawValue])
            return .failed(.other)
        }

        guard let hashFinished else {
            logSkipped(reason: "unexpectedHashState")
            return .failed(.other)
        }
        let stagedCompanions: [StagedCompanion]
        let companionsNotCopied: [MediaRelativePath]
        switch await stageCompanions(
            entry: entry,
            operation: &operation,
            sourceKind: context.sourceKind,
            sourceDeviceIdentity: context.sourceDeviceIdentity,
            destinationRoot: destinationRoot
        ) {
        case let .staged(staged, notCopied):
            stagedCompanions = staged
            companionsNotCopied = notCopied
        case let .stop(stop):
            await Self.abandonEntry(
                operation.operationKey,
                stagingFiles: operation.stagingFiles,
                store: store,
                reason: "companionTransferStopped"
            )
            logSkipped(reason: "companionTransferStopped")
            return stop
        }
        let outcome = await Self.publishAndSettle(PublishSettleRequest(
            operation: operation,
            store: store,
            stagingURL: stagingURL,
            finalURL: finalURL,
            stagedCompanions: stagedCompanions,
            companionsNotCopied: companionsNotCopied,
            destinationRoot: destinationRoot,
            destinationRelative: destinationRelative,
            sourceURL: sourceURL,
            sourceKind: context.sourceKind,
            sourceDeviceIdentity: context.sourceDeviceIdentity,
            sourceRelativePath: entry.source.relativePath,
            sourceByteSize: sourceByteSize,
            destinationModified: destinationModified,
            batch: context.batch,
            namespaceLease: namespaceLease,
            workerID: workerID,
            copyStarted: started,
            copyFinished: copyFinished,
            hashFinished: hashFinished
        ))
        if case .published = outcome {
            // Honest `mediaOperation.copy phase=finish` (actual bytes written) is
            // emitted inside publishAndSettleBody, which is the only place that
            // knows the settled byte size — never fabricated here.
        } else {
            logSkipped(reason: "publishFailed")
        }
        return outcome
    }

    private struct PublishSettleRequest {
        var operation: ActiveFileOperation
        let store: CatalogStore
        let stagingURL: URL
        let finalURL: URL
        let stagedCompanions: [StagedCompanion]
        let companionsNotCopied: [MediaRelativePath]
        let destinationRoot: LibraryRootPath
        let destinationRelative: MediaRelativePath
        let sourceURL: URL
        let sourceKind: LibraryRootKind
        let sourceDeviceIdentity: String?
        let sourceRelativePath: MediaRelativePath
        let sourceByteSize: Int64
        let destinationModified: Date
        let batch: ImportBatchID
        let namespaceLease: RootNamespaceMutationLease
        let workerID: Int
        let copyStarted: ContinuousClock.Instant
        let copyFinished: ContinuousClock.Instant
        let hashFinished: ContinuousClock.Instant
    }

    /// The publication handoff is one crash boundary: journal gate, exclusive rename,
    /// durable pending-settlement transition, and the single Store settlement transaction.
    /// Before the primary is published, an entry that stops is abandoned with every
    /// staging file its journal names. After it is published, a failure leaves the row
    /// for startup recovery to settle; the companion staging files it would not publish
    /// are removed now, and recovery removes any that would not go.
    private nonisolated static func publishAndSettle(_ request: PublishSettleRequest) async -> EntryOutcome {
        let outcome = await publishAndSettleBody(request)
        if case .published = outcome {
            return outcome
        }
        let unpublished = request.stagedCompanions.map(\.stagingURL)
            .filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
        ImportStaging.remove(unpublished, key: request.operation.operationKey, reason: "entryNotPublished")
        return outcome
    }

    private nonisolated static func publishAndSettleBody(_ request: PublishSettleRequest) async -> EntryOutcome {
        var operation = request.operation
        func abandonBeforePublication(_ reason: String) async {
            await abandonEntry(
                operation.operationKey,
                stagingFiles: operation.stagingFiles,
                store: request.store,
                reason: reason
            )
        }
        guard await request.store.ownsNamespaceMutationLease(request.namespaceLease) else {
            await abandonBeforePublication("namespaceLeaseUnavailable")
            OtosLog.catalog.noticeOperation("mediaOperation.publish", phase: "blocked", fields: [
                "reason": "namespaceLeaseUnavailable",
            ])
            return .failed(.other)
        }
        Self.stampModificationDate(request.destinationModified, at: request.stagingURL)
        operation.phase = .readyToPublish
        operation.updatedAt = Date()
        do {
            try await request.store.recordImportOperationProgress(operation)
        } catch {
            OtosLog.catalog.errorOperation("mediaOperation.journal", phase: "readyToPublishFailed", fields: [
                "key": operation.operationKey.rawValue,
                "error": String(describing: error),
            ])
            await abandonBeforePublication("readyToPublishFailed")
            return .failed(.other)
        }
        guard await request.store.ownsNamespaceMutationLease(request.namespaceLease) else {
            await abandonBeforePublication("namespaceLeaseUnavailable")
            OtosLog.catalog.noticeOperation("mediaOperation.publish", phase: "blocked", fields: [
                "reason": "namespaceLeaseUnavailable",
            ])
            return .failed(.other)
        }

        switch ExclusivePublication.publish(staging: request.stagingURL, final: request.finalURL) {
        case .destinationExists:
            await abandonBeforePublication("destinationExists")
            guard await request.store.ownsNamespaceMutationLease(request.namespaceLease) else {
                return .failed(.other)
            }
            await request.store.recordForeignOccupant(
                root: request.destinationRoot,
                relativePath: request.destinationRelative
            )
            return .skippedForeign
        case let .failed(message):
            OtosLog.catalog.errorOperation("mediaOperation.publish", phase: "failed", fields: [
                "key": operation.operationKey.rawValue,
                "detail": message,
            ])
            await abandonBeforePublication("publishFailed")
            return .failed(.other)
        case .published:
            break
        }
        let publishFinished = ContinuousClock().now
        let finalValues: URLResourceValues
        do {
            finalValues = try request.finalURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        } catch {
            OtosLog.catalog.errorOperation("mediaOperation.publish", phase: "finalFactsUnavailable", fields: [
                "key": operation.operationKey.rawValue,
                "error": String(describing: error),
            ])
            return .failed(.other)
        }
        guard let finalSize = finalValues.fileSize, let settledModified = finalValues.contentModificationDate else {
            OtosLog.catalog.errorOperation("mediaOperation.publish", phase: "finalFactsUnavailable", fields: [
                "key": operation.operationKey.rawValue,
            ])
            return .failed(.other)
        }
        let settledByteSize = Int64(finalSize)

        operation.phase = .publishedPendingSettlement
        operation.stagingURL = nil
        operation.destinationModifiedAt = settledModified
        operation.updatedAt = Date()
        do {
            try await request.store.recordImportOperationProgress(operation)
        } catch {
            OtosLog.catalog.errorOperation("mediaOperation.journal", phase: "publishedPendingSettlementFailed", fields: [
                "key": operation.operationKey.rawValue,
                "error": String(describing: error),
            ])
            return .failed(.other)
        }
        guard await request.store.ownsNamespaceMutationLease(request.namespaceLease) else {
            OtosLog.catalog.noticeOperation("mediaOperation.settle", phase: "blocked", fields: [
                "reason": "namespaceLeaseUnavailable",
            ])
            return .failed(.other)
        }

        let companions = Self.publishCompanions(request)
        var reuseResult = ImportOverlayReuseResult.notReused
        do {
            reuseResult = try await request.store.settleImportedAsset(
                operation: operation,
                byteSize: settledByteSize,
                contentModifiedAt: settledModified,
                batch: request.batch,
                companions: companions.published
            )
        } catch {
            OtosLog.catalog.errorOperation("mediaOperation.settle", phase: "failed", fields: [
                "key": operation.operationKey.rawValue,
                "error": String(describing: error),
            ])
            return .failed(.other)
        }
        // A1. The one route from "durably in the library" to "cache copy gone". Placed
        // after `settleImportedAsset` returns rather than beside the copy, because
        // settlement is what proves the bytes are safe elsewhere -- releasing before it
        // would discard the only local copy of something that might still fail to publish.
        // A failed or blocked entry never reaches here, so its bytes stay and a retry does
        // not re-download them.
        StagedSourceReleaser.releaseIfCached(kind: request.sourceKind, sourceURL: request.sourceURL)
        let settleFinished = ContinuousClock().now
        let totalElapsedMs = max(
            DiagnosticsTiming.milliseconds(from: request.copyStarted, to: settleFinished),
            1
        )
        OtosLog.mediaIO.noticeOperation("mediaOperation.copy", phase: "finish", fields: [
            "batch": "\(request.batch.unixMilliseconds)",
            "bytes": "\(settledByteSize)",
            "elapsedMs": "\(totalElapsedMs)",
            "mbps": throughputMBps(bytes: settledByteSize, elapsedMs: totalElapsedMs),
            "worker": "\(request.workerID)",
        ])
        OtosLog.mediaIO.noticeOperation("mediaOperation.copy", phase: "timings", fields: [
            "batch": "\(request.batch.unixMilliseconds)",
            "publishMs": elapsedMilliseconds(from: request.copyFinished, to: publishFinished),
            "settleMs": elapsedMilliseconds(from: publishFinished, to: settleFinished),
            "hashMs": "\(elapsedMilliseconds(from: request.copyFinished, to: request.hashFinished))",
            "copyMs": elapsedMilliseconds(from: request.copyStarted, to: request.copyFinished),
            "worker": "\(request.workerID)",
        ])
        return .published(
            reuseResult,
            bytes: settledByteSize,
            companionsNotCopied: request.companionsNotCopied + companions.notCopied
        )
    }

    /// Publishes each staged companion beside the published primary. Only a companion
    /// that landed is returned for the catalog, with the facts of the file that landed;
    /// one that met an occupant or a refusal stays on the source and is reported.
    private nonisolated static func publishCompanions(
        _ request: PublishSettleRequest
    ) -> (published: [MediaCompanion], notCopied: [MediaRelativePath]) {
        var published: [MediaCompanion] = []
        var notCopied: [MediaRelativePath] = []
        for companion in request.stagedCompanions {
            switch ExclusivePublication.publish(staging: companion.stagingURL, final: companion.finalURL) {
            case .published:
                let values = try? companion.finalURL.resourceValues(
                    forKeys: [.fileSizeKey, .contentModificationDateKey]
                )
                published.append(MediaCompanion(
                    relativePath: companion.destinationRelative,
                    primaryRelativePath: request.destinationRelative,
                    kind: companion.source.kind,
                    byteSize: values?.fileSize.map(Int64.init),
                    contentModifiedAt: values?.contentModificationDate
                ))
            case .destinationExists:
                ImportStaging.remove([companion.stagingURL], key: request.operation.operationKey, reason: "companionDestinationExists")
                notCopied.append(companion.source.relativePath)
                OtosLog.mediaIO.noticeOperation("mediaOperation.companion", phase: "notCopied", fields: [
                    "relativePath": companion.source.relativePath.rawValue,
                    "reason": "destinationExists",
                ])
            case let .failed(message):
                ImportStaging.remove([companion.stagingURL], key: request.operation.operationKey, reason: "companionPublishFailed")
                notCopied.append(companion.source.relativePath)
                OtosLog.mediaIO.errorOperation("mediaOperation.companion", phase: "notCopied", fields: [
                    "relativePath": companion.source.relativePath.rawValue,
                    "reason": message,
                ])
            }
        }
        return (published, notCopied)
    }

    /// Ends an entry that will not publish: removes the staging files it created, then
    /// deletes its journal row. A file that will not go keeps the row, marked
    /// `abandoned`, so the next launch's recovery removes it; nothing is left in the
    /// library that no record names.
    private nonisolated static func abandonEntry(
        _ key: ActiveFileOperationKey,
        stagingFiles: [URL],
        store: CatalogStore,
        reason: String
    ) async {
        let removed = ImportStaging.remove(stagingFiles, key: key, reason: reason)
        do {
            if removed {
                try await store.abandonImportOperation(key: key)
            } else {
                try await store.markImportOperationAbandoned(key: key)
            }
        } catch {
            OtosLog.catalog.errorOperation("mediaOperation.journal", phase: "abandonFailed", fields: [
                "key": key.rawValue,
                "reason": reason,
                "stagingRemoved": "\(removed)",
                "error": String(describing: error),
            ])
        }
    }

    private nonisolated static func stagingURL(adjacentTo final: URL) -> URL {
        let parent = final.deletingLastPathComponent()
        let name = ".\(UUID().uuidString)\(Self.destinationTempSuffix)"
        return parent.appendingPathComponent(name)
    }

    /// Gives a staged file the date it lands with. A refusal is logged: the file then
    /// keeps its copy time, which settlement reads back as the fact it is.
    private nonisolated static func stampModificationDate(_ date: Date, at url: URL) {
        do {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        } catch {
            OtosLog.mediaIO.errorOperation("mediaOperation.staging", phase: "stampFailed", fields: [
                "path": url.path(percentEncoded: false),
                "error": String(describing: error),
            ])
        }
    }

    private nonisolated static func fileValidation(url: URL, byteSize: Int64, modifiedAt: Date) -> SourceValidation {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize,
              let modified = values.contentModificationDate
        else {
            return .absent
        }
        guard Int64(size) == byteSize else {
            return .changed(.size)
        }
        guard Int(modified.timeIntervalSince1970) == Int(modifiedAt.timeIntervalSince1970) else {
            return .changed(.date)
        }
        return .matches
    }
}

nonisolated struct EraseOutcome: Equatable, Sendable {
    let deletedCount: Int
    let skippedCount: Int
    let failedCount: Int
}

/// What a run did to the entries it attempted, the same whether it completed or stopped.
/// `hasEntryFailures` is about copying and the batch's integrity; a source erase reports
/// its own failures in `EraseOutcome`.
nonisolated struct MediaImportRunTally: Equatable, Sendable {
    let publishedCount: Int
    let hasBlockedEntries: Bool
    let hasEntryFailures: Bool
    let skippedForeignCount: Int
    let failedCount: Int

    static let nothingAttempted = MediaImportRunTally(
        publishedCount: 0,
        hasBlockedEntries: false,
        hasEntryFailures: false,
        skippedForeignCount: 0,
        failedCount: 0
    )
}

nonisolated enum MediaImportExecutionResult: Equatable, Sendable {
    /// Every planned entry was attempted. `erase` is the source erase's outcome when the
    /// run was asked to erase its source, `nil` when it was not.
    case completed(MediaImportRunTally, incompleteItems: [MediaAssetID], erase: EraseOutcome?)
    /// The run ended before attempting every planned entry — a partial success
    /// carrying why (`ImportStopReason`), never a failure. What landed is a real
    /// batch and the remainder is the re-plan's to offer.
    case stopped(ImportStopReason, MediaImportRunTally)
    /// The run could not proceed. `publishedCount` is what this run had published when
    /// it failed — the executor's own count, not a later read of the catalog.
    case failed(MediaOperationFailureReason, publishedCount: Int)
}

/// Thread-safe byte-progress accumulator for copy callbacks off the executor
/// actor. Worker threads report in-flight offsets per entry index; settled totals
/// advance only on the actor's group loop. A time gate bounds emission frequency
/// so a fast copy cannot flood the coordinator stream, while a single large file
/// still keeps the visible bar moving.
///
/// `Mutex` (rather than an unsafe global escape): the state is genuinely shared
/// across worker threads, and `Mutex<State>` expresses that with a *checked*
/// `Sendable` conformance — ARC-042 forbids `@unchecked`.
private final nonisolated class ByteProgressTracker: Sendable {
    private struct State {
        var settledCount = 0
        var settledBytes: Int64 = 0
        var creditedBytes: Int64 = 0
        var inFlightOffsets: [Int: Int64] = [:]
        var lastEmit: ContinuousClock.Instant?
    }

    /// At most ten samples a second leave the copy workers. A rate limit standing on a
    /// measurement: `copyfile` reports once a megabyte, ~1,840 times a second for one
    /// worker on an internal SSD, and each delivered sample wakes a coordinator pass and
    /// a MainActor presentation apply (`docs/research/2026-10-23-cadence-audit.md`).
    private static let emitInterval: Duration = .milliseconds(100)

    private let totalCount: Int
    private let totalBytes: Int64
    private let startedAt = ContinuousClock().now
    private let state = Mutex(State())

    init(totalCount: Int, totalBytes: Int64) {
        self.totalCount = totalCount
        self.totalBytes = totalBytes
    }

    nonisolated func inFlightUpdate(index: Int, offset: Int64) -> MediaOperationProgress? {
        state.withLock { state in
            state.inFlightOffsets[index] = offset
            let now = ContinuousClock().now
            let due = state.lastEmit.map { now - $0 >= Self.emitInterval } ?? true
            guard due else { return nil }
            state.lastEmit = now
            return snapshot(state)
        }
    }

    /// Removes an entry's in-flight offset once its outcome is known.
    ///
    /// `creditedBytes` is what makes the bar monotonic. An entry that reached the
    /// end of its copy and then failed to publish (`.skippedForeign`, `.failed`,
    /// `.cancelled`) has already been counted through `inFlightOffsets`; zeroing it
    /// would walk the bar backwards by a full file. Bytes already shown stay shown —
    /// `completedCount` is the honest item count, and it is the denominator the user
    /// reads. HIG: progress indicators move forward.
    nonisolated func finish(index: Int, resolvedItem: Bool, publishedBytes: Int64) {
        state.withLock { state in
            let observed = state.inFlightOffsets.removeValue(forKey: index) ?? 0
            if resolvedItem {
                state.settledCount += 1
            }
            state.settledBytes += publishedBytes
            state.creditedBytes += max(0, observed - publishedBytes)
        }
    }

    nonisolated func current() -> MediaOperationProgress {
        state.withLock { snapshot($0) }
    }

    private nonisolated func snapshot(_ state: State) -> MediaOperationProgress {
        MediaOperationProgress(
            completedCount: state.settledCount,
            totalCount: totalCount,
            completedBytes: min(
                totalBytes,
                state.settledBytes + state.creditedBytes + state.inFlightOffsets.values.reduce(0, +)
            ),
            totalBytes: totalBytes,
            elapsedMs: DiagnosticsTiming.milliseconds(from: startedAt, to: .now)
        )
    }
}

/// Thread-safe cancel flag for copyfile callbacks off the executor actor.
private final nonisolated class CancelFlag: Sendable {
    private let flag = Mutex(false)
    nonisolated func reset() {
        flag.withLock { $0 = false }
    }

    nonisolated func cancel() {
        flag.withLock { $0 = true }
    }

    nonisolated var isCancelled: Bool {
        flag.withLock { $0 }
    }
}

/// The removal of Otos's own staging files in a destination library, shared by the
/// executor and recovery so every failure is logged the same way.
nonisolated enum ImportStaging {
    /// Removes each file. A file already gone counts as removed. Returns whether all
    /// of them are gone; each one that is not is logged with its error.
    @discardableResult
    static func remove(_ urls: [URL], key: ActiveFileOperationKey, reason: String) -> Bool {
        var allGone = true
        for url in urls {
            do {
                try FileManager.default.removeItem(at: url)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                continue
            } catch {
                allGone = false
                OtosLog.mediaIO.errorOperation("mediaOperation.staging", phase: "removeFailed", fields: [
                    "key": key.rawValue,
                    "reason": reason,
                    "path": url.path(percentEncoded: false),
                    "error": String(describing: error),
                ])
            }
        }
        return allGone
    }

    /// Clears an erase journal row once its file is gone. A failed clear is logged; the
    /// row is found again at startup, where the file is already gone and the row settles.
    static func completeEraseJournal(_ key: ActiveSourceEraseKey, store: CatalogStore) async {
        do {
            try await store.completeSourceEraseOperation(key: key)
        } catch {
            OtosLog.catalog.errorOperation("import.erase.journal", phase: "completeFailed", fields: [
                "key": key.rawValue,
                "error": String(describing: error),
            ])
        }
    }
}
