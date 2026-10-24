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
    /// copied entry, and `recoverJournal()` runs it again for every interrupted one at
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

    /// Journal-row recovery. Runs at coordinator start and again before each
    /// execution. The coordinator start pass may precede `CatalogStore.start()`;
    /// each row's namespace lease awaits the Store's initial load, so persisted
    /// roots are registered by the time a row is judged. Does not walk library
    /// trees — orphan staging cleanup is
    /// destination-parent scoped via `removeOrphanedDestinationTemps(near:)`.
    func recoverJournal() async {
        let signpost = OtosSignpost.catalog.beginInterval("ImportJournalRecovery")
        defer { OtosSignpost.catalog.endInterval("ImportJournalRecovery", signpost) }
        do {
            let operations = try await store.activeImportOperations()
            for operation in operations {
                await recover(operation)
            }
            let eraseOperations = try await store.activeSourceEraseOperations()
            await recoverSourceErases(eraseOperations)
        } catch {
            OtosLog.catalog.error(
                "op=mediaOperation.recover phase=failed error=\(String(describing: error), privacy: .public)"
            )
        }
    }

    /// Removes abandoned `*.otos-import-staging` files only in parent directories
    /// of planned destinations. Full-library enumeration is forbidden — large
    /// cloud libraries would hang startup and tests.
    func removeOrphanedDestinationTemps(near destinationURLs: [URL]) async {
        let journaledStaging: Set<String>
        do {
            journaledStaging = try await Set(store.activeImportOperations().compactMap(\.stagingPath))
        } catch {
            return
        }
        let parents = destinationURLs
        await Task.detached {
            let fileManager = FileManager.default
            for parent in parents {
                guard let items = try? fileManager.contentsOfDirectory(
                    at: parent,
                    includingPropertiesForKeys: nil,
                    options: []
                ) else {
                    continue
                }
                for item in items where item.lastPathComponent.hasSuffix(Self.destinationTempSuffix) {
                    guard !journaledStaging.contains(item.path) else { continue }
                    try? fileManager.removeItem(at: item)
                    OtosLog.catalog.notice(
                        "op=mediaOperation.recover phase=orphanStagingRemoved path=\(item.path, privacy: .public)"
                    )
                }
            }
        }.value
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
            return .failed(reason: .unexpected(detail: "notAnImportPlan"))
        }
        await recoverJournal()
        await removeOrphanedDestinationTemps(near: destinationParentURLs(plan: plan, destination: destination))
        let copyEntries = plan.entries.filter {
            if case .copy = $0.disposition {
                return true
            }
            return false
        }
        let totalBytes = copyEntries.reduce(Int64(0)) { $0 + ($1.source.byteSize ?? 0) }
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
                return .failed(reason: .destinationUnavailable)
            case .catalogUnavailable:
                // Not `.destinationUnavailable`: the catalog never loaded, so
                // whether the library is there is unknown.
                return .failed(reason: .unexpected(detail: "catalogUnavailable"))
            case let .busy(owner):
                // The library *is* available; another namespace mutation owns it.
                // Saying "isn't available" would be false, and the bar has no
                // vocabulary for "busy" — `.unexpected`'s detail is for the log
                // only (`MediaOperationModels.swift`), which is exactly right here.
                return .failed(reason: .unexpected(detail: "destinationNamespaceBusy:\(owner.rawValue)"))
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
        let storedBatchCount = await (try? store.importBatchAssetCount(batch)) ?? -1
        let batchIntegrityMismatch = storedBatchCount != entryTotals.publishedCount
        OtosLog.catalog.notice(
            "op=mediaOperation.batch phase=verified run=\(runID, privacy: .public) batch=\(batch.unixMilliseconds, privacy: .public) expectedPublished=\(entryTotals.publishedCount, privacy: .public) storedBatchCount=\(storedBatchCount, privacy: .public) skippedPreexisting=\(plan.totals.skipCount, privacy: .public) skippedForeign=\(entryTotals.skippedForeignCount, privacy: .public) failed=\(entryTotals.failedCount, privacy: .public) blocked=\(plan.totals.blockedCount, privacy: .public)"
        )
        OtosLog.catalog.notice(
            "op=mediaOperation.batch phase=overlayReuse run=\(runID, privacy: .public) batch=\(batch.unixMilliseconds, privacy: .public) metadataCloned=\(entryTotals.overlayReuse.metadataCloned, privacy: .public) thumbnailCopied=\(entryTotals.overlayReuse.thumbnailCopied, privacy: .public) misses=\(entryTotals.overlayReuse.missDescription, privacy: .public)"
        )
        if batchIntegrityMismatch {
            OtosLog.catalog.fault(
                "op=mediaOperation.batch phase=integrityMismatch run=\(runID, privacy: .public) batch=\(batch.unixMilliseconds, privacy: .public) expectedPublished=\(entryTotals.publishedCount, privacy: .public) storedBatchCount=\(storedBatchCount, privacy: .public)"
            )
        }
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
        if cancelFlag.isCancelled {
            return .stopped(
                reason: .user,
                publishedCount: entryTotals.publishedCount,
                hasBlockedEntries: hasBlockedEntries,
                hasEntryFailures: entryTotals.failedCount > 0 || batchIntegrityMismatch,
                skippedForeignCount: entryTotals.skippedForeignCount,
                failedCount: entryTotals.failedCount
            )
        }
        if let spaceStop = entryTotals.spaceStop {
            return .stopped(
                reason: .diskFloor(bytesFree: spaceStop.bytesFree),
                publishedCount: entryTotals.publishedCount,
                hasBlockedEntries: hasBlockedEntries,
                hasEntryFailures: entryTotals.failedCount > 0 || batchIntegrityMismatch,
                skippedForeignCount: entryTotals.skippedForeignCount,
                failedCount: entryTotals.failedCount
            )
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
            return .failed(reason: .sourceNotReady)
        }
        if deleteSourceRequested {
            return .completedWithErase(
                publishedCount: entryTotals.publishedCount,
                hasBlockedEntries: hasBlockedEntries,
                hasEntryFailures: entryTotals.failedCount > 0
                    || batchIntegrityMismatch
                    || entryTotals.eraseOutcome.failedCount > 0,
                skippedForeignCount: entryTotals.skippedForeignCount,
                failedCount: entryTotals.failedCount,
                incompleteItems: entryTotals.incompleteItems,
                eraseOutcome: entryTotals.eraseOutcome
            )
        }
        return .completed(
            publishedCount: entryTotals.publishedCount,
            hasBlockedEntries: hasBlockedEntries,
            hasEntryFailures: entryTotals.failedCount > 0 || batchIntegrityMismatch,
            skippedForeignCount: entryTotals.skippedForeignCount,
            failedCount: entryTotals.failedCount,
            incompleteItems: entryTotals.incompleteItems
        )
    }

    private func destinationParentURLs(
        plan: MediaOperationPlan,
        destination: LibraryRootPath
    ) -> [URL] {
        var parents = Set<URL>()
        let destinationRoot = URL(fileURLWithPath: destination.rawValue, isDirectory: true)
        for entry in plan.entries {
            if case let .copy(destRel) = entry.disposition {
                parents.insert(
                    destinationRoot.appending(path: destRel.rawValue).deletingLastPathComponent()
                )
            }
            for companionDest in entry.companionDestinations.values {
                parents.insert(
                    destinationRoot.appending(path: companionDest.rawValue).deletingLastPathComponent()
                )
            }
        }
        return Array(parents)
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
            func plannedBytes(_ index: Int) -> Int64 {
                let source = copyEntries[index].source
                return (source.byteSize ?? 0) + source.companions.reduce(Int64(0)) { $0 + ($1.byteSize ?? 0) }
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
                let entryBytes = plannedBytes(index)
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
                let bytes = plannedBytes(index)
                inFlightBytes += bytes
                inFlightByIndex[index] = bytes
                group.addTask {
                    guard !self.cancelFlag.isCancelled else {
                        return EntryResult(index: index, outcome: .cancelled, byteSize: 0)
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
                    return EntryResult(index: index, outcome: outcome, byteSize: entry.source.byteSize ?? 0)
                }
            }
            while nextIndex < min(Self.workerCount, copyEntries.count), admits(nextIndex) {
                submit(nextIndex)
                nextIndex += 1
            }
            while let result = await group.next() {
                inFlightBytes -= inFlightByIndex.removeValue(forKey: result.index) ?? 0
                switch result.outcome {
                case let .published(reuseResult, companionsNotCopied):
                    let entry = copyEntries[result.index]
                    let notCopied = Set(companionsNotCopied)
                    erasableSourcePaths.insert(entry.source.relativePath)
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
                    publishedBytes += result.byteSize
                    overlayReuse.record(reuseResult)
                    byteProgress.finish(index: result.index, resolvedItem: true, publishedBytes: result.byteSize)
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
        // A floor stop is never fully clean: the un-copied entries exist only
        // on the card, so the erase sweep does not run (ADR 0027).
        if context.allowSourceDeletion, spaceStop == nil {
            let eraseOutcome = await eraseSourceFiles(context: context, erasableSourcePaths: erasableSourcePaths)
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
            eraseOutcome: EraseOutcome(deletedCount: 0, skippedCount: 0, failedCount: 0)
        )
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
                key: UUID().uuidString,
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
                try? await store.completeSourceEraseOperation(key: journal.key)
            case .alreadyGone:
                skipped += 1
                try? await store.completeSourceEraseOperation(key: journal.key)
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

    /// One lease per source root for the whole sweep.
    ///
    /// Acquiring per entry and releasing from a detached `Task` inside a `defer`
    /// raced the next iteration's acquire — `defer` only *enqueues* the release —
    /// so every entry after the first could bail on an unsatisfiable acquire with
    /// no log at all, leaving journal rows and files the user asked to reclaim.
    /// It also left the lease held past the sweep, which an ordinary import then
    /// saw as a busy source namespace.
    private func recoverSourceErases(_ operations: [ActiveSourceEraseOperation]) async {
        let byRoot = Dictionary(grouping: operations, by: \.sourceRootPath)
        for (root, rootOperations) in byRoot.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let lease: RootNamespaceMutationLease
            let acquisition = await store.acquireNamespaceMutationLease(for: root, owner: .sourceErase)
            switch acquisition {
            case let .acquired(acquired):
                lease = acquired
            case let .busy(owner):
                // Retained, not dropped: the journal rows survive for the next
                // launch's sweep.
                OtosLog.mediaIO.noticeOperation("import.erase.recover", phase: "deferred", fields: [
                    "reason": "namespaceBusy",
                    "heldBy": owner.rawValue,
                    "rootPath": root.rawValue,
                    "pendingCount": "\(rootOperations.count)",
                ])
                continue
            case .rootNotRegistered, .catalogUnavailable:
                OtosLog.mediaIO.noticeOperation("import.erase.recover", phase: "deferred", fields: [
                    "reason": acquisition.logReason,
                    "rootPath": root.rawValue,
                    "pendingCount": "\(rootOperations.count)",
                ])
                continue
            }
            for operation in rootOperations {
                await recoverSourceErase(operation)
            }
            _ = await store.releaseNamespaceMutationLease(lease)
        }
    }

    /// The caller holds `operation.sourceRootPath`'s namespace lease.
    private func recoverSourceErase(_ operation: ActiveSourceEraseOperation) async {
        let url = operation.sourceRootPath.url
            .appending(path: operation.sourceRelativePath.rawValue)
            .standardizedFileURL
        let contained = CatalogPath.relativePath(
            rootPath: operation.sourceRootPath,
            fileURL: url
        )
        guard contained == operation.sourceRelativePath else {
            // Unreachable through `eraseSourceFiles`, which validates containment
            // before journaling. A row that fails it can never be acted on, so it
            // is surfaced rather than retried in silence, and retained rather than
            // deleted on a fact this code could not prove.
            OtosLog.mediaIO.fault(
                "op=import.erase.recover phase=uncontained rootPath=\(operation.sourceRootPath.rawValue, privacy: .public) relativePath=\(operation.sourceRelativePath.rawValue, privacy: .public)"
            )
            return
        }
        guard await SourceEraser.erase(
            kind: operation.sourceKind,
            identity: operation.sourceDeviceIdentity,
            relativePath: operation.sourceRelativePath,
            filesystemURL: url,
            cameraImport: cameraImport
        ).isSettled else { return }
        try? await store.completeSourceEraseOperation(key: operation.key)
    }

    private func sourceDeletionCandidates(
        plan: MediaOperationPlan,
        erasableSourcePaths publishedPaths: Set<MediaRelativePath>
    ) -> [EraseManifestEntry] {
        let retainedPaths = Set(plan.entries.compactMap { entry -> MediaRelativePath? in
            switch entry.disposition {
            case .skipPreexisting, .excluded:
                entry.source.relativePath
            case .copy, .relocate, .noOp, .blocked:
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
        /// The primary is published. `companionsNotCopied` are the source paths of
        /// companions that did not reach the library: they are not recorded, and their
        /// sources are never erased.
        case published(ImportOverlayReuseResult, companionsNotCopied: [MediaRelativePath])
        case skippedForeign
        case cancelled
        case failed(EntryFailure)
    }

    private struct EntryResult: Sendable {
        let index: Int
        let outcome: EntryOutcome
        let byteSize: Int64
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
            try? await store.abandonImportOperation(key: operationKey)
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
            try? FileManager.default.removeItem(at: stagingURL)
            try? await store.abandonImportOperation(key: operationKey)
            return .cancelled
        }
        if case let .failed(code) = copyOutcome {
            try? FileManager.default.removeItem(at: stagingURL)
            try? await store.abandonImportOperation(key: operationKey)
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
            try? await store.abandonImportOperation(key: operationKey)
            return .failed(.other)
        }
        if cancelFlag.isCancelled {
            try? FileManager.default.removeItem(at: stagingURL)
            try? await store.abandonImportOperation(key: operationKey)
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
            try? FileManager.default.removeItem(at: stagingURL)
            try? await store.abandonImportOperation(key: operationKey)
            return .cancelled
        case .failed(.outOfSpace):
            // The staging write refused for space: the floor, reached the hard
            // way, on a camera — the same stop as a refused `copyfile` on a card.
            try? FileManager.default.removeItem(at: stagingURL)
            try? await store.abandonImportOperation(key: operationKey)
            return .failed(.outOfSpace)
        case let .failed(.other(message)):
            try? FileManager.default.removeItem(at: stagingURL)
            try? await store.abandonImportOperation(key: operationKey)
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
    private nonisolated func stageCompanions(
        entry: MediaOperationPlanEntry,
        sourceKind: LibraryRootKind,
        sourceDeviceIdentity: String?,
        destinationRoot: LibraryRootPath
    ) async -> CompanionStaging {
        var staged: [StagedCompanion] = []
        var notCopied: [MediaRelativePath] = []
        func stop(_ outcome: EntryOutcome) -> CompanionStaging {
            for companion in staged {
                try? FileManager.default.removeItem(at: companion.stagingURL)
            }
            return .stop(outcome)
        }
        for companion in entry.source.companions {
            guard let destinationRelative = entry.companionDestinations[companion.relativePath] else {
                continue
            }
            if cancelFlag.isCancelled {
                return stop(.cancelled)
            }
            let finalURL = destinationRoot.url.appendingPathComponent(destinationRelative.rawValue)
            let stagingURL = Self.stagingURL(adjacentTo: finalURL)
            let sourceURL = entry.source.sourceURL
                .deletingLastPathComponent()
                .appendingPathComponent((companion.relativePath.rawValue as NSString).lastPathComponent)
            try? FileManager.default.createDirectory(
                at: stagingURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
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
                try? FileManager.default.removeItem(at: stagingURL)
                return stop(.cancelled)
            case .outOfSpace:
                try? FileManager.default.removeItem(at: stagingURL)
                return stop(.failed(.outOfSpace))
            case let .failed(detail):
                try? FileManager.default.removeItem(at: stagingURL)
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
            mode: "import",
            sourceKind: context.sourceKind,
            sourceDeviceIdentity: context.sourceDeviceIdentity,
            sourceRootPath: sourceRoot,
            sourceRelativePath: entry.source.relativePath,
            destinationRootPath: destinationRoot,
            destinationRelativePath: destinationRelative,
            stagingPath: stagingURL.path,
            importBatchUnixMs: context.batch.unixMilliseconds,
            sourceByteSize: sourceByteSize,
            sourceModifiedAt: operationSourceModified,
            destinationModifiedAt: destinationModified,
            phase: .copying,
            deleteSourceRequested: context.allowSourceDeletion,
            updatedAt: Date()
        )
        do {
            try await store.beginImportOperation(operation)
        } catch {
            logSkipped(reason: "journalBeginFailed")
            return .failed(.other)
        }

        try? FileManager.default.createDirectory(
            at: stagingURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
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
            try? FileManager.default.removeItem(at: stagingURL)
            try? await store.abandonImportOperation(key: operation.operationKey)
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
            try? FileManager.default.removeItem(at: stagingURL)
            try? await store.abandonImportOperation(key: operation.operationKey)
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
            try? FileManager.default.removeItem(at: stagingURL)
            try? await store.abandonImportOperation(key: operation.operationKey)
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
            sourceKind: context.sourceKind,
            sourceDeviceIdentity: context.sourceDeviceIdentity,
            destinationRoot: destinationRoot
        ) {
        case let .staged(staged, notCopied):
            stagedCompanions = staged
            companionsNotCopied = notCopied
        case let .stop(stop):
            try? FileManager.default.removeItem(at: stagingURL)
            try? await store.abandonImportOperation(key: operation.operationKey)
            logSkipped(reason: "companionTransferStopped")
            return stop
        }
        let outcome = await Self.publishAndSettle(PublishSettleRequest(
            operation: operation,
            store: store,
            cameraImport: cameraImport,
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
            deleteSourceRequested: context.allowSourceDeletion,
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
        let cameraImport: CameraImportAccess?
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
        let deleteSourceRequested: Bool
        let workerID: Int
        let copyStarted: ContinuousClock.Instant
        let copyFinished: ContinuousClock.Instant
        let hashFinished: ContinuousClock.Instant
    }

    /// The publication handoff is one crash boundary: journal gate, exclusive rename,
    /// durable pending-settlement transition, and the single Store settlement transaction.
    /// A staged companion that was not published by the time the entry ends is removed:
    /// staging is Otos's own hidden file, never a library item.
    private nonisolated static func publishAndSettle(_ request: PublishSettleRequest) async -> EntryOutcome {
        defer {
            for companion in request.stagedCompanions {
                try? FileManager.default.removeItem(at: companion.stagingURL)
            }
        }
        guard await request.store.ownsNamespaceMutationLease(request.namespaceLease) else {
            try? await request.store.abandonImportOperation(key: request.operation.operationKey)
            OtosLog.catalog.notice(
                "op=mediaOperation.publish phase=blocked reason=namespaceLeaseUnavailable"
            )
            return .failed(.other)
        }
        return await publishAndSettleBody(request)
    }

    private nonisolated static func publishAndSettleBody(_ request: PublishSettleRequest) async -> EntryOutcome {
        var operation = request.operation
        Self.stampModificationDate(request.destinationModified, at: request.stagingURL)
        operation.phase = .readyToPublish
        operation.updatedAt = Date()
        do {
            try await request.store.recordImportOperationProgress(operation)
        } catch {
            return await Self.journalFailureBeforePublication(request, error: error)
        }
        guard await request.store.ownsNamespaceMutationLease(request.namespaceLease) else {
            try? FileManager.default.removeItem(at: request.stagingURL)
            try? await request.store.abandonImportOperation(key: operation.operationKey)
            OtosLog.catalog.notice(
                "op=mediaOperation.publish phase=blocked reason=namespaceLeaseUnavailable"
            )
            return .failed(.other)
        }

        switch ExclusivePublication.publish(staging: request.stagingURL, final: request.finalURL) {
        case .destinationExists:
            try? FileManager.default.removeItem(at: request.stagingURL)
            do {
                try await request.store.abandonImportOperation(key: operation.operationKey)
            } catch {
                OtosLog.catalog.error(
                    "op=mediaOperation.journal phase=foreignAbandonFailed error=\(String(describing: error), privacy: .public)"
                )
                return .failed(.other)
            }
            guard await request.store.ownsNamespaceMutationLease(request.namespaceLease) else {
                return .failed(.other)
            }
            await request.store.recordForeignOccupant(
                root: request.destinationRoot,
                relativePath: request.destinationRelative
            )
            return .skippedForeign
        case let .failed(message):
            try? FileManager.default.removeItem(at: request.stagingURL)
            do {
                try await request.store.abandonImportOperation(key: operation.operationKey)
            } catch {
                OtosLog.catalog.error(
                    "op=mediaOperation.journal phase=publishFailureAbandonFailed error=\(String(describing: error), privacy: .public)"
                )
                return .failed(.other)
            }
            OtosLog.catalog.error(
                "op=mediaOperation.publish phase=failed detail=\(message, privacy: .public)"
            )
            return .failed(.other)
        case .published:
            break
        }
        let publishFinished = ContinuousClock().now
        guard let finalValues = try? request.finalURL.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey]
        ),
            let finalSize = finalValues.fileSize,
            let settledModified = finalValues.contentModificationDate
        else {
            OtosLog.catalog.error("op=mediaOperation.publish phase=finalFactsUnavailable")
            return .failed(.other)
        }
        let settledByteSize = Int64(finalSize)

        operation.phase = .publishedPendingSettlement
        operation.stagingPath = nil
        operation.destinationModifiedAt = settledModified
        operation.updatedAt = Date()
        do {
            try await request.store.recordImportOperationProgress(operation)
        } catch {
            OtosLog.catalog.error(
                "op=mediaOperation.journal phase=publishedPendingSettlementFailed error=\(String(describing: error), privacy: .public)"
            )
            return .failed(.other)
        }
        guard await request.store.ownsNamespaceMutationLease(request.namespaceLease) else {
            OtosLog.catalog.notice(
                "op=mediaOperation.settle phase=blocked reason=namespaceLeaseUnavailable"
            )
            return .failed(.other)
        }

        let companions = Self.publishCompanions(request)
        let companionRows = companions.published
        var reuseResult = ImportOverlayReuseResult.notReused
        do {
            reuseResult = try await request.store.settleImportedAsset(
                operation: operation,
                byteSize: settledByteSize,
                contentModifiedAt: settledModified,
                batch: request.batch,
                companions: companionRows
            )
        } catch {
            OtosLog.catalog.error(
                "op=mediaOperation.settle phase=failed error=\(String(describing: error), privacy: .public)"
            )
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

        if request.deleteSourceRequested {
            guard await request.store.ownsNamespaceMutationLease(request.namespaceLease) else {
                return .failed(.other)
            }
            guard await SourceEraser.erase(
                kind: request.sourceKind,
                identity: request.sourceDeviceIdentity,
                relativePath: request.sourceRelativePath,
                filesystemURL: request.sourceURL,
                cameraImport: request.cameraImport
            ).isSettled else {
                return .failed(.other)
            }
            do {
                try await request.store.completeImportOperation(key: operation.operationKey)
            } catch {
                OtosLog.catalog.error(
                    "op=mediaOperation.journal phase=sourceDeletionCompletionFailed error=\(String(describing: error), privacy: .public)"
                )
                return .failed(.other)
            }
        }
        return .published(
            reuseResult,
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
                try? FileManager.default.removeItem(at: companion.stagingURL)
                notCopied.append(companion.source.relativePath)
                OtosLog.mediaIO.noticeOperation("mediaOperation.companion", phase: "notCopied", fields: [
                    "relativePath": companion.source.relativePath.rawValue,
                    "reason": "destinationExists",
                ])
            case let .failed(message):
                try? FileManager.default.removeItem(at: companion.stagingURL)
                notCopied.append(companion.source.relativePath)
                OtosLog.mediaIO.errorOperation("mediaOperation.companion", phase: "notCopied", fields: [
                    "relativePath": companion.source.relativePath.rawValue,
                    "reason": message,
                ])
            }
        }
        return (published, notCopied)
    }

    private nonisolated static func journalFailureBeforePublication(
        _ request: PublishSettleRequest,
        error: Error
    ) async -> EntryOutcome {
        try? FileManager.default.removeItem(at: request.stagingURL)
        do {
            try await request.store.abandonImportOperation(key: request.operation.operationKey)
        } catch {
            OtosLog.catalog.error(
                "op=mediaOperation.journal phase=readyToPublishAbandonFailed error=\(String(describing: error), privacy: .public)"
            )
        }
        OtosLog.catalog.error(
            "op=mediaOperation.journal phase=readyToPublishFailed error=\(String(describing: error), privacy: .public)"
        )
        return .failed(.other)
    }

    private enum RecoveryOwnership: Sendable {
        case proven(byteSize: Int64, modifiedAt: Date)
        case foreign
        case deferredMaterialization
    }

    private func recover(_ operation: ActiveFileOperation) async {
        let lease: RootNamespaceMutationLease
        let acquisition = await store.acquireNamespaceMutationLease(
            for: operation.destinationRootPath,
            owner: .importPublication
        )
        switch acquisition {
        case let .acquired(acquired):
            lease = acquired
        case let .busy(owner):
            OtosLog.catalog.noticeOperation("mediaOperation.recover", phase: "blocked", fields: [
                "reason": "namespaceBusy",
                "heldBy": owner.rawValue,
                "rootPath": operation.destinationRootPath.rawValue,
            ])
            return
        case .rootNotRegistered, .catalogUnavailable:
            OtosLog.catalog.noticeOperation("mediaOperation.recover", phase: "blocked", fields: [
                "reason": acquisition.logReason,
                "rootPath": operation.destinationRootPath.rawValue,
            ])
            return
        }
        let staging = operation.stagingPath.map { URL(fileURLWithPath: $0) }
        let final = operation.destinationRootPath.url
            .appendingPathComponent(operation.destinationRelativePath.rawValue)
        let stagingExists = staging.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let finalExists = FileManager.default.fileExists(atPath: final.path)

        switch operation.phase {
        case .copying:
            if let staging, stagingExists {
                try? FileManager.default.removeItem(at: staging)
            }
            await abandonRecovery(operation, reason: "incompleteCopy")
        case .readyToPublish:
            if finalExists, stagingExists {
                // Both paths exist: the final occupant is not provably ours. Only
                // the journaled staging file belongs to Otos and may be removed.
                if let staging {
                    try? FileManager.default.removeItem(at: staging)
                }
                await recordForeignAndAbandon(operation)
            } else if finalExists {
                await recoverFinalOnly(operation, final: final)
            } else if let staging, stagingExists {
                switch ExclusivePublication.publish(staging: staging, final: final) {
                case .published:
                    await persistPublishedPendingSettlement(operation, final: final)
                case .destinationExists:
                    // A race that wins the exclusive create is always foreign.
                    try? FileManager.default.removeItem(at: staging)
                    await recordForeignAndAbandon(operation)
                case let .failed(message):
                    try? FileManager.default.removeItem(at: staging)
                    await abandonRecovery(operation, reason: "publishFailed")
                    OtosLog.catalog.error(
                        "op=mediaOperation.recover phase=publishFailed detail=\(message, privacy: .public)"
                    )
                }
            } else {
                await abandonRecovery(operation, reason: "incompletePublish")
            }
        case .publishedPendingSettlement:
            if finalExists {
                await settleIfOwned(operation, final: final)
            } else if let staging, stagingExists {
                try? FileManager.default.removeItem(at: staging)
                await abandonRecovery(operation, reason: "publishedFinalMissing")
            } else {
                await abandonRecovery(operation, reason: "publishedFinalMissing")
            }
        case .sourceDeletionPending:
            let sourceURL = operation.sourceRootPath.url
                .appendingPathComponent(operation.sourceRelativePath.rawValue)
            guard await SourceEraser.erase(
                kind: operation.sourceKind,
                identity: operation.sourceDeviceIdentity,
                relativePath: operation.sourceRelativePath,
                filesystemURL: sourceURL,
                cameraImport: cameraImport
            ).isSettled else {
                _ = await store.releaseNamespaceMutationLease(lease)
                return
            }
            do {
                try await store.completeImportOperation(key: operation.operationKey)
            } catch {
                OtosLog.catalog.error(
                    "op=mediaOperation.recover phase=sourceDeletionCompletionFailed error=\(String(describing: error), privacy: .public)"
                )
            }
        }
        OtosLog.catalog.notice(
            "op=mediaOperation.recover phase=\(operation.phase.rawValue, privacy: .public) key=\(operation.operationKey.rawValue, privacy: .public) stagingExists=\(stagingExists, privacy: .public) finalExists=\(finalExists, privacy: .public)"
        )
        _ = await store.releaseNamespaceMutationLease(lease)
    }

    private func recoverFinalOnly(_ operation: ActiveFileOperation, final: URL) async {
        switch await proveFinalOwnership(operation, final: final) {
        case let .proven(byteSize, modifiedAt):
            await settleRecovered(
                operation: operation,
                byteSize: byteSize,
                modifiedAt: modifiedAt
            )
        case .foreign:
            await recordForeignAndAbandon(operation)
        case .deferredMaterialization:
            return
        }
    }

    private func persistPublishedPendingSettlement(
        _ operation: ActiveFileOperation,
        final: URL
    ) async {
        guard let values = try? final.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey]
        ),
            values.fileSize != nil,
            let modifiedAt = values.contentModificationDate
        else {
            OtosLog.catalog.error("op=mediaOperation.recover phase=finalFactsUnavailable")
            return
        }
        var pending = operation
        pending.phase = .publishedPendingSettlement
        pending.stagingPath = nil
        pending.destinationModifiedAt = modifiedAt
        pending.updatedAt = Date()
        do {
            try await store.recordImportOperationProgress(pending)
        } catch {
            OtosLog.catalog.error(
                "op=mediaOperation.recover phase=publishedPendingSettlementFailed error=\(String(describing: error), privacy: .public)"
            )
            return
        }
        await settleIfOwned(pending, final: final)
    }

    private func settleIfOwned(_ operation: ActiveFileOperation, final: URL) async {
        switch await proveFinalOwnership(operation, final: final) {
        case let .proven(byteSize, modifiedAt):
            await settleRecovered(
                operation: operation,
                byteSize: byteSize,
                modifiedAt: modifiedAt
            )
        case .foreign, .deferredMaterialization:
            return
        }
    }

    private func proveFinalOwnership(
        _ operation: ActiveFileOperation,
        final: URL
    ) async -> RecoveryOwnership {
        guard let expectedModifiedAt = operation.destinationModifiedAt,
              let expectedHash = operation.contentHash
        else {
            OtosLog.catalog.notice(
                "op=mediaOperation.recover phase=foreignOccupant reason=missingOwnershipFacts"
            )
            return .foreign
        }
        if FileMaterialization.status(of: final) != .materialized {
            OtosLog.catalog.notice(
                "op=mediaOperation.recover phase=deferredMaterialization key=\(operation.operationKey.rawValue, privacy: .public)"
            )
            guard let materializationRequester else {
                return .deferredMaterialization
            }
            let result = await materializationRequester.materialize(
                MaterializationCoordinator.Request(
                    id: MediaAssetID(
                        libraryRootPath: operation.destinationRootPath,
                        relativePath: operation.destinationRelativePath
                    ),
                    sourceSize: operation.sourceByteSize,
                    isVideo: UTType(filenameExtension: final.pathExtension)?.conforms(to: .movie) == true,
                    priority: .background
                )
            )
            guard result.isMaterialized,
                  FileMaterialization.status(of: final) == .materialized
            else {
                return .deferredMaterialization
            }
        }
        guard case let .complete(actualHash) = ContentHasher().hashMaterializedFile(at: final)
        else {
            return .deferredMaterialization
        }
        guard let values = try? final.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey]
        ),
            let actualSize = values.fileSize,
            let actualModifiedAt = values.contentModificationDate,
            Int64(actualSize) == operation.sourceByteSize,
            Int(actualModifiedAt.timeIntervalSince1970) == Int(expectedModifiedAt.timeIntervalSince1970),
            actualHash == expectedHash
        else {
            OtosLog.catalog.notice(
                "op=mediaOperation.recover phase=foreignOccupant key=\(operation.operationKey.rawValue, privacy: .public)"
            )
            return .foreign
        }
        OtosLog.catalog.notice(
            "op=mediaOperation.recover phase=publishedByOperation key=\(operation.operationKey.rawValue, privacy: .public)"
        )
        return .proven(byteSize: Int64(actualSize), modifiedAt: actualModifiedAt)
    }

    private func settleRecovered(
        operation: ActiveFileOperation,
        byteSize: Int64,
        modifiedAt: Date
    ) async {
        guard let batchMs = operation.importBatchUnixMs else {
            OtosLog.catalog.error("op=mediaOperation.recover phase=settleFailed reason=missingBatch")
            return
        }
        do {
            try await store.settleImportedAsset(
                operation: operation,
                byteSize: byteSize,
                contentModifiedAt: modifiedAt,
                batch: ImportBatchID(unixMilliseconds: batchMs),
                companions: []
            )
            // Crash recovery settles the same way, so it must release the same way --
            // otherwise a run that was interrupted leaves its staged bytes behind forever,
            // which is the leak A1 exists to close.
            StagedSourceReleaser.releaseIfCached(
                kind: operation.sourceKind,
                sourceURL: operation.sourceRootPath.url
                    .appendingPathComponent(operation.sourceRelativePath.rawValue)
            )
            if operation.deleteSourceRequested {
                let sourceURL = operation.sourceRootPath.url
                    .appendingPathComponent(operation.sourceRelativePath.rawValue)
                guard await SourceEraser.erase(
                    kind: operation.sourceKind,
                    identity: operation.sourceDeviceIdentity,
                    relativePath: operation.sourceRelativePath,
                    filesystemURL: sourceURL,
                    cameraImport: cameraImport
                ).isSettled else {
                    return
                }
                try await store.completeImportOperation(key: operation.operationKey)
            }
        } catch {
            OtosLog.catalog.error(
                "op=mediaOperation.recover phase=settleFailed error=\(String(describing: error), privacy: .public)"
            )
        }
    }

    private func recordForeignAndAbandon(_ operation: ActiveFileOperation) async {
        await store.recordForeignOccupant(
            root: operation.destinationRootPath,
            relativePath: operation.destinationRelativePath
        )
        await abandonRecovery(operation, reason: "foreignOccupant")
    }

    private func abandonRecovery(_ operation: ActiveFileOperation, reason: String) async {
        do {
            try await store.abandonImportOperation(key: operation.operationKey)
        } catch {
            OtosLog.catalog.error(
                "op=mediaOperation.recover phase=abandonFailed reason=\(reason, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
        }
    }

    private func deleteSourceIfRequested(
        entry: MediaOperationPlanEntry,
        plan: MediaOperationPlan,
        sourceKind: LibraryRootKind,
        sourceDeviceIdentity: String?,
        batch: ImportBatchID?
    ) async -> Bool {
        guard case let .import(sourceRoot, destinationRoot, _) = plan.mode,
              case let .skipPreexisting(destinationRelative) = entry.disposition,
              let sourceByteSize = entry.source.byteSize,
              let sourceModified = entry.source.contentModifiedAt
        else {
            return true
        }
        let operation = ActiveFileOperation(
            operationKey: .make(),
            mode: "import",
            sourceKind: sourceKind,
            sourceDeviceIdentity: sourceDeviceIdentity,
            sourceRootPath: sourceRoot,
            sourceRelativePath: entry.source.relativePath,
            destinationRootPath: destinationRoot,
            destinationRelativePath: destinationRelative,
            stagingPath: nil,
            importBatchUnixMs: batch?.unixMilliseconds,
            sourceByteSize: sourceByteSize,
            sourceModifiedAt: sourceModified,
            destinationModifiedAt: nil,
            phase: .sourceDeletionPending,
            deleteSourceRequested: true,
            updatedAt: Date()
        )
        do {
            try await store.beginImportOperation(operation)
        } catch {
            OtosLog.catalog.error(
                "op=mediaOperation.journal phase=sourceDeletionBeginFailed error=\(String(describing: error), privacy: .public)"
            )
            return false
        }
        guard await SourceEraser.erase(
            kind: sourceKind,
            identity: sourceDeviceIdentity,
            relativePath: entry.source.relativePath,
            filesystemURL: entry.source.sourceURL,
            cameraImport: cameraImport
        ).isSettled else {
            return false
        }
        do {
            try await store.completeImportOperation(key: operation.operationKey)
            return true
        } catch {
            OtosLog.catalog.error(
                "op=mediaOperation.journal phase=sourceDeletionCompletionFailed error=\(String(describing: error), privacy: .public)"
            )
            return false
        }
    }

    private nonisolated static func stagingURL(adjacentTo final: URL) -> URL {
        let parent = final.deletingLastPathComponent()
        let name = ".\(UUID().uuidString)\(Self.destinationTempSuffix)"
        return parent.appendingPathComponent(name)
    }

    private nonisolated static func stampModificationDate(_ date: Date, at url: URL) {
        try? FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: url.path
        )
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

nonisolated enum MediaImportExecutionResult: Equatable, Sendable {
    case completed(
        publishedCount: Int,
        hasBlockedEntries: Bool,
        hasEntryFailures: Bool,
        skippedForeignCount: Int,
        failedCount: Int,
        incompleteItems: [MediaAssetID]
    )
    /// The run ended before attempting every planned entry — a partial success
    /// carrying why (`ImportStopReason`), never a failure. What landed is a real
    /// batch; the erase sweep never ran; the remainder is the re-plan's to offer.
    case stopped(
        reason: ImportStopReason,
        publishedCount: Int,
        hasBlockedEntries: Bool,
        hasEntryFailures: Bool,
        skippedForeignCount: Int,
        failedCount: Int
    )
    case failed(reason: MediaOperationFailureReason)
    case completedWithErase(
        publishedCount: Int,
        hasBlockedEntries: Bool,
        hasEntryFailures: Bool,
        skippedForeignCount: Int,
        failedCount: Int,
        incompleteItems: [MediaAssetID],
        eraseOutcome: EraseOutcome
    )
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
