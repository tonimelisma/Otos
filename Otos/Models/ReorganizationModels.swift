import Foundation

// Pure reorganization planning models (plan 0055 Stage G1).
// No I/O. Physical members (media + companions) share one reservation namespace.
// Components carry deterministic chain/cycle recipes; mutation is Stage G2.

nonisolated struct ReorganizationPlanningSnapshot: Equatable, Sendable {
    let libraryRoot: LibraryRootPath
    let volumeIdentifier: String
    let capabilities: VolumeNamespaceCapabilities
    let generation: UInt64
    let rootRevision: UInt64
    let policy: ImportPolicy
    let media: [PlanningFileFacts]
    /// Relative paths known to be stationary foreign occupants (from prior probes).
    let knownForeignOccupants: Set<MediaRelativePath>
}

nonisolated enum ReorganizationDisposition: Equatable, Sendable {
    case noOp
    case relocate(destination: MediaRelativePath)
    case blocked(ReorganizationBlockReason)
}

nonisolated enum ReorganizationBlockReason: Equatable, Sendable {
    case noUsableDate
    case crossVolume
    case ambiguousFilesystemName
    case ancestorConflict(MediaRelativePath)
    case stationaryConflict(MediaRelativePath)
}

nonisolated struct ReorganizationPhysicalMember: Equatable, Sendable, Identifiable {
    let id: String
    let source: MediaRelativePath
    let idealDestination: MediaRelativePath
    var finalDestination: MediaRelativePath
    let isCompanion: Bool
    let primarySource: MediaRelativePath?
    let mediaID: MediaAssetID?
}

nonisolated enum ReorganizationMoveStep: Equatable, Sendable {
    case move(from: MediaRelativePath, to: MediaRelativePath)
    case moveViaTemporary(from: MediaRelativePath, temporary: MediaRelativePath, to: MediaRelativePath)
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
    case needsProbes(occupancy: [NamespaceOccupancyRequest])
    case ready(ReorganizationPlan)
    case blocked(reason: String)
}
