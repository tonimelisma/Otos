import Foundation
import UniformTypeIdentifiers

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
    let contentTypeIdentifier: String?
    let fileExtension: String
    let companions: [MediaCompanion]

    init(
        id: MediaAssetID,
        sourceURL: URL,
        relativePath: MediaRelativePath,
        byteSize: Int64?,
        contentModifiedAt: Date?,
        captureWallCompact: Int64?,
        mediaKind: MediaKind?,
        fileExtension: String,
        companions: [MediaCompanion],
        contentTypeIdentifier: String? = nil
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.relativePath = relativePath
        self.byteSize = byteSize
        self.contentModifiedAt = contentModifiedAt
        self.captureWallCompact = captureWallCompact
        self.mediaKind = mediaKind
        self.contentTypeIdentifier = contentTypeIdentifier
        self.fileExtension = fileExtension
        self.companions = companions
    }

    /// Best planning date: embedded capture wall when present, else source mtime.
    var hasUsableDate: Bool {
        captureWallCompact != nil || contentModifiedAt != nil
    }
}

/// Chooses a destination extension only when Otos authors a new date/time leaf
/// name. The scanner's filesystem content type is authoritative; parser output
/// is deliberately absent from this boundary.
nonisolated enum CanonicalMediaExtension {
    static func forDateTimeName(
        contentTypeIdentifier: String?,
        sourceExtension: String
    ) -> String {
        guard let contentTypeIdentifier,
              let contentType = UTType(contentTypeIdentifier),
              !contentType.isDynamic,
              MediaKind.classify(contentType) != nil,
              let preferred = contentType.preferredFilenameExtension,
              !preferred.isEmpty
        else {
            return sourceExtension
        }
        return preferred.lowercased()
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
    case filesystemObservationUnavailable(destination: MediaRelativePath, detail: String)
}

nonisolated struct MediaOperationPlanEntry: Equatable, Sendable {
    let source: PlanningFileFacts
    let idealDestination: MediaRelativePath
    let finalDestination: MediaRelativePath
    let companionDestinations: [MediaRelativePath: MediaRelativePath]
    let disposition: MediaOperationDisposition

    var isSkipPreexisting: Bool {
        if case .skipPreexisting = disposition {
            return true
        }
        return false
    }

    var isBlocked: Bool {
        if case .blocked = disposition {
            return true
        }
        return false
    }
}

nonisolated func throughputMBps(bytes: Int64, elapsedMs: Int) -> String {
    let megabytes = Double(bytes) / 1_000_000
    return String(format: "%.2f", megabytes / (Double(max(elapsedMs, 1)) / 1000))
}

nonisolated func elapsedMilliseconds(
    from start: ContinuousClock.Instant,
    to end: ContinuousClock.Instant
) -> String {
    "\(DiagnosticsTiming.milliseconds(from: start, to: end))"
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
}

nonisolated struct ImportPlanningSnapshot: Equatable, Sendable {
    let generation: UInt64
    let sourceRoot: LibraryRootPath
    let destinationRoot: LibraryRootPath
    let sourceOccupancyRevision: UInt64
    let destinationOccupancyRevision: UInt64
    let sourceMedia: [PlanningFileFacts]
    let destinationOccupants: [MediaRelativePath: DestinationOccupantFacts]
    let policy: ImportPolicy
    let calendar: Calendar
    let timeZone: TimeZone
}

/// Complete live occupancy for the destination folders an import plan can touch.
///
/// Import planning needs to know which candidate names are free. Candidate folders
/// are derivable from source facts plus policy alone (a suffix changes the file
/// name, never the folder), so every question a plan can ask is answered by
/// enumerating that bounded folder set once. The planner then runs as one pure
/// pass instead of a probe-per-candidate fixed point.
///
/// Absence is a claim about a folder that was actually read: `occupancy(of:)`
/// returns `nil` for a path whose folder was never enumerated, so a caller can
/// never silently mistake ignorance for a free name.
nonisolated struct DestinationNamespace: Equatable, Sendable {
    private let entries: [MediaRelativePath: NamespaceOccupancyResult]
    private let enumeratedFolders: Set<String>

    init(
        entries: [MediaRelativePath: NamespaceOccupancyResult],
        enumeratedFolders: Set<String>
    ) {
        self.entries = entries
        self.enumeratedFolders = enumeratedFolders
    }

    static let empty = DestinationNamespace(entries: [:], enumeratedFolders: [])

    var entryCount: Int {
        entries.count
    }

    var folderCount: Int {
        enumeratedFolders.count
    }

    /// Live occupancy of one candidate, or `nil` when its folder was not enumerated.
    func occupancy(of relativePath: MediaRelativePath) -> NamespaceOccupancyResult? {
        if let entry = entries[relativePath] {
            return entry
        }
        guard enumeratedFolders.contains(Self.folder(of: relativePath)) else {
            return nil
        }
        return .absent
    }

    /// Folder component under the destination root; `""` addresses the root itself,
    /// matching `MediaTransferPlanner.folderPath` under `DestinationFolderPolicy.none`.
    static func folder(of relativePath: MediaRelativePath) -> String {
        let raw = relativePath.rawValue
        guard let separator = raw.lastIndex(of: "/") else {
            return ""
        }
        return String(raw[raw.startIndex ..< separator])
    }
}
