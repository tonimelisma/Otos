import Foundation

/// Durable import/copy settlement journal phases (ARC-048).
nonisolated enum ActiveFileOperationPhase: String, Equatable, Sendable {
    case copying
    case readyToPublish
    case publishedPendingSettlement
    case sourceDeletionPending
}

nonisolated enum ImportJournalTransition: Sendable {
    case begin
    case progress(ActiveFileOperationPhase)
    case abandon
    case complete
}

nonisolated struct ActiveFileOperationKey: Hashable, Sendable {
    let rawValue: String

    static func make() -> ActiveFileOperationKey {
        ActiveFileOperationKey(rawValue: UUID().uuidString)
    }
}

nonisolated struct ActiveFileOperation: Equatable, Sendable {
    let operationKey: ActiveFileOperationKey
    let mode: String
    let sourceKind: LibraryRootKind
    let sourceDeviceIdentity: String?
    let sourceRootPath: LibraryRootPath
    let sourceRelativePath: MediaRelativePath
    let destinationRootPath: LibraryRootPath
    let destinationRelativePath: MediaRelativePath
    var stagingPath: String?
    var contentHash: XXH3Digest128?
    let importBatchUnixMs: Int64?
    let sourceByteSize: Int64
    let sourceModifiedAt: Date
    var destinationModifiedAt: Date?
    var phase: ActiveFileOperationPhase
    let deleteSourceRequested: Bool
    var updatedAt: Date
}
