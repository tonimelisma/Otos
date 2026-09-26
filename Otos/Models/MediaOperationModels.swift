import Foundation
import UniformTypeIdentifiers

// Media operation planning models (ARC-046).
//
// Immutable Sendable values only. The pure planner consumes these; the
// coordinator (ARC-047) owns lifecycle. No I/O, no actor hops, no logging.

nonisolated enum MediaOperationMode: Equatable, Sendable {
    case `import`(source: LibraryRootPath, destination: LibraryRootPath, batch: ImportBatchID)
    case reorganize(library: LibraryRootPath)

    /// The library an import plan copies into; `nil` for a reorganization.
    var importDestination: LibraryRootPath? {
        if case let .import(_, destination, _) = self {
            return destination
        }
        return nil
    }
}

/// Which fact changed between what a plan expected and what the live source
/// reports.
nonisolated enum ChangedFact: Equatable, Sendable {
    case size
    case date
}

/// Why a plan entry's live source does or does not still match what the plan
/// captured. One typed answer for every "does this still match" check
/// (`MediaImportExecutor.sourceStillMatches`, `DeviceCameraSession.revalidate`),
/// so a systemic cause (the source itself wasn't ready) can be told apart from
/// an ordinary per-file one — a `Bool` would collapse the two.
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

/// How much the catalog knows about the fact an import plan names a file by.
/// Distinct from enrichment staleness, which asks whether enrichment should run
/// again — a file can be permanently "stale" (no mtime to compare against) while
/// its naming fact is fully known. `MediaOperationGateway` derives this.
nonisolated enum NamingFactState: Equatable, Sendable {
    /// No date of any kind yet. Planning waits (`import-bar.md` state A).
    case pending
    /// Enrichment is current for these exact file facts; nothing is outstanding.
    case settled
    /// Not enrichment-complete, but the naming fact cannot improve: either the
    /// capture wall is already known, or a durable filesystem mtime is the only
    /// fallback there will ever be. Planning proceeds.
    case terminal
}

nonisolated struct PlanningFileFacts: Equatable, Sendable, Identifiable {
    let id: MediaAssetID
    let sourceURL: URL
    let relativePath: MediaRelativePath
    let byteSize: Int64?
    let contentModifiedAt: Date?
    let captureWallCompact: Int64?
    /// How `captureWallCompact` was established. A wall Otos *derived* (a video's
    /// mtime less its duration) names the file but must not stamp the destination
    /// mtime — see `ImportDestinationDate`.
    let captureWallPrecision: String?
    let namingFactState: NamingFactState
    /// The source bytes could not be opened when enrichment tried. Such a file cannot
    /// be enriched *or* copied, so it must neither hold the naming gate open nor be
    /// silently skipped — the planner blocks it and the bar shows it (ARC-057).
    let isSourceUnreadable: Bool
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
        captureWallPrecision: String? = nil,
        namingFactState: NamingFactState = .settled,
        isSourceUnreadable: Bool = false,
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
        self.captureWallPrecision = captureWallPrecision
        self.namingFactState = namingFactState
        self.isSourceUnreadable = isSourceUnreadable
        self.mediaKind = mediaKind
        self.contentTypeIdentifier = contentTypeIdentifier
        self.fileExtension = fileExtension
        self.companions = companions
    }

    /// Best planning date: embedded capture wall when present, else source mtime.
    var hasAnyDate: Bool {
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
    case excluded(ExclusionReason)
    case blocked(MediaOperationBlockReason)
}

nonisolated enum ExclusionReason: Equatable, Sendable {
    case empty
    case cruft(SourceFileClass)
}

nonisolated enum MediaOperationBlockReason: Equatable, Sendable {
    case noUsableDate
    /// The destination folder this candidate would land in could not be read
    /// when the plan was built, so its freeness is unproven. The planner's
    /// safety net (ADR 0019) — the coordinator never presents a plan built on
    /// an unread folder; it retries the build and holds the last proven plan.
    case filesystemObservationUnavailable(destination: MediaRelativePath)
    /// Every suffix the naming policy allows is taken in the destination folder.
    case noFreeDestinationName(destination: MediaRelativePath)
    /// The source file's bytes could not be opened, so enrichment could not read it
    /// and a copy could not read it either. On a card this is a failing card or a
    /// file that vanished — never a transient condition worth waiting out, since a
    /// removable volume's bytes are local (ARC-057).
    case sourceUnreadable
}

/// One blocked plan entry the user can act on via "Show them" (state D). Carries
/// identity, not just a count, so the ViewModel can select and scroll the affected
/// tiles (`import-bar.md` state D).
nonisolated struct MediaAttentionItem: Equatable, Sendable, Identifiable {
    let id: MediaAssetID
    let reason: MediaOperationBlockReason
}

/// Why a run ended before attempting every entry it planned (`import-bar.md`
/// state F, Stopped). A stop is a stop — nothing went wrong that `Try Again`
/// could fix — and the reason is data the bar names at L3. Distinct from
/// `MediaOperationFailureReason` on purpose: a stopped run is a partial
/// success with a real batch, a remainder, and no auto-eject or erase.
nonisolated enum ImportStopReason: Equatable, Sendable {
    /// The user pressed Cancel.
    case user
    /// The next entry would have left the destination volume below
    /// `FreeSpaceFloor.bytes`, or a write refused for space first
    /// (ADR 0027). `bytesFree` is the capacity read at the stop, for the
    /// bar's clause.
    case diskFloor(bytesFree: Int64)
}

/// The free space Otos never takes a volume below (ADR 0027): the import
/// executor admits an entry only while the destination keeps this much after
/// it and every entry in flight lands, and device staging does not start a
/// download below it. One constant with one home — the promise is the same
/// wherever Otos writes.
nonisolated enum FreeSpaceFloor {
    static let bytes: Int64 = 5 * 1024 * 1024 * 1024
}

/// Causes of an import failure a user can act on (DES-035/DES-039 forbid
/// publishing internal vocabulary to the bar). `.unexpected` is the one case
/// whose detail is for the log, never the bar (`import-bar.md` state G).
nonisolated enum MediaOperationFailureReason: Equatable, Sendable {
    case sourceRemoved
    case destinationUnavailable
    /// Every attempted entry failed `SourceValidation` with the same
    /// non-per-file reason — the source itself wasn't ready, not any one
    /// file. Per the owner decision, `ImportSourceReadiness` (ADR 0024)
    /// should make this unreachable in practice; it exists so that if it
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
}

nonisolated struct EraseManifestEntry: Equatable, Sendable, Identifiable {
    let relativePath: MediaRelativePath
    let byteSize: Int64?
    let fileClass: SourceFileClass

    var id: String {
        relativePath.rawValue
    }
}

/// The immutable, planner-owned set of source paths that may be erased after
/// execution. Execution never walks the source volume looking for extra files.
nonisolated struct EraseManifest: Equatable, Sendable {
    let entries: [EraseManifestEntry]

    var count: Int {
        entries.count
    }

    static func from(
        planEntries: [MediaOperationPlanEntry],
        sourceMedia: [PlanningFileFacts] = []
    ) -> Self {
        var byPath: [MediaRelativePath: EraseManifestEntry] = [:]
        for entry in planEntries {
            let eligible = switch entry.disposition {
            case .copy, .skipPreexisting, .excluded: true
            case .relocate, .noOp, .blocked: false
            }
            guard eligible else { continue }
            byPath[entry.source.relativePath] = EraseManifestEntry(
                relativePath: entry.source.relativePath,
                byteSize: entry.source.byteSize,
                fileClass: .classify(relativePath: entry.source.relativePath)
            )
            for companion in entry.source.companions {
                byPath[companion.relativePath] = EraseManifestEntry(
                    relativePath: companion.relativePath,
                    byteSize: companion.byteSize,
                    fileClass: .classify(relativePath: companion.relativePath)
                )
            }
        }
        for fact in sourceMedia {
            let fileClass = SourceFileClass.classify(relativePath: fact.relativePath)
            let eligible = switch fileClass {
            case .usefulSidecar, .cruftSidecar, .sourceArtifact: true
            case .media, .unknown: false
            }
            guard eligible, byPath[fact.relativePath] == nil
            else { continue }
            byPath[fact.relativePath] = EraseManifestEntry(
                relativePath: fact.relativePath,
                byteSize: fact.byteSize,
                fileClass: fileClass
            )
        }
        return EraseManifest(entries: byPath.values.sorted { $0.relativePath.rawValue < $1.relativePath.rawValue })
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
    var excludedCount: Int

    init(
        copyCount: Int,
        skipCount: Int,
        blockedCount: Int,
        companionCopyCount: Int,
        copyBytes: Int64,
        excludedCount: Int = 0
    ) {
        self.copyCount = copyCount
        self.skipCount = skipCount
        self.blockedCount = blockedCount
        self.companionCopyCount = companionCopyCount
        self.copyBytes = copyBytes
        self.excludedCount = excludedCount
    }
}

nonisolated struct MediaOperationPlan: Equatable, Sendable {
    let generation: UInt64
    let mode: MediaOperationMode
    let sourceNamespaceRevision: UInt64
    let sourceNamingRevision: UInt64
    let destinationNamespaceRevision: UInt64
    let policy: ImportPolicy
    let entries: [MediaOperationPlanEntry]
    let eraseManifest: EraseManifest
    let totals: MediaOperationPlanTotals

    init(
        generation: UInt64,
        mode: MediaOperationMode,
        sourceNamespaceRevision: UInt64,
        sourceNamingRevision: UInt64,
        destinationNamespaceRevision: UInt64,
        policy: ImportPolicy,
        entries: [MediaOperationPlanEntry],
        eraseManifest: EraseManifest? = nil,
        totals: MediaOperationPlanTotals
    ) {
        self.generation = generation
        self.mode = mode
        self.sourceNamespaceRevision = sourceNamespaceRevision
        self.sourceNamingRevision = sourceNamingRevision
        self.destinationNamespaceRevision = destinationNamespaceRevision
        self.policy = policy
        self.entries = entries
        self.eraseManifest = eraseManifest ?? EraseManifest.from(planEntries: entries)
        self.totals = totals
    }

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

/// The pair of revisions an import plan's staleness is judged against, sampled
/// together so the two halves cannot be read across a suspension.
nonisolated struct RootPlanningRevisions: Equatable, Sendable {
    let namespaceRevision: UInt64
    let namingRevision: UInt64
}

/// Import-planning wake published on the Store's planning-change stream. Carries
/// both of the root's planning revisions so the import coordinator can decide, per
/// role, whether this wake invalidates anything:
///
/// - `namespaceRevision` — which paths the root occupies. Invalidates a plan that
///   reads this root as **source or destination**.
/// - `namingRevision` — what Otos would call this root's assets. Invalidates a plan
///   that reads this root as **source only**; enriching an asset already in the
///   destination renames nothing on disk (ARC-046).
///
/// A wake with both unchanged is `planRevision`-only churn (no-op rescans, event
/// deferrals) and is a cheap no-op.
nonisolated struct RootPlanningChange: Equatable, Sendable {
    let rootPath: LibraryRootPath
    let namespaceRevision: UInt64
    let namingRevision: UInt64

    var revisions: RootPlanningRevisions {
        RootPlanningRevisions(namespaceRevision: namespaceRevision, namingRevision: namingRevision)
    }
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
    case executing(progress: MediaOperationProgress)
    case completed(
        summary: MediaOperationPlanTotals,
        skippedForeignCount: Int = 0,
        failedCount: Int = 0,
        incompleteItems: [MediaAssetID] = []
    )
    /// A run the user started ended in failure (`import-bar.md` state G,
    /// "Couldn't finish the import").
    case failed(reason: MediaOperationFailureReason, publishedCount: Int = 0)
    /// No plan could be made, so nothing was attempted — the destination folder
    /// stayed unreadable past the retry budget, a root vanished between the wake
    /// and the snapshot, or the builder threw. Distinct from `failed` because the
    /// bar names the stage honestly: "Couldn't prepare the import", never
    /// "finish" for a run that never started (state G, planning variant).
    case planningFailed(reason: MediaOperationFailureReason)
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

    /// Whether this sample would move either counter backwards relative to `other`.
    ///
    /// Both counters are monotonic where they are produced (`ByteProgressTracker`), so a
    /// decrease in either never means progress reversed — it identifies a sample that lost
    /// its ordering in transit between the worker thread that computed it and the actor
    /// that applies it. Stating the rule on the type keeps it with the values it constrains,
    /// rather than leaving each consumer to rediscover that these samples can arrive
    /// shuffled.
    nonisolated func isStale(comparedTo other: MediaOperationProgress) -> Bool {
        completedBytes < other.completedBytes || completedCount < other.completedCount
    }
}

/// Process-local identity of one removable-source attachment. It is owned by
/// `CatalogStore` and carried through operation publication; it is not durable
/// media identity and never becomes a card fingerprint or sidecar value.
nonisolated struct MediaOperationAttachmentGeneration: Equatable, Hashable, Sendable {
    let rawValue: UInt64
}

nonisolated struct MediaOperationSourcePresentation: Equatable, Sendable, Identifiable {
    let sourcePath: LibraryRootPath
    let attachmentGeneration: MediaOperationAttachmentGeneration
    /// Chooses "the camera" vs. "the card" wording while preparing
    /// (`import-bar.md` state A) without the mapper re-deriving it.
    let sourceKind: LibraryRootKind
    let destinationPath: LibraryRootPath?
    /// The destination library's display name, so the bar states it without a
    /// second lookup at the view layer (`import-bar.md` "What the presentation
    /// must carry").
    let destinationDisplayName: String?
    let state: MediaOperationSourceState
    /// Import was pressed and the coordinator is holding the click until the
    /// plan is ready (`queueImport` on a session that is not `.ready`, or a
    /// Ready plan that went stale before execution began). Not a state: the
    /// bar keeps drawing whatever `state` says — count, track and choices
    /// included — and disables Import, which is the click's acknowledgement
    /// (`import-bar.md` row 7). Cleared when execution starts or the request
    /// is refused.
    let importRequested: Bool
    let attachToReadyMs: Int?
    /// State rather than an event `presentationsStream()`'s dropping buffer
    /// could lose (`import-bar.md` "Where the user is standing"). Present
    /// once set, not from execution start: `.executing` withholds it until
    /// the batch has at least one durably-published asset. A terminal
    /// `.failed`/`.completed` state's own fallback is unaffected by that gate
    /// — those keep the run's batch pinned and visible regardless of whether
    /// anything ever published, per `MediaOperationCoordinator`'s
    /// `exposedBatch(for:)`. This is the batch's *identity*; whether the user
    /// should be taken to its row is `batchHasPublishedAssets`.
    let batchID: ImportBatchID?
    /// Whether the batch `batchID` names holds at least one durably-published
    /// asset — the fact `followNewBatchesOnce` needs before moving the user to
    /// its row. Carrying an identity and choosing to navigate to it are two
    /// different questions: a run refused before any copy still pins its batch
    /// (identity, for state G and detach), but its row has nothing to show, and
    /// a selection moved there leaves the sidebar and the grid disagreeing.
    /// `false` whenever `batchID` is `nil`.
    let batchHasPublishedAssets: Bool
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
    /// Whether that same settled run was fully clean. On the batch row this
    /// is also the dismissal gate: a fully clean settle has nothing left to
    /// report where the user is already looking at the items, so the bar
    /// leaves that row the moment it settles (`import-bar.md` state F,
    /// "Dismissal"). The card's own row never dismisses.
    let isFullyClean: Bool?
    /// Why that same settled execution stopped before attempting everything it
    /// planned, or `nil` for a run that attempted every entry (whether or not
    /// every entry landed). Set, the bar draws state F's Stopped variant from
    /// this and `copiedJustNow` of `plannedCount` — the run's own facts, not the
    /// re-plan's, which describes the remainder and moves if the card gains
    /// files. Persists across the post-settlement re-plan like the rest of the
    /// completion (`import-bar.md` state F, Stopped).
    let stopReason: ImportStopReason?
    /// How many entries that same settled execution set out to copy — the "of
    /// 42" in `Stopped — 12 of 42 items copied`. `nil` exactly when
    /// `copiedJustNow` is.
    let plannedCount: Int?
    /// The destination volume's available capacity, sampled by the coordinator
    /// when this Ready presentation was published, so the bar can say *before*
    /// the click that not everything will fit (`import-bar.md` state C). A
    /// measured value with the same reader the floor uses, not a forecast:
    /// stale by construction, it gates nothing, and the Stopped bar states what
    /// actually happened afterwards (ADR 0027). `nil` when the volume did not
    /// answer or the state has no plan to compare against.
    let destinationAvailableBytes: Int64?
    /// This attachment's live session preferences, read directly off the
    /// coordinator's own `SourceSession.preferences` rather than mirrored into a
    /// second ViewModel-owned dictionary. `setSessionPreferences` writes only to
    /// the coordinator; the next `publish()` carrying the new value here is the
    /// confirmation — eliminates the two-owner race where a per-frame refresh
    /// could revert an in-flight optimistic write.
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
    let eraseOutcome: EraseOutcome?

    init(
        sourcePath: LibraryRootPath,
        attachmentGeneration: MediaOperationAttachmentGeneration = .init(rawValue: 0),
        sourceKind: LibraryRootKind,
        destinationPath: LibraryRootPath?,
        destinationDisplayName: String?,
        state: MediaOperationSourceState,
        importRequested: Bool = false,
        attachToReadyMs: Int?,
        batchID: ImportBatchID?,
        batchHasPublishedAssets: Bool,
        cardStillExists: Bool,
        copiedJustNow: Int?,
        isFullyClean: Bool?,
        stopReason: ImportStopReason?,
        plannedCount: Int?,
        destinationAvailableBytes: Int64? = nil,
        sessionPreferences: ImportPreferences,
        incompleteItems: [MediaAssetID],
        eraseOutcome: EraseOutcome? = nil
    ) {
        self.sourcePath = sourcePath
        self.attachmentGeneration = attachmentGeneration
        self.sourceKind = sourceKind
        self.destinationPath = destinationPath
        self.destinationDisplayName = destinationDisplayName
        self.state = state
        self.importRequested = importRequested
        self.attachToReadyMs = attachToReadyMs
        self.batchID = batchID
        self.batchHasPublishedAssets = batchHasPublishedAssets
        self.cardStillExists = cardStillExists
        self.copiedJustNow = copiedJustNow
        self.isFullyClean = isFullyClean
        self.stopReason = stopReason
        self.plannedCount = plannedCount
        self.destinationAvailableBytes = destinationAvailableBytes
        self.sessionPreferences = sessionPreferences
        self.incompleteItems = incompleteItems
        self.eraseOutcome = eraseOutcome
    }

    var id: String {
        let attachment = attachmentGeneration.rawValue
        let state = cardStillExists ? "live" : "detached"
        let batch = batchID.map { String(describing: $0) } ?? "none"
        return "\(sourcePath.rawValue)#\(attachment)#\(state)#\(batch)"
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
    let sourceNamespaceRevision: UInt64
    let sourceNamingRevision: UInt64
    let destinationNamespaceRevision: UInt64
    let sourceMedia: [PlanningFileFacts]
    let destinationOccupants: [MediaRelativePath: DestinationOccupantFacts]
    let destinationOccupantKeys: Set<FilesystemNameKey>
    let policy: ImportPolicy
    let calendar: Calendar
    let timeZone: TimeZone
    let destinationCapabilities: VolumeNamespaceCapabilities

    init(
        generation: UInt64,
        sourceRoot: LibraryRootPath,
        destinationRoot: LibraryRootPath,
        sourceNamespaceRevision: UInt64,
        sourceNamingRevision: UInt64,
        destinationNamespaceRevision: UInt64,
        sourceMedia: [PlanningFileFacts],
        destinationOccupants: [MediaRelativePath: DestinationOccupantFacts],
        policy: ImportPolicy,
        calendar: Calendar,
        timeZone: TimeZone,
        destinationCapabilities: VolumeNamespaceCapabilities = .unknown
    ) {
        self.generation = generation
        self.sourceRoot = sourceRoot
        self.destinationRoot = destinationRoot
        self.sourceNamespaceRevision = sourceNamespaceRevision
        self.sourceNamingRevision = sourceNamingRevision
        self.destinationNamespaceRevision = destinationNamespaceRevision
        self.sourceMedia = sourceMedia
        self.destinationOccupants = destinationOccupants
        destinationOccupantKeys = Set(destinationOccupants.keys.map {
            FilesystemNamespaceSemantics.nameKey(relativePath: $0, capabilities: destinationCapabilities)
        })
        self.policy = policy
        self.calendar = calendar
        self.timeZone = timeZone
        self.destinationCapabilities = destinationCapabilities
    }
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
    private struct Entry: Equatable, Sendable {
        let path: MediaRelativePath
        let result: NamespaceOccupancyResult
    }

    private let entries: [FilesystemNameKey: Entry]
    private let enumeratedFolders: Set<String>
    /// Folders that exist but could not be listed, with the error each gave.
    /// Absence is a claim about a folder that was actually read (ADR 0019);
    /// these were not, so every candidate in them answers `nil` — and the
    /// coordinator treats a build carrying any of these as a transient
    /// condition to retry, not a plan to present.
    let unreadableFolders: [String: String]
    let capabilities: VolumeNamespaceCapabilities

    init(
        entries: [MediaRelativePath: NamespaceOccupancyResult],
        enumeratedFolders: Set<String>,
        unreadableFolders: [String: String] = [:],
        capabilities: VolumeNamespaceCapabilities = .unknown
    ) {
        var keyed: [FilesystemNameKey: Entry] = [:]
        for (path, result) in entries {
            let key = FilesystemNamespaceSemantics.nameKey(relativePath: path, capabilities: capabilities)
            if keyed[key] != nil {
                keyed[key] = Entry(path: path, result: .foreign(kind: .other))
            } else {
                keyed[key] = Entry(path: path, result: result)
            }
        }
        self.entries = keyed
        self.enumeratedFolders = enumeratedFolders
        self.unreadableFolders = unreadableFolders
        self.capabilities = capabilities
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
        let key = FilesystemNamespaceSemantics.nameKey(relativePath: relativePath, capabilities: capabilities)
        if let entry = entries[key] {
            return entry.result
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
