import Foundation

// Media operation planning models (plan 0055 Stage C).
//
// Immutable Sendable values only. The pure planner consumes these; the
// coordinator (Stage D) owns lifecycle. No I/O, no actor hops, no logging.

nonisolated enum MediaOperationMode: Equatable, Sendable {
    case `import`(source: LibraryRootPath, destination: LibraryRootPath, batch: ImportBatchID)
    case reorganize(library: LibraryRootPath)
}

nonisolated struct ImportPolicy: Equatable, Sendable {
    var destinationFolderPolicy: DestinationFolderPolicy
    var destinationNamePolicy: DestinationNamePolicy
    var importSidecarFiles: Bool
    var deleteSourceAfterImport: Bool
    var autoEjectAfterImport: Bool

    static func from(_ preferences: ImportPreferences) -> ImportPolicy {
        ImportPolicy(
            destinationFolderPolicy: preferences.destinationFolderPolicy,
            destinationNamePolicy: preferences.destinationNamePolicy,
            importSidecarFiles: preferences.importSidecarFiles,
            deleteSourceAfterImport: preferences.deleteSourceAfterImport,
            autoEjectAfterImport: preferences.autoEjectAfterImport
        )
    }
}

nonisolated struct PlanningFileFacts: Equatable, Sendable, Identifiable {
    let id: MediaAssetID
    let sourceURL: URL
    let relativePath: MediaRelativePath
    let byteSize: Int64?
    let contentModifiedAt: Date?
    let captureWallCompact: Int64?
    let mediaKind: MediaKind?
    let fileExtension: String
    let companions: [MediaCompanion]

    /// Best planning date: embedded capture wall when present, else source mtime.
    var hasUsableDate: Bool {
        captureWallCompact != nil || contentModifiedAt != nil
    }
}

nonisolated struct DestinationOccupantFacts: Equatable, Sendable {
    let relativePath: MediaRelativePath
    let byteSize: Int64?
    let contentModifiedAt: Date?
}

nonisolated enum MediaOperationDisposition: Equatable, Sendable {
    case copy(destination: MediaRelativePath)
    case skipPreexisting(destination: MediaRelativePath)
    case relocate(destination: MediaRelativePath)
    case noOp
    case blocked(MediaOperationBlockReason)
}

nonisolated enum MediaOperationBlockReason: Equatable, Sendable {
    case noUsableDate
    case comparisonUnavailable(destination: MediaRelativePath, detail: String)
    case comparisonRequiresMaterialization(destination: MediaRelativePath)
}

nonisolated struct MediaOperationPlanEntry: Equatable, Sendable {
    let source: PlanningFileFacts
    let idealDestination: MediaRelativePath
    let finalDestination: MediaRelativePath
    let companionDestinations: [MediaRelativePath: MediaRelativePath]
    let disposition: MediaOperationDisposition
}

nonisolated struct MediaOperationPlanTotals: Equatable, Sendable {
    var copyCount: Int
    var skipCount: Int
    var blockedCount: Int
    var companionCopyCount: Int
    var copyBytes: Int64
}

nonisolated struct MediaOperationPlan: Equatable, Sendable {
    let generation: UInt64
    let mode: MediaOperationMode
    let sourceOccupancyRevision: UInt64
    let destinationOccupancyRevision: UInt64
    let policy: ImportPolicy
    let entries: [MediaOperationPlanEntry]
    let totals: MediaOperationPlanTotals
}

/// Import-planning wake published on the Store's planning-change stream. Carries
/// the root's current `occupancyRevision` so the import coordinator can cheaply
/// distinguish a real occupancy change from `planRevision`-only churn (no-op
/// rescans, event deferrals) and skip a needless replan.
nonisolated struct RootPlanningChange: Equatable, Sendable {
    let rootPath: LibraryRootPath
    let occupancyRevision: UInt64
}

/// Per-source import lifecycle published to the footer/overlay (plan 0055 §6.3).
nonisolated enum MediaOperationSourceState: Equatable, Sendable {
    case inventory
    case waitingForDestination
    case waitingForMetadata(done: Int, total: Int)
    case planning
    case ready(summary: MediaOperationPlanTotals, generation: UInt64, skippedPackageCount: Int)
    case queuedForReadiness
    case executing(progress: MediaOperationProgress)
    case needsReplan
    case completed(summary: MediaOperationPlanTotals)
    case failed(problem: String)
    /// Source kind cannot execute import (for example a fixed library selected as source).
    case executionUnavailable(summary: MediaOperationPlanTotals, generation: UInt64)
}

nonisolated struct MediaOperationProgress: Equatable, Sendable {
    let completedCount: Int
    let totalCount: Int
    let completedBytes: Int64
    let totalBytes: Int64
}

nonisolated struct MediaOperationSourcePresentation: Equatable, Sendable, Identifiable {
    let sourcePath: LibraryRootPath
    let destinationPath: LibraryRootPath?
    let state: MediaOperationSourceState
    let attachToReadyMs: Int?

    var id: String {
        sourcePath.rawValue
    }
}

nonisolated struct NamespaceOccupancyRequest: Hashable, Sendable {
    let rootPath: LibraryRootPath
    let relativePath: MediaRelativePath
}

nonisolated enum NamespaceOccupancyResult: Equatable, Sendable {
    case absent
    case regularFile(byteSize: Int64?, contentModifiedAt: Date?)
    case foreign(kind: ForeignOccupantKind)
}

nonisolated enum ForeignOccupantKind: String, Equatable, Sendable {
    case symlink
    case directory
    case package
    case other
    case knownForeignFact
}

nonisolated struct ComparisonRequest: Hashable, Sendable {
    let sourceRoot: LibraryRootPath
    let sourceRelativePath: MediaRelativePath
    let sourceByteSize: Int64?
    let sourceModifiedAt: Date?
    let destinationRoot: LibraryRootPath
    let destinationRelativePath: MediaRelativePath
    let destinationByteSize: Int64?
    let destinationModifiedAt: Date?
    let sourceURL: URL
    let destinationURL: URL
}

nonisolated enum ComparisonResult: Equatable, Sendable {
    case equal
    case unequal
    case unavailable(detail: String)
    case requiresMaterialization
}

nonisolated struct ComparisonMemoKey: Hashable, Sendable {
    let sourceRoot: LibraryRootPath
    let sourceRelativePath: MediaRelativePath
    let sourceByteSize: Int64?
    let sourceModifiedSeconds: Int?
    let destinationRoot: LibraryRootPath
    let destinationRelativePath: MediaRelativePath
    let destinationByteSize: Int64?
    let destinationModifiedSeconds: Int?

    init(_ request: ComparisonRequest) {
        sourceRoot = request.sourceRoot
        sourceRelativePath = request.sourceRelativePath
        sourceByteSize = request.sourceByteSize
        sourceModifiedSeconds = request.sourceModifiedAt.map { Int($0.timeIntervalSince1970) }
        destinationRoot = request.destinationRoot
        destinationRelativePath = request.destinationRelativePath
        destinationByteSize = request.destinationByteSize
        destinationModifiedSeconds = request.destinationModifiedAt.map { Int($0.timeIntervalSince1970) }
    }
}

nonisolated struct ImportPlanningSnapshot: Equatable, Sendable {
    let generation: UInt64
    let sourceRoot: LibraryRootPath
    let destinationRoot: LibraryRootPath
    let sourceOccupancyRevision: UInt64
    let destinationOccupancyRevision: UInt64
    let sourceMedia: [PlanningFileFacts]
    let destinationOccupants: [MediaRelativePath: DestinationOccupantFacts]
    let knownForeignOccupants: Set<MediaRelativePath>
    let policy: ImportPolicy
    let calendar: Calendar
    let timeZone: TimeZone
}

nonisolated enum ImportPlanBuildOutcome: Equatable, Sendable {
    case ready(MediaOperationPlan)
    case needsProbes(
        occupancy: [NamespaceOccupancyRequest],
        comparisons: [ComparisonRequest]
    )
}
