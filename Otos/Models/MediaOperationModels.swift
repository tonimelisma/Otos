import Foundation
import UniformTypeIdentifiers

// Media operation planning models (ARC-046).
//
// Immutable Sendable values only. The pure planner consumes these; the
// coordinator (ARC-047) owns lifecycle. No I/O, no actor hops, no logging.

nonisolated enum MediaOperationMode: Equatable, Sendable {
    case `import`(source: LibraryRootPath, destination: LibraryRootPath, batch: ImportBatchID)
    case reorganize(library: LibraryRootPath)
}

/// Which fact changed between what a plan expected and what the live source
/// reports (plan 0095 D8).
nonisolated enum ChangedFact: Equatable, Sendable {
    case size
    case date
}

/// Why a plan entry's live source does or does not still match what the plan
/// captured. One typed owner for every "does this still match" check
/// (`MediaImportExecutor.sourceStillMatches`, `DeviceCameraSession.revalidate`)
/// replaces the collapsed `Bool` each used to return, so a systemic cause
/// (the source itself wasn't ready) can be told apart from an ordinary
/// per-file one (plan 0095 D8).
nonisolated enum SourceValidation: Equatable, Sendable {
    case matches
    /// The device session or volume mount wasn't ready to answer at all —
    /// true for every entry from this source simultaneously, not a fact
    /// about any one file.
    case sourceNotReady
    case changed(ChangedFact)
    case absent
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

/// One blocked plan entry the user can act on via "Show them" (state D). Carries
/// identity, not just a count, so the ViewModel can select and scroll the affected
/// tiles (`import-bar.md` state D).
nonisolated struct MediaAttentionItem: Equatable, Sendable, Identifiable {
    let id: MediaAssetID
    let reason: MediaOperationBlockReason
}

/// Causes of an import failure a user can act on (DES-035/DES-039 forbid
/// publishing internal vocabulary to the bar). `.unexpected` is the one case
/// whose detail is for the log, never the bar (`import-bar.md` state G).
nonisolated enum MediaOperationFailureReason: Equatable, Sendable {
    case sourceRemoved
    case destinationUnavailable
    case outOfSpace
    /// Every attempted entry failed `SourceValidation` with the same
    /// non-per-file reason — the source itself wasn't ready, not any one
    /// file (plan 0095 D8). Per the owner decision, the increment 4 readiness
    /// gate should make this unreachable in practice; it exists so that if it
    /// ever happens, the bar says something true instead of "Done".
    case sourceNotReady
    case unexpected(detail: String)

    /// Classifies why an import-planning snapshot came back empty: whichever of
    /// the two roots is missing from the currently available set, or unexpected
    /// when both are present. `blocked` is never "can't be read"
    /// (`MediaOperationBlockReason`); this applies the same discipline to a
    /// failed plan build instead of guessing (trap #3).
    static func forMissingSnapshot(
        source: LibraryRootPath,
        destination: LibraryRootPath,
        availableRoots: Set<LibraryRootPath>
    ) -> MediaOperationFailureReason {
        if !availableRoots.contains(source) {
            return .sourceRemoved
        }
        if !availableRoots.contains(destination) {
            return .destinationUnavailable
        }
        return .unexpected(detail: "snapshotUnavailable")
    }
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

    /// Blocked entries' identities and reasons, for state D's "Show them"
    /// (`import-bar.md` state D). `totals.blockedCount` is a count only; this is
    /// what lets the ViewModel select and scroll the affected tiles.
    var attentionItems: [MediaAttentionItem] {
        entries.compactMap { entry in
            guard case let .blocked(reason) = entry.disposition else { return nil }
            return MediaAttentionItem(id: entry.source.id, reason: reason)
        }
    }
}

/// Import-planning wake published on the Store's planning-change stream. Carries
/// the root's current `occupancyRevision` so the import coordinator can cheaply
/// distinguish a real occupancy change from `planRevision`-only churn (no-op
/// rescans, event deferrals) and skip a needless replan.
nonisolated struct RootPlanningChange: Equatable, Sendable {
    let rootPath: LibraryRootPath
    let occupancyRevision: UInt64
}

/// Per-source import lifecycle published to the footer (ARC-047).
nonisolated enum MediaOperationSourceState: Equatable, Sendable {
    case inventory
    case waitingForMetadata(done: Int, total: Int)
    case planning
    case ready(
        summary: MediaOperationPlanTotals,
        generation: UInt64,
        skippedPackageCount: Int,
        attentionItems: [MediaAttentionItem] = []
    )
    case queuedForReadiness
    case executing(progress: MediaOperationProgress)
    case needsReplan
    case completed(
        summary: MediaOperationPlanTotals,
        skippedForeignCount: Int = 0,
        failedCount: Int = 0,
        incompleteItems: [MediaAssetID] = []
    )
    case failed(reason: MediaOperationFailureReason, publishedCount: Int = 0)
    /// Source kind cannot execute import (for example a fixed library selected as source).
    case executionUnavailable(
        summary: MediaOperationPlanTotals,
        generation: UInt64,
        attentionItems: [MediaAttentionItem] = []
    )
}

nonisolated struct MediaOperationProgress: Equatable, Sendable {
    let completedCount: Int
    let totalCount: Int
    let completedBytes: Int64
    let totalBytes: Int64
    /// Milliseconds since this execution started. The time base `import-bar.md`
    /// state E needs to compute "about N seconds left" from bytes-over-elapsed;
    /// the mapper omits the estimate until this and `completedBytes` are large
    /// enough for a rate to be meaningful, never guessing one.
    let elapsedMs: Int
}

nonisolated struct MediaOperationSourcePresentation: Equatable, Sendable, Identifiable {
    let sourcePath: LibraryRootPath
    /// Chooses "the camera" vs. "the card" wording while preparing
    /// (`import-bar.md` state A) without the mapper re-deriving it.
    let sourceKind: LibraryRootKind
    let destinationPath: LibraryRootPath?
    /// The destination library's display name, so the bar states it without a
    /// second lookup at the view layer (`import-bar.md` "What the presentation
    /// must carry").
    let destinationDisplayName: String?
    let state: MediaOperationSourceState
    let attachToReadyMs: Int?
    /// State rather than an event `presentationsStream()`'s dropping buffer
    /// could lose (`import-bar.md` "Where the user is standing"). Present
    /// once set, not from execution start: `.executing` withholds it until
    /// the batch has at least one durably-published asset, so
    /// `followNewBatchesOnce` never navigates to a batch row with nothing in
    /// it yet (plan 0095 step 7, owner decision — "move batch selection to
    /// first-asset"). A terminal `.failed`/`.cancelled`/`.completed` state's
    /// own fallback is unaffected by that gate — those keep the run's batch
    /// pinned and visible regardless of whether anything ever published, per
    /// `MediaOperationCoordinator`'s `currentBatchID(for:)`.
    let batchID: ImportBatchID?
    /// Whether this source is still attached and available, read fresh from the
    /// catalog rather than inferred from session existence — a fact about the
    /// world, not about where the user is standing (`import-bar.md` state F).
    /// `true` for every live source session (the coordinator removes a session
    /// outright the moment its source drops out of the catalog's available
    /// set, rather than keeping it around long enough to observe it
    /// unavailable). `false` only on the detached-batch snapshot
    /// `MediaOperationCoordinator` keeps under the batch's own identity after
    /// its source session is gone (`refreshSources`'s detach path) — that
    /// snapshot is what lets state F's "card gone" variant render from the
    /// batch row once the removable row itself has disappeared.
    let cardStillExists: Bool
    /// Count copied by the most recent *settled* (completed or cancelled)
    /// execution in this attachment, and whether that run was fully clean (no
    /// skips, failures, or blocked entries) — the auto-dismiss gate. Both
    /// persist across the post-settlement re-plan so state F keeps reporting
    /// what it just copied instead of that fact vanishing once `state` leaves
    /// `.completed`; `nil` until the first execution in this attachment
    /// settles (`import-bar.md` "What the presentation must carry").
    ///
    /// Deliberately independent of a *subsequently failed* retry: if a clean
    /// run lands 5 items and a later retry in the same attachment fails before
    /// copying anything, these still report the 5 that really did land —
    /// `state`'s own `.failed(reason:publishedCount:)` carries that failed
    /// attempt's own count separately (`import-bar.md` state G: "nothing
    /// already copied is lost").
    let copiedJustNow: Int?
    let isFullyClean: Bool?
    /// This attachment's live session preferences, read directly off the
    /// coordinator's own `SourceSession.preferences` rather than mirrored into a
    /// second ViewModel-owned dictionary. `setSessionPreferences` writes only to
    /// the coordinator; the next `publish()` carrying the new value here is the
    /// confirmation — eliminates the two-owner race where a per-frame refresh
    /// could revert an in-flight optimistic write (plan 0095 D7).
    let sessionPreferences: ImportPreferences
    /// Items from that same settled execution that started but did not land —
    /// failed mid-copy, or skipped because an identical file already exists in
    /// a *different* library — so state F's incomplete variant can select and
    /// scroll them the same way state D does for blocked items
    /// (`import-bar.md` state F, "couldn't be copied · Show them"). Blocked
    /// entries (never attempted; state D) are a separate population with their
    /// own reason and are not included here. Persists across the
    /// post-settlement re-plan alongside `copiedJustNow`/`isFullyClean`.
    let incompleteItems: [MediaAssetID]

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
