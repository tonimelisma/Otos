import Foundation

// Active reorganization journal models (ARC-051).
// Bounded recovery recipe only — deleted after catalog commit or proven rollback.

nonisolated struct ReorganizationComponentKey: Hashable, Sendable {
    let rawValue: String

    static func make() -> ReorganizationComponentKey {
        ReorganizationComponentKey(rawValue: UUID().uuidString)
    }
}

nonisolated enum ActiveReorganizationComponentPhase: String, Equatable, Sendable {
    case prepared
    case moving
    case filesystemComplete
    case catalogCommitted
    case rollingBack
    case blocked
}

nonisolated enum ActiveReorganizationStepPhase: String, Equatable, Sendable {
    case planned
    case willMove
    case didMove
    case rolledBack
}

nonisolated enum ActiveReorganizationDirectoryPhase: String, Equatable, Sendable {
    case planned
    case created
    case preexisting
}

nonisolated enum ActiveReorganizationMemberKind: String, Equatable, Sendable {
    case media
    case companion
}

nonisolated struct ActiveReorganizationMember: Equatable, Sendable {
    let memberIndex: Int
    let kind: ActiveReorganizationMemberKind
    let logicalSourceRelativePath: MediaRelativePath
    var currentRelativePath: MediaRelativePath
    let finalRelativePath: MediaRelativePath
    let byteSize: Int64
    let contentModifiedAt: Date
}

nonisolated struct ActiveReorganizationStep: Equatable, Sendable {
    let stepIndex: Int
    let memberIndex: Int
    let sourceRelativePath: MediaRelativePath
    let destinationRelativePath: MediaRelativePath
    var phase: ActiveReorganizationStepPhase
}

nonisolated struct ActiveReorganizationDirectory: Equatable, Sendable {
    let relativePath: MediaRelativePath
    var phase: ActiveReorganizationDirectoryPhase
}

nonisolated struct ActiveReorganizationComponent: Equatable, Sendable {
    let componentKey: ReorganizationComponentKey
    let libraryRootPath: LibraryRootPath
    let planGeneration: UInt64
    let plannedRootRevision: UInt64
    var phase: ActiveReorganizationComponentPhase
    var nextStepIndex: Int
    let createdAt: Date
    var updatedAt: Date
    var members: [ActiveReorganizationMember]
    var steps: [ActiveReorganizationStep]
    var directories: [ActiveReorganizationDirectory]
}

nonisolated struct CatalogIdentityRemap: Equatable, Sendable {
    let oldID: MediaAssetID
    let newID: MediaAssetID
}

nonisolated struct CatalogIdentityRemapBatch: Equatable, Sendable {
    let libraryRootPath: LibraryRootPath
    let remaps: [CatalogIdentityRemap]
    let rootRevision: UInt64
}

nonisolated enum RootNamespaceMutationOwner: String, Equatable, Sendable {
    case importPublication
    case sourceErase
    case reorganization
    case mediaTrash
}

nonisolated struct RootNamespaceMutationLease: Equatable, Sendable {
    let libraryRootPath: LibraryRootPath
    let generation: UInt64
    let owner: RootNamespaceMutationOwner
    var markedDirtyByExternalEvents: Bool
}

nonisolated enum ReorganizationRecoveryObservation: Equatable, Sendable {
    case moveDidNotHappen
    case moveHappened
    case ambiguousBothExist
    case ambiguousNeitherExists
}

nonisolated enum ReorganizationExecutionOutcome: Equatable, Sendable {
    case filesystemComplete(ReorganizationComponentKey)
    case blocked(reason: String)
    case cancelled
    case failed(reason: String)
}
