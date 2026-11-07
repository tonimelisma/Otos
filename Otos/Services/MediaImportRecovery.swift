import Foundation
import OSLog
import UniformTypeIdentifiers

/// Import recovery guide
///
/// Settles or cleans up what an earlier process left in the import journals, once,
/// when `MediaOperationCoordinator` starts and before it runs any import. Every row
/// it finds belongs to a process that has ended: an import of this process is never
/// "recovered", so recovery can never remove a staging file a running copy is
/// writing or abandon a row a running copy will settle.
///
/// For an import entry, the journal names every staging file the entry created, the
/// primary's and each companion's (ARC-048). Companion staging files are always
/// removed: recovery publishes a primary it can prove, never a companion, so such an
/// item stays incomplete and its companion stays on the card. The primary follows its
/// phase: an unfinished copy is removed, a ready one is published and settled unless
/// a foreign file took its name, a published one is settled once its bytes are proven
/// ours. A row is deleted only once its staging files are gone; one whose file will
/// not go is kept as `abandoned` for the next launch. For a card erase, each journaled
/// candidate is erased under its source root's namespace lease and its row cleared.
struct MediaImportRecovery {
    let store: CatalogStore
    var cameraImport: CameraImportAccess?
    var materializationRequester: MaterializationRequesting?

    func run() async {
        let signpost = OtosSignpost.catalog.beginInterval("ImportJournalRecovery")
        defer { OtosSignpost.catalog.endInterval("ImportJournalRecovery", signpost) }
        let operations: [ActiveFileOperation]
        let erases: [ActiveSourceEraseOperation]
        do {
            operations = try await store.activeImportOperations()
            erases = try await store.activeSourceEraseOperations()
        } catch {
            OtosLog.catalog.errorOperation("mediaOperation.recover", phase: "journalUnreadable", fields: [
                "error": String(describing: error),
            ])
            return
        }
        OtosLog.catalog.noticeOperation("mediaOperation.recover", phase: "start", fields: [
            "importRows": "\(operations.count)",
            "eraseRows": "\(erases.count)",
        ])
        for operation in operations {
            await recover(operation)
        }
        await recoverSourceErases(erases)
    }

    // MARK: - Import entries

    private enum Ownership {
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
            OtosLog.catalog.noticeOperation("mediaOperation.recover", phase: "deferred", fields: [
                "reason": "namespaceBusy",
                "heldBy": owner.rawValue,
                "rootPath": operation.destinationRootPath.rawValue,
            ])
            return
        case .rootNotRegistered, .catalogUnavailable:
            OtosLog.catalog.noticeOperation("mediaOperation.recover", phase: "deferred", fields: [
                "reason": acquisition.logReason,
                "rootPath": operation.destinationRootPath.rawValue,
            ])
            return
        }
        await recoverHoldingLease(operation)
        _ = await store.releaseNamespaceMutationLease(lease)
    }

    /// The caller holds the destination root's namespace lease.
    private func recoverHoldingLease(_ operation: ActiveFileOperation) async {
        OtosLog.catalog.noticeOperation("mediaOperation.recover", phase: operation.phase.rawValue, fields: [
            "key": operation.operationKey.rawValue,
            "stagingFiles": "\(operation.stagingFiles.count)",
        ])
        // Companions are never published by recovery.
        guard ImportStaging.remove(operation.companionStagingURLs, key: operation.operationKey, reason: "recovery") else {
            await keepAbandoned(operation)
            return
        }
        var operation = operation
        operation.companionStagingURLs = []
        let final = operation.destinationRootPath.url
            .appendingPathComponent(operation.destinationRelativePath.rawValue)
        let finalExists = FileManager.default.fileExists(atPath: final.path)
        let staging = operation.stagingURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }

        switch operation.phase {
        case .copying, .abandoned:
            await discard(operation, reason: "incompleteCopy")
        case .readyToPublish:
            if let staging {
                if finalExists {
                    // Both exist: the final occupant is not provably ours. Only the
                    // journaled staging file belongs to Otos.
                    await recordForeignAndDiscard(operation)
                    return
                }
                switch ExclusivePublication.publish(staging: staging, final: final) {
                case .published:
                    await persistPublished(operation, final: final)
                case .destinationExists:
                    await recordForeignAndDiscard(operation)
                case let .failed(failure):
                    OtosLog.catalog.errorOperation("mediaOperation.recover", phase: "publishFailed", fields: [
                        "key": operation.operationKey.rawValue,
                        "detail": failure.detail,
                    ])
                    await discard(operation, reason: "publishFailed")
                }
            } else if finalExists {
                await settleIfOwned(operation, final: final)
            } else {
                await discard(operation, reason: "incompletePublish")
            }
        case .publishedPendingSettlement:
            if finalExists {
                await settleIfOwned(operation, final: final)
            } else {
                await discard(operation, reason: "publishedFinalMissing")
            }
        }
    }

    /// Removes the entry's staging files and then its row. A file that will not go
    /// keeps the row, marked `abandoned`, for the next launch.
    private func discard(_ operation: ActiveFileOperation, reason: String) async {
        guard ImportStaging.remove(operation.stagingFiles, key: operation.operationKey, reason: reason) else {
            await keepAbandoned(operation)
            return
        }
        do {
            try await store.abandonImportOperation(key: operation.operationKey)
            OtosLog.catalog.noticeOperation("mediaOperation.recover", phase: "discarded", fields: [
                "key": operation.operationKey.rawValue,
                "reason": reason,
            ])
        } catch {
            OtosLog.catalog.errorOperation("mediaOperation.recover", phase: "discardFailed", fields: [
                "key": operation.operationKey.rawValue,
                "reason": reason,
                "error": String(describing: error),
            ])
        }
    }

    private func keepAbandoned(_ operation: ActiveFileOperation) async {
        var abandoned = operation
        abandoned.phase = .abandoned
        abandoned.updatedAt = Date()
        do {
            try await store.recordImportOperationProgress(abandoned)
        } catch {
            OtosLog.catalog.errorOperation("mediaOperation.recover", phase: "abandonRecordFailed", fields: [
                "key": operation.operationKey.rawValue,
                "error": String(describing: error),
            ])
        }
    }

    private func recordForeignAndDiscard(_ operation: ActiveFileOperation) async {
        await store.recordForeignOccupant(
            root: operation.destinationRootPath,
            relativePath: operation.destinationRelativePath
        )
        await discard(operation, reason: "foreignOccupant")
    }

    private func persistPublished(_ operation: ActiveFileOperation, final: URL) async {
        let values: URLResourceValues
        do {
            values = try final.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        } catch {
            OtosLog.catalog.errorOperation("mediaOperation.recover", phase: "finalFactsUnavailable", fields: [
                "key": operation.operationKey.rawValue,
                "error": String(describing: error),
            ])
            return
        }
        guard values.fileSize != nil, let modifiedAt = values.contentModificationDate else {
            OtosLog.catalog.errorOperation("mediaOperation.recover", phase: "finalFactsUnavailable", fields: [
                "key": operation.operationKey.rawValue,
            ])
            return
        }
        var pending = operation
        pending.phase = .publishedPendingSettlement
        pending.stagingURL = nil
        pending.destinationModifiedAt = modifiedAt
        pending.updatedAt = Date()
        do {
            try await store.recordImportOperationProgress(pending)
        } catch {
            OtosLog.catalog.errorOperation("mediaOperation.recover", phase: "publishedPendingSettlementFailed", fields: [
                "key": operation.operationKey.rawValue,
                "error": String(describing: error),
            ])
            return
        }
        await settleIfOwned(pending, final: final)
    }

    private func settleIfOwned(_ operation: ActiveFileOperation, final: URL) async {
        switch await ownership(of: final, for: operation) {
        case let .proven(byteSize, modifiedAt):
            do {
                try await store.settleImportedAsset(
                    operation: operation,
                    byteSize: byteSize,
                    contentModifiedAt: modifiedAt,
                    companions: []
                )
                // Crash recovery settles the same way, so it releases the same way:
                // otherwise an interrupted run leaves its staged source bytes forever.
                StagedSourceReleaser.releaseIfCached(
                    kind: operation.sourceKind,
                    sourceURL: operation.sourceRootPath.url
                        .appendingPathComponent(operation.sourceRelativePath.rawValue)
                )
            } catch {
                OtosLog.catalog.errorOperation("mediaOperation.recover", phase: "settleFailed", fields: [
                    "key": operation.operationKey.rawValue,
                    "error": String(describing: error),
                ])
            }
        case .foreign:
            await recordForeignAndDiscard(operation)
        case .deferredMaterialization:
            return
        }
    }

    private func ownership(of final: URL, for operation: ActiveFileOperation) async -> Ownership {
        guard let expectedModifiedAt = operation.destinationModifiedAt,
              let expectedHash = operation.contentHash
        else {
            OtosLog.catalog.noticeOperation("mediaOperation.recover", phase: "foreignOccupant", fields: [
                "key": operation.operationKey.rawValue,
                "reason": "missingOwnershipFacts",
            ])
            return .foreign
        }
        if FileMaterialization.status(of: final) != .materialized {
            OtosLog.catalog.noticeOperation("mediaOperation.recover", phase: "deferredMaterialization", fields: [
                "key": operation.operationKey.rawValue,
            ])
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
            guard result.isMaterialized, FileMaterialization.status(of: final) == .materialized else {
                return .deferredMaterialization
            }
        }
        guard case let .complete(actualHash) = ContentHasher().hashMaterializedFile(at: final) else {
            return .deferredMaterialization
        }
        let values: URLResourceValues
        do {
            values = try final.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        } catch {
            return .deferredMaterialization
        }
        guard let actualSize = values.fileSize,
              let actualModifiedAt = values.contentModificationDate,
              Int64(actualSize) == operation.sourceByteSize,
              Int(actualModifiedAt.timeIntervalSince1970) == Int(expectedModifiedAt.timeIntervalSince1970),
              actualHash == expectedHash
        else {
            OtosLog.catalog.noticeOperation("mediaOperation.recover", phase: "foreignOccupant", fields: [
                "key": operation.operationKey.rawValue,
            ])
            return .foreign
        }
        OtosLog.catalog.noticeOperation("mediaOperation.recover", phase: "publishedByOperation", fields: [
            "key": operation.operationKey.rawValue,
        ])
        return .proven(byteSize: Int64(actualSize), modifiedAt: actualModifiedAt)
    }

    // MARK: - Card erase

    /// One lease per source root for every row under it. A root another owner holds,
    /// or a card that is not mounted (`SourceEraser` refuses it), keeps its rows for the
    /// next launch.
    private func recoverSourceErases(_ operations: [ActiveSourceEraseOperation]) async {
        let byRoot = Dictionary(grouping: operations, by: \.sourceRootPath)
        for (root, rootOperations) in byRoot.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let acquisition = await store.acquireNamespaceMutationLease(for: root, owner: .sourceErase)
            guard case let .acquired(lease) = acquisition else {
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
        guard CatalogPath.relativePath(rootPath: operation.sourceRootPath, fileURL: url)
            == operation.sourceRelativePath
        else {
            // The sweep validates containment before journaling, so this cannot be
            // reached through it. A row that fails it is kept and reported rather than
            // retried in silence or deleted on a fact this code could not prove.
            OtosLog.mediaIO.faultOperation("import.erase.recover", phase: "uncontained", fields: [
                "rootPath": operation.sourceRootPath.rawValue,
                "relativePath": operation.sourceRelativePath.rawValue,
            ])
            return
        }
        guard await SourceEraser.erase(
            kind: operation.sourceKind,
            identity: operation.sourceDeviceIdentity,
            rootPath: operation.sourceRootPath,
            relativePath: operation.sourceRelativePath,
            filesystemURL: url,
            cameraImport: cameraImport
        ).isSettled else { return }
        await ImportStaging.recordErased(operation, store: store)
    }
}
