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
    private let store: CatalogStore
    private let cameraImport: CameraImportAccess?
    private let cancelFlag = CancelFlag()

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
            let operations = try await store.fetchActiveFileOperations()
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
        await store.removeOrphanedImportStagingFiles(near: destinationURLs)
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
        let publishedCount = await runPlanEntries(
            plan: plan,
            batch: batch,
            sourceKind: sourceKind,
            sourceDeviceIdentity: sourceDeviceIdentity,
            allowSourceDeletion: allowSourceDeletion,
            totalCount: copyEntries.count,
            totalBytes: totalBytes,
            onProgress: onProgress
        )
        if cancelFlag.isCancelled {
            return .cancelled(
                publishedCount: publishedCount,
                batch: publishedCount > 0 ? batch : nil,
                hasBlockedEntries: hasBlockedEntries
            )
        }
        return .completed(
            publishedCount: publishedCount,
            batch: publishedCount > 0 ? batch : nil,
            hasBlockedEntries: hasBlockedEntries
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
    ) async -> Int {
        var completed = 0
        var completedBytes: Int64 = 0
        var publishedCount = 0
        for entry in plan.entries {
            if cancelFlag.isCancelled {
                break
            }
            switch entry.disposition {
            case .copy:
                let completedSnapshot = completed
                let completedBytesSnapshot = completedBytes
                let outcome = await copyEntry(
                    entry,
                    plan: plan,
                    batch: batch,
                    sourceKind: sourceKind,
                    sourceDeviceIdentity: sourceDeviceIdentity,
                    deleteSourceRequested: allowSourceDeletion,
                    onByteProgress: { bytes in
                        onProgress(MediaOperationProgress(
                            completedCount: completedSnapshot,
                            totalCount: totalCount,
                            completedBytes: completedBytesSnapshot + bytes,
                            totalBytes: totalBytes
                        ))
                    }
                )
                switch outcome {
                case .published:
                    publishedCount += 1
                    completed += 1
                    completedBytes += entry.source.byteSize ?? 0
                case .cancelled:
                    cancelFlag.cancel()
                case .skippedForeign, .failed:
                    completed += 1
                }
                onProgress(MediaOperationProgress(
                    completedCount: completed,
                    totalCount: totalCount,
                    completedBytes: completedBytes,
                    totalBytes: totalBytes
                ))
            case .skipPreexisting:
                if allowSourceDeletion {
                    await deleteSourceIfRequested(
                        entry: entry,
                        plan: plan,
                        sourceKind: sourceKind,
                        sourceDeviceIdentity: sourceDeviceIdentity,
                        batch: nil
                    )
                }
            case .blocked, .noOp, .relocate:
                continue
            }
        }
        return publishedCount
    }

    private enum EntryOutcome {
        case published
        case skippedForeign
        case cancelled
        case failed
    }

    private func sourceStillMatches(
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

    private func transferBytesToStaging(
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
            try? await store.deleteActiveFileOperation(key: operationKey)
            return .failed
        }
    }

    private func transferVolumeBytes(
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
            try? await store.deleteActiveFileOperation(key: operationKey)
            return .cancelled
        }
        if case let .failed(message) = copyOutcome {
            try? FileManager.default.removeItem(at: stagingURL)
            try? await store.deleteActiveFileOperation(key: operationKey)
            OtosLog.catalog.error(
                "op=mediaOperation.copy phase=failed detail=\(message, privacy: .public)"
            )
            return .failed
        }
        return nil
    }

    private func transferCameraBytes(
        entry: MediaOperationPlanEntry,
        identity: String?,
        enrichmentURL: URL,
        stagingURL: URL,
        operationKey: ActiveFileOperationKey,
        onByteProgress: @escaping @Sendable (Int64) -> Void
    ) async -> EntryOutcome? {
        guard let identity, let cameraImport else {
            try? await store.deleteActiveFileOperation(key: operationKey)
            return .failed
        }
        if cancelFlag.isCancelled {
            try? FileManager.default.removeItem(at: stagingURL)
            try? await store.deleteActiveFileOperation(key: operationKey)
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
            return nil
        case .cancelled:
            try? FileManager.default.removeItem(at: stagingURL)
            try? await store.deleteActiveFileOperation(key: operationKey)
            return .cancelled
        case let .failed(message):
            try? FileManager.default.removeItem(at: stagingURL)
            try? await store.deleteActiveFileOperation(key: operationKey)
            OtosLog.catalog.error(
                "op=mediaOperation.camera phase=failed detail=\(message, privacy: .public)"
            )
            return .failed
        }
    }

    private func copyEntry(
        _ entry: MediaOperationPlanEntry,
        plan: MediaOperationPlan,
        batch: ImportBatchID,
        sourceKind: LibraryRootKind,
        sourceDeviceIdentity: String?,
        deleteSourceRequested: Bool,
        onByteProgress: @escaping @Sendable (Int64) -> Void
    ) async -> EntryOutcome {
        guard case let .import(sourceRoot, destinationRoot, _) = plan.mode,
              case let .copy(destinationRelative) = entry.disposition
        else {
            return .failed
        }
        let sourceURL = entry.source.sourceURL
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

        let stagingURL = stagingURL(adjacentTo: finalURL)
        let destinationModified = destinationModifiedDate(for: entry)
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
            sourceModifiedAt: sourceModified ?? destinationModified,
            destinationModifiedAt: destinationModified,
            phase: .copying,
            deleteSourceRequested: deleteSourceRequested,
            updatedAt: Date()
        )
        do {
            try await store.insertActiveFileOperation(operation)
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
            deleteSourceRequested: deleteSourceRequested
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
    }

    private func publishAndSettle(_ request: PublishSettleRequest) async -> EntryOutcome {
        var operation = request.operation
        stampModificationDate(request.destinationModified, at: request.stagingURL)
        operation.phase = .readyToPublish
        operation.updatedAt = Date()
        try? await store.updateActiveFileOperation(operation)

        switch ExclusivePublication.publish(staging: request.stagingURL, final: request.finalURL) {
        case .destinationExists:
            try? FileManager.default.removeItem(at: request.stagingURL)
            try? await store.deleteActiveFileOperation(key: operation.operationKey)
            await store.recordForeignOccupant(
                root: request.destinationRoot,
                relativePath: request.destinationRelative
            )
            return .skippedForeign
        case let .failed(message):
            try? FileManager.default.removeItem(at: request.stagingURL)
            try? await store.deleteActiveFileOperation(key: operation.operationKey)
            OtosLog.catalog.error(
                "op=mediaOperation.publish phase=failed detail=\(message, privacy: .public)"
            )
            return .failed
        case .published:
            break
        }

        operation.phase = .publishedPendingSettlement
        operation.stagingPath = nil
        operation.updatedAt = Date()
        try? await store.updateActiveFileOperation(operation)

        let companionRows = companionDestinations(
            entry: request.entry,
            destinationRoot: request.destinationRoot
        )
        do {
            try await store.settleImportedFile(
                operation: operation,
                byteSize: request.sourceByteSize,
                contentModifiedAt: request.destinationModified,
                batch: request.batch,
                companions: companionRows
            )
        } catch {
            OtosLog.catalog.error(
                "op=mediaOperation.settle phase=failed error=\(String(describing: error), privacy: .public)"
            )
            return .failed
        }

        if request.deleteSourceRequested {
            operation.phase = .sourceDeletionPending
            operation.updatedAt = Date()
            try? await store.updateActiveFileOperation(operation)
            await deleteSource(
                kind: request.sourceKind,
                identity: request.sourceDeviceIdentity,
                relativePath: request.sourceRelativePath,
                filesystemURL: request.sourceURL
            )
            try? await store.deleteActiveFileOperation(key: operation.operationKey)
        }
        return .published
    }

    private func recover(_ operation: ActiveFileOperation) async {
        let staging = operation.stagingPath.map { URL(fileURLWithPath: $0) }
        let final = operation.destinationRootPath.url
            .appendingPathComponent(operation.destinationRelativePath.rawValue)
        let stagingExists = staging.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let finalExists = FileManager.default.fileExists(atPath: final.path)

        switch operation.phase {
        case .copying, .readyToPublish:
            if stagingExists {
                try? FileManager.default.removeItem(at: staging!)
            }
            if finalExists, operation.phase == .readyToPublish {
                // Do not auto-publish; settle if final somehow exists.
                await settleRecovered(operation)
            } else {
                try? await store.deleteActiveFileOperation(key: operation.operationKey)
            }
        case .publishedPendingSettlement:
            if finalExists {
                await settleRecovered(operation)
            } else if stagingExists {
                try? FileManager.default.removeItem(at: staging!)
                try? await store.deleteActiveFileOperation(key: operation.operationKey)
            } else {
                try? await store.deleteActiveFileOperation(key: operation.operationKey)
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
            try? await store.deleteActiveFileOperation(key: operation.operationKey)
        }
        OtosLog.catalog.notice(
            // swiftlint:disable:next line_length
            "op=mediaOperation.recover phase=\(operation.phase.rawValue, privacy: .public) key=\(operation.operationKey.rawValue, privacy: .public) stagingExists=\(stagingExists, privacy: .public) finalExists=\(finalExists, privacy: .public)"
        )
    }

    private func settleRecovered(_ operation: ActiveFileOperation) async {
        guard let batchMs = operation.importBatchUnixMs,
              let modified = operation.destinationModifiedAt
        else {
            try? await store.deleteActiveFileOperation(key: operation.operationKey)
            return
        }
        do {
            try await store.settleImportedFile(
                operation: operation,
                byteSize: operation.sourceByteSize,
                contentModifiedAt: modified,
                batch: ImportBatchID(unixMilliseconds: batchMs),
                companions: []
            )
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
        var operation = ActiveFileOperation(
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
        try? await store.insertActiveFileOperation(operation)
        await deleteSource(
            kind: sourceKind,
            identity: sourceDeviceIdentity,
            relativePath: entry.source.relativePath,
            filesystemURL: entry.source.sourceURL
        )
        try? await store.deleteActiveFileOperation(key: operation.operationKey)
        _ = operation
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

    private func companionDestinations(
        entry: MediaOperationPlanEntry,
        destinationRoot: LibraryRootPath
    ) -> [MediaCompanion] {
        entry.companionDestinations.compactMap { sourceRelative, destinationRelative in
            let companion = entry.source.companions.first { $0.relativePath == sourceRelative }
            guard let companion else {
                return nil
            }
            // Copy companion bytes beside the published primary when present.
            let sourceURL = entry.source.sourceURL
                .deletingLastPathComponent()
                .appendingPathComponent((sourceRelative.rawValue as NSString).lastPathComponent)
            let destURL = destinationRoot.url.appendingPathComponent(destinationRelative.rawValue)
            if FileManager.default.fileExists(atPath: sourceURL.path),
               !FileManager.default.fileExists(atPath: destURL.path)
            {
                try? FileManager.default.createDirectory(
                    at: destURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                _ = CopyfileTransfer.copy(
                    from: sourceURL,
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

    private func stagingURL(adjacentTo final: URL) -> URL {
        let parent = final.deletingLastPathComponent()
        let name = ".\(UUID().uuidString).otos-import-staging"
        return parent.appendingPathComponent(name)
    }

    private func destinationModifiedDate(for entry: MediaOperationPlanEntry) -> Date {
        if let wall = entry.source.captureWallCompact {
            // Compact local wall YYYYMMDDHHmmss → Date in current calendar.
            return CaptureWallClock.date(fromCompact: wall) ?? entry.source.contentModifiedAt ?? Date()
        }
        return entry.source.contentModifiedAt ?? Date()
    }

    private func stampModificationDate(_ date: Date, at url: URL) {
        try? FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: url.path
        )
    }

    private func fileMatches(url: URL, byteSize: Int64, modifiedAt: Date) -> Bool {
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
    case completed(publishedCount: Int, batch: ImportBatchID?, hasBlockedEntries: Bool)
    case cancelled(publishedCount: Int, batch: ImportBatchID?, hasBlockedEntries: Bool)
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
