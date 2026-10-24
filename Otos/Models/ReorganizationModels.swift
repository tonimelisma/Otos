import Foundation

// Pure reorganization planning models (ARC-050).
// No I/O. Physical members (media + companions) share one reservation namespace.
// Components carry deterministic chain/cycle recipes; mutation lives in the
// journal/executor (ARC-051).

nonisolated struct ReorganizationPlanningSnapshot: Equatable, Sendable {
    let libraryRoot: LibraryRootPath
    let capabilities: VolumeNamespaceCapabilities
    let generation: UInt64
    let rootRevision: UInt64
    let policy: ImportPolicy
    let calendar: Calendar
    let timeZone: TimeZone
    let media: [PlanningFileFacts]
}

nonisolated enum ReorganizationDisposition: Equatable, Sendable {
    case noOp
    case relocate(destination: MediaRelativePath)
    case blocked(ReorganizationBlockReason)
}

/// Why an item stays where it is. Each one is reported as "can't be processed".
nonisolated enum ReorganizationBlockReason: Equatable, Sendable {
    /// The naming policy needs a date and the item has none.
    case noUsableDate
    /// A file holds the name of the folder the item would go in, or of a folder above it.
    case folderOccupied(occupant: String)
    /// The destination folder exists but could not be listed, so no name in it is proven free.
    case folderUnreadable(folder: String)
    /// Every suffix the naming policy allows is taken.
    case noFreeName(destination: MediaRelativePath)
}

nonisolated struct ReorganizationPhysicalMember: Equatable, Sendable, Identifiable {
    let id: String
    let source: MediaRelativePath
    var finalDestination: MediaRelativePath
    let isCompanion: Bool
    let primarySource: MediaRelativePath?
    let mediaID: MediaAssetID?
}

/// One no-overwrite rename. A member that has to step aside (a cycle, or a case-only
/// relabel on a case-insensitive volume) takes two: to a temporary name in its own
/// folder, then to its destination.
nonisolated enum ReorganizationMoveStep: Equatable, Sendable {
    case move(from: MediaRelativePath, to: MediaRelativePath)
}

nonisolated struct ReorganizationComponent: Equatable, Sendable, Identifiable {
    let id: String
    let memberIDs: [String]
    let steps: [ReorganizationMoveStep]
}

nonisolated struct ReorganizationPlan: Equatable, Sendable {
    let generation: UInt64
    let libraryRoot: LibraryRootPath
    let rootRevision: UInt64
    let policy: ImportPolicy
    let members: [ReorganizationPhysicalMember]
    let components: [ReorganizationComponent]
    let mediaDispositions: [MediaAssetID: ReorganizationDisposition]

    var noOpCount: Int {
        mediaDispositions.values.filter { $0 == .noOp }.count
    }

    var relocateCount: Int {
        mediaDispositions.values.filter {
            if case .relocate = $0 {
                return true
            }
            return false
        }.count
    }

    var blockedCount: Int {
        mediaDispositions.values.filter {
            if case .blocked = $0 {
                return true
            }
            return false
        }.count
    }
}

nonisolated enum ReorganizationPlanBuildOutcome: Equatable, Sendable {
    case ready(ReorganizationPlan)
    /// The plan broke its own invariant (two members claiming one name); never presented.
    case inconsistent(reason: String)
}
