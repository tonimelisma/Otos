import Foundation
import OSLog
import Synchronization
import UniformTypeIdentifiers

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
    static let importStagingSuffix = ".otos-import-staging"
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

    private struct EntryTotals: Sendable {
        let publishedCount: Int
        let failedCount: Int
        let skippedForeignCount: Int
        let overlayReuse: OverlayReuseSummary
    }

    private struct EntryExecutionContext: Sendable {
        let plan: MediaOperationPlan
        let batch: ImportBatchID
        let sourceKind: LibraryRootKind
        let sourceDeviceIdentity: String?
        let allowSourceDeletion: Bool
        let namespaceLease: RootNamespaceMutationLease?
    }

    init(
        store: CatalogStore,
        cameraImport: CameraImportAccess? = nil,
        materializationRequester: MaterializationRequesting? = nil
    ) {
        self.store = store
        self.cameraImport = cameraImport
        self.materializationRequester = materializationRequester
    }

    func cancel() {
        cancelFlag.cancel()
    }

    /// Journal-row recovery. Runs at coordinator start and again before each
    /// execution. Does not walk library trees — orphan staging cleanup is
    /// destination-parent scoped via `removeOrphanedStaging(near:)`.
    func recoverJournal() async {
        let signpost = OtosSignpost.catalog.beginInterval("ImportJournalRecovery")
        defer { OtosSignpost.catalog.endInterval("ImportJournalRecovery", signpost) }
        do {
            let operations = try await store.activeImportOperations()
            for operation in operations {
                await recover(operation)
            }
        } catch {
            OtosLog.catalog.error(
                "op=mediaOperation.recover phase=failed error=\(String(describing: error), privacy: .public)"
            )
        }
    }

    /// Removes abandoned `*.otos-import-staging` files only in parent directories
    /// of planned destinations. Full-library enumeration is forbidden — large
    /// cloud libraries would hang startup and tests.
    func removeOrphanedStaging(near destinationURLs: [URL]) async {
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
                for item in items where item.lastPathComponent.hasSuffix(Self.importStagingSuffix) {
                    guard !journaledStaging.contains(item.path) else { continue }
                    try? fileManager.removeItem(at: item)
                    OtosLog.catalog.notice(
                        // swiftlint:disable:next line_length
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
        onProgress: @escaping @Sendable (MediaOperationProgress) -> Void
    ) async -> MediaImportExecutionResult {
        cancelFlag.reset()
        guard case let .import(_, destination, _) = plan.mode else {
            return .failed(reason: .unexpected(detail: "notAnImportPlan"))
        }
        await recoverJournal()
        await removeOrphanedStaging(near: destinationParentURLs(plan: plan, destination: destination))
        let copyEntries = plan.entries.filter {
            if case .copy = $0.disposition {
                return true
            }
            return false
        }
        let totalBytes = copyEntries.reduce(Int64(0)) { $0 + ($1.source.byteSize ?? 0) }
        if let needed = freeSpaceRequired(for: copyEntries),
           !hasEnoughFreeSpace(at: destination.url, required: needed)
        {
            return .failed(reason: .outOfSpace)
        }
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
            guard let lease = await store.acquireNamespaceMutationLease(
                for: destination,
                owner: .importPublication
            ) else {
                return .failed(reason: .destinationUnavailable)
            }
            namespaceLease = lease
        }
        let started = ContinuousClock().now
        let batchSignpost = OtosSignpost.mediaIO.beginInterval("MediaImportBatch")
        OtosLog.mediaIO.noticeOperation("mediaOperation.batch", phase: "start", fields: [
            "batch": "\(batch.unixMilliseconds)",
            "bytes": "\(totalBytes)",
            "files": "\(copyEntries.count)",
            "workers": "\(Self.workerCount)",
        ])
        let executionContext = EntryExecutionContext(
            plan: plan,
            batch: batch,
            sourceKind: sourceKind,
            sourceDeviceIdentity: sourceDeviceIdentity,
            allowSourceDeletion: allowSourceDeletion,
            namespaceLease: namespaceLease
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
            // swiftlint:disable:next line_length
            "op=mediaOperation.batch phase=verified batch=\(batch.unixMilliseconds, privacy: .public) expectedPublished=\(entryTotals.publishedCount, privacy: .public) storedBatchCount=\(storedBatchCount, privacy: .public) skippedPreexisting=\(plan.totals.skipCount, privacy: .public) skippedForeign=\(entryTotals.skippedForeignCount, privacy: .public) failed=\(entryTotals.failedCount, privacy: .public) blocked=\(plan.totals.blockedCount, privacy: .public)"
        )
        OtosLog.catalog.notice(
            // swiftlint:disable:next line_length
            "op=mediaOperation.batch phase=overlayReuse batch=\(batch.unixMilliseconds, privacy: .public) metadataCloned=\(entryTotals.overlayReuse.metadataCloned, privacy: .public) thumbnailCopied=\(entryTotals.overlayReuse.thumbnailCopied, privacy: .public) misses=\(entryTotals.overlayReuse.missDescription, privacy: .public)"
        )
        if batchIntegrityMismatch {
            OtosLog.catalog.fault(
                // swiftlint:disable:next line_length
                "op=mediaOperation.batch phase=integrityMismatch batch=\(batch.unixMilliseconds, privacy: .public) expectedPublished=\(entryTotals.publishedCount, privacy: .public) storedBatchCount=\(storedBatchCount, privacy: .public)"
            )
        }
        OtosSignpost.mediaIO.endInterval("MediaImportBatch", batchSignpost)
        let elapsedMs = max(DiagnosticsTiming.milliseconds(from: started, to: .now), 1)
        OtosLog.mediaIO.noticeOperation("mediaOperation.batch", phase: "finish", fields: [
            "batch": "\(batch.unixMilliseconds)",
            "bytes": "\(totalBytes)",
            "elapsedMs": "\(elapsedMs)",
            "files": "\(copyEntries.count)",
            "mbps": throughputMBps(bytes: totalBytes, elapsedMs: elapsedMs),
            "workers": "\(Self.workerCount)",
        ])
        if cancelFlag.isCancelled {
            return .cancelled(
                publishedCount: entryTotals.publishedCount,
                hasBlockedEntries: hasBlockedEntries,
                hasEntryFailures: entryTotals.failedCount > 0 || batchIntegrityMismatch,
                skippedForeignCount: entryTotals.skippedForeignCount,
                failedCount: entryTotals.failedCount
            )
        }
        return .completed(
            publishedCount: entryTotals.publishedCount,
            hasBlockedEntries: hasBlockedEntries,
            hasEntryFailures: entryTotals.failedCount > 0 || batchIntegrityMismatch,
            skippedForeignCount: entryTotals.skippedForeignCount,
            failedCount: entryTotals.failedCount
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
        var failedCount = 0
        var skippedForeignCount = 0
        var overlayReuse = OverlayReuseSummary()
        let copyEntries = context.plan.entries.filter {
            if case .copy = $0.disposition {
                true
            } else {
                false
            }
        }
        let byteProgress = ByteProgressTracker(totalCount: totalCount, totalBytes: totalBytes)
        await withTaskGroup(of: EntryResult.self) { group in
            var nextIndex = 0
            func submit(_ index: Int) {
                let entry = copyEntries[index]
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
            while nextIndex < min(Self.workerCount, copyEntries.count) {
                submit(nextIndex)
                nextIndex += 1
            }
            while let result = await group.next() {
                switch result.outcome {
                case let .published(reuseResult):
                    publishedCount += 1
                    overlayReuse.record(reuseResult)
                    byteProgress.finish(index: result.index, resolvedItem: true, publishedBytes: result.byteSize)
                case .cancelled:
                    cancelFlag.cancel()
                    byteProgress.finish(index: result.index, resolvedItem: false, publishedBytes: 0)
                case .skippedForeign:
                    skippedForeignCount += 1
                    byteProgress.finish(index: result.index, resolvedItem: true, publishedBytes: 0)
                case .failed:
                    failedCount += 1
                    byteProgress.finish(index: result.index, resolvedItem: true, publishedBytes: 0)
                }
                onProgress(byteProgress.current())
                if nextIndex < copyEntries.count, !cancelFlag.isCancelled {
                    submit(nextIndex)
                    nextIndex += 1
                }
            }
        }
        if context.allowSourceDeletion {
            for entry in context.plan.entries where entry.isSkipPreexisting {
                if await deleteSourceIfRequested(
                    entry: entry,
                    plan: context.plan,
                    sourceKind: context.sourceKind,
                    sourceDeviceIdentity: context.sourceDeviceIdentity,
                    batch: nil
                ) == false {
                    failedCount += 1
                }
            }
        }
        return EntryTotals(
            publishedCount: publishedCount,
            failedCount: failedCount,
            skippedForeignCount: skippedForeignCount,
            overlayReuse: overlayReuse
        )
    }

    private enum EntryOutcome: Sendable {
        case published(ImportOverlayReuseResult)
        case skippedForeign
        case cancelled
        case failed
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
    ) async -> Bool {
        switch sourceKind {
        case .removableVolume:
            guard let sourceModified else {
                return false
            }
            return Self.fileMatches(url: sourceURL, byteSize: sourceByteSize, modifiedAt: sourceModified)
        case .deviceMTP:
            guard let identity = sourceDeviceIdentity, let cameraImport else {
                return false
            }
            return await cameraImport.revalidateItem(
                identity: identity,
                relativePath: entry.source.relativePath,
                byteSize: sourceByteSize,
                modifiedAt: sourceModified
            )
        case .library:
            return false
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
            return .failed
        }
    }

    private nonisolated func transferVolumeBytes(
        from sourceURL: URL,
        to stagingURL: URL,
        operationKey: ActiveFileOperationKey,
        onByteProgress: @escaping @Sendable (Int64) -> Void
    ) async -> EntryOutcome? {
        let sharedCancel = cancelFlag
        let copyOutcome = await withCheckedContinuation {
            (continuation: CheckedContinuation<CopyfileTransfer.Outcome, Never>) in
            Task.detached {
                let outcome = CopyfileTransfer.copy(
                    from: sourceURL,
                    to: stagingURL,
                    onProgress: { progress in
                        onByteProgress(progress.completedBytes)
                    },
                    shouldContinue: { !sharedCancel.isCancelled }
                )
                continuation.resume(returning: outcome)
            }
        }
        if sharedCancel.isCancelled || copyOutcome == .cancelled {
            try? FileManager.default.removeItem(at: stagingURL)
            try? await store.abandonImportOperation(key: operationKey)
            return .cancelled
        }
        if case let .failed(message) = copyOutcome {
            try? FileManager.default.removeItem(at: stagingURL)
            try? await store.abandonImportOperation(key: operationKey)
            OtosLog.catalog.error(
                "op=mediaOperation.copy phase=failed detail=\(message, privacy: .public)"
            )
            return .failed
        }
        return nil
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
            return .failed
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
            importStagingURL: stagingURL
        ) {
        case .completed:
            if let size = try? stagingURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                onByteProgress(Int64(size))
            }
            // Download planned companions into the staging directory before settlement.
            for (sourceRelative, _) in entry.companionDestinations {
                let leaf = (sourceRelative.rawValue as NSString).lastPathComponent
                let companionEnrichment = enrichmentURL
                    .deletingLastPathComponent()
                    .appendingPathComponent(leaf)
                let companionStaging = stagingURL
                    .deletingLastPathComponent()
                    .appendingPathComponent(leaf)
                switch await cameraImport.ensureImportBytes(
                    identity: identity,
                    relativePath: sourceRelative,
                    enrichmentURL: companionEnrichment,
                    importStagingURL: companionStaging
                ) {
                case .completed:
                    continue
                case .cancelled:
                    try? FileManager.default.removeItem(at: stagingURL)
                    try? await store.abandonImportOperation(key: operationKey)
                    return .cancelled
                case let .failed(message):
                    try? FileManager.default.removeItem(at: stagingURL)
                    try? await store.abandonImportOperation(key: operationKey)
                    OtosLog.catalog.error(
                        // swiftlint:disable:next line_length
                        "op=mediaOperation.camera phase=companionFailed detail=\(message, privacy: .public)"
                    )
                    return .failed
                }
            }
            return nil
        case .cancelled:
            try? FileManager.default.removeItem(at: stagingURL)
            try? await store.abandonImportOperation(key: operationKey)
            return .cancelled
        case let .failed(message):
            try? FileManager.default.removeItem(at: stagingURL)
            try? await store.abandonImportOperation(key: operationKey)
            OtosLog.catalog.error(
                "op=mediaOperation.camera phase=failed detail=\(message, privacy: .public)"
            )
            return .failed
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
            return .failed
        }
        guard let namespaceLease = context.namespaceLease else {
            return .failed
        }
        let sourceURL = entry.source.sourceURL
        let started = ContinuousClock().now
        let signpost = OtosSignpost.mediaIO.beginInterval("MediaImportFileCopy")
        defer {
            OtosSignpost.mediaIO.endInterval("MediaImportFileCopy", signpost)
            let elapsedMs = max(DiagnosticsTiming.milliseconds(from: started, to: .now), 1)
            OtosLog.mediaIO.noticeOperation("mediaOperation.copy", phase: "finish", fields: [
                "batch": "\(context.batch.unixMilliseconds)",
                "bytes": "\(entry.source.byteSize ?? 0)",
                "elapsedMs": "\(elapsedMs)",
                "mbps": throughputMBps(bytes: entry.source.byteSize ?? 0, elapsedMs: elapsedMs),
                "worker": "\(workerID)",
            ])
        }
        let finalURL = destinationRoot.url.appendingPathComponent(destinationRelative.rawValue)
        guard let sourceByteSize = entry.source.byteSize else {
            return .failed
        }
        let sourceModified = entry.source.contentModifiedAt
        let matches = await sourceStillMatches(
            entry: entry,
            sourceKind: context.sourceKind,
            sourceDeviceIdentity: context.sourceDeviceIdentity,
            sourceURL: sourceURL,
            sourceByteSize: sourceByteSize,
            sourceModified: sourceModified
        )
        guard matches else {
            OtosLog.catalog.notice(
                "op=mediaOperation.copy phase=staleSource path=\(sourceURL.path, privacy: .public)"
            )
            return .failed
        }
        if FileManager.default.fileExists(atPath: finalURL.path) {
            return .skippedForeign
        }

        let stagingURL = Self.stagingURL(adjacentTo: finalURL)
        guard let destinationModified = ImportDestinationDate.expected(for: entry.source)
        else {
            return .failed
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
            return .failed
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
            return early
        }

        guard !cancelFlag.isCancelled else {
            try? FileManager.default.removeItem(at: stagingURL)
            try? await store.abandonImportOperation(key: operation.operationKey)
            return .cancelled
        }
        let copyFinished = ContinuousClock().now
        let hashStart = Date()
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
            return .failed
        }

        guard let hashFinished else {
            return .failed
        }
        return await Self.publishAndSettle(PublishSettleRequest(
            operation: operation,
            store: store,
            cameraImport: cameraImport,
            entry: entry,
            stagingURL: stagingURL,
            finalURL: finalURL,
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
    }

    private struct PublishSettleRequest {
        var operation: ActiveFileOperation
        let store: CatalogStore
        let cameraImport: CameraImportAccess?
        let entry: MediaOperationPlanEntry
        let stagingURL: URL
        let finalURL: URL
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

    // The publication handoff is one crash boundary: journal gate, exclusive rename,
    // durable pending-settlement transition, and the single Store settlement transaction.
    // swiftlint:disable:next function_body_length
    private nonisolated static func publishAndSettle(_ request: PublishSettleRequest) async -> EntryOutcome {
        guard await request.store.ownsNamespaceMutationLease(request.namespaceLease) else {
            try? await request.store.abandonImportOperation(key: request.operation.operationKey)
            OtosLog.catalog.notice(
                "op=mediaOperation.publish phase=blocked reason=namespaceLeaseUnavailable"
            )
            return .failed
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
            return .failed
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
                return .failed
            }
            guard await request.store.ownsNamespaceMutationLease(request.namespaceLease) else {
                return .failed
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
                return .failed
            }
            OtosLog.catalog.error(
                "op=mediaOperation.publish phase=failed detail=\(message, privacy: .public)"
            )
            return .failed
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
            return .failed
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
            return .failed
        }
        guard await request.store.ownsNamespaceMutationLease(request.namespaceLease) else {
            OtosLog.catalog.notice(
                "op=mediaOperation.settle phase=blocked reason=namespaceLeaseUnavailable"
            )
            return .failed
        }

        let companionRows = Self.companionDestinations(
            entry: request.entry,
            destinationRoot: request.destinationRoot
        )
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
            return .failed
        }
        let settleFinished = ContinuousClock().now
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
                return .failed
            }
            guard await Self.deleteSource(
                kind: request.sourceKind,
                identity: request.sourceDeviceIdentity,
                relativePath: request.sourceRelativePath,
                filesystemURL: request.sourceURL,
                cameraImport: request.cameraImport
            ) else {
                return .failed
            }
            do {
                try await request.store.completeImportOperation(key: operation.operationKey)
            } catch {
                OtosLog.catalog.error(
                    "op=mediaOperation.journal phase=sourceDeletionCompletionFailed error=\(String(describing: error), privacy: .public)"
                )
                return .failed
            }
        }
        return .published(reuseResult)
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
        return .failed
    }

    private enum RecoveryOwnership: Sendable {
        case proven(byteSize: Int64, modifiedAt: Date)
        case foreign
        case deferredMaterialization
    }

    private func recover(_ operation: ActiveFileOperation) async {
        guard let lease = await store.acquireNamespaceMutationLease(
            for: operation.destinationRootPath,
            owner: .importPublication
        ) else {
            OtosLog.catalog.notice(
                "op=mediaOperation.recover phase=blocked reason=namespaceLeaseUnavailable"
            )
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
            guard await Self.deleteSource(
                kind: operation.sourceKind,
                identity: operation.sourceDeviceIdentity,
                relativePath: operation.sourceRelativePath,
                filesystemURL: sourceURL,
                cameraImport: cameraImport
            ) else {
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
            // swiftlint:disable:next line_length
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
            if operation.deleteSourceRequested {
                let sourceURL = operation.sourceRootPath.url
                    .appendingPathComponent(operation.sourceRelativePath.rawValue)
                guard await Self.deleteSource(
                    kind: operation.sourceKind,
                    identity: operation.sourceDeviceIdentity,
                    relativePath: operation.sourceRelativePath,
                    filesystemURL: sourceURL,
                    cameraImport: cameraImport
                ) else {
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
        guard await Self.deleteSource(
            kind: sourceKind,
            identity: sourceDeviceIdentity,
            relativePath: entry.source.relativePath,
            filesystemURL: entry.source.sourceURL,
            cameraImport: cameraImport
        ) else {
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

    private nonisolated static func deleteSource(
        kind: LibraryRootKind,
        identity: String?,
        relativePath: MediaRelativePath,
        filesystemURL: URL,
        cameraImport: CameraImportAccess?
    ) async -> Bool {
        switch kind {
        case .removableVolume, .library:
            guard FileManager.default.fileExists(atPath: filesystemURL.path) else {
                return true
            }
            do {
                try FileManager.default.removeItem(at: filesystemURL)
                return true
            } catch {
                OtosLog.catalog.error(
                    "op=mediaOperation.sourceDelete phase=failed path=\(filesystemURL.path, privacy: .public)"
                )
                return false
            }
        case .deviceMTP:
            guard let identity, let cameraImport else {
                return false
            }
            guard await cameraImport.canDelete(identity: identity) else {
                OtosLog.catalog.notice(
                    "op=mediaOperation.sourceDelete phase=unsupported identity=\(identity, privacy: .public)"
                )
                return false
            }
            let ok = await cameraImport.deleteItem(identity: identity, relativePath: relativePath)
            if !ok {
                OtosLog.catalog.error(
                    // swiftlint:disable:next line_length
                    "op=mediaOperation.sourceDelete phase=failed identity=\(identity, privacy: .public) path=\(relativePath.rawValue, privacy: .public)"
                )
            }
            return ok
        }
    }

    private nonisolated static func companionDestinations(
        entry: MediaOperationPlanEntry,
        destinationRoot: LibraryRootPath
    ) -> [MediaCompanion] {
        entry.companionDestinations.compactMap { sourceRelative, destinationRelative in
            let companion = entry.source.companions.first { $0.relativePath == sourceRelative }
            guard let companion else {
                return nil
            }
            // Copy companion bytes beside the published primary when present.
            // Camera imports stage companions next to the primary staging file; after
            // publish the primary is at finalURL, so also accept companions beside it.
            let sourceURL = entry.source.sourceURL
                .deletingLastPathComponent()
                .appendingPathComponent((sourceRelative.rawValue as NSString).lastPathComponent)
            let stagedBesidePrimary = destinationRoot.url
                .appendingPathComponent(entry.finalDestination.rawValue)
                .deletingLastPathComponent()
                .appendingPathComponent((sourceRelative.rawValue as NSString).lastPathComponent)
            let destURL = destinationRoot.url.appendingPathComponent(destinationRelative.rawValue)
            let companionSource: URL? = if FileManager.default.fileExists(atPath: sourceURL.path) {
                sourceURL
            } else if FileManager.default.fileExists(atPath: stagedBesidePrimary.path),
                      stagedBesidePrimary.path != destURL.path
            {
                stagedBesidePrimary
            } else {
                nil
            }
            if let companionSource,
               !FileManager.default.fileExists(atPath: destURL.path)
            {
                try? FileManager.default.createDirectory(
                    at: destURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                _ = CopyfileTransfer.copy(
                    from: companionSource,
                    to: destURL,
                    onProgress: { _ in },
                    shouldContinue: { true }
                )
            }
            return MediaCompanion(
                relativePath: destinationRelative,
                primaryRelativePath: entry.finalDestination,
                kind: companion.kind,
                byteSize: companion.byteSize,
                contentModifiedAt: companion.contentModifiedAt
            )
        }
    }

    private nonisolated static func stagingURL(adjacentTo final: URL) -> URL {
        let parent = final.deletingLastPathComponent()
        let name = ".\(UUID().uuidString)\(Self.importStagingSuffix)"
        return parent.appendingPathComponent(name)
    }

    private nonisolated static func stampModificationDate(_ date: Date, at url: URL) {
        try? FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: url.path
        )
    }

    private nonisolated static func fileMatches(url: URL, byteSize: Int64, modifiedAt: Date) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize,
              let modified = values.contentModificationDate
        else {
            return false
        }
        return Int64(size) == byteSize
            && Int(modified.timeIntervalSince1970) == Int(modifiedAt.timeIntervalSince1970)
    }

    private func freeSpaceRequired(for entries: [MediaOperationPlanEntry]) -> Int64? {
        let bytes = entries.reduce(Int64(0)) { $0 + ($1.source.byteSize ?? 0) }
        guard bytes > 0 else {
            return nil
        }
        return bytes + (64 * 1024 * 1024)
    }

    private func hasEnoughFreeSpace(at url: URL, required: Int64) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let capacity = values.volumeAvailableCapacityForImportantUsage
        else {
            // Provider quota is unobservable; do not block when capacity is unknown.
            return true
        }
        return capacity >= required
    }
}

nonisolated enum MediaImportExecutionResult: Equatable, Sendable {
    case completed(
        publishedCount: Int,
        hasBlockedEntries: Bool,
        hasEntryFailures: Bool,
        skippedForeignCount: Int,
        failedCount: Int
    )
    case cancelled(
        publishedCount: Int,
        hasBlockedEntries: Bool,
        hasEntryFailures: Bool,
        skippedForeignCount: Int,
        failedCount: Int
    )
    case failed(reason: MediaOperationFailureReason)
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
