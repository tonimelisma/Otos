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

/// The identity changes one settled reorganization component committed, waiting for the
/// window to carry its selection, focus and painted tiles across them (ARC-052).
///
/// Written in the same transaction that remaps the catalog rows and read in the same
/// transaction as the window's ordered IDs, so a published state that shows a new
/// identity always carries the batch that created it. `id` is the durable row the
/// window acknowledges once applied; acknowledging deletes it.
nonisolated struct CatalogIdentityRemapBatch: Equatable, Sendable {
    let id: Int64
    let libraryRootPath: LibraryRootPath
    let remaps: [CatalogIdentityRemap]
}

nonisolated enum RootNamespaceMutationOwner: String, Equatable, Sendable {
    case importPublication
    case sourceErase
    case reorganization
    case mediaTrash
    case libraryRemoval
    /// A card, camera or phone taking over its root's row as it attaches: a few writes, which
    /// a removal waits out rather than deferring behind (`CatalogStore.attachRemovableRoot`).
    case sourceAttachment
}

/// The outcome of asking for a root's namespace lease.
///
/// Deliberately not `Optional`. A `nil` return would collapse two facts a caller
/// must tell apart — "another owner holds this root" and "there is no such root" —
/// and reporting the first as the second fails an entire import with "The card was
/// removed" while the card sits in the reader. Callers switch on this so that
/// mistake cannot be written.
nonisolated enum RootNamespaceLeaseAcquisition: Equatable, Sendable {
    case acquired(RootNamespaceMutationLease)
    /// A different namespace mutation owns this root right now. Transient: the
    /// root is present and the work is usually retryable.
    case busy(owner: RootNamespaceMutationOwner)
    /// No such root in the loaded catalog. Not transient for this operation.
    case rootNotRegistered
    /// The catalog could not load, so whether the root is registered is unknown.
    /// Never reported as `rootNotRegistered`: an empty pre-load registry is not
    /// evidence that a persisted root is absent.
    case catalogUnavailable

    /// The `reason=` value a denied caller logs, one spelling per outcome.
    var logReason: String {
        switch self {
        case .acquired: "acquired"
        case .busy: "namespaceBusy"
        case .rootNotRegistered: "rootNotRegistered"
        case .catalogUnavailable: "catalogUnavailable"
        }
    }
}

nonisolated struct RootNamespaceMutationLease: Equatable, Sendable {
    let libraryRootPath: LibraryRootPath
    let generation: UInt64
    let owner: RootNamespaceMutationOwner
    var markedDirtyByExternalEvents: Bool
}

/// A step of a root's namespace mutation at which the Store suspends, named for the test
/// that parks one mutation there while a competing one arrives (ADR 0032 rule 7).
nonisolated enum NamespaceMutationPoint: Equatable, Sendable {
    /// A removal has read the root's rows and is about to delete it.
    case removalWillDelete(LibraryRootPath)
    /// An attachment is about to write the source's facts onto the root row it takes over.
    case attachmentWillWrite(LibraryRootPath)
    /// An attachment found the root's namespace held by a removal or another attachment, and
    /// waits for it to be released.
    case attachmentWaits(LibraryRootPath)
}

nonisolated enum ReorganizationRecoveryObservation: Equatable, Sendable {
    case moveDidNotHappen
    case moveHappened
    case ambiguousBothExist
    case ambiguousNeitherExists
}

/// Why a reorganization component stopped short of finishing. Each case names the
/// path it stopped at; the user-facing wording lives in `ReorganizationOutcomePresentation`.
nonisolated enum ReorganizationFault: Equatable, Sendable {
    /// A durable journal or catalog transition could not be written.
    case journalWrite
    /// A folder a destination needs could not be created (a file holds its name, or
    /// the volume refused).
    case folderUnavailable(MediaRelativePath)
    /// A file that is not part of this reorganization already holds a destination name.
    case destinationTaken(MediaRelativePath)
    /// The volume refused to move a file.
    case moveRefused(MediaRelativePath)
    /// A file changed while it was being moved, so whether its move happened is unknown.
    case fileChanged(MediaRelativePath)
    /// The catalog no longer describes a file the plan moves.
    case libraryChanged

    var logCode: String {
        switch self {
        case .journalWrite: "journalWrite"
        case let .folderUnavailable(path): "folderUnavailable:\(path.rawValue)"
        case let .destinationTaken(path): "destinationTaken:\(path.rawValue)"
        case let .moveRefused(path): "moveRefused:\(path.rawValue)"
        case let .fileChanged(path): "fileChanged:\(path.rawValue)"
        case .libraryChanged: "libraryChanged"
        }
    }
}

/// Why a reorganization could not start. Nothing in the library changed.
nonisolated enum ReorganizationUnavailability: Equatable, Sendable {
    /// Another operation holds the library: an import, Move to Trash, or a reorganization.
    case libraryBusy(RootNamespaceMutationOwner)
    /// The library is no longer one of the user's libraries.
    case libraryUnavailable
    /// The catalog could not be read for this library.
    case catalogUnreadable
    /// The planner could not produce a consistent plan.
    case planInconsistent
}

/// A run that started and stopped partway.
nonisolated struct ReorganizationStop: Equatable, Sendable {
    struct Progress: Equatable, Sendable {
        /// Components that settled before the failing one; their files moved and the
        /// catalog follows them.
        let settledComponentCount: Int
        let componentCount: Int
        /// Items (media, not companions) in the settled components.
        let relocatedCount: Int
    }

    let fault: ReorganizationFault
    let progress: Progress
    /// Whether the failing component was fully rolled back. When false its journal is
    /// kept blocked, the library stays under the reorganization lease, and the next
    /// launch's recovery retries the rollback.
    let libraryRestored: Bool
}

nonisolated enum ReorganizationExecutionOutcome: Equatable, Sendable {
    /// Every step is done and the journal says so; the catalog is ready to settle.
    case filesystemComplete
    case stopped(ReorganizationFault)
}

nonisolated enum ReorganizationRollbackOutcome: Equatable, Sendable {
    /// Every completed step was moved back and the journal deleted: the library is as
    /// it was before the component.
    case restored
    /// A file could not be moved back. The journal is marked blocked and kept.
    case stuck(ReorganizationFault)
}
