import Foundation
import OSLog

/// Filesystem import executor (plan 0055 Stage E).
///
/// Runs bounded copy lanes for one ready plan: journal → copyfile/camera staging →
/// exclusive publish → durable settlement. Camera downloads reuse enrichment
/// staging when present, revalidate `ICCameraFile` facts, and stamp
/// `destination_modified_at`. Cancellation aborts the in-flight transfer, removes
/// staging, settles any already-published entries, and stops scheduling new ones.
actor MediaImportExecutor {
    static let workerCount = 8
    private let store: CatalogStore
    private let cameraImport: CameraImportAccess?
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

    init(store: CatalogStore, cameraImport: CameraImportAccess? = nil) {
        self.store = store
        self.cameraImport = cameraImport
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
                for item in items where item.lastPathComponent.hasSuffix(".otos-import-staging") {
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
        sourceKind: LibraryRootKind,
        sourceDeviceIdentity: String?,
        deleteSourceRequested: Bool,
        onProgress: @escaping @Sendable (MediaOperationProgress) -> Void
    ) async -> MediaImportExecutionResult {
        cancelFlag.reset()
        guard case let .import(_, destination, _) = plan.mode else {
            return .failed(problem: "notAnImportPlan")
        }
        await recoverJournal()
        await removeOrphanedStaging(near: destinationParentURLs(plan: plan, destination: destination))
        let batch = ImportBatchID()
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
            return .failed(problem: "insufficientSpace")
        }
        let hasBlockedEntries = plan.entries.contains {
            if case .blocked = $0.disposition {
                return true
            }
            return false
        }
        let allowSourceDeletion = deleteSourceRequested && !hasBlockedEntries
        let started = ContinuousClock().now
        let batchSignpost = OtosSignpost.mediaIO.beginInterval("MediaImportBatch")
        OtosLog.mediaIO.noticeOperation("mediaOperation.batch", phase: "start", fields: [
            "batch": "\(batch.unixMilliseconds)",
            "bytes": "\(totalBytes)",
            "files": "\(copyEntries.count)",
            "workers": "\(Self.workerCount)",
        ])
        let entryTotals = await runPlanEntries(
            plan: plan,
            batch: batch,
            sourceKind: sourceKind,
            sourceDeviceIdentity: sourceDeviceIdentity,
            allowSourceDeletion: allowSourceDeletion,
            totalCount: copyEntries.count,
            totalBytes: totalBytes,
            onProgress: onProgress
        )
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
        let elapsedMs = max(Int(started.duration(to: .now).components.attoseconds / 1_000_000_000_000_000), 1)
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
                batch: entryTotals.publishedCount > 0 ? batch : nil,
                hasBlockedEntries: hasBlockedEntries,
                hasEntryFailures: entryTotals.failedCount > 0 || batchIntegrityMismatch
            )
        }
        return .completed(
            publishedCount: entryTotals.publishedCount,
            batch: entryTotals.publishedCount > 0 ? batch : nil,
            hasBlockedEntries: hasBlockedEntries,
            hasEntryFailures: entryTotals.failedCount > 0 || batchIntegrityMismatch
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
        plan: MediaOperationPlan,
        batch: ImportBatchID,
        sourceKind: LibraryRootKind,
        sourceDeviceIdentity: String?,
        allowSourceDeletion: Bool,
        totalCount: Int,
        totalBytes: Int64,
        onProgress: @escaping @Sendable (MediaOperationProgress) -> Void
    ) async -> EntryTotals {
        var completed = 0
        var completedBytes: Int64 = 0
        var publishedCount = 0
        var failedCount = 0
        var skippedForeignCount = 0
        var overlayReuse = OverlayReuseSummary()
        let copyEntries = plan.entries.filter {
            if case .copy = $0.disposition {
                true
            } else {
                false
            }
        }
        await withTaskGroup(of: EntryResult.self) { group in
            var nextIndex = 0
            func submit(_ index: Int) {
                let entry = copyEntries[index]
                group.addTask {
                    guard !self.cancelFlag.isCancelled else {
                        return EntryResult(outcome: .cancelled, byteSize: 0)
                    }
                    let outcome = await self.copyEntry(
                        entry,
                        plan: plan,
                        batch: batch,
                        sourceKind: sourceKind,
                        sourceDeviceIdentity: sourceDeviceIdentity,
                        deleteSourceRequested: allowSourceDeletion,
                        workerID: index % Self.workerCount,
                        onByteProgress: { _ in }
                    )
                    return EntryResult(outcome: outcome, byteSize: entry.source.byteSize ?? 0)
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
                    completed += 1
                    completedBytes += result.byteSize
                case .cancelled:
                    cancelFlag.cancel()
                case .skippedForeign:
                    skippedForeignCount += 1
                    completed += 1
                case .failed:
                    failedCount += 1
                    completed += 1
                }
                onProgress(MediaOperationProgress(
                    completedCount: completed,
                    totalCount: totalCount,
                    completedBytes: completedBytes,
                    totalBytes: totalBytes
                ))
                if nextIndex < copyEntries.count, !cancelFlag.isCancelled {
                    submit(nextIndex)
                    nextIndex += 1
                }
            }
        }
        if allowSourceDeletion {
            for entry in plan.entries where entry.isSkipPreexisting {
                await deleteSourceIfRequested(
                    entry: entry,
                    plan: plan,
                    sourceKind: sourceKind,
                    sourceDeviceIdentity: sourceDeviceIdentity,
                    batch: nil
                )
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
            return fileMatches(url: sourceURL, byteSize: sourceByteSize, modifiedAt: sourceModified)
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
        plan: MediaOperationPlan,
        batch: ImportBatchID,
        sourceKind: LibraryRootKind,
        sourceDeviceIdentity: String?,
        deleteSourceRequested: Bool,
        workerID: Int,
        onByteProgress: @escaping @Sendable (Int64) -> Void
    ) async -> EntryOutcome {
        guard case let .import(sourceRoot, destinationRoot, _) = plan.mode,
              case let .copy(destinationRelative) = entry.disposition
        else {
            return .failed
        }
        let sourceURL = entry.source.sourceURL
        let started = ContinuousClock().now
        let signpost = OtosSignpost.mediaIO.beginInterval("MediaImportFileCopy")
        defer {
            OtosSignpost.mediaIO.endInterval("MediaImportFileCopy", signpost)
            let elapsedMs = max(
                Int(started.duration(to: .now).components.attoseconds / 1_000_000_000_000_000),
                1
            )
            OtosLog.mediaIO.noticeOperation("mediaOperation.copy", phase: "finish", fields: [
                "batch": "\(batch.unixMilliseconds)",
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
            sourceKind: sourceKind,
            sourceDeviceIdentity: sourceDeviceIdentity,
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
            sourceKind: sourceKind,
            sourceDeviceIdentity: sourceDeviceIdentity,
            sourceRootPath: sourceRoot,
            sourceRelativePath: entry.source.relativePath,
            destinationRootPath: destinationRoot,
            destinationRelativePath: destinationRelative,
            stagingPath: stagingURL.path,
            importBatchUnixMs: batch.unixMilliseconds,
            sourceByteSize: sourceByteSize,
            sourceModifiedAt: operationSourceModified,
            destinationModifiedAt: destinationModified,
            phase: .copying,
            deleteSourceRequested: deleteSourceRequested,
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
            sourceKind: sourceKind,
            sourceDeviceIdentity: sourceDeviceIdentity,
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
            try? await store.recordImportOperationProgress(operation)
            hashFinished = ContinuousClock().now
            OtosLog.mediaIO.noticeOperation(
                "contentHash",
                phase: "finish",
                fields: [
                    "owner": "import",
                    "batch": "\(batch.unixMilliseconds)",
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
                fields: ["owner": "import", "batch": "\(batch.unixMilliseconds)", "worker": "\(workerID)"]
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
                    "batch": "\(batch.unixMilliseconds)",
                    "worker": "\(workerID)",
                    "category": category.rawValue,
                ]
            )
            return .failed
        }

        guard let hashFinished else {
            return .failed
        }
        return await publishAndSettle(PublishSettleRequest(
            operation: operation,
            entry: entry,
            stagingURL: stagingURL,
            finalURL: finalURL,
            destinationRoot: destinationRoot,
            destinationRelative: destinationRelative,
            sourceURL: sourceURL,
            sourceKind: sourceKind,
            sourceDeviceIdentity: sourceDeviceIdentity,
            sourceRelativePath: entry.source.relativePath,
            sourceByteSize: sourceByteSize,
            destinationModified: destinationModified,
            batch: batch,
            deleteSourceRequested: deleteSourceRequested,
            workerID: workerID,
            copyStarted: started,
            copyFinished: copyFinished,
            hashFinished: hashFinished
        ))
    }

    private struct PublishSettleRequest {
        var operation: ActiveFileOperation
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
        let deleteSourceRequested: Bool
        let workerID: Int
        let copyStarted: ContinuousClock.Instant
        let copyFinished: ContinuousClock.Instant
        let hashFinished: ContinuousClock.Instant
    }

    private nonisolated func publishAndSettle(_ request: PublishSettleRequest) async -> EntryOutcome {
        var operation = request.operation
        stampModificationDate(request.destinationModified, at: request.stagingURL)
        operation.phase = .readyToPublish
        operation.updatedAt = Date()
        try? await store.recordImportOperationProgress(operation)

        switch ExclusivePublication.publish(staging: request.stagingURL, final: request.finalURL) {
        case .destinationExists:
            try? FileManager.default.removeItem(at: request.stagingURL)
            try? await store.abandonImportOperation(key: operation.operationKey)
            await store.recordForeignOccupant(
                root: request.destinationRoot,
                relativePath: request.destinationRelative
            )
            return .skippedForeign
        case let .failed(message):
            try? FileManager.default.removeItem(at: request.stagingURL)
            try? await store.abandonImportOperation(key: operation.operationKey)
            OtosLog.catalog.error(
                "op=mediaOperation.publish phase=failed detail=\(message, privacy: .public)"
            )
            return .failed
        case .published:
            break
        }
        let publishFinished = ContinuousClock().now
        let finalValues = try? request.finalURL.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey]
        )
        let settledByteSize = Int64(finalValues?.fileSize ?? Int(request.sourceByteSize))
        let settledModified = finalValues?.contentModificationDate ?? request.destinationModified

        operation.phase = .publishedPendingSettlement
        operation.stagingPath = nil
        operation.destinationModifiedAt = settledModified
        operation.updatedAt = Date()
        try? await store.recordImportOperationProgress(operation)

        let companionRows = companionDestinations(
            entry: request.entry,
            destinationRoot: request.destinationRoot
        )
        var reuseResult = ImportOverlayReuseResult.notReused
        do {
            reuseResult = try await store.settleImportedAsset(
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
            "stagingMs": elapsedMilliseconds(from: request.copyStarted, to: request.copyFinished),
            "worker": "\(request.workerID)",
        ])

        if request.deleteSourceRequested {
            await deleteSource(
                kind: request.sourceKind,
                identity: request.sourceDeviceIdentity,
                relativePath: request.sourceRelativePath,
                filesystemURL: request.sourceURL
            )
            try? await store.completeImportOperation(key: operation.operationKey)
        }
        return .published(reuseResult)
    }

    private func recover(_ operation: ActiveFileOperation) async {
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
            try? await store.abandonImportOperation(key: operation.operationKey)
        case .readyToPublish:
            if finalExists {
                if let staging, stagingExists {
                    try? FileManager.default.removeItem(at: staging)
                }
                await settleRecovered(operation)
            } else if let staging, stagingExists {
                switch ExclusivePublication.publish(staging: staging, final: final) {
                case .published:
                    await settleRecovered(operation)
                case .destinationExists:
                    await settleRecovered(operation)
                case let .failed(message):
                    try? FileManager.default.removeItem(at: staging)
                    try? await store.abandonImportOperation(key: operation.operationKey)
                    OtosLog.catalog.error(
                        "op=mediaOperation.recover phase=publishFailed detail=\(message, privacy: .public)"
                    )
                }
            } else {
                try? await store.abandonImportOperation(key: operation.operationKey)
            }
        case .publishedPendingSettlement:
            if finalExists {
                await settleRecovered(operation)
            } else if let staging, stagingExists {
                try? FileManager.default.removeItem(at: staging)
                try? await store.abandonImportOperation(key: operation.operationKey)
            } else {
                try? await store.abandonImportOperation(key: operation.operationKey)
            }
        case .sourceDeletionPending:
            let sourceURL = operation.sourceRootPath.url
                .appendingPathComponent(operation.sourceRelativePath.rawValue)
            await deleteSource(
                kind: operation.sourceKind,
                identity: operation.sourceDeviceIdentity,
                relativePath: operation.sourceRelativePath,
                filesystemURL: sourceURL
            )
            try? await store.completeImportOperation(key: operation.operationKey)
        }
        OtosLog.catalog.notice(
            // swiftlint:disable:next line_length
            "op=mediaOperation.recover phase=\(operation.phase.rawValue, privacy: .public) key=\(operation.operationKey.rawValue, privacy: .public) stagingExists=\(stagingExists, privacy: .public) finalExists=\(finalExists, privacy: .public)"
        )
    }

    private func settleRecovered(_ operation: ActiveFileOperation) async {
        guard let batchMs = operation.importBatchUnixMs
        else {
            try? await store.abandonImportOperation(key: operation.operationKey)
            return
        }
        let final = operation.destinationRootPath.url
            .appendingPathComponent(operation.destinationRelativePath.rawValue)
        let values = try? final.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let byteSize = Int64(values?.fileSize ?? Int(operation.sourceByteSize))
        let modified = values?.contentModificationDate ?? operation.destinationModifiedAt
        guard let modified else {
            try? await store.abandonImportOperation(key: operation.operationKey)
            return
        }
        do {
            try await store.settleImportedAsset(
                operation: operation,
                byteSize: byteSize,
                contentModifiedAt: modified,
                batch: ImportBatchID(unixMilliseconds: batchMs),
                companions: []
            )
            if operation.deleteSourceRequested {
                let sourceURL = operation.sourceRootPath.url
                    .appendingPathComponent(operation.sourceRelativePath.rawValue)
                await deleteSource(
                    kind: operation.sourceKind,
                    identity: operation.sourceDeviceIdentity,
                    relativePath: operation.sourceRelativePath,
                    filesystemURL: sourceURL
                )
                try? await store.completeImportOperation(key: operation.operationKey)
            }
        } catch {
            OtosLog.catalog.error(
                "op=mediaOperation.recover phase=settleFailed error=\(String(describing: error), privacy: .public)"
            )
        }
    }

    private func deleteSourceIfRequested(
        entry: MediaOperationPlanEntry,
        plan: MediaOperationPlan,
        sourceKind: LibraryRootKind,
        sourceDeviceIdentity: String?,
        batch: ImportBatchID?
    ) async {
        guard case let .import(sourceRoot, destinationRoot, _) = plan.mode,
              case let .skipPreexisting(destinationRelative) = entry.disposition,
              let sourceByteSize = entry.source.byteSize,
              let sourceModified = entry.source.contentModifiedAt
        else {
            return
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
        try? await store.beginImportOperation(operation)
        await deleteSource(
            kind: sourceKind,
            identity: sourceDeviceIdentity,
            relativePath: entry.source.relativePath,
            filesystemURL: entry.source.sourceURL
        )
        try? await store.completeImportOperation(key: operation.operationKey)
    }

    private func deleteSource(
        kind: LibraryRootKind,
        identity: String?,
        relativePath: MediaRelativePath,
        filesystemURL: URL
    ) async {
        switch kind {
        case .removableVolume, .library:
            do {
                try FileManager.default.removeItem(at: filesystemURL)
            } catch {
                OtosLog.catalog.error(
                    "op=mediaOperation.sourceDelete phase=failed path=\(filesystemURL.path, privacy: .public)"
                )
            }
        case .deviceMTP:
            guard let identity, let cameraImport else {
                return
            }
            guard await cameraImport.canDelete(identity: identity) else {
                OtosLog.catalog.notice(
                    "op=mediaOperation.sourceDelete phase=unsupported identity=\(identity, privacy: .public)"
                )
                return
            }
            let ok = await cameraImport.deleteItem(identity: identity, relativePath: relativePath)
            if !ok {
                OtosLog.catalog.error(
                    // swiftlint:disable:next line_length
                    "op=mediaOperation.sourceDelete phase=failed identity=\(identity, privacy: .public) path=\(relativePath.rawValue, privacy: .public)"
                )
            }
        }
    }

    private nonisolated func companionDestinations(
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
        let name = ".\(UUID().uuidString).otos-import-staging"
        return parent.appendingPathComponent(name)
    }

    private nonisolated func stampModificationDate(_ date: Date, at url: URL) {
        try? FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: url.path
        )
    }

    private nonisolated func fileMatches(url: URL, byteSize: Int64, modifiedAt: Date) -> Bool {
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
        batch: ImportBatchID?,
        hasBlockedEntries: Bool,
        hasEntryFailures: Bool
    )
    case cancelled(
        publishedCount: Int,
        batch: ImportBatchID?,
        hasBlockedEntries: Bool,
        hasEntryFailures: Bool
    )
    case failed(problem: String)
}

/// Thread-safe cancel flag for copyfile callbacks off the executor actor.
private final class CancelFlag: @unchecked Sendable {
    private nonisolated(unsafe) var cancelled = false
    private let lock = NSLock()

    nonisolated func reset() {
        lock.lock()
        cancelled = false
        lock.unlock()
    }

    nonisolated func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    nonisolated var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}
