import Foundation

/// Durable import/copy settlement journal phases (ARC-048).
nonisolated enum ActiveFileOperationPhase: String, Equatable, Sendable {
    case copying
    case readyToPublish
    case publishedPendingSettlement
    /// The entry ended without publishing and a staging file it created could not be
    /// removed. Nothing is in flight; startup recovery removes the file and the row.
    case abandoned
}

nonisolated enum ImportJournalTransition: Sendable {
    case begin
    case progress(ActiveFileOperationPhase)
    case abandon
}

nonisolated struct ActiveFileOperationKey: Hashable, Sendable {
    let rawValue: String

    static func make() -> ActiveFileOperationKey {
        ActiveFileOperationKey(rawValue: UUID().uuidString)
    }
}

/// One import entry's durable record (ARC-048). It names every file Otos creates in
/// the destination library for the entry — the primary's staging file and each
/// companion's — before the file exists, so a process that ends at any point leaves
/// nothing in the library that startup recovery cannot find.
nonisolated struct ActiveFileOperation: Equatable, Sendable {
    let operationKey: ActiveFileOperationKey
    let sourceKind: LibraryRootKind
    let sourceDeviceIdentity: String?
    let sourceRootPath: LibraryRootPath
    let sourceRelativePath: MediaRelativePath
    let destinationRootPath: LibraryRootPath
    let destinationRelativePath: MediaRelativePath
    /// The primary's staging file, until it is published.
    var stagingURL: URL?
    /// Every companion staging file created for this entry and not yet published or removed.
    var companionStagingURLs: [URL]
    var contentHash: XXH3Digest128?
    let importBatch: ImportBatchID
    let sourceByteSize: Int64
    let sourceModifiedAt: Date
    var destinationModifiedAt: Date?
    var phase: ActiveFileOperationPhase
    var updatedAt: Date

    /// Every staging file this entry may have left in the library.
    var stagingFiles: [URL] {
        (stagingURL.map { [$0] } ?? []) + companionStagingURLs
    }
}

nonisolated struct ActiveSourceEraseKey: Hashable, Sendable {
    let rawValue: String

    static func make() -> ActiveSourceEraseKey {
        ActiveSourceEraseKey(rawValue: UUID().uuidString)
    }
}

nonisolated struct ActiveSourceEraseOperation: Equatable, Sendable {
    let key: ActiveSourceEraseKey
    let sourceKind: LibraryRootKind
    let sourceDeviceIdentity: String?
    let sourceRootPath: LibraryRootPath
    let sourceRelativePath: MediaRelativePath
    let sourceByteSize: Int64?
    var updatedAt: Date
}
