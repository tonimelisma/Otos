import CoreGraphics
import Foundation
import GRDB
import MediaMetadata
import OSLog
import Synchronization

/// Store notifications remain cheap invalidation signals. Most changes carry no
/// payload; root removal carries its typed path because a remove followed by a
/// same-path add can otherwise coalesce into a queried state where Projection cannot
/// observe that the selected library instance disappeared.
nonisolated enum CatalogStoreChange: Equatable {
    case catalogChanged
    /// Rows were inserted and nothing else changed (`CatalogRowChanges`). They carry
    /// nothing derived yet, so only the window and enrichment have new input; an owner
    /// of derived facts (duplicates, people, search, places, faces, render signatures)
    /// hears them when enrichment writes what it derives from them.
    case assetsAdded
    case assetsDetailChanged
    case libraryRemoved(LibraryRootPath)
}

/// An asset the Store has claimed for enrichment, together with the claim-time scope —
/// decided once, by the owner of root kind, from the partial-index predicate the row was
/// claimed under and its staleness at that moment (ADR 0018). Carried rather than
/// re-derived downstream: a later re-derivation reads root kind from a possibly-staler
/// cache and can disagree with the predicate the row was actually claimed under.
nonisolated struct ClaimedEnrichmentCandidate: Sendable {
    let asset: MediaAsset
    let scope: EnrichmentScope
}

/// Catalog Store guide
///
/// This actor is the only runtime owner of catalog truth. SQLite provides durable
/// overlay storage and the per-asset working set; the actor keeps only root identity,
/// source metadata, per-root runtime facts via `RootRegistry` / `RootRuntimeState`,
/// scan/enumeration leases via `ScanLeaseController`, and notification state resident. Fixed libraries, removable
/// volumes, and MTP cameras share the root
/// table because the current filesystem or staging path remains the asset identity
/// boundary, while `LibraryRootKind` controls lifecycle rules such as All Media
/// membership, launch scans, detach, and Forget. Filesystem scans and device catalog
/// batches write SQLite and notify consumers only when those writes actually inserted,
/// updated, or deleted rows. While the app runs, `CatalogFilesystemWatcher` forwards
/// macOS events, in order, to one reconciliation pass per root via `FilesystemReconciler`
/// (pure batch classification) plus Store-owned execution: safe single-file
/// events update one row and unsafe events fall back to the full scan pipeline. Views
/// never access persistence directly. The app owns one Store for the process lifetime;
/// `shutdown()` is therefore a cancellation and watcher boundary, while the database
/// writer is released with the actor rather than through a partial mid-lifecycle close.
///
/// Why an actor: the database handle, root runtime state, scan lifecycle, and
/// background scans all touch the same catalog authority, and a scan streams in
/// thousands of files concurrently with user actions. Actor isolation serializes every access to that state
/// automatically, so the catalog cannot be corrupted by two operations at once and
/// we never reach for a lock. The cost is that `await` is a yield point — the actor
/// can run another message mid-operation — which is exactly why scans carry the
/// ownership lease described below.
///
/// Store notifications are intentionally lightweight. Ordinary events only mark
/// Projection dirty; successful root removal additionally carries its typed path
/// so same-path replacement cannot hide selection invalidation. Projection pulls
/// cheap root state and descriptor-ordered asset IDs on its background cadence
/// and owns presentation.
/// Initial loading is represented by one finite task so every concurrent caller
/// observes the same load instead of applying competing root sets. Awaited GRDB calls
/// make this actor reentrant, so active scans carry the root path, private root-row
/// instance, and in-memory lease generation they own and revalidate them after each
/// database await. `ScanLeaseController` holds the lease/queue bookkeeping; this actor
/// keeps one scan task per lane and all spawn/await orchestration. Completed scans reconcile missing paths; failed,
/// cancelled, or
/// stale scans preserve prior rows because incomplete observation cannot prove
/// removal. Device enumerations use the same process-local lease before they may
/// reconcile missing rows, so a stale camera flow cannot delete rows written by a
/// newer attach. A single regular-file remove
/// event proves deletion only after Store checks that exact path is absent under an
/// armed available root.
actor CatalogStore {
    private nonisolated static let slowQueryDiagnosticThresholdMs = 50

    enum Location: Sendable {
        case application(bundleIdentifier: String)
        case databaseFile(URL)
        case inMemory
    }

    struct StoredRoot {
        let id: Int64
        let path: LibraryRootPath
        let kind: LibraryRootKind
        let deviceIdentity: DeviceIdentity?
        let displayName: String?
        let lastSeenAt: Date?
        let sortIndex: Int64
        let capabilities: VolumeNamespaceCapabilities
        let deviceModel: String?
        let remoteBaseURL: URL?
    }

    struct ThumbnailPathMigration {
        let oldRelativeName: String
        let newRelativeName: String
    }

    /// This value is a process-local ownership lease, not durable scan identity.
    /// The normalized path identifies the domain root, the private row ID
    /// distinguishes a removed root from a later root added at the same path, and
    /// the in-memory generation distinguishes overlapping callbacks for the same
    /// root instance.
    struct ActiveScan: Equatable {
        let rootPath: LibraryRootPath
        let rootRowID: Int64
        let leaseGeneration: UInt64
        let startNamespaceMutationEpoch: UInt64
    }

    private struct RemovableRootAttachment {
        let kind: LibraryRootKind
        let path: LibraryRootPath
        let identity: DeviceIdentity
        let displayName: String
        let isEjectable: Bool
        let activity: CatalogLibraryActivity
        let enqueuesScan: Bool
        let capabilities: VolumeNamespaceCapabilities
        let deviceModel: String?
        let volumeFormat: String?

        func root(lastSeenAt: Date) -> LibraryRoot {
            LibraryRoot(
                path: path,
                kind: kind,
                deviceIdentity: identity,
                displayName: displayName,
                lastSeenAt: lastSeenAt
            )
        }
    }

    private struct EnrichmentBatchWriteOutcome {
        var appliedCount = 0
        /// True when any applied result changed the *effective* generated
        /// ordering/scope columns (`best_capture_local`, `best_kind`, `best_format`).
        /// A batch that changed none of these is detail-only: the projection can skip
        /// the full order query and re-sort (ADR 0011).
        var structureChanged = false
        var namingChangedRoots: Set<LibraryRootPath> = []
        var promotionFailed = false
        var discardedImages: [StagedDerivedImage] = []
        var supersededImagePaths: Set<String> = []
        var waitMs = 0
        var execMs = 0

        mutating func discard(_ images: [StagedDerivedImage]) {
            discardedImages.append(contentsOf: images)
        }

        mutating func failPromotion(_ images: [StagedDerivedImage]) {
            promotionFailed = true
            discard(images)
        }

        /// Records a stored derived image (thumbnail or preview) replaced by a new path,
        /// so its file is deleted once the batch commits.
        mutating func replaceImage(oldPath: String?, newPath: String?) {
            if let newPath {
                supersededImagePaths.remove(newPath)
            }
            if let oldPath, oldPath != newPath {
                supersededImagePaths.insert(oldPath)
            }
        }
    }

    /// Ordering/scope-relevant STORED generated columns, read either before or after an
    /// enrichment overwrite, so the batch can tell a detail-only apply from one that
    /// actually changes the effective `best_capture`/`best_kind`/`best_format` (ADR
    /// 0011) by comparing what SQLite actually stored, not a Swift guess at what
    /// it would store (the guess had no fallback path matching the generated
    /// column's own COALESCE chain and could silently disagree with it).
    private struct EnrichmentOverlayBeforeWrite {
        let bestCaptureLocal: Double?
        let bestKind: String?
        let bestFormat: String?
        let captureWallCompact: Int64?
        let thumbnailPath: String?
        let previewPath: String?
        let faceFramesPath: String?
        let contentIdentifier: String?
        let burstIdentifier: String?

        static let columnsSQL = """
        SELECT best_capture_local, best_kind, best_format, capture_wall_compact, thumbnail_path, preview_path,
            face_frames_path, content_identifier, burst_identifier
        FROM media_asset
        WHERE library_root_id = ? AND relative_path = ?
        """

        init(row: Row) {
            bestCaptureLocal = row["best_capture_local"]
            bestKind = row["best_kind"]
            bestFormat = row["best_format"]
            captureWallCompact = row["capture_wall_compact"]
            thumbnailPath = row["thumbnail_path"]
            previewPath = row["preview_path"]
            faceFramesPath = row["face_frames_path"]
            contentIdentifier = row["content_identifier"]
            burstIdentifier = row["burst_identifier"]
        }

        /// Whether the write changed what a scoped query returns or its order: the sort
        /// date, the kind and format filters, or — through the content identifier and the
        /// kind — which movies a Live Photo hides (ADR 0041), or through the burst
        /// identifier which frames a burst collapses (ADR 0052). Anything else is detail-only.
        func changesStructure(to new: EnrichmentOverlayBeforeWrite) -> Bool {
            bestCaptureLocal != new.bestCaptureLocal
                || bestKind != new.bestKind
                || bestFormat != new.bestFormat
                || contentIdentifier != new.contentIdentifier
                || burstIdentifier != new.burstIdentifier
        }
    }

    nonisolated struct MediaChoiceMutationResult: Equatable, Sendable {
        let existingCount: Int
        let changedCount: Int
        /// The choice each existing row held before this write — catalog truth read in
        /// the same transaction, so a caller can register an exact inverse (APP-039).
        let previous: [MediaAssetID: MediaChoice]

        init(existingCount: Int, changedCount: Int, previous: [MediaAssetID: MediaChoice] = [:]) {
            self.existingCount = existingCount
            self.changedCount = changedCount
            self.previous = previous
        }

        var accepted: Bool {
            existingCount > 0
        }
    }

    private struct DatabaseTimedValue<Value: Sendable> {
        let value: Value
        let waitMs: Int
        let execMs: Int

        var totalMs: Int {
            waitMs + execMs
        }
    }

    private let location: Location
    /// Bytes the WAL file may reach before a bulk write empties it (64 MiB). A
    /// write-ahead log is reset only at an instant no reader is using it, so while readers
    /// overlap one another back to back — the window, enrichment and the derived owners
    /// during a listing — SQLite's own checkpoint can never reset it and the file grows
    /// without end (257 MB in the installed app, 250–357 MB in the listing probe,
    /// `docs/research/2026-11-12-listing-batch-cost.md`). A log SQLite resets stays near
    /// one batch's pages: 26 MB at its largest in the same probe with no reader.
    static let defaultWALByteBudget: Int64 = 64 * 1024 * 1024

    /// The WAL file size past which a bulk write empties the log (`boundWAL`).
    private let walByteBudget: Int64
    /// Where this build's staging roots live. A camera's or an Immich account's root path is
    /// derived from it and the source's identity, and re-derived at every load
    /// (`normalizedLoadedRoot`), so no root keeps a folder another build owns (ADR 0046).
    private let stagingContainers: StagingContainers
    private let scanner: CatalogScanner
    private let filesystemWatcher: CatalogFilesystemWatcher
    /// How often a running scan flushes what it has found: at most once a second. A rate
    /// limit standing on a measurement: a 20,000-file scan took 8–9 s at 1 s, 11–12 s at
    /// 100 ms and over a minute flushing every file, since each flush is a write
    /// transaction and a change notification (`docs/research/2026-10-23-cadence-audit.md`).
    private let scanCadence: Duration
    /// Wall-clock time for persisted facts only: a removable source's last-seen date and
    /// the retention cutoff measured against it (ADR 0033: `Date` is for persisted and
    /// displayed timestamps). Injected so retention is testable without waiting 90 days.
    private let wallClock: @Sendable () -> Date
    private let initialLoadDidRead: (@Sendable () async -> Void)?
    private let importJournalFailure: (@Sendable (ImportJournalTransition) throws -> Void)?
    private var dbWriter: (any DatabaseWriter)?
    private var databaseFileURL: URL?
    private var started = false
    private var startupTask: Task<Void, Error>?
    private var unrequestedLoadedRootPaths: [LibraryRootPath] = []
    private var roots = RootRegistry()
    /// Rows whose bytes just became local and still owe a product, in landing order: copies
    /// an import settled, and originals a source's download staged (an Immich account's,
    /// ADR 0046 §7). Their bytes may not stay — a cloud-synced library evicts uploaded
    /// files, a staging folder is swept at launch — so background claims offer them before
    /// any other row, for every product their bytes can give (ADR 0009 §9). Runtime only:
    /// after a relaunch they wait in the ordinary order.
    private var localBytesAwaitingProducts: [MediaAssetID] = []
    /// What each duplicates Move to Trash carried onto kept copies, by its batch, so the
    /// command's undo puts back exactly what the kept copies held (ADR 0042). In memory:
    /// it lives as long as the undo stack that names the batch.
    private var carriedWorkByBatch: [MediaTrashBatchID: [DuplicateCarryRecord]] = [:]
    private var changeContinuations: [UUID: AsyncStream<CatalogStoreChange>.Continuation] = [:]
    private var planningChangeContinuations: [UUID: AsyncStream<RootPlanningChange>.Continuation] = [:]
    private var changeDeliveries: [UUID: DeliveryCount] = [:]
    private var planningChangeDeliveries: [UUID: DeliveryCount] = [:]
    private var scanLeases = ScanLeaseController()
    /// The filesystem walk each lane is running (`ScanLeaseController.ScanLane`): one
    /// for the fixed libraries, one per card. Each is cancelled when its root goes away,
    /// and every callback revalidates its `ActiveScan` lease before mutating actor state.
    private var scanTasks: [ScanLeaseController.ScanLane: Task<Void, Never>] = [:]
    private var filesystemWatchingStarted = false
    private var filesystemEventSink: AsyncStream<FilesystemEvent>.Continuation?
    private var filesystemEventConsumer: Task<Void, Never>?
    /// The one owner of dirty-scope reconciliation and of starting the next queued
    /// full-root scan (ADR 0032). Anything that leaves reconcilable work — a scan or a
    /// lease ending, an event batch classified, an independent mutation settled — rings
    /// the doorbell; the loop drains every dirty root it may act on, then starts the
    /// next queued scan. One loop, so two drains of one root never interleave.
    private var reconcileLoop: Task<Void, Never>?
    private var reconcileDoorbell: AsyncStream<Void>.Continuation?
    /// Bumped by every ring; a pass covers the value it started from.
    private var reconcileRequested: UInt64 = 0
    private var reconcileCovered: UInt64 = 0
    /// True while the loop's pass runs, so a scan enqueued mid-pass waits for the pass
    /// to finish every dirty root. Written only by the loop.
    private var reconcilePassRunning = false
    private var filesystemWatchingArmed: Set<LibraryRootPath> = []
    /// One pass per root acts on that root's filesystem events. Events that arrive while
    /// it awaits join `filesystemEventBatches` and the same pass takes them next, so a
    /// burst is coalesced by the work itself, never by waiting for a quiet period.
    private var filesystemEventPasses: [LibraryRootPath: Task<Void, Never>] = [:]
    /// Which pass is current per root, so a pass that ends clears its entry only when a
    /// cancellation has not already replaced it.
    private var filesystemEventPassGenerations: [LibraryRootPath: UInt64] = [:]
    private var filesystemEventBatches: [LibraryRootPath: [FilesystemEvent]] = [:]
    /// Filesystem events this Store has handled — dropped, deferred or batched. With
    /// `isFilesystemQuiescent` it says what the Store did with an event, so a caller
    /// never has to guess how long event delivery and reconciliation take.
    private(set) var handledFilesystemEventCount = 0
    /// Filesystem events a pass has taken from its batch and classified, so a caller can
    /// wait for the dirt they record rather than for their intake alone.
    private(set) var classifiedFilesystemEventCount = 0
    /// Callers that found the initial load already running and awaited it instead of
    /// starting their own database read.
    private(set) var joinedInitialLoadCount = 0

    /// True when no filesystem event is being acted on or unprocessed in a batch, no scan is active or queued, and no dirty scope is retained: everything
    /// the Store was told about the filesystem has been acted on.
    var isFilesystemQuiescent: Bool {
        filesystemEventPasses.isEmpty
            && filesystemEventBatches.isEmpty
            && scanLeases.activeScans.isEmpty
            && scanLeases.pendingScanPaths.isEmpty
            && scanLeases.rescanAfterCurrentScan.isEmpty
            && filesystemDirty.isEmpty
            && reconcileRequested == reconcileCovered
            && !reconcilePassRunning
    }

    /// Per-root typed dirty-scope accumulator. Events that arrive while a lease
    /// owns the root retain file/subtree/root granularity here instead of being
    /// collapsed into an unconditional full-root rescan.
    private var filesystemDirty: [LibraryRootPath: FilesystemDirtyAccumulator] = [:]
    /// Last successful completed full-root reconciliation per root. Launch/add
    /// scans count; used only for the long-running-session integrity sweep.
    private var unreadableSourceIDs: Set<MediaAssetID> = []
    private var lastSuccessfulFullRootScanAt: [LibraryRootPath: ContinuousClock.Instant] = [:]
    private var integrityScanTask: Task<Void, Never>?
    private var knownMaterializationSuppression = KnownMaterializationSuppressionState()
    /// Typed namespace-mutation lease per root. Import publication, library
    /// reorganization, and system Trash share this one exclusion boundary;
    /// deferred dirty-only reconciliation runs when the owner releases it.
    private var namespaceMutationLeases: [LibraryRootPath: RootNamespaceMutationLease] = [:]
    private var nextNamespaceMutationLeaseGeneration: UInt64 = 0
    /// Roots whose reorganization lease the journal holds: installed at load for every
    /// root with a journaled component, so nothing touches a half-moved library before
    /// its recovery adopts the lease.
    private var journalHeldReorganizationRoots: Set<LibraryRootPath> = []
    /// Libraries the user asked to remove while another owner held them. The release of
    /// that owner's lease hands the root straight to a removal lease, so nothing else
    /// starts on it in between, and the reconcile loop then removes it. A request lives
    /// for this process: one whose holder never finishes here — the app quits mid-import
    /// — leaves the library in place, where the user sees it and can remove it again.
    private var deferredLibraryRemovals: Set<LibraryRootPath> = []
    /// Removal leases a release handed over, waiting for the reconcile loop to run them.
    private var handedOffLibraryRemovals: [LibraryRootPath: RootNamespaceMutationLease] = [:]

    /// Long-running-session integrity interval. Launch scans already repair after
    /// process death; this bounds residual FSEvents/provider misses while the app
    /// stays open. Chosen as 24h for measurement/review
    /// (docs/research/2026-07-11-onedrive-materialization-fsevents.md).
    static let integrityScanInterval: Duration = .seconds(60 * 60 * 24)
    static let integrityScanPollInterval: Duration = .seconds(60 * 15)

    init(
        location: Location,
        scanner: CatalogScanner = .live,
        filesystemWatcher: CatalogFilesystemWatcher = .live(),
        scanCadence: Duration = .seconds(1),
        wallClock: @escaping @Sendable () -> Date = { Date() },
        initialLoadDidRead: (@Sendable () async -> Void)? = nil,
        importJournalFailure: (@Sendable (ImportJournalTransition) throws -> Void)? = nil,
        walByteBudget: Int64 = CatalogStore.defaultWALByteBudget,
        stagingContainers: StagingContainers = .live
    ) {
        self.walByteBudget = walByteBudget
        self.stagingContainers = stagingContainers
        self.location = location
        self.scanner = scanner
        self.filesystemWatcher = filesystemWatcher
        self.scanCadence = scanCadence
        self.wallClock = wallClock
        self.initialLoadDidRead = initialLoadDidRead
        self.importJournalFailure = importJournalFailure
    }
}

extension CatalogStore {
    /// Counts the changes the Store has yielded to one subscriber, recorded in the same
    /// step as each yield. A subscriber that counts what it has handled can compare the
    /// two and know it has acted on every change, which the stream alone cannot say.
    final nonisolated class DeliveryCount: Sendable {
        private let count = Mutex<UInt64>(0)

        var delivered: UInt64 {
            count.withLock { $0 }
        }

        func recordDelivery() {
            count.withLock { $0 += 1 }
        }
    }

    func changeNotifications(deliveries: DeliveryCount? = nil) -> AsyncStream<CatalogStoreChange> {
        let (stream, continuation) = AsyncStream<CatalogStoreChange>.makeStream(
            // Root-removal signals cannot be dropped: a same-path add may follow
            // before Projection gets another executor turn. Events are tiny and
            // Projection coalesces their expensive work on its existing cadence.
            bufferingPolicy: .unbounded
        )
        let id = UUID()
        changeContinuations[id] = continuation
        changeDeliveries[id] = deliveries
        continuation.onTermination = { [weak self] _ in
            // AsyncStream termination is synchronous, while the continuations
            // dictionary is actor state. This short task is the required actor
            // hop that removes the observer after the stream goes away.
            Task {
                await self?.removeChangeContinuation(id)
            }
        }
        return stream
    }

    /// Lossless planning-input revision stream (ARC-046). Separate from
    /// coarse `CatalogStoreChange` so thumbnail-only mutations do not replan.
    func planningChangeNotifications(deliveries: DeliveryCount? = nil) -> AsyncStream<RootPlanningChange> {
        let (stream, continuation) = AsyncStream<RootPlanningChange>.makeStream(
            bufferingPolicy: .unbounded
        )
        let id = UUID()
        planningChangeContinuations[id] = continuation
        planningChangeDeliveries[id] = deliveries
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removePlanningChangeContinuation(id)
            }
        }
        let listenerCount = planningChangeContinuations.count
        OtosLog.catalog.notice(
            "op=catalog.planningChange phase=subscribed listeners=\(listenerCount, privacy: .public)"
        )
        return stream
    }

    func planRevision(for rootPath: LibraryRootPath) -> UInt64? {
        roots[rootPath]?.planRevision
    }

    /// Assets whose bytes enrichment could not open. Process-local by design, and
    /// discarded for a root the moment that root detaches — so re-inserting a card
    /// re-evaluates every file rather than inheriting a verdict from the attachment
    /// that observed it. Without that boundary a single unreadable file would stay
    /// blocked for the lifetime of the process, even once it read cleanly again, and
    /// the set would grow without bound.
    ///
    /// On a removable volume nothing about the condition is transient — the bytes are
    /// local, so a failure to open them is a failing card or a file that vanished, not
    /// something to wait out (ARC-057).
    func markSourceUnreadable(_ id: MediaAssetID) {
        guard unreadableSourceIDs.insert(id).inserted else {
            return
        }
        OtosLog.metadata.notice(
            "op=enrichment.sourceUnreadable phase=record rootPath=\(id.libraryRootPath.rawValue, privacy: .public) relativePath=\(id.relativePath.rawValue, privacy: .public)"
        )
        bumpNamingRevision(for: id.libraryRootPath, reason: "sourceUnreadable")
    }

    /// Drops every unreadable verdict recorded under `rootPath`. Called where a root
    /// stops being attached, so the next attachment starts from observation rather
    /// than from memory.
    func forgetUnreadableSources(under rootPath: LibraryRootPath) {
        let before = unreadableSourceIDs.count
        unreadableSourceIDs = unreadableSourceIDs.filter { $0.libraryRootPath != rootPath }
        let dropped = before - unreadableSourceIDs.count
        guard dropped > 0 else {
            return
        }
        OtosLog.metadata.notice(
            "op=enrichment.sourceUnreadable phase=forget rootPath=\(rootPath.rawValue, privacy: .public) dropped=\(dropped, privacy: .public)"
        )
    }

    func namespaceRevision(for rootPath: LibraryRootPath) -> UInt64? {
        roots[rootPath]?.namespaceRevision
    }

    /// The pair an import plan's staleness is judged against, read in one actor hop
    /// so the two halves cannot be sampled across a suspension.
    func planningRevisions(for rootPath: LibraryRootPath) -> RootPlanningRevisions? {
        guard let state = roots[rootPath] else { return nil }
        return RootPlanningRevisions(
            namespaceRevision: state.namespaceRevision,
            namingRevision: state.namingRevision
        )
    }

    /// General planning revision bump for changes that may invalidate reorganization
    /// planning but change neither the occupied namespace nor naming (no-op rescans,
    /// event deferrals, watch arming). Wakes the import coordinator with both
    /// revisions unchanged, which the coordinator treats as a cheap no-op.
    @discardableResult
    func bumpPlanRevision(for path: LibraryRootPath) -> UInt64? {
        guard var state = roots[path] else {
            return nil
        }
        state.planRevision &+= 1
        upsert(state)
        emitPlanningChange(rootPath: path, state: state)
        OtosLog.catalog.notice(
            "op=catalog.planRevision phase=bump rootPath=\(path.rawValue, privacy: .public) planRevision=\(state.planRevision, privacy: .public)"
        )
        return state.planRevision
    }

    /// Namespace bump for a real change to which paths this root occupies (media
    /// added/removed/renamed/resized, companion inventory change, import/reorg
    /// settlement, foreign occupant). Also advances `planRevision` — a namespace
    /// change is a superset planning change — and wakes the import coordinator, which
    /// replans every session reading this root as source or destination.
    @discardableResult
    func bumpNamespaceRevision(for path: LibraryRootPath, reason: String = "catalogChange") -> UInt64? {
        guard var state = roots[path] else {
            return nil
        }
        state.namespaceRevision &+= 1
        state.planRevision &+= 1
        upsert(state)
        emitPlanningChange(rootPath: path, state: state)
        OtosLog.catalog.notice(
            "op=catalog.namespaceRevision phase=bump rootPath=\(path.rawValue, privacy: .public) reason=\(reason, privacy: .public) namespaceRevision=\(state.namespaceRevision, privacy: .public) planRevision=\(state.planRevision, privacy: .public)"
        )
        return state.namespaceRevision
    }

    /// Naming bump for an enrichment write that changed what Otos would call this
    /// root's assets (`capture_wall_compact`). Also advances `planRevision`, because
    /// reorganization naming legitimately depends on capture dates.
    ///
    /// This does **not** advance `namespaceRevision`: no file moved, so a plan
    /// copying *into* this root is untouched. Only a session reading this root as its
    /// **source** replans, because the source's capture wall is what names the copy
    /// (ARC-046, ARC-057).
    @discardableResult
    func bumpNamingRevision(for path: LibraryRootPath, reason: String = "enrichmentNaming") -> UInt64? {
        guard var state = roots[path] else {
            return nil
        }
        state.namingRevision &+= 1
        state.planRevision &+= 1
        upsert(state)
        emitPlanningChange(rootPath: path, state: state)
        OtosLog.catalog.notice(
            "op=catalog.namingRevision phase=bump rootPath=\(path.rawValue, privacy: .public) reason=\(reason, privacy: .public) namingRevision=\(state.namingRevision, privacy: .public) planRevision=\(state.planRevision, privacy: .public)"
        )
        return state.namingRevision
    }

    /// Records a namespace mutation before its owner crosses a database await.
    /// The epoch invalidates any older destructive observation, scan or file reconcile,
    /// and the typed dirty scope is a reconcile request in the same step: the loop
    /// reconciles it once no lease holds the root, so a reconcile the epoch deferred
    /// is observed again without waiting for another event.
    private func recordIndependentNamespaceMutation(
        root: LibraryRootPath,
        scope: FilesystemDirtyScope,
        fileAction: SingleFileReconcileOperation? = nil
    ) {
        guard var state = roots[root] else {
            return
        }
        state.namespaceMutationEpoch &+= 1
        upsert(state)
        var dirty = filesystemDirty[root] ?? FilesystemDirtyAccumulator()
        dirty.insert(scope, fileAction: fileAction)
        filesystemDirty[root] = dirty
        OtosLog.catalog.debugOperation(
            "catalog.namespaceMutation",
            phase: "record",
            fields: [
                "rootPath": root.rawValue,
                "epoch": "\(state.namespaceMutationEpoch)",
                "scope": String(describing: scope),
            ]
        )
        requestReconcile()
    }

    /// Planning media facts for reorganization of one fixed library root.
    func planningMedia(for rootPath: LibraryRootPath) async -> [PlanningFileFacts]? {
        guard let state = roots[rootPath] else {
            return nil
        }
        do {
            let dbWriter = try database()
            let companions = try await dbWriter.read { db in
                try Self.fetchCompanions(libraryRootID: state.rowID, db: db)
            }
            let companionsByPrimary = Dictionary(grouping: companions) {
                $0.primaryRelativePath?.rawValue ?? ""
            }
            let unreadable = unreadableSourceIDs
            let rowID = state.rowID
            return try await dbWriter.read { db in
                try MediaOperationGateway.fetchPlanningSourceMedia(
                    libraryRootID: rowID,
                    sourceRoot: rootPath,
                    companionsByPrimary: companionsByPrimary,
                    unreadableSourceIDs: unreadable,
                    db: db
                )
            }
        } catch {
            OtosLog.catalog.error(
                "op=reorganization.snapshot phase=failed rootPath=\(rootPath.rawValue, privacy: .public)"
            )
            return nil
        }
    }

    /// Immutable import planning snapshot for one source→destination pair.
    func importPlanningSnapshot(
        source: LibraryRootPath,
        destination: LibraryRootPath,
        policy: ImportPolicy,
        generation: UInt64,
        calendar: Calendar = .current,
        timeZone: TimeZone = .current
    ) async throws -> ImportPlanningSnapshot? {
        guard let sourceState = roots[source],
              let destinationState = roots[destination]
        else {
            return nil
        }
        let dbWriter = try database()
        let sourceRowID = sourceState.rowID
        let destinationRowID = destinationState.rowID
        let companions = try await dbWriter.read { db in
            try Self.fetchCompanions(libraryRootID: sourceRowID, db: db)
        }
        let companionsByPrimary = Dictionary(grouping: companions) {
            $0.primaryRelativePath?.rawValue ?? ""
        }
        let unreadable = unreadableSourceIDs
        let sourceMedia = try await dbWriter.read { db in
            try MediaOperationGateway.fetchPlanningSourceMedia(
                libraryRootID: sourceRowID,
                sourceRoot: source,
                companionsByPrimary: companionsByPrimary,
                unreadableSourceIDs: unreadable,
                db: db
            )
        }
        let destinationOccupants = try await dbWriter.read { db in
            try MediaOperationGateway.fetchDestinationOccupants(
                libraryRootID: destinationRowID,
                db: db
            )
        }
        let libraryRowIDs = roots.availableFixedLibraryRowIDs()
        let pathsByRowID = roots.pathsByRowID
        let libraryContent = try await dbWriter.read { db in
            try MediaOperationGateway.fetchLibraryContent(libraryRootIDs: libraryRowIDs, db: db)
        }.compactMapValues { pathsByRowID[$0] }
        let destinationCapabilities = await Self.probeCapabilities(of: destination)
        return ImportPlanningSnapshot(
            generation: generation,
            sourceRoot: source,
            destinationRoot: destination,
            sourceNamespaceRevision: sourceState.namespaceRevision,
            sourceNamingRevision: sourceState.namingRevision,
            destinationNamespaceRevision: destinationState.namespaceRevision,
            sourceMedia: sourceMedia,
            destinationOccupants: destinationOccupants,
            libraryContent: libraryContent,
            policy: policy,
            calendar: calendar,
            timeZone: timeZone,
            destinationCapabilities: destinationCapabilities
        )
    }

    /// The digests among `digests` that a fixed library still holds now: a row in an
    /// available library, not pending trash, with a digest current for its file. A card
    /// Erase asks this just before deleting items the plan skipped by content (ADR 0018).
    func librariesHoldContent(_ digests: Set<XXH3Digest128>) async throws -> Set<XXH3Digest128> {
        let libraryRowIDs = roots.availableFixedLibraryRowIDs()
        let held = try await database().read { db in
            try MediaOperationGateway.fetchLibraryContent(libraryRootIDs: libraryRowIDs, db: db)
        }
        return digests.filter { held[$0] != nil }
    }

    /// The kind of a known root, so a caller can dispatch on what a root *is* rather
    /// than infer it from its path. Returns nil for a path this store does not know.
    func rootKind(for rootPath: LibraryRootPath) -> LibraryRootKind? {
        roots[rootPath]?.root.kind
    }

    /// The libraries once the initial load has applied, and nil before it: before the
    /// load the catalog's roots are unknown, which is not the same as having none
    /// (APP-044).
    func loadedLibraries() -> [CatalogLibraryState]? {
        started ? currentLibraries() : nil
    }

    func currentLibraries() -> [CatalogLibraryState] {
        roots.values
            .map { catalogLibraryState(from: $0) }
            .sorted {
                if $0.sortIndex != $1.sortIndex {
                    return $0.sortIndex < $1.sortIndex
                }
                return $0.path.rawValue < $1.path.rawValue
            }
    }

    /// Nonempty import batches newest-first. Projection publishes these for the
    /// Imports sidebar section. SQL lives in the gateway; Store owns `timedRead`
    /// and `roots` capture.
    func importBatches() async throws -> [ImportBatchSummary] {
        let dbWriter = try database()
        return try await dbWriter.read { db in
            try CatalogQueryGateway.fetchImportBatches(db: db)
        }
    }

    /// Surviving assets that carry the given import batch stamp, across fixed libraries.
    func assetIDs(inImportBatch batchID: ImportBatchID) async throws -> [MediaAssetID] {
        let dbWriter = try database()
        let pathsByRowID = roots.pathsByRowID
        return try await dbWriter.read { db in
            try CatalogQueryGateway.fetchAssetIDs(inImportBatch: batchID, pathsByRowID: pathsByRowID, db: db)
        }
    }

    /// Reports cataloged assets that violate the total best-date invariant for
    /// planning (no embedded date and no filesystem/camera modification date).
    /// Camera items without any usable date are expected here and become
    /// `.blocked(.noUsableDate)` plan entries later — they are never silently dropped.
    func assetsMissingBestDateFacts() async throws -> [MediaAssetID] {
        let dbWriter = try database()
        let pathsByRowID = roots.pathsByRowID
        return try await dbWriter.read { db in
            try CatalogQueryGateway.fetchAssetIDsMissingBestDate(pathsByRowID: pathsByRowID, db: db)
        }
    }

    /// Capture-wall naming fact for one asset, when enrichment selected a local-authority timestamp.
    func captureWall(for id: MediaAssetID) async throws -> CaptureWallClock.Selection? {
        guard let rootRowID = roots[id.libraryRootPath]?.rowID else {
            return nil
        }
        let dbWriter = try database()
        return try await dbWriter.read { db in
            try CatalogQueryGateway.fetchCaptureWall(id: id, rootRowID: rootRowID, db: db)
        }
    }

    /// Companions inventoried under a root. Never appear in media queries.
    func companions(in rootPath: LibraryRootPath) async throws -> [MediaCompanion] {
        guard let rootRowID = roots[rootPath]?.rowID else {
            return []
        }
        let dbWriter = try database()
        return try await dbWriter.read { db in
            try Self.fetchCompanions(libraryRootID: rootRowID, db: db)
        }
    }

    /// Whether `id`'s faces have been read and how many of its stored faces are still faces,
    /// whoever's they are, from one read, so the Info pane's `No Faces` and `Not Checked Yet`
    /// are the catalog's facts (APP-041). Nil when the asset is not cataloged.
    func facesRead(for id: MediaAssetID) async throws -> PhotoFacesRead? {
        guard let rootRowID = roots[id.libraryRootPath]?.rowID else {
            return nil
        }
        let dbWriter = try database()
        return try await dbWriter.read { db -> PhotoFacesRead? in
            try Row.fetchOne(
                db,
                sql: """
                SELECT m.faces_source_size IS NOT NULL AS is_read,
                    (SELECT COUNT(*) FROM face AS f
                     WHERE f.library_root_id = m.library_root_id AND f.relative_path = m.relative_path
                       AND f.is_not_face = 0) AS faces
                FROM media_asset AS m WHERE m.library_root_id = ? AND m.relative_path = ?
                """,
                arguments: [rootRowID, id.relativePath.rawValue]
            ).map { row in
                PhotoFacesRead(photo: id, isRead: row["is_read"], faceCount: row["faces"])
            }
        }
    }

    /// The overlay the Info pane shows for `id` (APP-041): its companion files, the import it
    /// arrived in, whether it carries an edit, and what search recognised in it — the confident
    /// scene labels of its current embedding row and the certain lines of its current text
    /// reading, each nil while that reading is owed. Nil when the asset is not cataloged.
    func photoInfoOverlay(for id: MediaAssetID) async throws -> PhotoInfoOverlay? {
        guard let rootRowID = roots[id.libraryRootPath]?.rowID else {
            return nil
        }
        let dbWriter = try database()
        let overlay = try await dbWriter.read { db -> PhotoInfoOverlay? in
            let arguments: StatementArguments = [rootRowID, id.relativePath.rawValue]
            guard let asset = try Row.fetchOne(
                db,
                sql: """
                SELECT import_batch_unix_ms, edit_recipe_json IS NOT NULL AS edited
                FROM media_asset WHERE library_root_id = ? AND relative_path = ?
                """,
                arguments: arguments
            ) else {
                return nil
            }
            let companions = try Row.fetchAll(
                db,
                sql: """
                SELECT relative_path FROM media_companion
                WHERE library_root_id = ? AND primary_relative_path = ?
                ORDER BY relative_path
                """,
                arguments: arguments
            ).map { MediaRelativePath(rawValue: $0["relative_path"]).fileName }
            let batch: Int64? = asset["import_batch_unix_ms"]
            let labels = try Row.fetchOne(
                db,
                sql: """
                SELECT e.confident_labels FROM search_embedding AS e
                JOIN media_asset AS a ON a.library_root_id = e.library_root_id AND a.relative_path = e.relative_path
                WHERE e.library_root_id = ? AND e.relative_path = ?
                  AND e.source = \(SearchEmbeddingStorage.currentSource("a"))
                """,
                arguments: arguments
            ).map { SearchEmbeddingStorage.confidentLabels(from: $0[0]) }
            let lines = try String.fetchOne(
                db,
                sql: """
                SELECT t.lines FROM search_text AS t
                JOIN media_asset AS a ON a.library_root_id = t.library_root_id AND a.relative_path = t.relative_path
                WHERE t.library_root_id = ? AND t.relative_path = ?
                  AND t.source = \(SearchTextStorage.currentSource("a"))
                """,
                arguments: arguments
            )
            return try PhotoInfoOverlay(
                companionFileNames: companions,
                importedAt: batch.map { Date(timeIntervalSince1970: Double($0) / 1000) },
                isEdited: asset["edited"],
                sceneLabels: labels,
                textLines: lines.map { try SearchTextReading.certain(SearchTextStorage.lines(fromJSON: $0)) }
            )
        }
        guard roots[id.libraryRootPath]?.rowID == rootRowID else {
            return nil
        }
        return overlay
    }

    /// The faces stored for `id`, in the order its reading found them. Empty when the asset
    /// has none, has not been read for faces yet, or its library is no longer cataloged.
    func faces(of id: MediaAssetID) async throws -> [DetectedFace] {
        guard let rootRowID = roots[id.libraryRootPath]?.rowID else {
            return []
        }
        let dbWriter = try database()
        return try await dbWriter.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT box_x, box_y, box_width, box_height, landmarks, quality, embedding
                FROM face
                WHERE library_root_id = ? AND relative_path = ?
                ORDER BY face_index
                """,
                arguments: [rootRowID, id.relativePath.rawValue]
            ).map { row in
                let landmarks: Data = row["landmarks"]
                let embedding: Data = row["embedding"]
                guard let points = FaceStorage.landmarks(from: landmarks),
                      let vector = FaceStorage.embedding(from: embedding)
                else {
                    throw CatalogStoreError.malformedFaceRow(id)
                }
                let quality: Double = row["quality"]
                return DetectedFace(
                    box: CGRect(x: row["box_x"] as Double, y: row["box_y"] as Double,
                                width: row["box_width"] as Double, height: row["box_height"] as Double),
                    landmarks: points,
                    quality: Float(quality),
                    embedding: vector
                )
            }
        }
    }

    // MARK: - People (ADR 0047)

    /// The roots of `availableLibraryPaths` whose faces Otos reads, by row ID.
    private func faceRootIDs(_ availableLibraryPaths: Set<LibraryRootPath>) -> [Int64] {
        availableLibraryPaths.compactMap { path in
            roots[path].flatMap { $0.root.kind.readsFaces ? $0.rowID : nil }
        }.sorted()
    }

    /// The unchecked tally alone (`PeopleSnapshot.unchecked`): what rows only added change.
    func uncheckedForFaces(availableLibraryPaths: Set<LibraryRootPath>) async throws -> MediaCount {
        let rootIDs = faceRootIDs(availableLibraryPaths)
        return try await database().read { db in
            try Self.uncheckedForFaces(rootIDs: rootIDs, db: db)
        }
    }

    /// Everything People reads, in one transaction: each face with its photo's capture
    /// instant, its tile, whose word its person is and the user's acts on it, the people, and
    /// the stills in `availableLibraryPaths` whose faces are not yet read. Faces of libraries
    /// no longer cataloged are left out. A photo with a face row no reading writes (an
    /// embedding not of unit length, an assignment no case holds) is left out whole and owes
    /// its faces again: its faces stamp is cleared, so it is read afresh, and it is logged.
    func peopleSnapshot(availableLibraryPaths: Set<LibraryRootPath> = []) async throws -> PeopleSnapshot {
        let pathsByRowID = roots.pathsByRowID
        let rowIDs = roots.rowIDSnapshot()
        let faceRootIDs = faceRootIDs(availableLibraryPaths)
        let dbWriter = try database()
        let (snapshot, malformed) = try await dbWriter.read { db -> (PeopleSnapshot, Set<FaceRowKey.Photo>) in
            var malformed: Set<FaceRowKey.Photo> = []
            var rejections: [FaceRowKey: Set<PersonID>] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT library_root_id, relative_path, face_index, person_id FROM face_rejection") {
                rejections[FaceRowKey(row), default: []].insert(PersonID(rawValue: row["person_id"]))
            }
            var faces: [FaceFact] = []
            var tiles: [FaceID: FaceTile] = [:]
            var likeness: [FaceID: Float] = [:]
            var keyPhotos: [PersonID: FaceID] = [:]
            // A Live Photo's movie is one item with its still (ADR 0041), whose faces are its.
            // Read by position (`PeopleFaceColumn`): a name lookup scans the row's columns,
            // and at 18 columns over every face it was most of the read (bench
            // people.snapshot.10k, 2026-11-13).
            for row in try Row.fetchAll(
                db,
                sql: """
                SELECT \(PeopleFaceColumn.selectList)
                FROM face f
                JOIN media_asset m ON m.library_root_id = f.library_root_id AND m.relative_path = f.relative_path
                WHERE m.trash_path IS NULL AND f.is_not_face = 0
                  AND NOT \(LivePhotoSQL.isPairedMotion("m"))
                ORDER BY f.library_root_id, f.relative_path, f.face_index
                """
            ) {
                let key = FaceRowKey(
                    rootID: row[PeopleFaceColumn.rootID.rawValue],
                    path: MediaRelativePath(rawValue: row[PeopleFaceColumn.path.rawValue]),
                    index: row[PeopleFaceColumn.faceIndex.rawValue]
                )
                guard let rootPath = pathsByRowID[key.rootID], !malformed.contains(key.photo) else { continue }
                let asset = MediaAssetID(libraryRootPath: rootPath, relativePath: key.path)
                let data: Data = row[PeopleFaceColumn.embedding.rawValue]
                let person: Int64? = row[PeopleFaceColumn.personID.rawValue]
                guard let embedding = FaceStorage.embedding(from: data),
                      let assignment = try? FaceAssignmentColumn.assignment(
                          column: row[PeopleFaceColumn.assignment.rawValue], person: person
                      )
                else {
                    malformed.insert(key.photo)
                    continue
                }
                let id = FaceID(asset: asset, index: key.index)
                let capture: Double? = row[PeopleFaceColumn.captureLocal.rawValue]
                faces.append(FaceFact(
                    id: id,
                    captureSeconds: capture,
                    embedding: embedding,
                    assignment: assignment,
                    rejected: rejections[key] ?? []
                ))
                if let stored = row[PeopleFaceColumn.likeness.rawValue] as Double? {
                    likeness[id] = Float(stored)
                }
                if let person, (row[PeopleFaceColumn.isKeyPhoto.rawValue] as Int) != 0 {
                    keyPhotos[PersonID(rawValue: person)] = id
                }
                tiles[id] = FaceTile(
                    id: id,
                    box: CGRect(
                        x: row[PeopleFaceColumn.boxX.rawValue] as Double,
                        y: row[PeopleFaceColumn.boxY.rawValue] as Double,
                        width: row[PeopleFaceColumn.boxWidth.rawValue] as Double,
                        height: row[PeopleFaceColumn.boxHeight.rawValue] as Double
                    ),
                    preview: Self.facePreview(row, asset: asset),
                    captureSeconds: capture,
                    isInVideo: (row[PeopleFaceColumn.isVideo.rawValue] as Int) != 0
                )
            }
            let people = try Row.fetchAll(
                db,
                sql: "SELECT id, name, birthday, is_hidden, is_favorite FROM person ORDER BY id"
            ).map(Self.person)
            var stacks: [PhotoStack] = []
            for (rowID, candidates) in try PhotoStackSQL.fetchCandidates(rootIDs: faceRootIDs, db: db).byRoot {
                guard let rootPath = pathsByRowID[rowID] else { continue }
                stacks += PhotoStackRule.stacks(candidates: candidates, libraryRootPath: rootPath)
            }
            let photoOfStackMember = CatalogStacks(stacks).keyOfMember
            // A malformed row's photo is left out whole: its other faces were read before the
            // bad row was reached.
            let left = { (id: FaceID) in
                rowIDs[id.asset.libraryRootPath].map { !malformed.contains(FaceRowKey.Photo(rootID: $0, path: id.asset.relativePath)) } ?? true
            }
            let snapshot = try PeopleSnapshot(
                faces: faces.filter { left($0.id) },
                tiles: tiles.filter { left($0.key) },
                people: people,
                likeness: likeness.filter { left($0.key) },
                keyPhotos: keyPhotos.filter { left($0.value) },
                photoOfStackMember: photoOfStackMember,
                unchecked: Self.uncheckedForFaces(rootIDs: faceRootIDs, db: db)
            )
            return (snapshot, malformed)
        }
        if !malformed.isEmpty {
            try await oweFacesAgain(malformed, pathsByRowID: pathsByRowID)
        }
        return snapshot
    }

    /// Clears the faces stamp of each photo holding a malformed face row, so it is read for its
    /// faces again and the reading replaces the row (ADR 0047). Rings the change notifications
    /// only when a stamp was cleared, so the People read that found the rows does not start
    /// itself again.
    private func oweFacesAgain(_ photos: Set<FaceRowKey.Photo>, pathsByRowID: [Int64: LibraryRootPath]) async throws {
        let cleared = try await database().write { db -> Int in
            var cleared = 0
            for photo in photos {
                try db.execute(
                    sql: """
                    UPDATE media_asset SET faces_source_size = NULL, faces_source_mtime = NULL
                    WHERE library_root_id = ? AND relative_path = ? AND faces_source_size IS NOT NULL
                    """,
                    arguments: [photo.rootID, photo.path.rawValue]
                )
                cleared += db.changesCount
            }
            return cleared
        }
        for photo in photos {
            OtosLog.catalog.errorOperation("people.snapshot", phase: "malformedFaceRow", fields: [
                "rootPath": pathsByRowID[photo.rootID]?.rawValue ?? "?",
                "relativePath": photo.path.rawValue,
                "owedAgain": "\(cleared > 0)",
            ])
        }
        if cleared > 0 {
            notifyCatalogChanged(.assetsDetailChanged)
        }
    }

    /// The stored image a face tile is cut from. A video's face: the image of its stored face
    /// frames it was read in, none for a face kept from an earlier reading. A still's: its
    /// stored preview, with the edit it shows, none before one is made, while a rendering of a
    /// newer edit is owed, or when the edit cannot be read (logged). The tile then shows its
    /// placeholder.
    private static func facePreview(_ row: Row, asset: MediaAssetID) -> FacePreview? {
        if let frameIndex = row[PeopleFaceColumn.frameIndex.rawValue] as Int? {
            return (row[PeopleFaceColumn.faceFramesPath.rawValue] as String?).map {
                FacePreview(name: $0, recipe: .neutral, image: frameIndex)
            }
        }
        guard let name: String = row[PeopleFaceColumn.previewPath.rawValue],
              (row[PeopleFaceColumn.previewEditIsKnown.rawValue] as Int) != 0
        else {
            return nil
        }
        let renderedRevision: Int64 = row[PeopleFaceColumn.renderedRevision.rawValue]
        do {
            let recipe = renderedRevision == 0
                ? .neutral
                : try editRecipe(json: row[PeopleFaceColumn.editRecipeJSON.rawValue]) ?? .neutral
            return FacePreview(name: name, recipe: recipe)
        } catch {
            OtosLog.catalog.errorOperation("people.faceTile", phase: "recipeUnreadable", fields: [
                "relativePath": asset.relativePath.rawValue, "error": String(describing: error),
            ])
            return nil
        }
    }

    private static func person(_ row: Row) throws -> PeopleSnapshot.Person {
        let id = PersonID(rawValue: row["id"])
        return try PeopleSnapshot.Person(
            id: id,
            name: row["name"],
            birthday: birthday(row["birthday"], of: id),
            isHidden: (row["is_hidden"] as Int) != 0,
            isFavorite: (row["is_favorite"] as Int) != 0
        )
    }

    /// A stored birthday; nil when the person has none. Every write stores a valid one.
    private static func birthday(_ text: String?, of person: PersonID) throws -> PersonBirthday? {
        guard let text else { return nil }
        guard let birthday = PersonBirthday(text) else { throw CatalogStoreError.malformedPersonRow(person) }
        return birthday
    }

    /// What is not yet read for faces (ADR 0047): stills whose stored preview is still to
    /// come, or whose faces were not read from the one they have, and videos of a library or
    /// an Immich account whose frames are not yet read. A Live Photo's movie is not counted: its still holds its faces.
    private static func uncheckedForFaces(rootIDs: [Int64], db: Database) throws -> MediaCount {
        guard !rootIDs.isEmpty else { return MediaCount() }
        let row = try Row.fetchOne(
            db,
            sql: PreviewFaceSQL.uncheckedSQL(rootCount: rootIDs.count),
            arguments: StatementArguments(rootIDs + rootIDs + rootIDs)
        )
        let owed: Int = row?[0] ?? 0
        let awaiting: Int = row?[1] ?? 0
        return MediaCount(photos: owed + awaiting, videos: row?[2] ?? 0)
    }

    /// Stills whose faces are owed from their stored preview (ADR 0047), in every library and
    /// Immich account: the preview's edit is known, and the faces stamp does not name the
    /// source that preview was made from. Videos are never read for faces. In catalog order,
    /// after `cursor`, from the partial index over the stills that owe them, so a catalog with
    /// nothing owed reads no row; a row whose edit cannot be read is passed over and logged.
    func previewFaceCandidates(after cursor: PreviewFaceCursor? = nil, limit: Int) async throws -> PreviewFacePage {
        let rootIDs = roots.values.filter(\.root.kind.readsFaces).map(\.rowID).sorted()
        guard !rootIDs.isEmpty else { return PreviewFacePage(candidates: [], next: nil) }
        let pathsByRowID = roots.pathsByRowID
        let arguments = StatementArguments(rootIDs) + [cursor?.rootID ?? Int64.min, cursor?.relativePath ?? "", limit]
        return try await database().read { db in
            let rows = try Row.fetchAll(db, sql: PreviewFaceSQL.candidatesSQL(rootCount: rootIDs.count), arguments: arguments)
            let candidates = rows.compactMap { row -> PreviewFaceCandidate? in
                guard let root = pathsByRowID[row["library_root_id"]] else { return nil }
                let id = MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: row["relative_path"]))
                let renderedRevision: Int64 = row["rendered_revision"]
                let recipe: EditRecipe
                do {
                    recipe = renderedRevision == 0 ? .neutral : try Self.editRecipe(json: row["edit_recipe_json"]) ?? .neutral
                } catch {
                    OtosLog.metadata.errorOperation("face.preview", phase: "recipeUnreadable", fields: [
                        "relativePath": id.relativePath.rawValue, "error": String(describing: error),
                    ])
                    return nil
                }
                return PreviewFaceCandidate(
                    id: id,
                    previewPath: row["preview_path"],
                    sourceSize: row["preview_source_size"],
                    sourceMTimeSeconds: row["preview_source_mtime"],
                    renderedRevision: renderedRevision,
                    recipe: recipe
                )
            }
            let next = rows.count < limit ? nil : rows.last.map {
                PreviewFaceCursor(rootID: $0["library_root_id"], relativePath: $0["relative_path"])
            }
            return PreviewFacePage(candidates: candidates, next: next)
        }
    }

    /// Writes faces read from stored previews, for rows whose preview is still the one read;
    /// the faces are stamped with the preview's source stamp. Returns the rows written, and
    /// rings the change notifications when any was.
    @discardableResult
    func applyPreviewFaces(_ results: [PreviewFaceResult]) async throws -> Int {
        let rowIDs = roots.rowIDSnapshot()
        let written = try await database().write { db -> Int in
            var written = 0
            for result in results {
                guard let rootID = rowIDs[result.candidate.id.libraryRootPath] else { continue }
                // The preview file's name is the asset's own, so a new rendering keeps it: the
                // source stamp and the edit revision it shows say whether it is the one read.
                let current = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT 1 FROM media_asset
                    WHERE library_root_id = ? AND relative_path = ? AND preview_path IS ?
                      AND (\(PreviewFaceSQL.previewSize)) IS ? AND (\(PreviewFaceSQL.previewMTime)) IS ?
                      AND rendered_revision = ?
                    """,
                    arguments: [
                        rootID, result.candidate.id.relativePath.rawValue, result.candidate.previewPath,
                        result.candidate.sourceSize, result.candidate.sourceMTimeSeconds,
                        result.candidate.renderedRevision,
                    ]
                )
                guard current != nil else { continue }
                try Self.writeFaces(
                    result.faces,
                    stamp: (result.candidate.sourceSize, result.candidate.sourceMTimeSeconds),
                    row: (rootID, result.candidate.id.relativePath),
                    db: db
                )
                written += 1
            }
            return written
        }
        // People and the grid's faces read what was written.
        if written > 0 {
            notifyCatalogChanged(.assetsDetailChanged)
        }
        return written
    }

    /// Writes what one assignment changed (ADR 0047), in one transaction. A lapsed seed is
    /// released only while it is still that person's seed, and a guess or a seed is written
    /// only where the face is still Otos's to decide (none or a guess), so an act the user
    /// made since the snapshot always wins; the next assignment sees it. A new person none of
    /// whose seeds could still be written is not created, and its guesses wait for the next
    /// assignment. A face whose library is no longer cataloged is skipped and counted.
    /// Returns the rows written; zero means the catalog already held the plan.
    @discardableResult
    func applyAssignment(_ plan: FaceAssignmentPlan) async throws -> Int {
        guard !plan.isEmpty else { return 0 }
        let rowIDs = roots.rowIDSnapshot()
        let (written, skipped) = try await database().write { db -> (Int, Int) in
            var written = 0
            var skipped = 0
            var created: [Int: PersonID] = [:]
            let guessable = "assignment IN \(FaceAssignmentColumn.sqlList { $0.isGuessable })"
            let key = { (face: FaceID) -> FaceRowKey? in
                guard let key = try? FaceRowKey(face, rowIDs: rowIDs) else {
                    skipped += 1
                    return nil
                }
                return key
            }
            for (face, person) in plan.lapsedSeeds {
                guard let key = key(face) else { continue }
                try db.execute(
                    sql: """
                    UPDATE face SET person_id = NULL, assignment = ?, is_key_photo = 0
                    WHERE library_root_id = ? AND relative_path = ? AND face_index = ?
                      AND assignment = ? AND person_id = ?
                    """,
                    arguments: [
                        FaceAssignmentColumn.open.rawValue, key.rootID, key.path.rawValue, key.index,
                        FaceAssignmentColumn.seed.rawValue, person.rawValue,
                    ]
                )
                written += db.changesCount
            }
            for (index, seeds) in plan.newPeople.enumerated() {
                let person = try Self.insertPerson(name: nil, birthday: nil, db: db)
                var seeded = 0
                for face in seeds {
                    guard let key = key(face) else { continue }
                    try db.execute(
                        sql: """
                        UPDATE face SET person_id = ?, assignment = ?, is_key_photo = 0
                        WHERE library_root_id = ? AND relative_path = ? AND face_index = ? AND is_not_face = 0 AND \(guessable)
                        """,
                        arguments: [person.rawValue, FaceAssignmentColumn.seed.rawValue, key.rootID, key.path.rawValue, key.index]
                    )
                    seeded += db.changesCount
                }
                if seeded > 0 {
                    created[index] = person
                    written += 1 + seeded
                } else {
                    try db.execute(sql: "DELETE FROM person WHERE id = ?", arguments: [person.rawValue])
                }
            }
            for guess in plan.guesses {
                let person: PersonID?
                switch guess.person {
                case let .existing(id): person = id
                case let .new(index):
                    guard let id = created[index] else { continue }
                    person = id
                case nil: person = nil
                }
                guard let key = key(guess.face) else { continue }
                try db.execute(
                    sql: """
                    UPDATE face SET person_id = ?, assignment = ?,
                        is_key_photo = CASE WHEN person_id IS ? THEN is_key_photo ELSE 0 END
                    WHERE library_root_id = ? AND relative_path = ? AND face_index = ? AND is_not_face = 0 AND \(guessable)
                      AND (? IS NULL OR EXISTS (SELECT 1 FROM person WHERE id = ?))
                    """,
                    arguments: [
                        person?.rawValue, (person == nil ? FaceAssignmentColumn.open : .model).rawValue, person?.rawValue,
                        key.rootID, key.path.rawValue, key.index, person?.rawValue, person?.rawValue,
                    ]
                )
                written += db.changesCount
            }
            for (face, likeness) in plan.likeness {
                guard let key = key(face) else { continue }
                try db.execute(
                    sql: "UPDATE face SET likeness = ? WHERE library_root_id = ? AND relative_path = ? AND face_index = ?",
                    arguments: [likeness.map { Double($0) }, key.rootID, key.path.rawValue, key.index]
                )
                written += db.changesCount
            }
            for person in plan.emptied {
                try db.execute(
                    sql: """
                    DELETE FROM person WHERE id = ? AND name IS NULL AND birthday IS NULL
                      AND is_hidden = 0 AND is_favorite = 0
                      AND NOT EXISTS (SELECT 1 FROM face WHERE person_id = ?)
                    """,
                    arguments: [person.rawValue, person.rawValue]
                )
                written += db.changesCount
            }
            return (written, skipped)
        }
        if written > 0 {
            notifyCatalogChanged()
        }
        OtosLog.catalog.debugOperation("people.applyAssignment", phase: "applied", fields: [
            "guesses": "\(plan.guesses.count)", "newPeople": "\(plan.newPeople.count)",
            "likeness": "\(plan.likeness.count)", "emptied": "\(plan.emptied.count)",
            "lapsedSeeds": "\(plan.lapsedSeeds.count)", "rows": "\(written)", "skippedFaces": "\(skipped)",
        ])
        return written
    }

    /// The one write path for what the user decides about faces and people (ADR 0047):
    /// performs one act in one transaction and returns what undoes it, with the person the
    /// act gave the faces to (for a merge, the person merged into). A refused act (a hard rule, `PeopleRuleViolation`) changes
    /// nothing.
    func perform(_ act: PeopleAct) async throws -> PeopleActOutcome {
        let rowIDs = roots.rowIDSnapshot()
        let pathsByRowID = roots.pathsByRowID
        let applied = try await database().write { db -> (restore: PeopleRestore, person: PersonID?) in
            let key = { (face: FaceID) throws -> FaceRowKey in try FaceRowKey(face, rowIDs: rowIDs) }
            let touched = try Self.touched(by: act, rowIDs: rowIDs, db: db)
            let before = try Self.restoreRecord(faces: touched.faces, people: touched.people, pathsByRowID: pathsByRowID, db: db)
            var created: [PersonID] = []
            var given: PersonID?
            switch act {
            case let .move(faces, person):
                given = person
                try Self.give(faces.map(key), to: person, db: db)
            case let .moveToNewPerson(faces, name, birthday):
                let keys = try faces.map(key)
                guard Set(keys.map(\.photo)).count == keys.count else { throw PeopleRuleViolation.twoFacesOfOnePhoto }
                if let name, try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM person WHERE name = ?", arguments: [name]) ?? 0 > 0 {
                    throw PeopleRuleViolation.nameTaken
                }
                let person = try Self.insertPerson(name: name, birthday: birthday, db: db)
                created.append(person)
                given = person
                try Self.give(keys, to: person, db: db)
            case let .removeName(faces):
                for face in try faces.map(key) {
                    try db.execute(
                        sql: """
                        INSERT OR IGNORE INTO face_rejection (library_root_id, relative_path, face_index, person_id)
                        SELECT library_root_id, relative_path, face_index, person_id FROM face
                        WHERE library_root_id = ? AND relative_path = ? AND face_index = ? AND person_id IS NOT NULL
                        """,
                        arguments: [face.rootID, face.path.rawValue, face.index]
                    )
                    try Self.setFace(face, person: nil, assignment: .held, db: db)
                }
            case let .notAFace(faces):
                for face in try faces.map(key) {
                    try Self.setFace(face, person: nil, assignment: .open, db: db)
                    try db.execute(
                        sql: "UPDATE face SET is_not_face = 1 WHERE library_root_id = ? AND relative_path = ? AND face_index = ?",
                        arguments: [face.rootID, face.path.rawValue, face.index]
                    )
                }
            case let .edit(person, name, birthday):
                try Self.updatePerson(person, name: name, birthday: birthday, db: db)
            case let .merge(from, into):
                given = into
                try Self.mergePerson(from, into: into, db: db)
            case let .setHidden(person, hidden):
                try db.execute(sql: "UPDATE person SET is_hidden = ? WHERE id = ?", arguments: [hidden ? 1 : 0, person.rawValue])
            case let .setFavorite(person, favorite):
                try db.execute(sql: "UPDATE person SET is_favorite = ? WHERE id = ?", arguments: [favorite ? 1 : 0, person.rawValue])
            case let .makeKeyPhoto(face, person):
                // Choosing a face as a person's cover is the user's word that it is them: the
                // face becomes theirs on the user's word, so a re-read carries the key photo
                // and assignment never moves it (ADR 0047).
                let face = try key(face)
                guard try Int64.fetchOne(
                    db,
                    sql: "SELECT person_id FROM face WHERE library_root_id = ? AND relative_path = ? AND face_index = ?",
                    arguments: [face.rootID, face.path.rawValue, face.index]
                ) == person.rawValue else { throw PeopleRuleViolation.unknownFace }
                try Self.give([face], to: person, db: db)
                try db.execute(sql: "UPDATE face SET is_key_photo = 0 WHERE person_id = ?", arguments: [person.rawValue])
                try db.execute(
                    sql: "UPDATE face SET is_key_photo = 1 WHERE library_root_id = ? AND relative_path = ? AND face_index = ?",
                    arguments: [face.rootID, face.path.rawValue, face.index]
                )
            }
            var people = before.people
            for person in created {
                people[person] = .some(nil)
            }
            return (PeopleRestore(people: people, faces: before.faces, rejections: before.rejections), given)
        }
        let outcome = PeopleActOutcome(restore: applied.restore, person: applied.person)
        notifyCatalogChanged()
        OtosLog.catalog.noticeOperation("people.act", phase: "applied", fields: [
            "act": act.logName, "faces": "\(act.faceCount)",
        ])
        return outcome
    }

    /// Writes back what an act changed, undoing it, and returns what redoes the undo: the
    /// state the restore replaced.
    @discardableResult
    func restore(_ restore: PeopleRestore) async throws -> PeopleRestore {
        let rowIDs = roots.rowIDSnapshot()
        let pathsByRowID = roots.pathsByRowID
        let redo = try await database().write { db -> PeopleRestore in
            let faceKeys = restore.faces.compactMap { try? FaceRowKey($0.face, rowIDs: rowIDs) }
            let people = Array(restore.people.keys)
            let current = try Self.restoreRecord(faces: faceKeys, people: people, pathsByRowID: pathsByRowID, db: db)
            // People first, so the faces and rejections below can name them.
            for (id, person) in restore.people {
                if let person {
                    try db.execute(
                        sql: """
                        INSERT INTO person (id, name, birthday, is_hidden, is_favorite) VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET name = excluded.name, birthday = excluded.birthday,
                            is_hidden = excluded.is_hidden, is_favorite = excluded.is_favorite
                        """,
                        arguments: [id.rawValue, person.name, person.birthday?.text, person.isHidden ? 1 : 0, person.isFavorite ? 1 : 0]
                    )
                }
            }
            // A person holds one key photo: clear theirs before writing back the one the
            // record holds.
            for row in restore.faces where row.isKeyPhoto {
                if let person = row.assignment.person {
                    try db.execute(sql: "UPDATE face SET is_key_photo = 0 WHERE person_id = ?", arguments: [person.rawValue])
                }
            }
            for row in restore.faces {
                guard let key = try? FaceRowKey(row.face, rowIDs: rowIDs) else { continue }
                try db.execute(
                    sql: """
                    UPDATE face SET person_id = ?, assignment = ?, is_not_face = ?, is_key_photo = ?
                    WHERE library_root_id = ? AND relative_path = ? AND face_index = ?
                    """,
                    arguments: [row.assignment.person?.rawValue, FaceAssignmentColumn(row.assignment).rawValue,
                                row.isNotFace ? 1 : 0, row.isKeyPhoto ? 1 : 0, key.rootID, key.path.rawValue, key.index]
                )
            }
            try Self.deleteRejections(faces: faceKeys, people: people, db: db)
            for rejection in restore.rejections {
                guard let key = try? FaceRowKey(rejection.face, rowIDs: rowIDs) else { continue }
                // A face a new reading replaced is gone, and so is what was decided about it.
                try db.execute(
                    sql: """
                    INSERT OR IGNORE INTO face_rejection (library_root_id, relative_path, face_index, person_id)
                    SELECT ?, ?, ?, ? WHERE EXISTS (
                        SELECT 1 FROM face WHERE library_root_id = ? AND relative_path = ? AND face_index = ?
                    ) AND EXISTS (SELECT 1 FROM person WHERE id = ?)
                    """,
                    arguments: [key.rootID, key.path.rawValue, key.index, rejection.person.rawValue,
                                key.rootID, key.path.rawValue, key.index, rejection.person.rawValue]
                )
            }
            // People the act created go last: deleting one clears what it held.
            for (id, person) in restore.people where person == nil {
                try db.execute(sql: "DELETE FROM person WHERE id = ?", arguments: [id.rawValue])
            }
            // A person the act created exists now, so the redo re-creates them; a person it
            // removed does not, so the redo removes them again.
            return current
        }
        notifyCatalogChanged()
        return redo
    }

    // MARK: People writes inside one transaction

    private static func insertPerson(name: String?, birthday: PersonBirthday?, db: Database) throws -> PersonID {
        try db.execute(sql: "INSERT INTO person (name, birthday) VALUES (?, ?)", arguments: [name, birthday?.text])
        return PersonID(rawValue: db.lastInsertedRowID)
    }

    /// Rename, Add Name and Set Birthday. A name another person holds is refused: the two
    /// are merged instead. A birthday after a photo the user gave the person is refused;
    /// Otos's own guesses and seeds from before it lose the person, and assignment gives
    /// those faces to someone else (`holdToBirthday`).
    private static func updatePerson(_ person: PersonID, name: String?, birthday: PersonBirthday?, db: Database) throws {
        if let name, try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM person WHERE name = ? AND id <> ?",
            arguments: [name, person.rawValue]
        ) ?? 0 > 0 {
            throw PeopleRuleViolation.nameTaken
        }
        try holdToBirthday(birthday, faces: [person], db: db)
        try db.execute(
            sql: "UPDATE person SET name = ?, birthday = ? WHERE id = ?",
            arguments: [name, birthday?.text, person.rawValue]
        )
    }

    /// The birthday rule on the faces of `people`, who are to have `birthday` (ADR 0047): a face
    /// from before it is never theirs. Refused when the user gave one of them such a face;
    /// every other such face, Otos's guess or seed, loses its person, for assignment to give
    /// out again. The one statement of the rule for Set Birthday and for a merge.
    private static func holdToBirthday(_ birthday: PersonBirthday?, faces people: [PersonID], db: Database) throws {
        guard let birthdaySeconds = birthday?.seconds, !people.isEmpty else { return }
        let placeholders = Array(repeating: "?", count: people.count).joined(separator: ", ")
        let before = """
        FROM face f
        JOIN media_asset m ON m.library_root_id = f.library_root_id AND m.relative_path = f.relative_path
        WHERE f.person_id IN (\(placeholders)) AND m.best_capture_local < ?
        """
        let arguments = StatementArguments(people.map(\.rawValue)) + [birthdaySeconds]
        let earlier = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) \(before) AND f.assignment = \(FaceAssignmentColumn.user.rawValue)",
            arguments: arguments
        ) ?? 0
        guard earlier == 0 else { throw PeopleRuleViolation.confirmedBeforeBirthday(count: earlier) }
        try db.execute(
            sql: """
            UPDATE face SET person_id = NULL, assignment = \(FaceAssignmentColumn.open.rawValue), is_key_photo = 0
            WHERE (library_root_id, relative_path, face_index) IN (
                SELECT f.library_root_id, f.relative_path, f.face_index \(before)
            )
            """,
            arguments: arguments
        )
    }

    /// Gives faces to a person on the user's word. Refused for two faces of one photo, a
    /// photo where the user already gave another face to the person, or a photo from before
    /// their birthday. Another face of the photo Otos had given the person loses them.
    private static func give(_ keys: [FaceRowKey], to person: PersonID, db: Database) throws {
        guard Set(keys.map(\.photo)).count == keys.count else { throw PeopleRuleViolation.twoFacesOfOnePhoto }
        guard let row = try Row.fetchOne(db, sql: "SELECT birthday FROM person WHERE id = ?", arguments: [person.rawValue]) else {
            throw PeopleRuleViolation.unknownFace
        }
        let birthday = try Self.birthday(row["birthday"], of: person)?.seconds
        for key in keys {
            let others = try Int.fetchAll(
                db,
                sql: """
                SELECT assignment FROM face WHERE library_root_id = ? AND relative_path = ?
                  AND person_id = ? AND face_index <> ?
                """,
                arguments: [key.rootID, key.path.rawValue, person.rawValue, key.index]
            )
            guard !others.contains(FaceAssignmentColumn.user.rawValue) else { throw PeopleRuleViolation.personAlreadyInPhoto }
            if let birthday, let capture = try Double.fetchOne(
                db,
                sql: "SELECT best_capture_local FROM media_asset WHERE library_root_id = ? AND relative_path = ?",
                arguments: [key.rootID, key.path.rawValue]
            ), capture < birthday {
                throw PeopleRuleViolation.beforeBirthday
            }
        }
        for key in keys {
            try db.execute(
                sql: """
                UPDATE face SET person_id = NULL, assignment = \(FaceAssignmentColumn.open.rawValue), is_key_photo = 0
                WHERE library_root_id = ? AND relative_path = ? AND person_id = ? AND face_index <> ?
                """,
                arguments: [key.rootID, key.path.rawValue, person.rawValue, key.index]
            )
            try setFace(key, person: person, assignment: .user, db: db)
            try db.execute(
                sql: """
                DELETE FROM face_rejection WHERE library_root_id = ? AND relative_path = ?
                  AND face_index = ? AND person_id = ?
                """,
                arguments: [key.rootID, key.path.rawValue, key.index, person.rawValue]
            )
        }
    }

    /// Sets a face's person and whose word it is; a face that changes person stops being its
    /// old person's key photo.
    private static func setFace(_ key: FaceRowKey, person: PersonID?, assignment: FaceAssignmentColumn, db: Database) throws {
        try db.execute(
            sql: """
            UPDATE face SET is_key_photo = CASE WHEN person_id IS ? THEN is_key_photo ELSE 0 END,
                person_id = ?, assignment = ?
            WHERE library_root_id = ? AND relative_path = ? AND face_index = ?
            """,
            arguments: [person?.rawValue, person?.rawValue, assignment.rawValue, key.rootID, key.path.rawValue, key.index]
        )
    }

    /// The first person's faces become the second's. Refused when the user gave both a face
    /// of one photo, or gave either a photo from before the merged birthday; Otos's guesses and
    /// seeds from before it lose their person (`holdToBirthday`). Where Otos had guessed both
    /// into one photo, the guesses there are dropped for assignment to redo.
    /// The second keeps its name, birthday and key photo, taking the first's where it
    /// has none, and is a favourite if either was.
    private static func mergePerson(_ from: PersonID, into: PersonID, db: Database) throws {
        let anchors = FaceAssignmentColumn.sqlList { $0.isAnchor }
        let shared = try Int.fetchOne(
            db,
            sql: """
            SELECT COUNT(*) FROM face a JOIN face b
              ON a.library_root_id = b.library_root_id AND a.relative_path = b.relative_path
            WHERE a.person_id = ? AND b.person_id = ? AND a.assignment IN \(anchors) AND b.assignment IN \(anchors)
            """,
            arguments: [from.rawValue, into.rawValue]
        ) ?? 0
        guard shared == 0 else { throw PeopleRuleViolation.bothInPhotos(count: shared) }
        guard let target = try Row.fetchOne(db, sql: "SELECT * FROM person WHERE id = ?", arguments: [into.rawValue]).map(person),
              let source = try Row.fetchOne(db, sql: "SELECT * FROM person WHERE id = ?", arguments: [from.rawValue]).map(person)
        else {
            throw PeopleRuleViolation.unknownFace
        }
        let birthday = target.birthday ?? source.birthday
        try holdToBirthday(birthday, faces: [from, into], db: db)
        // Guesses of either in a photo the other is in.
        try db.execute(
            sql: """
            UPDATE face SET person_id = NULL, assignment = \(FaceAssignmentColumn.open.rawValue), is_key_photo = 0
            WHERE assignment = \(FaceAssignmentColumn.model.rawValue) AND person_id IN (?, ?) AND EXISTS (
                SELECT 1 FROM face other WHERE other.library_root_id = face.library_root_id
                  AND other.relative_path = face.relative_path AND other.face_index <> face.face_index
                  AND other.person_id IN (?, ?) AND other.person_id <> face.person_id
            )
            """,
            arguments: [from.rawValue, into.rawValue, from.rawValue, into.rawValue]
        )
        let targetHasKeyPhoto = try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM face WHERE person_id = ? AND is_key_photo = 1", arguments: [into.rawValue]
        ) ?? 0 > 0
        if targetHasKeyPhoto {
            try db.execute(sql: "UPDATE face SET is_key_photo = 0 WHERE person_id = ?", arguments: [from.rawValue])
        }
        try db.execute(sql: "UPDATE face SET person_id = ? WHERE person_id = ?", arguments: [into.rawValue, from.rawValue])
        try db.execute(
            sql: """
            INSERT OR IGNORE INTO face_rejection (library_root_id, relative_path, face_index, person_id)
            SELECT library_root_id, relative_path, face_index, ? FROM face_rejection WHERE person_id = ?
            """,
            arguments: [into.rawValue, from.rawValue]
        )
        try db.execute(sql: "DELETE FROM person WHERE id = ?", arguments: [from.rawValue])
        try db.execute(
            sql: "UPDATE person SET name = ?, birthday = ?, is_favorite = ? WHERE id = ?",
            arguments: [target.name ?? source.name, birthday?.text, target.isFavorite || source.isFavorite ? 1 : 0, into.rawValue]
        )
    }

    /// The faces and people an act can change: every face of the photos it names, and every
    /// face of a person it merges or edits.
    private static func touched(
        by act: PeopleAct,
        rowIDs: [LibraryRootPath: Int64],
        db: Database
    ) throws -> (faces: [FaceRowKey], people: [PersonID]) {
        func faces(of people: [PersonID]) throws -> [FaceRowKey] {
            try people.flatMap { person in
                try Row.fetchAll(
                    db,
                    sql: "SELECT library_root_id, relative_path, face_index FROM face WHERE person_id = ?",
                    arguments: [person.rawValue]
                ).map(FaceRowKey.init)
            }
        }
        func photos(_ faces: [FaceID]) throws -> [FaceRowKey] {
            try photosOf(faces.map { try FaceRowKey($0, rowIDs: rowIDs) })
        }
        func photosOf(_ keys: [FaceRowKey]) throws -> [FaceRowKey] {
            try Set(keys.map(\.photo)).flatMap { photo in
                try Row.fetchAll(
                    db,
                    sql: "SELECT library_root_id, relative_path, face_index FROM face WHERE library_root_id = ? AND relative_path = ?",
                    arguments: [photo.rootID, photo.path.rawValue]
                ).map(FaceRowKey.init)
            }
        }
        func people(of keys: [FaceRowKey]) throws -> [PersonID] {
            try keys.compactMap { key in
                try Int64.fetchOne(
                    db,
                    sql: "SELECT person_id FROM face WHERE library_root_id = ? AND relative_path = ? AND face_index = ?",
                    arguments: [key.rootID, key.path.rawValue, key.index]
                ).map(PersonID.init(rawValue:))
            }
        }
        func keyPhotos(of people: [PersonID]) throws -> [FaceRowKey] {
            try people.flatMap { person in
                try Row.fetchAll(
                    db,
                    sql: "SELECT library_root_id, relative_path, face_index FROM face WHERE person_id = ? AND is_key_photo = 1",
                    arguments: [person.rawValue]
                ).map(FaceRowKey.init)
            }
        }
        switch act {
        case let .move(named, person):
            let keys = try photos(named)
            let involved = try [person] + people(of: keys)
            return try (keys + keyPhotos(of: involved), involved)
        case let .moveToNewPerson(named, _, _), let .removeName(named), let .notAFace(named):
            let keys = try photos(named)
            let involved = try people(of: keys)
            return try (keys + keyPhotos(of: involved), involved)
        case let .edit(person, _, _):
            return try (faces(of: [person]), [person])
        case let .merge(from, into):
            return try (photosOf(faces(of: [from, into])), [from, into])
        case let .setHidden(person, _), let .setFavorite(person, _):
            return ([], [person])
        case let .makeKeyPhoto(face, person):
            return try ([FaceRowKey(face, rowIDs: rowIDs)] + keyPhotos(of: [person]), [person])
        }
    }

    /// The rows `faces` and `people` hold now, and every rejection naming either.
    private static func restoreRecord(
        faces keys: [FaceRowKey],
        people: [PersonID],
        pathsByRowID: [Int64: LibraryRootPath],
        db: Database
    ) throws -> PeopleRestore {
        func faceID(_ key: FaceRowKey) -> FaceID? {
            pathsByRowID[key.rootID].map { FaceID(asset: MediaAssetID(libraryRootPath: $0, relativePath: key.path), index: key.index) }
        }
        var rows: [PeopleRestore.FaceRow] = []
        var rejections: Set<PeopleRestore.Rejection> = []
        for key in Set(keys) {
            guard let id = faceID(key), let row = try Row.fetchOne(
                db,
                sql: """
                SELECT person_id, assignment, is_not_face, is_key_photo FROM face
                WHERE library_root_id = ? AND relative_path = ? AND face_index = ?
                """,
                arguments: [key.rootID, key.path.rawValue, key.index]
            ) else { continue }
            try rows.append(PeopleRestore.FaceRow(
                face: id,
                assignment: FaceAssignmentColumn.assignment(column: row["assignment"], person: row["person_id"]),
                isNotFace: (row["is_not_face"] as Int) != 0,
                isKeyPhoto: (row["is_key_photo"] as Int) != 0
            ))
            for person in try Int64.fetchAll(
                db,
                sql: "SELECT person_id FROM face_rejection WHERE library_root_id = ? AND relative_path = ? AND face_index = ?",
                arguments: [key.rootID, key.path.rawValue, key.index]
            ) {
                rejections.insert(.init(face: id, person: PersonID(rawValue: person)))
            }
        }
        var record: [PersonID: PeopleSnapshot.Person?] = [:]
        for person in Set(people) {
            let row = try Row.fetchOne(db, sql: "SELECT * FROM person WHERE id = ?", arguments: [person.rawValue])
            // `.some(nil)` keeps a missing person in the record: a plain nil would drop the key,
            // and the restore would forget to remove them.
            record[person] = try .some(row.map(Self.person))
            for row in try Row.fetchAll(
                db,
                sql: "SELECT library_root_id, relative_path, face_index FROM face_rejection WHERE person_id = ?",
                arguments: [person.rawValue]
            ) {
                if let id = faceID(FaceRowKey(row)) {
                    rejections.insert(.init(face: id, person: person))
                }
            }
        }
        return PeopleRestore(people: record, faces: rows, rejections: rejections)
    }

    /// Deletes every rejection naming one of `faces` or one of `people`: the scope a
    /// `PeopleRestore` records.
    private static func deleteRejections(faces keys: [FaceRowKey], people: [PersonID], db: Database) throws {
        for key in keys {
            try db.execute(
                sql: "DELETE FROM face_rejection WHERE library_root_id = ? AND relative_path = ? AND face_index = ?",
                arguments: [key.rootID, key.path.rawValue, key.index]
            )
        }
        for person in people {
            try db.execute(sql: "DELETE FROM face_rejection WHERE person_id = ?", arguments: [person.rawValue])
        }
    }

    func skippedPackageCount(for rootPath: LibraryRootPath) -> Int {
        roots[rootPath]?.skippedPackageCount ?? 0
    }

    /// `dayBuckets` is empty unless `descriptor.effectiveSort.field == .bestDate`
    /// (day-contiguity — and so grouping — only holds under that sort), else
    /// index-paired with the returned IDs (DES-069; see
    /// `CatalogMediaGridState.dayBuckets`).
    func orderedAssetIDs(
        for descriptor: CatalogQueryDescriptor,
        availableLibraryPaths: Set<LibraryRootPath>
    ) async throws -> CatalogOrderedAssets {
        let scope = scopePredicate(selection: descriptor.scope, availableLibraryPaths: availableLibraryPaths)
        guard !scope.selectsNothing else {
            var fields = [
                "scope": String(describing: descriptor.scope),
                "availablePaths": "\(availableLibraryPaths.count)",
            ]
            if case let .library(path) = descriptor.scope {
                fields["pathAvailable"] = "\(availableLibraryPaths.contains(path))"
                fields["pathRegistered"] = "\(roots[path] != nil)"
            }
            OtosLog.catalog.noticeOperation("catalog.store.query.order", phase: "selectsNothing", fields: fields)
            let pending = try await database().read { db in
                try Self.fetchPendingIdentityRemapBatches(db: db)
            }
            return CatalogOrderedAssets(ids: [], dayBuckets: [], pendingIdentityRemaps: pending)
        }

        let signpost = OtosSignpost.persistence.beginInterval("CatalogStoreOrderedAssetIDQuery")
        let dbWriter = try database()
        // The stacks are built in the read, before its rows: On This Day's match judges a
        // year's rows by them (`OnThisDayPicks.shows`), and every stack and row then comes
        // from one snapshot (ADR 0052).
        let stackRootPaths = roots.pathsByRowID.filter { rowID, path in
            scope.rootIDs.contains(rowID) && availableLibraryPaths.contains(path)
        }
        // One read transaction: a row this read sees under a new identity always comes
        // with the pending batch that renamed it (ARC-052).
        let timedRows = try await timedRead(dbWriter) { db in
            let stacks = try PhotoStackSQL.build(rootPaths: stackRootPaths, db: db)
            return try (
                rows: CatalogQueryGateway.fetchOrderedAssetIDRows(
                    descriptor: descriptor,
                    scope: scope,
                    stacks: .built(stacks),
                    db: db
                ),
                pending: Self.fetchPendingIdentityRemapBatches(db: db),
                stacks: stacks
            )
        }
        OtosSignpost.persistence.endInterval("CatalogStoreOrderedAssetIDQuery", signpost)

        let validRootPathsByRowID = roots.pathsByRowID.filter { rowID, path in
            scope.rootIDs.contains(rowID) && availableLibraryPaths.contains(path)
        }
        let groupsByDate = descriptor.effectiveSort.field == .bestDate
        // On This Day shows each day's Liked photos first (`OnThisDayPicks`).
        let orderedRows = scope.isAnniversary
            ? OnThisDayPicks.likedFirst(timedRows.value.rows)
            : timedRows.value.rows
        var ids: [MediaAssetID] = []
        var dayBuckets: [Date?] = []
        var dayStarts: [Int: Date] = [:]
        var coordinates: [PlaceCoordinate] = []
        ids.reserveCapacity(orderedRows.count)
        if groupsByDate {
            dayBuckets.reserveCapacity(orderedRows.count)
        }
        if scope.requiresLocation {
            coordinates.reserveCapacity(orderedRows.count)
        }
        for row in orderedRows {
            guard let rootPath = validRootPathsByRowID[row.libraryRootID] else {
                continue
            }
            if scope.requiresLocation {
                // The join guarantees a location on every row; a row without one would be
                // a query defect, not an item without a place, so it is not shown.
                guard let coordinate = row.coordinate else {
                    OtosLog.catalog.errorOperation("catalog.store.query.order", phase: "locationMissing", fields: [
                        "path": row.relativePath.rawValue,
                    ])
                    continue
                }
                coordinates.append(coordinate)
            }
            ids.append(MediaAssetID(libraryRootPath: rootPath, relativePath: row.relativePath))
            if groupsByDate {
                // The day the item was taken on (`CaptureLocalTime.dayNumber`), as the start
                // of that day here, which is what the header formats. A day's start is made
                // once per day, not once per row.
                dayBuckets.append(row.captureLocalTime.map { local in
                    let day = local.dayNumber
                    if let start = dayStarts[day] {
                        return start
                    }
                    let start = Calendar.current.startOfDay(for: CaptureLocalTime(dayNumber: day).presentationDate())
                    dayStarts[day] = start
                    return start
                })
            }
        }
        let queryMs = timedRows.totalMs
        // The log reports the stacks' read and rule apart from the order's own work (ADR 0052).
        let builtStacks = timedRows.value.stacks
        let catalogStacks = builtStacks.stacks
        // On This Day judges a stack by its key: the SQL left out a Disliked key's row, and
        // its RAW twin or its burst's other frames leave with it (`OnThisDayPicks.shows`, the
        // rule its years-or-months match asks too).
        if scope.isAnniversary, !catalogStacks.stacks.isEmpty {
            let kept = ids.indices.filter { OnThisDayPicks.shows(ids[$0], stacks: catalogStacks) }
            if kept.count != ids.count {
                ids = kept.map { ids[$0] }
                // Each is empty or index-paired with the order.
                dayBuckets = dayBuckets.isEmpty ? [] : kept.map { dayBuckets[$0] }
                coordinates = coordinates.isEmpty ? [] : kept.map { coordinates[$0] }
            }
        }
        OtosLog.catalog.debug(
            """
            Catalog ordered asset IDs queried descriptor=\(descriptor.diagnosticDescription, privacy: .public) \
            roots=\(scope.rootIDs.count, privacy: .public) count=\(ids.count, privacy: .public) \
            waitMs=\(timedRows.waitMs, privacy: .public) \
            execMs=\(timedRows.execMs, privacy: .public) queryMs=\(queryMs, privacy: .public)
            """
        )
        if case let .anniversary(day) = scope.date {
            OtosLog.catalog.noticeOperation("onThisDay.query", phase: "finish", fields: [
                "day": day.diagnosticDescription,
                "count": "\(ids.count)",
                "queryMs": "\(queryMs)",
            ])
        }
        OtosLog.catalog.notice(
            "op=catalog.store.query.order phase=finish descriptor=\(descriptor.diagnosticDescription, privacy: .public) rootCount=\(scope.rootIDs.count, privacy: .public) count=\(ids.count, privacy: .public) stackCandidates=\(builtStacks.candidateCount, privacy: .public) stackReadMs=\(DiagnosticsTiming.milliseconds(builtStacks.readDuration), privacy: .public) stackRuleMs=\(DiagnosticsTiming.milliseconds(builtStacks.ruleDuration), privacy: .public) waitMs=\(timedRows.waitMs, privacy: .public) execMs=\(timedRows.execMs, privacy: .public) queryMs=\(queryMs, privacy: .public)"
        )
        return CatalogOrderedAssets(
            ids: ids,
            dayBuckets: dayBuckets,
            coordinates: coordinates,
            pendingIdentityRemaps: timedRows.value.pending,
            stacks: catalogStacks
        )
    }

    func orderedAssetIDs(
        for selection: SidebarSelection,
        availableLibraryPaths: Set<LibraryRootPath>
    ) async throws -> [MediaAssetID] {
        try await orderedAssetIDs(
            for: CatalogQueryDescriptor(scope: selection),
            availableLibraryPaths: availableLibraryPaths
        ).ids
    }

    /// Rows this scope holds regardless of whether their roots are reachable right
    /// now. Projection compares it against the visible count to tell "nothing was
    /// ever here" from "its libraries are offline", so it deliberately resolves
    /// against every known root.
    func catalogedAssetCount(for selection: SidebarSelection) async throws -> Int {
        let scope = scopePredicate(selection: selection, availableLibraryPaths: Set(roots.keys))
        guard !scope.selectsNothing else {
            return 0
        }
        let dbWriter = try database()
        let timedCount = try await timedRead(dbWriter) { db in
            try CatalogQueryGateway.countAssets(scope: scope, db: db)
        }
        OtosLog.catalog.notice(
            "op=catalog.store.query.catalogedCount phase=finish selection=\(selection.diagnosticDescription, privacy: .public) rootCount=\(scope.rootIDs.count, privacy: .public) count=\(timedCount.value, privacy: .public) waitMs=\(timedCount.waitMs, privacy: .public) execMs=\(timedCount.execMs, privacy: .public) queryMs=\(timedCount.totalMs, privacy: .public)"
        )
        return timedCount.value
    }

    /// Rows this scope holds in currently reachable roots, under `filter` (the default
    /// ignores the user filter). Projection uses the unfiltered count to tell an empty
    /// scope from a scope the filter emptied, and the filtered All Media count to say
    /// how many items the Places map leaves out (ADR 0040).
    func visibleAssetCount(
        for selection: SidebarSelection,
        filter: MediaFilter = .all,
        availableLibraryPaths: Set<LibraryRootPath>
    ) async throws -> Int {
        let scope = scopePredicate(selection: selection, availableLibraryPaths: availableLibraryPaths)
        guard !scope.selectsNothing else {
            return 0
        }
        let dbWriter = try database()
        let timedCount = try await timedRead(dbWriter) { db in
            try CatalogQueryGateway.countAssets(scope: scope, filter: filter, db: db)
        }
        OtosLog.catalog.notice(
            "op=catalog.store.query.visibleCount phase=finish selection=\(selection.diagnosticDescription, privacy: .public) filtered=\(filter.isActive, privacy: .public) rootCount=\(scope.rootIDs.count, privacy: .public) count=\(timedCount.value, privacy: .public) waitMs=\(timedCount.waitMs, privacy: .public) execMs=\(timedCount.execMs, privacy: .public) queryMs=\(timedCount.totalMs, privacy: .public)"
        )
        return timedCount.value
    }

    /// The file types and places the filter popover offers when the window shows
    /// `selection`: those present in the scope of its sidebar row (`SidebarSelection.sidebarRow`),
    /// so a library offers only what it holds and a leaf offers what its row does
    /// (`CatalogFilterOptions`). Places are offered only while the catalog holds names in one
    /// language, `placeNameLanguages` being the languages it holds (`placeNameLanguages()`).
    func filterOptions(
        for selection: SidebarSelection,
        availableLibraryPaths: Set<LibraryRootPath>,
        placeNameLanguages: Set<PlaceNameLanguage>
    ) async throws -> CatalogFilterOptions {
        let row = selection.sidebarRow
        let scope = scopePredicate(selection: row, availableLibraryPaths: availableLibraryPaths)
        guard !scope.selectsNothing else {
            return .empty
        }
        let language = placeNameLanguages.count == 1 ? placeNameLanguages.first : nil
        let dbWriter = try database()
        let timedOptions = try await timedRead(dbWriter) { db in
            try CatalogQueryGateway.filterOptions(scope: scope, placeNameLanguage: language, db: db)
        }
        OtosLog.catalog.notice(
            "op=catalog.store.query.filterOptions phase=finish row=\(row.diagnosticDescription, privacy: .public) rootCount=\(scope.rootIDs.count, privacy: .public) kindCount=\(timedOptions.value.formatsByKind.count, privacy: .public) formatCount=\(timedOptions.value.formatsByKind.values.reduce(0) { $0 + $1.count }, privacy: .public) countryCount=\(timedOptions.value.countries.count, privacy: .public) placeLanguage=\(language?.identifier ?? "none", privacy: .public) waitMs=\(timedOptions.waitMs, privacy: .public) execMs=\(timedOptions.execMs, privacy: .public) queryMs=\(timedOptions.totalMs, privacy: .public)"
        )
        return timedOptions.value
    }

    /// The languages the catalog holds place names in (ADR 0051): one once the reader has
    /// forgotten the others, none before anything is named. A held place filter lives only
    /// while its language is among them (`MediaFilter.keepingPlaces(namedIn:)`).
    func placeNameLanguages() async throws -> Set<PlaceNameLanguage> {
        try await database().read { db in
            try Set(String.fetchAll(db, sql: CatalogQueryGateway.placeNameLanguagesSQL).map(PlaceNameLanguage.init(identifier:)))
        }
    }

    // MARK: - Place names (ADR 0040)

    /// Cells of the map holding a located item that Maps has not named in `language` yet,
    /// in cell order after `after` (from the first when nil), at most `limit`. Every located
    /// item counts, wherever it is cataloged, so a card's photos are named before they are
    /// imported. Walks `idx_asset_metadata_place_cell`.
    func unnamedPlaceCells(language: PlaceNameLanguage, after: PlaceCell? = nil, limit: Int) async throws -> [PlaceCell] {
        try await database().read { db in
            try Row.fetchAll(
                db,
                sql: CatalogQueryGateway.unnamedPlaceCellsSQL(after: after != nil),
                arguments: StatementArguments(
                    (after.map { [$0.latitude, $0.longitude] as [any DatabaseValueConvertible] } ?? [])
                        + [language.identifier, limit]
                )
            ).map { PlaceCell(latitude: $0["place_cell_latitude"], longitude: $0["place_cell_longitude"]) }
        }
    }

    /// Stores what Maps named each cell in `language`. Only an answer reaches here, never a
    /// failed naming (`PlaceNameReader`), so a stored name is only ever replaced by another
    /// answer. A catalog change: the Places filter offers what was named.
    func applyPlaceNames(_ names: [PlaceCell: PlaceNames], language: PlaceNameLanguage) async throws {
        guard !names.isEmpty else { return }
        try await database().write { db in
            for (cell, name) in names {
                try db.execute(
                    sql: """
                    INSERT INTO place_cell (cell_latitude, cell_longitude, country, town, language) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(cell_latitude, cell_longitude) DO UPDATE SET
                        country = excluded.country, town = excluded.town, language = excluded.language
                    """,
                    arguments: [cell.latitude, cell.longitude, name.country, name.town, language.identifier]
                )
            }
        }
        notifyCatalogChanged()
    }

    /// Forgets the names stored in any language but `language` (ADR 0051): the catalog keeps
    /// one language's names, so the filter never offers one place under two names, and a
    /// place held in the filter under its old name leaves the filter rather than match a
    /// dwindling share of its photos (`MediaFilter.keepingPlaces(namedIn:)`). Returns how
    /// many cells were forgotten; a catalog change when any.
    func forgetPlaceNames(notIn language: PlaceNameLanguage) async throws -> Int {
        let forgotten = try await database().write { db in
            try db.execute(sql: "DELETE FROM place_cell WHERE language <> ?", arguments: [language.identifier])
            return db.changesCount
        }
        if forgotten > 0 {
            notifyCatalogChanged()
        }
        return forgotten
    }

    func mediaAssets(for ids: [MediaAssetID]) async throws -> [MediaAssetID: MediaAsset] {
        guard !ids.isEmpty else {
            return [:]
        }

        let signpost = OtosSignpost.persistence.beginInterval("CatalogStoreTileDetailQuery")
        let rootIDsBeforeRead = roots.rowIDSnapshot()
        let dbWriter = try database()
        let timedAssets = try await timedRead(dbWriter) { db in
            try CatalogQueryGateway.fetchStoredAssets(ids: ids, rootIDsByPath: rootIDsBeforeRead, db: db)
        }
        OtosSignpost.persistence.endInterval("CatalogStoreTileDetailQuery", signpost)

        var assetsByID: [MediaAssetID: MediaAsset] = [:]
        assetsByID.reserveCapacity(timedAssets.value.count)
        for storedAsset in timedAssets.value {
            guard let rootPath = roots.pathsByRowID[storedAsset.libraryRootID],
                  roots[rootPath]?.rowID == storedAsset.libraryRootID
            else {
                continue
            }
            let asset = mediaAsset(from: storedAsset, rootPath: rootPath)
            assetsByID[asset.id] = asset
        }

        let queryMs = timedAssets.totalMs
        if queryMs > Self.slowQueryDiagnosticThresholdMs {
            await recordSlowTileDetailQuery(
                requestedCount: ids.count,
                returnedCount: assetsByID.count,
                timing: timedAssets
            )
        }
        return assetsByID
    }

    func mediaTileDetails(for ids: [MediaAssetID]) async throws -> [MediaAssetID: MediaTileDetail] {
        guard !ids.isEmpty else {
            return [:]
        }

        let signpost = OtosSignpost.persistence.beginInterval("CatalogStoreTileDetailQuery")
        let rootIDsBeforeRead = roots.rowIDSnapshot()
        let dbWriter = try database()
        let timedDetails = try await timedRead(dbWriter) { db in
            try CatalogQueryGateway.fetchStoredTileDetails(ids: ids, rootIDsByPath: rootIDsBeforeRead, db: db)
        }
        OtosSignpost.persistence.endInterval("CatalogStoreTileDetailQuery", signpost)

        var detailsByID: [MediaAssetID: MediaTileDetail] = [:]
        detailsByID.reserveCapacity(timedDetails.value.count)
        for storedDetail in timedDetails.value {
            guard let rootPath = roots.pathsByRowID[storedDetail.libraryRootID],
                  roots[rootPath]?.rowID == storedDetail.libraryRootID
            else {
                continue
            }
            let detail = mediaTileDetail(from: storedDetail, rootPath: rootPath)
            detailsByID[detail.id] = detail
        }

        let queryMs = timedDetails.totalMs
        OtosLog.catalog.debugOperation(
            "catalog.store.query.tileDetail",
            phase: "finish",
            fields: [
                "requested": "\(ids.count)",
                "returned": "\(detailsByID.count)",
                "waitMs": "\(timedDetails.waitMs)",
                "execMs": "\(timedDetails.execMs)",
                "queryMs": "\(queryMs)",
            ]
        )
        if queryMs > Self.slowQueryDiagnosticThresholdMs {
            await recordSlowTileDetailQuery(
                requestedCount: ids.count,
                returnedCount: detailsByID.count,
                timing: timedDetails
            )
        }
        return detailsByID
    }

    /// Snapshots only catalog-proven physical members for explicit system-Trash
    /// commands. Device/MTP rows are intentionally excluded because they do not
    /// represent user-filesystem originals. Companion membership comes from the
    /// inventoried pairing table, never from a filename heuristic; a Live Photo's motion
    /// movie from the pair rule (ADR 0041).
    func mediaTrashItems(for ids: [MediaAssetID]) async throws -> [MediaTrashItem] {
        var seen = Set<MediaAssetID>()
        let requested = ids.filter { seen.insert($0).inserted }
        let assets = try await mediaAssets(for: requested)
        let dbWriter = try database()
        var items: [MediaTrashItem] = []
        for id in requested {
            guard let rootState = roots[id.libraryRootPath],
                  rootState.root.kind.supportsMoveToTrash,
                  assets[id] != nil
            else {
                continue
            }
            let (companions, motion) = try await dbWriter.read { db in
                try (
                    Self.fetchCompanions(libraryRootID: rootState.rowID, db: db)
                        .filter { $0.primaryRelativePath == id.relativePath },
                    CatalogQueryGateway.fetchLivePhotoMotions(
                        libraryRootID: rootState.rowID,
                        stillPaths: [id.relativePath],
                        db: db
                    )[id.relativePath]
                )
            }
            let members = companions.map {
                MediaTrashMember(relativePath: $0.relativePath, role: .companion, byteSize: $0.byteSize)
            } + [motion].compactMap(\.self).map {
                MediaTrashMember(relativePath: $0.relativePath, role: .livePhotoMotion, byteSize: $0.byteSize)
            } + [MediaTrashMember(relativePath: id.relativePath, role: .primary, byteSize: assets[id]?.byteSize)]
            items.append(MediaTrashItem(id: id, root: rootState.root, members: members))
        }
        return items
    }

    /// The motion movie of `id` when it is a Live Photo's still (ADR 0041), else nil.
    func livePhotoMotion(of id: MediaAssetID) async throws -> MediaAssetID? {
        guard let rootID = roots[id.libraryRootPath]?.rowID else { return nil }
        let dbWriter = try database()
        return try await dbWriter.read { db in
            try CatalogQueryGateway.fetchLivePhotoMotions(
                libraryRootID: rootID,
                stillPaths: [id.relativePath],
                db: db
            )[id.relativePath]?.id(in: id.libraryRootPath)
        }
    }

    /// Hides the requested items behind one pending Move to Trash. Only existing,
    /// non-device rows that are not already pending are marked; the returned IDs are
    /// exactly the rows this call hid, in request order.
    /// Hides the items behind a pending Move to Trash. `carrying` is the authored work the
    /// duplicates act moves onto kept copies (ADR 0042): it is written in the same
    /// transaction, only for copies this call hid, and only where the kept copy lacks that
    /// work — so a move that hides nothing carries nothing. What it wrote is recorded under
    /// the batch for `revertCarriedWork`.
    func markPendingTrash(
        _ ids: [MediaAssetID],
        batch: MediaTrashBatchID,
        carrying carries: [DuplicateCarry] = []
    ) async throws -> [MediaAssetID] {
        try await setPendingTrash(ids, batch: batch, carrying: carries, operation: "mark")
    }

    /// Undo of a duplicates Move to Trash: puts back what the batch carried onto kept copies,
    /// for the moved copies that came back. Work carried from a copy still in the Trash stays
    /// on the kept copy, since its source is not back to hold it.
    func revertCarriedWork(batch: MediaTrashBatchID, restored: Set<MediaAssetID>) async throws {
        guard let records = carriedWorkByBatch[batch] else {
            return
        }
        let reverting = records.filter { restored.contains($0.from) }
        guard !reverting.isEmpty else {
            carriedWorkByBatch[batch] = nil
            return
        }
        let rootIDs = roots.rowIDSnapshot()
        let reverted = try await database().write { db in
            var reverted = 0
            for record in reverting {
                guard let rootID = rootIDs[record.to.libraryRootPath] else {
                    continue
                }
                switch record.previous {
                case let .choice(previous):
                    try db.execute(
                        sql: "UPDATE media_asset SET media_choice = ? WHERE library_root_id = ? AND relative_path = ?",
                        arguments: [previous.rawValue, rootID, record.to.relativePath.rawValue]
                    )
                    reverted += db.changesCount
                case let .edit(previousJSON):
                    reverted += try Self.replaceEditRecipe(
                        json: previousJSON,
                        rootID: rootID,
                        relativePath: record.to.relativePath.rawValue,
                        db: db
                    ) ? 1 : 0
                }
            }
            return reverted
        }
        // Forgotten only once written: a failed write leaves the record for a retry.
        carriedWorkByBatch[batch] = nil
        if reverted > 0 {
            notifyCatalogChanged()
        }
        OtosLog.catalog.noticeOperation("catalog.duplicateCarry", phase: "reverted", fields: [
            "batch": "\(batch.unixMilliseconds)",
            "records": "\(records.count)",
            "reverted": "\(reverted)",
        ])
    }

    /// Ends a pending Move to Trash without moving anything: the items reappear.
    /// Returns exactly the rows this call un-hid.
    func clearPendingTrash(_ ids: [MediaAssetID]) async throws -> [MediaAssetID] {
        try await setPendingTrash(ids, batch: nil, carrying: [], operation: "clear")
    }

    private func setPendingTrash(
        _ ids: [MediaAssetID],
        batch: MediaTrashBatchID?,
        carrying carries: [DuplicateCarry],
        operation: String
    ) async throws -> [MediaAssetID] {
        var seen = Set<MediaAssetID>()
        let requested = ids.filter { seen.insert($0).inserted }
        let eligible = requested.compactMap { id -> (MediaAssetID, Int64)? in
            guard let rootState = roots[id.libraryRootPath], rootState.root.kind.supportsMoveToTrash else {
                return nil
            }
            return (id, rootState.rowID)
        }
        guard !eligible.isEmpty else {
            return []
        }
        let rootIDs = roots.rowIDSnapshot()
        let dbWriter = try database()
        let (changed, carried) = try await dbWriter.write { db in
            var changed: [MediaAssetID] = []
            for (id, rootID) in eligible {
                // Mark touches only visible rows; clear touches only pending ones whose file
                // has not moved yet — a row whose file is in the Trash shows again only when
                // the file comes back to its path.
                try db.execute(
                    sql: """
                    UPDATE media_asset SET pending_trash_batch_unix_ms = ?
                    WHERE library_root_id = ? AND relative_path = ?
                      AND (pending_trash_batch_unix_ms IS NULL) = ?
                      AND trash_path IS NULL
                    """,
                    arguments: [batch?.unixMilliseconds, rootID, id.relativePath.rawValue, batch != nil]
                )
                if db.changesCount > 0 {
                    changed.append(id)
                }
            }
            let hidden = Set(changed)
            let carried = try carries.filter { hidden.contains($0.from) && !hidden.contains($0.to) }.compactMap { carry in
                try Self.carryWork(carry, rootIDs: rootIDs, db: db)
            }
            return (changed, carried)
        }
        if let batch, !carried.isEmpty {
            carriedWorkByBatch[batch] = carried
        }
        if !changed.isEmpty {
            notifyCatalogChanged()
        }
        OtosLog.catalog.noticeOperation(
            "catalog.pendingTrash",
            phase: operation,
            fields: [
                "batch": batch.map { "\($0.unixMilliseconds)" } ?? "none",
                "requested": "\(requested.count)",
                "changed": "\(changed.count)",
                "carried": "\(carried.count)",
            ]
        )
        return changed
    }

    /// Writes one carry inside the hiding transaction when the kept copy still lacks the work
    /// and the moved copy still holds it; returns what the kept copy held before.
    private nonisolated static func carryWork(
        _ carry: DuplicateCarry,
        rootIDs: [LibraryRootPath: Int64],
        db: Database
    ) throws -> DuplicateCarryRecord? {
        guard let fromRoot = rootIDs[carry.from.libraryRootPath], let toRoot = rootIDs[carry.to.libraryRootPath],
              let from = try Row.fetchOne(
                  db,
                  sql: "SELECT media_choice, edit_recipe_json FROM media_asset WHERE library_root_id = ? AND relative_path = ?",
                  arguments: [fromRoot, carry.from.relativePath.rawValue]
              ),
              let to = try Row.fetchOne(
                  db,
                  sql: "SELECT media_choice, edit_recipe_json FROM media_asset WHERE library_root_id = ? AND relative_path = ?",
                  arguments: [toRoot, carry.to.relativePath.rawValue]
              )
        else {
            return nil
        }
        switch carry.work {
        case .choice:
            let moved = MediaChoice(rawValue: from["media_choice"] ?? "") ?? .default
            let kept = MediaChoice(rawValue: to["media_choice"] ?? "") ?? .default
            guard moved != .notRated, kept == .notRated else {
                return nil
            }
            try db.execute(
                sql: "UPDATE media_asset SET media_choice = ? WHERE library_root_id = ? AND relative_path = ?",
                arguments: [moved.rawValue, toRoot, carry.to.relativePath.rawValue]
            )
            return DuplicateCarryRecord(from: carry.from, to: carry.to, previous: .choice(kept))
        case .edit:
            guard let movedJSON = from["edit_recipe_json"] as String?, (to["edit_recipe_json"] as String?) == nil else {
                return nil
            }
            guard try replaceEditRecipe(json: movedJSON, rootID: toRoot, relativePath: carry.to.relativePath.rawValue, db: db)
            else {
                return nil
            }
            return DuplicateCarryRecord(from: carry.from, to: carry.to, previous: .edit(nil))
        }
    }

    /// Re-catalogs an item undo moved back from the Trash. Its row never left the catalog
    /// (ADR 0022): it was kept, hidden, while the file sat in the Trash. Reconciling the
    /// returned paths from the filesystem — exactly as a file event would — sees the file at
    /// the row's own path, which shows the row again with everything Otos held for it.
    /// Returns whether the item is back: its row exists and is no longer hidden. A failed
    /// read is logged and answers false.
    func restoreTrashedItem(_ trashed: TrashedItem) async -> Bool {
        guard let rootRowID = roots[trashed.item.root.path]?.rowID else {
            return false
        }
        let root = trashed.item.root.path
        var changed = false
        for restored in trashed.members {
            let path = restored.member.relativePath
            recordIndependentNamespaceMutation(root: root, scope: .file(path), fileAction: .upsert)
            changed = await reconcileFile(
                path,
                action: .upsert,
                root: root,
                rootRowID: rootRowID,
                witness: nil
            ) == .changed || changed
        }
        let primaryPath = trashed.item.id.relativePath.rawValue
        let isBack: Bool
        do {
            isBack = try await database().read { db in
                try Bool.fetchOne(
                    db,
                    sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM media_asset
                        WHERE library_root_id = ? AND relative_path = ?
                          AND pending_trash_batch_unix_ms IS NULL AND trash_path IS NULL
                    )
                    """,
                    arguments: [rootRowID, primaryPath]
                ) ?? false
            }
        } catch {
            OtosLog.catalog.errorOperation("mediaTrash.undo", phase: "restoreReadFailed", fields: [
                "path": primaryPath,
                "error": String(describing: error),
            ])
            isBack = false
        }
        if changed || isBack {
            notifyCatalogChanged()
        }
        OtosLog.catalog.noticeOperation("mediaTrash.undo", phase: "restored", fields: [
            "path": primaryPath,
            "rowBack": "\(isBack)",
        ])
        return isBack
    }

    /// Every item still waiting to move to the Trash, oldest command first, each
    /// with its catalog-proven members. The durable queue `MediaTrashCoordinator`
    /// drains, including after relaunch.
    func pendingTrashItems() async throws -> [PendingTrashItem] {
        // Rows map to roots through the loaded registry; before the catalog's one load
        // the registry is empty and every pending row would be silently skipped.
        try await loadIfNeeded()
        let dbWriter = try database()
        let pathsByRowID = roots.pathsByRowID
        let rows: [(rootID: Int64, relativePath: String, batchMs: Int64)] = try await dbWriter.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT library_root_id, relative_path, pending_trash_batch_unix_ms
                FROM media_asset INDEXED BY idx_media_asset_pending_trash
                WHERE pending_trash_batch_unix_ms IS NOT NULL AND trash_path IS NULL
                ORDER BY pending_trash_batch_unix_ms, library_root_id, relative_path
                """
            ).map { row in
                (row["library_root_id"], row["relative_path"], row["pending_trash_batch_unix_ms"])
            }
        }
        var batches: [MediaAssetID: MediaTrashBatchID] = [:]
        var ordered: [MediaAssetID] = []
        for row in rows {
            guard let rootPath = pathsByRowID[row.rootID] else {
                continue
            }
            let id = MediaAssetID(
                libraryRootPath: rootPath,
                relativePath: MediaRelativePath(rawValue: row.relativePath)
            )
            batches[id] = MediaTrashBatchID(unixMilliseconds: row.batchMs)
            ordered.append(id)
        }
        return try await mediaTrashItems(for: ordered).compactMap { item in
            batches[item.id].map { PendingTrashItem(batch: $0, item: item) }
        }
    }

    /// Changes the authored choice for every existing requested asset in one SQLite
    /// transaction. A repeated choice is accepted with zero changed rows so the UI's
    /// optional advance policy can still treat `U` as a deliberate command.
    func setMediaChoice(
        _ choice: MediaChoice,
        for ids: [MediaAssetID]
    ) async throws -> MediaChoiceMutationResult {
        try await setMediaChoices(Dictionary(ids.map { ($0, choice) }, uniquingKeysWith: { _, last in last }))
    }

    /// One transaction assigning a possibly different choice per asset. Rows that no
    /// longer exist are skipped; the result reports each existing row's prior value.
    /// Writes each member's key-choice stamp (ADR 0052): Make Key Photo stamps the chosen
    /// member now and clears the stack's other members; undo writes back what it returns.
    /// Returns every member's previous stamp, for members that still exist; an empty result
    /// changed nothing.
    func setStackKeyChoices(
        _ stamps: [MediaAssetID: Int64?],
        kind: PhotoStackKind
    ) async throws -> [MediaAssetID: Int64?] {
        guard !stamps.isEmpty else { return [:] }
        // A pair's file and a burst's frame are chosen apart, so choosing one never clears
        // the other.
        let column = switch kind {
        case .pair: "stack_key_chosen_at_unix_ms"
        case .burst: "burst_key_chosen_at_unix_ms"
        }
        let rootIDs = roots.rowIDSnapshot()
        let dbWriter = try database()
        let (previous, changed) = try await dbWriter.write { db -> ([MediaAssetID: Int64?], Int) in
            var previous: [MediaAssetID: Int64?] = [:]
            var changed = 0
            for (id, stamp) in stamps {
                guard let rootID = rootIDs[id.libraryRootPath],
                      let row = try Row.fetchOne(
                          db,
                          sql: "SELECT \(column) FROM media_asset WHERE library_root_id = ? AND relative_path = ?",
                          arguments: [rootID, id.relativePath.rawValue]
                      )
                else {
                    continue
                }
                previous[id] = row[0] as Int64?
                try db.execute(
                    sql: """
                    UPDATE media_asset SET \(column) = ?
                    WHERE library_root_id = ? AND relative_path = ? AND \(column) IS NOT ?
                    """,
                    arguments: [stamp, rootID, id.relativePath.rawValue, stamp]
                )
                changed += db.changesCount
            }
            return (previous, changed)
        }
        OtosLog.catalog.noticeOperation("stack.key", phase: "written", fields: [
            "kind": kind.rawValue, "requested": "\(stamps.count)", "existing": "\(previous.count)", "changed": "\(changed)",
        ])
        if changed > 0 {
            notifyCatalogChanged()
        }
        return previous
    }

    func setMediaChoices(_ assignments: [MediaAssetID: MediaChoice]) async throws -> MediaChoiceMutationResult {
        guard !assignments.isEmpty else {
            return MediaChoiceMutationResult(existingCount: 0, changedCount: 0)
        }
        let rootIDs = roots.rowIDSnapshot()
        let dbWriter = try database()
        let result = try await dbWriter.write { db in
            var existingCount = 0
            var changedCount = 0
            var previous: [MediaAssetID: MediaChoice] = [:]
            for (id, choice) in assignments {
                guard let rootID = rootIDs[id.libraryRootPath] else {
                    continue
                }
                guard let current = try String.fetchOne(
                    db,
                    sql: "SELECT media_choice FROM media_asset WHERE library_root_id = ? AND relative_path = ?",
                    arguments: [rootID, id.relativePath.rawValue]
                ) else {
                    continue
                }
                existingCount += 1
                previous[id] = MediaChoice(rawValue: current) ?? .default
                try db.execute(
                    sql: """
                    UPDATE media_asset
                    SET media_choice = ?
                    WHERE library_root_id = ? AND relative_path = ? AND media_choice <> ?
                    """,
                    arguments: [choice.rawValue, rootID, id.relativePath.rawValue, choice.rawValue]
                )
                changedCount += db.changesCount
            }
            return MediaChoiceMutationResult(
                existingCount: existingCount,
                changedCount: changedCount,
                previous: previous
            )
        }
        if result.changedCount > 0 {
            notifyCatalogChanged()
        }
        OtosLog.catalog.noticeOperation(
            "catalog.mediaChoice",
            phase: "finish",
            fields: [
                "choices": Set(assignments.values).map(\.rawValue).sorted().joined(separator: "+"),
                "requested": "\(assignments.count)",
                "existing": "\(result.existingCount)",
                "changed": "\(result.changedCount)",
            ]
        )
        return result
    }

    /// The photo's current recipe, or nil when it was never edited (ADR 0036).
    func editRecipe(for id: MediaAssetID) async throws -> StoredEditRecipe? {
        guard let rootID = roots.rowIDSnapshot()[id.libraryRootPath] else {
            return nil
        }
        return try await database().read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT edit_recipe_json, edit_revision FROM media_asset
                WHERE library_root_id = ? AND relative_path = ?
                """,
                arguments: [rootID, id.relativePath.rawValue]
            ) else {
                return nil
            }
            return try Self.storedEditRecipe(json: row["edit_recipe_json"], revision: row["edit_revision"])
        }
    }

    /// Saves `recipe` as the photo's current edit under the next revision and reports the
    /// recipe it replaced, so a caller can register the exact inverse (APP-039's pattern).
    /// Saving the recipe already current changes nothing and is reported as unchanged.
    func setEditRecipe(_ recipe: EditRecipe, for id: MediaAssetID) async throws -> EditRecipeMutationResult {
        guard let rootID = roots.rowIDSnapshot()[id.libraryRootPath] else {
            return EditRecipeMutationResult(exists: false, previous: nil, saved: nil)
        }
        let json = try Self.editRecipeJSON(recipe)
        let result = try await database().write { db -> EditRecipeMutationResult in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT edit_recipe_json, edit_revision, byte_size, content_modified_at_unix, best_kind FROM media_asset
                WHERE library_root_id = ? AND relative_path = ?
                """,
                arguments: [rootID, id.relativePath.rawValue]
            ) else {
                return EditRecipeMutationResult(exists: false, previous: nil, saved: nil)
            }
            let previous = try Self.storedEditRecipe(json: row["edit_recipe_json"], revision: row["edit_revision"])
            guard (previous?.recipe ?? .neutral) != recipe else {
                return EditRecipeMutationResult(exists: true, previous: previous, saved: nil)
            }
            let modified: Double? = row["content_modified_at_unix"]
            let isVideo = (row["best_kind"] as String?) == MediaKind.video.rawValue
            // The row's revision, not the saved edit's: a photo with no edit saved (a reset, an
            // undone first edit) still counts on from its last revision, so a revision never
            // names two edits and a rendering of one is never taken for the other.
            let revision = (row["edit_revision"] as Int64) + 1
            try Self.writeEditRecipe(
                json: json,
                revision: revision,
                isVideo: isVideo,
                rootID: rootID,
                relativePath: id.relativePath.rawValue,
                db: db
            )
            return EditRecipeMutationResult(
                exists: true,
                previous: previous,
                saved: StoredEditRecipe(recipe: recipe, revision: revision),
                sourceSize: row["byte_size"],
                sourceMTimeSeconds: modified.map { Int($0.rounded(.down)) },
                isVideo: isVideo
            )
        }
        if result.saved != nil {
            notifyCatalogChanged(.assetsDetailChanged)
        }
        OtosLog.catalog.noticeOperation("catalog.editRecipe", phase: "finish", fields: [
            "rootPath": id.libraryRootPath.rawValue,
            "relativePath": id.relativePath.rawValue,
            "exists": "\(result.exists)",
            "revision": result.saved.map { "\($0.revision)" } ?? "unchanged",
        ])
        return result
    }

    /// Promotes a thumbnail and preview rendered from recipe `revision` (ADR 0036) — only
    /// while that revision is still the photo's current edit and the file is the one it
    /// was rendered from; otherwise the staged files are discarded and a newer save's
    /// render, or enrichment, supplies them. Returns whether they were applied.
    func applyRenderedEditProducts(_ products: RenderedEditProducts) async -> Bool {
        let staged = [products.thumbnail, products.preview]
        guard let rootID = roots.rowIDSnapshot()[products.id.libraryRootPath], let thumbnailDirectory else {
            discardStagedImages(staged)
            return false
        }
        let outcome: (applied: Bool, superseded: Set<String>)
        do {
            outcome = try await database().write { db in
                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT edit_revision, byte_size, content_modified_at_unix, thumbnail_path, preview_path
                    FROM media_asset WHERE library_root_id = ? AND relative_path = ?
                    """,
                    arguments: [rootID, products.id.relativePath.rawValue]
                ) else {
                    return (false, [])
                }
                let revision: Int64 = row["edit_revision"]
                let byteSize: Int64? = row["byte_size"]
                let modified: Double? = row["content_modified_at_unix"]
                guard revision == products.revision,
                      byteSize == products.sourceSize,
                      modified.map({ Int($0.rounded(.down)) }) == products.sourceMTimeSeconds
                else {
                    return (false, [])
                }
                for image in staged {
                    try ThumbnailStore.promote(image, in: thumbnailDirectory)
                }
                try db.execute(
                    sql: """
                    UPDATE media_asset SET thumbnail_path = ?, preview_path = ?, rendered_revision = ?
                    WHERE library_root_id = ? AND relative_path = ?
                    """,
                    arguments: [
                        products.thumbnail.finalRelativePath, products.preview.finalRelativePath, products.revision,
                        rootID, products.id.relativePath.rawValue,
                    ]
                )
                let oldPaths: [String?] = [row["thumbnail_path"], row["preview_path"]]
                let newPaths = Set(staged.map(\.finalRelativePath))
                return (true, Set(oldPaths.compactMap(\.self)).subtracting(newPaths))
            }
        } catch {
            OtosLog.catalog.errorOperation("catalog.editProducts", phase: "failed", fields: [
                "relativePath": products.id.relativePath.rawValue,
                "error": String(describing: error),
            ])
            discardStagedImages(staged)
            return false
        }
        if outcome.applied {
            deleteSupersededImages(outcome.superseded)
            notifyCatalogChanged(.assetsDetailChanged)
        } else {
            discardStagedImages(staged)
        }
        OtosLog.catalog.noticeOperation("catalog.editProducts", phase: outcome.applied ? "applied" : "stale", fields: [
            "relativePath": products.id.relativePath.rawValue,
            "revision": "\(products.revision)",
        ])
        return outcome.applied
    }

    /// Hands a photo whose saved edit the edit panel could not render to enrichment, which
    /// renders thumbnails and previews with the current recipe (ADR 0036). A photo whose
    /// products already carry its edit is left alone.
    func handUnrenderedEditToEnrichment(_ id: MediaAssetID) async throws {
        guard let rootID = roots.rowIDSnapshot()[id.libraryRootPath] else {
            return
        }
        let released = try await database().write { db in
            try Self.releaseUnrenderedEdits(db: db, rootID: rootID, relativePath: id.relativePath)
        }
        OtosLog.catalog.noticeOperation("catalog.editProducts", phase: "handedToEnrichment", fields: [
            "relativePath": id.relativePath.rawValue,
            "released": "\(released)",
        ])
        if released {
            notifyCatalogChanged(.assetsDetailChanged)
        }
    }

    /// Clears the rendering stamp of every photo — or the one named — whose saved edit is
    /// newer than its thumbnail and preview, so enrichment claims it again for a rendering
    /// alone: an edit changes neither the file's metadata nor its digest (ADR 0009).
    @discardableResult
    nonisolated static func releaseUnrenderedEdits(
        db: Database,
        rootID: Int64? = nil,
        relativePath: MediaRelativePath? = nil
    ) throws -> Bool {
        if let rootID, let relativePath {
            try db.execute(
                sql: """
                UPDATE media_asset SET rendered_source_size = NULL, rendered_source_mtime = NULL
                WHERE library_root_id = ? AND relative_path = ? AND edit_revision <> rendered_revision
                """,
                arguments: [rootID, relativePath.rawValue]
            )
        } else {
            try db.execute(sql: """
            UPDATE media_asset SET rendered_source_size = NULL, rendered_source_mtime = NULL
            WHERE edit_revision <> rendered_revision
            """)
        }
        return db.changesCount > 0
    }

    /// The recipe as `edit_recipe_json` stores it: sorted-key JSON, so one recipe always
    /// encodes to the same text.
    /// Saves `json` (nil: no edit) as a photo's edit under the given revision. A video's
    /// products do not carry its edit, so they are current as soon as it is saved;
    /// otherwise enrichment would download the video again to re-render them.
    nonisolated static func writeEditRecipe(
        json: String?,
        revision: Int64,
        isVideo: Bool,
        rootID: Int64,
        relativePath: String,
        db: Database
    ) throws {
        try db.execute(
            sql: """
            UPDATE media_asset SET edit_recipe_json = ?, edit_revision = ?,
                rendered_revision = CASE WHEN ? THEN ? ELSE rendered_revision END
            WHERE library_root_id = ? AND relative_path = ?
            """,
            arguments: [json, revision, isVideo, revision, rootID, relativePath]
        )
    }

    /// Replaces a photo's edit with `json` (nil: no edit) under its next revision, inside a
    /// write. Returns false when the row is gone or already holds exactly that edit.
    nonisolated static func replaceEditRecipe(
        json: String?,
        rootID: Int64,
        relativePath: String,
        db: Database
    ) throws -> Bool {
        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT edit_recipe_json, edit_revision, best_kind FROM media_asset
            WHERE library_root_id = ? AND relative_path = ?
            """,
            arguments: [rootID, relativePath]
        ), (row["edit_recipe_json"] as String?) != json else {
            return false
        }
        let revision: Int64 = row["edit_revision"]
        try writeEditRecipe(
            json: json,
            revision: revision + 1,
            isVideo: (row["best_kind"] as String?) == MediaKind.video.rawValue,
            rootID: rootID,
            relativePath: relativePath,
            db: db
        )
        return true
    }

    nonisolated static func editRecipeJSON(_ recipe: EditRecipe) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let json = try String(bytes: encoder.encode(recipe), encoding: .utf8) else {
            throw EncodingError.invalidValue(recipe, EncodingError.Context(
                codingPath: [], debugDescription: "The encoded recipe is not UTF-8."
            ))
        }
        return json
    }

    /// The recipe `edit_recipe_json` holds, or nil when the photo was never edited.
    nonisolated static func editRecipe(json: String?) throws -> EditRecipe? {
        guard let json else {
            return nil
        }
        return try JSONDecoder().decode(EditRecipe.self, from: Data(json.utf8))
    }

    nonisolated static func storedEditRecipe(json: String?, revision: Int64) throws -> StoredEditRecipe? {
        try editRecipe(json: json).map { StoredEditRecipe(recipe: $0, revision: revision) }
    }

    private func recordSlowTileDetailQuery(
        requestedCount: Int,
        returnedCount: Int,
        timing: DatabaseTimedValue<some Any>
    ) async {
        OtosLog.catalog.debug(
            """
            Catalog slow tile details query requested=\(requestedCount, privacy: .public) \
            returned=\(returnedCount, privacy: .public) \
            waitMs=\(timing.waitMs, privacy: .public) \
            execMs=\(timing.execMs, privacy: .public) queryMs=\(timing.totalMs, privacy: .public)
            """
        )
        OtosLog.catalog.notice(
            "op=catalog.store.query.tileDetail phase=finish requested=\(requestedCount, privacy: .public) returned=\(returnedCount, privacy: .public) waitMs=\(timing.waitMs, privacy: .public) execMs=\(timing.execMs, privacy: .public) queryMs=\(timing.totalMs, privacy: .public) thresholdMs=\(Self.slowQueryDiagnosticThresholdMs, privacy: .public)"
        )
    }

    /// On-demand metadata read retained for the future tile/inspector metadata surface
    /// owned by ADR 0009. It is test-exercised today but stays out of the hot grid path.
    func metadata(for id: MediaAssetID) async throws -> AssetMetadata? {
        guard let rootID = roots[id.libraryRootPath]?.rowID else {
            return nil
        }

        let signpost = OtosSignpost.persistence.beginInterval("CatalogStoreMetadataQuery")
        let dbWriter = try database()
        let timedMetadata = try await timedRead(dbWriter) { db in
            try CatalogQueryGateway.metadataExtra(libraryRootID: rootID, relativePath: id.relativePath, db: db)
        }
        OtosSignpost.persistence.endInterval("CatalogStoreMetadataQuery", signpost)

        guard roots[id.libraryRootPath]?.rowID == rootID else {
            return nil
        }
        let queryMs = timedMetadata.totalMs
        OtosLog.catalog.debug(
            """
            Catalog metadata queried returned=\(timedMetadata.value == nil ? 0 : 1, privacy: .public) \
            waitMs=\(timedMetadata.waitMs, privacy: .public) \
            execMs=\(timedMetadata.execMs, privacy: .public) queryMs=\(queryMs, privacy: .public)
            """
        )
        OtosLog.metadata.notice(
            "op=catalog.store.query.metadata phase=finish 0=1 returned=\(timedMetadata.value == nil ? "0" : "1", privacy: .public) waitMs=\(timedMetadata.waitMs, privacy: .public) execMs=\(timedMetadata.execMs, privacy: .public) queryMs=\(queryMs, privacy: .public)"
        )
        return timedMetadata.value
    }

    /// Claims the rows among `ids` that need enrichment on a root enrichment may read, in
    /// `ids` order. These are the rows the user is looking at and rows a download just made
    /// local; the coordinator claims them ahead of background work and outside its claim
    /// window, so the list's own length is the bound. While `videoFaces` is held, no row is
    /// claimed for a video's faces (`EnrichmentClaim.admitting`).
    func priorityEnrichmentCandidates(
        _ ids: [MediaAssetID],
        videoFaces: VideoFacesAdmission
    ) async throws -> [ClaimedEnrichmentCandidate] {
        var seen = Set<MediaAssetID>()
        let uniqueIDs = EnrichmentClaimGateway.unclaimedPriorityIDs(ids, claimedIDs: &seen)
        guard !uniqueIDs.isEmpty else {
            return []
        }
        let queryStart = ContinuousClock.now
        let claims = try await priorityEnrichmentCandidates(ids: uniqueIDs, limit: uniqueIDs.count, videoFaces: videoFaces)
        await recordSlowEnrichmentCandidateQueryIfNeeded(
            priorityCount: uniqueIDs.count,
            returnedCount: claims.value.count,
            waitMs: claims.waitMs,
            execMs: claims.execMs,
            queryStart: queryStart
        )
        return claims.value
    }

    /// Claims up to `limit` background rows: removable sources first, then libraries, each
    /// newest capture first (ADR 0013, ADR 0018). While `videoFaces` is held, no row is
    /// claimed for a video's faces (`EnrichmentClaim.admitting`), so a video that owes only
    /// them is not claimed at all.
    func enrichmentCandidates(limit: Int, videoFaces: VideoFacesAdmission) async throws -> [ClaimedEnrichmentCandidate] {
        guard limit > 0 else {
            return []
        }
        let queryStart = ContinuousClock.now
        let signpost = OtosSignpost.persistence.beginInterval("CatalogStoreEnrichmentCandidateQuery")
        defer {
            OtosSignpost.persistence.endInterval("CatalogStoreEnrichmentCandidateQuery", signpost)
        }
        // Each landed copy is offered once, ahead of the tiers; one not claimed now (already
        // claimed, or current) is enriched or done, and otherwise waits in the tiers' order.
        let landed = Array(localBytesAwaitingProducts.prefix(limit))
        localBytesAwaitingProducts.removeFirst(landed.count)
        let landedClaims = try await priorityEnrichmentCandidates(
            ids: landed, limit: landed.count, videoFaces: videoFaces, bytesAreLocal: true
        )
        if !landed.isEmpty {
            // Whether a fresh copy was enriched while its bytes were local: each claim's
            // `enrichment.item` line names the file; this says the queue offered it first.
            OtosLog.catalog.noticeOperation("enrichment.candidates", phase: "landed", fields: [
                "offered": "\(landed.count)",
                "claimed": "\(landedClaims.value.count)",
                "waiting": "\(localBytesAwaitingProducts.count)",
            ])
        }
        var claims = landedClaims
        if landedClaims.value.count < limit {
            let tiers = try await claimedEnrichmentCandidates(
                limit: limit - landedClaims.value.count, videoFaces: videoFaces
            )
            claims = DatabaseTimedValue(
                value: landedClaims.value + tiers.value,
                waitMs: landedClaims.waitMs + tiers.waitMs,
                execMs: landedClaims.execMs + tiers.execMs
            )
        }
        await recordSlowEnrichmentCandidateQueryIfNeeded(
            priorityCount: landed.count,
            returnedCount: claims.value.count,
            waitMs: claims.waitMs,
            execMs: claims.execMs,
            queryStart: queryStart
        )
        return claims.value
    }

    private func recordSlowEnrichmentCandidateQueryIfNeeded(
        priorityCount: Int,
        returnedCount: Int,
        waitMs: Int,
        execMs: Int,
        queryStart: ContinuousClock.Instant
    ) async {
        guard waitMs + execMs > Self.slowQueryDiagnosticThresholdMs else {
            return
        }
        await recordSlowEnrichmentCandidateQuery(
            priorityCount: priorityCount,
            returnedCount: returnedCount,
            waitMs: waitMs,
            execMs: execMs,
            wallMs: DiagnosticsTiming.milliseconds(since: queryStart)
        )
    }

    private func recordSlowEnrichmentCandidateQuery(
        priorityCount: Int,
        returnedCount: Int,
        waitMs: Int,
        execMs: Int,
        wallMs: Int
    ) async {
        let queryMs = waitMs + execMs
        OtosLog.catalog.debug(
            """
            Catalog slow enrichment candidates query priority=\(priorityCount, privacy: .public) \
            returned=\(returnedCount, privacy: .public) \
            waitMs=\(waitMs, privacy: .public) execMs=\(execMs, privacy: .public) \
            queryMs=\(queryMs, privacy: .public) wallMs=\(wallMs, privacy: .public)
            """
        )
        OtosLog.catalog.notice(
            "op=catalog.store.query.enrichment phase=finish priority=\(priorityCount, privacy: .public) returned=\(returnedCount, privacy: .public) waitMs=\(waitMs, privacy: .public) execMs=\(execMs, privacy: .public) queryMs=\(queryMs, privacy: .public) wallMs=\(wallMs, privacy: .public) thresholdMs=\(Self.slowQueryDiagnosticThresholdMs, privacy: .public)"
        )
    }

    func releaseEnrichmentClaims(_ ids: [MediaAssetID]) async throws {
        guard !ids.isEmpty else {
            return
        }
        let rootIDsByPathBeforeWrite = roots.rowIDSnapshot()
        let dbWriter = try database()
        try await dbWriter.write { db in
            try EnrichmentClaimGateway.releaseEnrichmentClaims(
                ids: ids,
                rootIDsByPath: rootIDsByPathBeforeWrite,
                db: db
            )
        }
    }

    /// `bytesAreLocal` marks rows whose bytes just became local: a root first claimed for
    /// metadata alone (a card, a camera, an Immich account) is claimed for its rendering and
    /// digest too (`EnrichmentClaim.products`); a fixed library is claimed for its every
    /// product from the start (`EnrichmentClaim.library`); either, admitting `videoFaces`.
    private func priorityEnrichmentCandidates(
        ids: [MediaAssetID],
        limit: Int,
        videoFaces: VideoFacesAdmission,
        bytesAreLocal: Bool = false
    ) async throws -> DatabaseTimedValue<[ClaimedEnrichmentCandidate]> {
        let priorityAssetsByID = try await mediaAssets(for: ids)
        let rootIDsByPathBeforeWrite = roots.rowIDSnapshot()
        let dbWriter = try database()
        let eligibleClaims = EnrichmentClaimGateway.priorityClaimInputs(
            ids: ids,
            assetsByID: priorityAssetsByID,
            rootIDsByPath: rootIDsByPathBeforeWrite,
            isRootEnrichable: { [roots] path in roots[path]?.isEnrichable == true },
            firstClaim: { [roots] path in
                let first = roots[path]?.root.firstClaim ?? .metadata
                let claim = bytesAreLocal && (first == .metadata || first == .account) ? .products : first
                return claim.admitting(videoFaces)
            }
        )
        guard !eligibleClaims.isEmpty else {
            return DatabaseTimedValue(value: [], waitMs: 0, execMs: 0)
        }
        let timedClaim = try await timedWrite(dbWriter) { db in
            var candidates: [ClaimedEnrichmentCandidate] = []
            candidates.reserveCapacity(min(limit, eligibleClaims.count))
            for (asset, rootID, claim) in eligibleClaims {
                guard candidates.count < limit else {
                    break
                }
                guard try EnrichmentClaimGateway.claimEnrichmentAsset(
                    libraryRootID: rootID,
                    relativePath: asset.relativePath,
                    claim: claim,
                    db: db
                ) else {
                    continue
                }
                candidates.append(ClaimedEnrichmentCandidate(
                    asset: asset,
                    scope: EnrichmentScope(claim: claim, asset: asset)
                ))
            }
            return candidates
        }
        let result = timedClaim
        if result.totalMs > Self.slowQueryDiagnosticThresholdMs {
            await recordSlowPriorityEnrichmentClaim(
                priorityCount: ids.count,
                eligibleCount: eligibleClaims.count,
                result: result
            )
        }
        return result
    }

    private func recordSlowPriorityEnrichmentClaim(
        priorityCount: Int,
        eligibleCount: Int,
        result: DatabaseTimedValue<[ClaimedEnrichmentCandidate]>
    ) async {
        OtosLog.catalog.notice(
            "op=catalog.store.query.enrichment.priorityClaim phase=finish priority=\(priorityCount, privacy: .public) eligible=\(eligibleCount, privacy: .public) returned=\(result.value.count, privacy: .public) waitMs=\(result.waitMs, privacy: .public) execMs=\(result.execMs, privacy: .public) queryMs=\(result.totalMs, privacy: .public) thresholdMs=\(Self.slowQueryDiagnosticThresholdMs, privacy: .public)"
        )
    }

    private func claimedEnrichmentCandidates(limit: Int, videoFaces: VideoFacesAdmission) async throws
        -> DatabaseTimedValue<[ClaimedEnrichmentCandidate]>
    {
        let prioritizedRootIDs = roots.enrichableRootIDsByRemovablePriority()
        let (libraryRootIDs, accountRootIDs, metadataFirstRootIDs) = roots.enrichableRootIDsByFirstClaim()
        let cardRootIDs = roots.enrichableCardRootIDs()
        let dbWriter = try database()
        let timedStoredAssets = try await timedWrite(dbWriter) { db in
            var storedAssets: [(asset: StoredAsset, claim: EnrichmentClaim)] = []
            // The fallback spans roots of mixed kinds (ADR 0018): a fixed library's rows are
            // claimed for every product they owe at once (`EnrichmentClaim.library`), an Immich
            // account's for metadata and a video's faces (`.account`), and a card's and a
            // camera's for metadata first.
            // `INDEXED BY` forbids one statement across claims, so partition by claim within
            // each priority tier: removable roots first (ENR-011), then a card's
            // rendering-and-digest pass, then the fixed sources, sharing what is left.
            let removableRoots = Set(prioritizedRootIDs.removable)
            let fixedRoots = Set(prioritizedRootIDs.fixed)
            // A card's renderings and digests come in a pass of their own, offered only once
            // no row of that card still needs metadata, so developing and checksumming
            // every byte never delays the import (ADR 0009). Claimed under the broad
            // products, those rows' metadata is current, so their scope is the rendering and
            // the digest, made from one read.
            let cardsReadyForProducts = try cardRootIDs.filter { rootID in
                try !EnrichmentClaimGateway.hasRowsNeedingMetadata(rootID: rootID, db: db)
            }
            let priorityGroups: [(rootIDs: [Int64], claim: EnrichmentClaim)] = [
                (removableRoots.intersection(libraryRootIDs).sorted(), EnrichmentClaim.library.admitting(videoFaces)),
                (removableRoots.intersection(metadataFirstRootIDs).sorted(), .metadata),
                (removableRoots.intersection(accountRootIDs).sorted(), EnrichmentClaim.account.admitting(videoFaces)),
                (cardsReadyForProducts, .products),
            ]
            for group in priorityGroups where storedAssets.count < limit && !group.rootIDs.isEmpty {
                let claimed = try EnrichmentClaimGateway.fetchStoredAssetsNeedingEnrichment(
                    rootIDs: group.rootIDs,
                    limit: limit - storedAssets.count,
                    claim: group.claim,
                    db: db
                )
                storedAssets.append(contentsOf: claimed.map { (asset: $0, claim: group.claim) })
            }
            // Each fixed source gets its share of what is left, then any room a source did
            // not fill goes to the others in turn. A source whose rows wait on downloads (a
            // cloud library's videos, paced by the materialization budget) is claimed again
            // every pass; claimed first, it would fill every window and hold back a source
            // whose rows are readable now (an Immich account's, read in ranges).
            let fixedSources: [(rootID: Int64, claim: EnrichmentClaim)] =
                fixedRoots.intersection(libraryRootIDs).sorted().map { ($0, EnrichmentClaim.library.admitting(videoFaces)) }
                    + fixedRoots.intersection(metadataFirstRootIDs).sorted().map { ($0, .metadata) }
                    + fixedRoots.intersection(accountRootIDs).sorted().map { ($0, EnrichmentClaim.account.admitting(videoFaces)) }
            if storedAssets.count < limit, !fixedSources.isEmpty {
                let share = max(1, (limit - storedAssets.count) / fixedSources.count)
                for pass in [share, limit] {
                    for source in fixedSources where storedAssets.count < limit {
                        let claimed = try EnrichmentClaimGateway.fetchStoredAssetsNeedingEnrichment(
                            rootIDs: [source.rootID],
                            limit: min(pass, limit - storedAssets.count),
                            claim: source.claim,
                            db: db
                        )
                        storedAssets.append(contentsOf: claimed.map { (asset: $0, claim: source.claim) })
                    }
                }
            }
            return storedAssets
        }
        // `claim` here is the claim the row was just claimed under
        // (carried from the `claimGroups` entry above), not re-derived from current
        // root kind. A root's kind cannot change between the claim
        // above and this mapping since both run inside the same actor-isolated call, but
        // carrying the value keeps one owner rather than inviting a second opinion later.
        let candidates: [ClaimedEnrichmentCandidate] = timedStoredAssets.value.compactMap { entry in
            guard let rootPath = roots.pathsByRowID[entry.asset.libraryRootID],
                  roots[rootPath]?.rowID == entry.asset.libraryRootID,
                  roots[rootPath]?.availability == .available
            else {
                return nil
            }
            let asset = mediaAsset(from: entry.asset, rootPath: rootPath)
            return ClaimedEnrichmentCandidate(
                asset: asset,
                scope: EnrichmentScope(claim: entry.claim, asset: asset)
            )
        }
        let result = DatabaseTimedValue(
            value: candidates,
            waitMs: timedStoredAssets.waitMs,
            execMs: timedStoredAssets.execMs
        )
        if result.totalMs > Self.slowQueryDiagnosticThresholdMs {
            await recordSlowFallbackEnrichmentClaim(
                limit: limit,
                removableRootCount: prioritizedRootIDs.removable.count,
                fixedRootCount: prioritizedRootIDs.fixed.count,
                result: result
            )
        }
        return result
    }

    private func recordSlowFallbackEnrichmentClaim(
        limit: Int,
        removableRootCount: Int,
        fixedRootCount: Int,
        result: DatabaseTimedValue<[ClaimedEnrichmentCandidate]>
    ) async {
        OtosLog.catalog.notice(
            "op=catalog.store.query.enrichment.claim phase=finish limit=\(limit, privacy: .public) availableRootCount=\(removableRootCount + fixedRootCount, privacy: .public) removableRootCount=\(removableRootCount, privacy: .public) returned=\(result.value.count, privacy: .public) waitMs=\(result.waitMs, privacy: .public) execMs=\(result.execMs, privacy: .public) queryMs=\(result.totalMs, privacy: .public) thresholdMs=\(Self.slowQueryDiagnosticThresholdMs, privacy: .public)"
        )
    }

    func start(scansSavedLibraries: Bool = true) async throws {
        try await loadIfNeeded()
        await forgetRemovableSourcesUnseenForRetentionPeriod()
        if scansSavedLibraries {
            requestLoadedRootScansIfNeeded()
        }
        startFilesystemWatchingIfNeeded()
        startIntegrityScanSchedulerIfNeeded()
    }

    /// Registers an explicit provider materialization for known-event suppression.
    /// Identity must be the normalized catalog path (not a raw alias spelling).
    func beginKnownMaterialization(for id: MediaAssetID) {
        knownMaterializationSuppression.begin(id: id)
    }

    func endKnownMaterialization(for id: MediaAssetID, success: Bool) {
        if success {
            knownMaterializationSuppression.endSuccess(id: id)
        } else {
            knownMaterializationSuppression.endFailure(id: id)
        }
    }

    /// Every entry point that needs catalog truth awaits the same finite load.
    /// The task is installed before its first suspension, which closes the actor
    /// reentrancy window where two callers could read and later apply competing
    /// database loads.
    private func loadIfNeeded() async throws {
        if started {
            return
        }
        if let startupTask {
            joinedInitialLoadCount += 1
            OtosLog.persistence.debug("Catalog startup joined existing load")
            OtosLog.catalog.noticeOperation("catalog.start", phase: "coalesced")
            try await startupTask.value
            return
        }

        let task = Task {
            try await self.performInitialLoad()
        }
        startupTask = task
        do {
            try await task.value
            startupTask = nil
        } catch {
            startupTask = nil
            throw error
        }
    }

    private func performInitialLoad() async throws {
        let state = OtosSignpost.persistence.beginInterval("CatalogStart")
        OtosLog.catalog.noticeOperation("catalog.start", phase: "start")
        defer {
            OtosSignpost.persistence.endInterval("CatalogStart", state)
        }

        let dbQueue = try database()
        let loaded = try await dbQueue.read { db in
            try Self.fetchCatalog(db)
        }
        try await clearAbandonedEnrichmentClaims(dbQueue)
        // An edit saved but not yet rendered into its thumbnail and preview when the last
        // process ended is enrichment's to render (ADR 0036).
        try await dbQueue.write { db in
            _ = try Self.releaseUnrenderedEdits(db: db)
        }
        // A still no decoder could read was read by this build's decoder or an earlier
        // one; one an earlier decoder could not read is this decoder's to try (ENR-029).
        let decoder = ImageRenderer.decoderIdentity
        let releasedUndecodable = try await dbQueue.write { db in
            try Self.releaseStillsUndecodedByAnotherDecoder(decoder, db: db)
        }
        OtosLog.catalog.noticeOperation("catalog.start", phase: "undecodableReleased", fields: [
            "count": "\(releasedUndecodable)", "decoder": decoder,
        ])
        // No card or camera is attached while the catalog loads; a process that ended
        // while one was being read left its unseen rows marked (ADR 0013).
        let clearedAwaiting = try await dbQueue.write { db in
            try Self.clearAllAwaitingPresence(db: db)
        }
        if clearedAwaiting > 0 {
            OtosLog.catalog.noticeOperation("catalog.start", phase: "clearedAwaitingPresence", fields: [
                "count": "\(clearedAwaiting)",
            ])
        }
        // Remap batches a previous process settled had a window that no longer exists;
        // no identity this process shows was ever under their old paths (ARC-052).
        try await dbQueue.write { db in
            try Self.deleteAllPendingIdentityRemapBatches(db: db)
        }
        // Tests pause precisely at this real suspension boundary to prove that
        // concurrent mutation callers join this load. Production leaves the
        // hook nil and performs no additional work.
        await initialLoadDidRead?()
        let normalizedRoots = await normalizeLoadedRoots(loaded.roots, dbWriter: dbQueue)
        let journaledRoots = try await dbQueue.read { db in
            try Set(Self.fetchAllActiveReorganizationComponents(db: db).map(\.libraryRootPath))
        }
        let applyState = OtosSignpost.catalog.beginInterval("CatalogApplyLoadedCatalog")
        applyLoadedCatalog(roots: normalizedRoots)
        holdJournaledReorganizationRoots(journaledRoots)
        unrequestedLoadedRootPaths = normalizedRoots
            .filter(\.kind.isUserChosenFolder)
            .map(\.path)
        OtosSignpost.catalog.endInterval("CatalogApplyLoadedCatalog", applyState)
        started = true
        OtosLog.persistence.info(
            """
            Catalog loaded roots=\(normalizedRoots.count, privacy: .public) \
            assets=\(loaded.assetCount, privacy: .public)
            """
        )
        OtosLog.catalog.notice(
            "op=catalog.start phase=finish roots=\(normalizedRoots.count, privacy: .public) assets=\(loaded.assetCount, privacy: .public)"
        )
        notifyCatalogChanged()
    }

    /// A root with a journaled reorganization component is half-moved until its recovery
    /// finishes. Its lease is held from the moment the catalog loads, so no scan, reconcile
    /// pass, import or Move to Trash acts on it first, whoever runs recovery and when.
    private func holdJournaledReorganizationRoots(_ journaledRoots: Set<LibraryRootPath>) {
        for root in journaledRoots.sorted(by: { $0.rawValue < $1.rawValue }) where roots[root] != nil {
            installNamespaceMutationLease(for: root, owner: .reorganization)
            journalHeldReorganizationRoots.insert(root)
            OtosLog.catalog.noticeOperation("reorganization.recover", phase: "held", fields: [
                "rootPath": root.rawValue,
            ])
        }
    }

    /// The lease the journal has held for `root` since load, handed to the recovery that
    /// finishes its component; `nil` when the journal holds none for it.
    func adoptJournalHeldReorganizationLease(for root: LibraryRootPath) -> RootNamespaceMutationLease? {
        guard journalHeldReorganizationRoots.remove(root) != nil else { return nil }
        return namespaceMutationLeases[root]
    }

    private func clearAbandonedEnrichmentClaims(_ dbQueue: any DatabaseWriter) async throws {
        let clearedCount = try await dbQueue.write { db in
            try EnrichmentClaimGateway.clearEnrichmentClaims(db: db)
        }
        guard clearedCount > 0 else {
            return
        }
        OtosLog.metadata.info(
            "Cleared abandoned enrichment claims count=\(clearedCount, privacy: .public)"
        )
        OtosLog.metadata.notice(
            "op=catalog.enrichment.claims phase=startupClear count=\(clearedCount, privacy: .public)"
        )
    }

    /// Writes a digest read on its own (`EnrichmentScope.hash`) while the row's file
    /// signature is still the one it was read at, and releases the row's claim whatever the
    /// answer (ADR 0018). A digest names no file, so no planning revision moves. A failed
    /// write publishes nothing and is logged; the row stays hash-stale and is claimed again.
    func applyContentHash(_ result: ContentHashResult) async -> EnrichmentApplyOutcome {
        guard let rootRowID = roots[result.id.libraryRootPath]?.rowID else {
            return .applied(count: 0)
        }
        let relativePath = result.id.relativePath.rawValue
        do {
            let written = try await database().write { db -> Int in
                try db.execute(
                    sql: """
                    UPDATE media_asset SET
                        content_hash_xxh3_128 = ?,
                        content_hash_source_size = ?,
                        content_hash_source_mtime = ?,
                        enrichment_claimed = NULL
                    WHERE library_root_id = ? AND relative_path = ?
                      AND COALESCE(byte_size, -1) = COALESCE(?, -1)
                      AND CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER) = COALESCE(?, -1)
                    """,
                    arguments: [
                        result.contentHash.data,
                        result.sourceSize,
                        result.sourceMTimeSeconds,
                        rootRowID,
                        relativePath,
                        result.sourceSize,
                        result.sourceMTimeSeconds,
                    ]
                )
                let written = db.changesCount
                if written == 0 {
                    // The file changed while it was read: the digest is for other bytes.
                    try db.execute(
                        sql: "UPDATE media_asset SET enrichment_claimed = NULL WHERE library_root_id = ? AND relative_path = ?",
                        arguments: [rootRowID, relativePath]
                    )
                }
                return written
            }
            OtosLog.metadata.noticeOperation("enrichment.contentHash", phase: written > 0 ? "applied" : "stale", fields: [
                "rootPath": result.id.libraryRootPath.rawValue,
                "relativePath": relativePath,
            ])
            if written > 0 {
                notifyCatalogChanged()
            }
            return .applied(count: written)
        } catch {
            OtosLog.metadata.errorOperation("enrichment.contentHash", phase: "writeFailed", fields: [
                "relativePath": relativePath,
                "error": String(describing: error),
            ])
            await releaseEnrichmentClaimsAfterBatch([result.id])
            return .writeFailed
        }
    }

    /// Applies a batch of completed enrichments in one transaction and one notification.
    /// The transaction also releases every row's enrichment claim, so the notification
    /// never reaches a claimant before the rows it settled are claimable again; a failed
    /// write rolls back and releases the claims on its own.
    /// Batching mirrors `recordScannedBatch`: a per-asset transaction across a whole
    /// library would crawl, and a notification per asset would re-sort the catalog in
    /// Projection per completion. Enrichment writes only enrichment columns/fields,
    /// disjoint from facts; a row that was proven-deleted or whose source facts changed
    /// between extraction and this write is skipped, so a removed or edited asset is never
    /// stamped current by stale work. Generated thumbnails are staged by the enricher and
    /// promoted here only for accepted rows, keeping derived files subordinate to Store's
    /// current SQLite truth.
    /// Applies a batch and reports the outcome so the coordinator can react correctly.
    /// `.applied(count:)` with `count < results.count` means some results were *validated*
    /// drops — proven-deleted, or stale because a scan observed newer bytes — which the
    /// coordinator should re-wake to retry. `.writeFailed` means the SQLite write or
    /// thumbnail promotion failed (disk full, corruption, permissions, missing staged file);
    /// the coordinator must *not* re-wake into a tight read/generate/fail loop and instead
    /// lets the recorded error back it off.
    @discardableResult
    func applyEnrichmentBatch(_ results: [EnrichmentResult]) async -> EnrichmentApplyOutcome {
        guard !results.isEmpty else {
            return .applied(count: 0)
        }
        let rootIDsByPathBeforeWrite = roots.rowIDSnapshot()
        guard results.contains(where: { rootIDsByPathBeforeWrite[$0.id.libraryRootPath] != nil }) else {
            discardStagedImages(results.flatMap(\.stagedImages))
            return .applied(count: 0)
        }
        let resultIDs = results.map(\.id)

        let state = OtosSignpost.persistence.beginInterval("CatalogEnrichmentBatchWrite")
        let writeOutcome: EnrichmentBatchWriteOutcome
        let thumbnailDirectory = thumbnailDirectory
        do {
            let dbQueue = try database()
            writeOutcome = try await writeEnrichmentBatch(
                results,
                rootIDsByPath: rootIDsByPathBeforeWrite,
                thumbnailDirectory: thumbnailDirectory,
                dbWriter: dbQueue
            )
        } catch {
            OtosSignpost.persistence.endInterval("CatalogEnrichmentBatchWrite", state)
            discardStagedImages(results.flatMap(\.stagedImages))
            await recordEnrichmentBatchError(error, count: results.count)
            await releaseEnrichmentClaimsAfterBatch(resultIDs)
            return .writeFailed
        }
        OtosSignpost.persistence.endInterval("CatalogEnrichmentBatchWrite", state)
        discardStagedImages(writeOutcome.discardedImages)
        deleteSupersededImages(writeOutcome.supersededImagePaths)

        await recordEnrichmentBatchWrite(resultsCount: results.count, writeOutcome: writeOutcome)
        await boundWAL(reason: "enrichmentBatch")
        if writeOutcome.appliedCount > 0 {
            for rootPath in writeOutcome.namingChangedRoots {
                bumpNamingRevision(for: rootPath)
            }
            // An enrichment batch that changed no effective ordering/scope column is a
            // detail-only change: the projection refreshes visible detail but skips the
            // full order re-query (ADR 0011). Any `best_capture`/`best_kind`/
            // `best_format` change is structural and keeps the full rebuild.
            notifyCatalogChanged(writeOutcome.structureChanged ? .catalogChanged : .assetsDetailChanged)
        }
        if writeOutcome.promotionFailed {
            return .writeFailed
        }
        return .applied(count: writeOutcome.appliedCount)
    }

    private func recordEnrichmentBatchWrite(
        resultsCount: Int,
        writeOutcome: EnrichmentBatchWriteOutcome
    ) async {
        OtosLog.metadata.notice(
            "op=catalog.enrichment.batch phase=finish attempted=\(resultsCount, privacy: .public) count=\(writeOutcome.appliedCount, privacy: .public) namingChanged=\(writeOutcome.namingChangedRoots.count, privacy: .public) rootPaths=\(writeOutcome.namingChangedRoots.map(\.rawValue).sorted().joined(separator: ","), privacy: .public) discardedImages=\(writeOutcome.discardedImages.count, privacy: .public) supersededImages=\(writeOutcome.supersededImagePaths.count, privacy: .public) promotionFailed=\(writeOutcome.promotionFailed, privacy: .public) waitMs=\(writeOutcome.waitMs, privacy: .public) execMs=\(writeOutcome.execMs, privacy: .public) writeMs=\(writeOutcome.waitMs + writeOutcome.execMs, privacy: .public)"
        )
    }

    private func releaseEnrichmentClaimsAfterBatch(_ resultIDs: [MediaAssetID]) async {
        do {
            try await releaseEnrichmentClaims(resultIDs)
        } catch {
            OtosLog.metadata.error(
                """
                Enrichment claim release failed count=\(resultIDs.count, privacy: .public) \
                error=\(String(describing: error), privacy: .public)
                """
            )
        }
    }

    private func writeEnrichmentBatch(
        _ results: [EnrichmentResult],
        rootIDsByPath: [LibraryRootPath: Int64],
        thumbnailDirectory: URL?,
        dbWriter: any DatabaseWriter
    ) async throws -> EnrichmentBatchWriteOutcome {
        let timedOutcome = try await timedWrite(dbWriter) { db in
            var outcome = EnrichmentBatchWriteOutcome()
            for result in results {
                try Self.applyEnrichmentResult(
                    result,
                    rootIDsByPath: rootIDsByPath,
                    thumbnailDirectory: thumbnailDirectory,
                    outcome: &outcome,
                    db: db
                )
            }
            // Released in the write that settles the rows, so no change notification can
            // reach a claimant while a row it is due to claim still reads as claimed.
            try EnrichmentClaimGateway.releaseEnrichmentClaims(
                ids: results.map(\.id),
                rootIDsByPath: rootIDsByPath,
                db: db
            )
            return outcome
        }
        var outcome = timedOutcome.value
        outcome.waitMs = timedOutcome.waitMs
        outcome.execMs = timedOutcome.execMs
        return outcome
    }

    private static func applyEnrichmentResult(
        _ result: EnrichmentResult,
        rootIDsByPath: [LibraryRootPath: Int64],
        thumbnailDirectory: URL?,
        outcome: inout EnrichmentBatchWriteOutcome,
        db: Database
    ) throws {
        let staged = result.stagedImages
        guard let rootID = rootIDsByPath[result.id.libraryRootPath] else {
            outcome.discard(staged)
            return
        }
        guard staged.isEmpty || thumbnailDirectory != nil else {
            outcome.failPromotion(staged)
            return
        }
        guard try enrichmentResultMatchesCurrentRow(result, libraryRootID: rootID, db: db) else {
            outcome.discard(staged)
            return
        }
        if let thumbnailDirectory {
            for (index, image) in staged.enumerated() {
                do {
                    try ThumbnailStore.promote(image, in: thumbnailDirectory)
                } catch {
                    outcome.failPromotion(Array(staged[index...]))
                    return
                }
            }
        }
        let overlayColumnsSQL = EnrichmentOverlayBeforeWrite.columnsSQL
        let overlayColumnsArguments: StatementArguments = [rootID, result.id.relativePath.rawValue]
        let oldRow: EnrichmentOverlayBeforeWrite? = try Row.fetchOne(
            db,
            sql: overlayColumnsSQL,
            arguments: overlayColumnsArguments
        ).map(EnrichmentOverlayBeforeWrite.init(row:))
        try writeEnrichmentOverlay(result, libraryRootID: rootID, db: db)
        // Ask SQLite what it actually stored for the STORED generated columns rather
        // than predicting it: the COALESCE chain lives once, in the schema
        // (CatalogStorePersistence.swift), and a batch that leaves `best_capture`/
        // `best_kind`/`best_format` unchanged (e.g. a first enrichment whose capture
        // date equals the filesystem date, or a no-op re-enrichment) is detail-only —
        // the projection can skip the full re-sort. Only an effective order/scope
        // change is structural.
        let newRow: EnrichmentOverlayBeforeWrite? = try Row.fetchOne(
            db,
            sql: overlayColumnsSQL,
            arguments: overlayColumnsArguments
        ).map(EnrichmentOverlayBeforeWrite.init(row:))
        if let old = oldRow, let newRow, old.changesStructure(to: newRow) {
            outcome.structureChanged = true
        }
        if oldRow?.captureWallCompact != newRow?.captureWallCompact {
            outcome.namingChangedRoots.insert(result.id.libraryRootPath)
        }
        // A product the result does not carry keeps the row's file: only a rendering
        // replaces the preview, and a metadata-only result touches neither image.
        if result.rendering != nil || result.provisionalThumbnail != nil {
            outcome.replaceImage(oldPath: oldRow?.thumbnailPath, newPath: result.shownThumbnailPath)
        }
        if let rendering = result.rendering {
            outcome.replaceImage(oldPath: oldRow?.previewPath, newPath: rendering.previewPath)
        }
        if let videoFaces = result.videoFaces {
            outcome.replaceImage(oldPath: oldRow?.faceFramesPath, newPath: videoFaces.frames?.finalRelativePath)
        }
        outcome.appliedCount += 1
    }

    // MARK: - Metadata refresh (ADR 0039)

    /// Library rows whose metadata record an older reading of its format family produced
    /// (`MediaMetadataReader.extractionRevision(for:)`; a record with none counts as 0, as
    /// the library defines it), in path order after `cursor`. Only rows whose enrichment is
    /// current: a row that is stale anyway is re-read by enrichment, which stamps the
    /// revision itself. Card and camera rows are never listed.
    func metadataRefreshCandidates(
        after cursor: MediaAssetID?,
        limit: Int
    ) async throws -> [MetadataRefreshCandidate] {
        let rootsByID = Dictionary(uniqueKeysWithValues: roots.rowIDSnapshot().map { ($0.value, $0.key) })
        let dbWriter = try database()
        let cursorRootID = cursor.flatMap { roots.rowIDSnapshot()[$0.libraryRootPath] } ?? -1
        let cursorPath = cursor?.relativePath.rawValue ?? ""
        return try await dbWriter.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT a.library_root_id, a.relative_path, a.byte_size, a.metadata_source_mtime,
                    (\(Self.predatesContentIdentifierSQL) AND m.camera_make = 'Apple') AS may_complete_live_photo
                FROM media_asset a
                JOIN asset_metadata m USING (library_root_id, relative_path)
                JOIN library_root r ON r.id = a.library_root_id
                WHERE r.kind IN (\(LibraryRootKind.sqlLiteralList(\.isUserChosenFolder)))
                    AND COALESCE(m.extraction_revision, 0) < \(Self.currentExtractionRevisionSQL)
                    AND NOT (\(EnrichmentClaimGateway.metadataStalenessSQLPredicate()))
                    AND (a.library_root_id, a.relative_path) > (?, ?)
                ORDER BY a.library_root_id, a.relative_path
                LIMIT ?
                """,
                arguments: [cursorRootID, cursorPath, limit]
            ).compactMap { row -> MetadataRefreshCandidate? in
                let rootID: Int64 = row["library_root_id"]
                guard let rootPath = rootsByID[rootID] else { return nil }
                return MetadataRefreshCandidate(
                    id: MediaAssetID(
                        libraryRootPath: rootPath,
                        relativePath: MediaRelativePath(rawValue: row["relative_path"])
                    ),
                    sourceSize: row["byte_size"],
                    sourceMTimeSeconds: row["metadata_source_mtime"],
                    mayCompleteLivePhoto: row["may_complete_live_photo"] ?? false
                )
            }
        }
    }

    /// A record read before MediaMetadata reported the content identifier (0.8.2), of a
    /// family that can carry one. v7 cleared every stored revision and v9 cleared these
    /// families' again, and every read since stores its revision, so a NULL revision here
    /// is exactly a record the identifier was never read for.
    nonisolated static let predatesContentIdentifierSQL =
        "(m.family IN ('heif', 'jpeg', 'isoBMFF') AND m.extraction_revision IS NULL)"

    /// Hands rows whose bytes are not local back to enrichment, which downloads each once
    /// and derives everything from that one read — metadata, checksum, thumbnail and
    /// preview — rather than a metadata read alone (ADR 0041). The row's metadata and
    /// rendering stamps are cleared, the facts enrichment claims on: its stored products
    /// describe a reading the current reader would extend. A row whose file changed or whose record
    /// was re-read meanwhile is left alone. Returns how many rows were handed over.
    @discardableResult
    func requestEnrichmentDownload(_ candidates: [MetadataRefreshCandidate]) async throws -> Int {
        guard !candidates.isEmpty else { return 0 }
        let rootIDs = roots.rowIDSnapshot()
        let dbWriter = try database()
        let requested = try await dbWriter.write { db in
            var count = 0
            for candidate in candidates {
                guard let rootID = rootIDs[candidate.id.libraryRootPath] else { continue }
                try db.execute(
                    sql: """
                    UPDATE media_asset SET
                        metadata_source_size = NULL, metadata_source_mtime = NULL,
                        rendered_source_size = NULL, rendered_source_mtime = NULL
                    WHERE library_root_id = ? AND relative_path = ?
                        AND byte_size IS ? AND metadata_source_size IS ? AND metadata_source_mtime IS ?
                        AND EXISTS (
                            SELECT 1 FROM asset_metadata m
                            WHERE m.library_root_id = media_asset.library_root_id
                                AND m.relative_path = media_asset.relative_path
                                AND \(Self.predatesContentIdentifierSQL)
                        )
                    """,
                    arguments: [
                        rootID, candidate.id.relativePath.rawValue,
                        candidate.sourceSize, candidate.sourceSize, candidate.sourceMTimeSeconds,
                    ]
                )
                count += db.changesCount
            }
            return count
        }
        OtosLog.metadata.noticeOperation("metadata.refresh", phase: "downloadRequested", fields: [
            "candidates": "\(candidates.count)", "requested": "\(requested)",
        ])
        if requested > 0 {
            notifyCatalogChanged()
        }
        return requested
    }

    /// The library's current revision for `asset_metadata.family`, as SQL: one `WHEN` per
    /// family the library names, and its `unknown` revision for anything else.
    nonisolated static var currentExtractionRevisionSQL: String {
        let cases = MediaFormat.Family.allCases.map {
            "WHEN '\($0.rawValue)' THEN \(MediaMetadataReader.extractionRevision(for: $0))"
        }
        return "(CASE m.family \(cases.joined(separator: " ")) ELSE \(MediaMetadataReader.extractionRevision(for: .unknown)) END)"
    }

    /// Writes re-read metadata records (ADR 0039). Each one lands only while its row still
    /// has the file signature it was read at and its stored record is still older than the
    /// current reading of the stored record's own family — the test that made it a
    /// candidate. Revisions are numbered per family, so the stored record is never compared
    /// with the new one's: a re-read can change family (0.7.1's `unknown` 1 is 0.8.0's
    /// `png` 0). A file that changed meanwhile, or a row enrichment re-stamped at its
    /// family's current revision, keeps what it has. Only the metadata and the columns
    /// derived from it change; thumbnails and previews do not.
    func applyMetadataRefresh(_ refreshes: [MetadataRefresh]) async throws -> Int {
        guard !refreshes.isEmpty else { return 0 }
        let rootIDsByPath = roots.rowIDSnapshot()
        let dbWriter = try database()
        let timed = try await timedWrite(dbWriter) { db in
            var outcome = EnrichmentBatchWriteOutcome()
            for refresh in refreshes {
                guard let rootID = rootIDsByPath[refresh.id.libraryRootPath] else { continue }
                let arguments: StatementArguments = [rootID, refresh.id.relativePath.rawValue]
                guard try Row.fetchOne(
                    db,
                    sql: """
                    SELECT 1 FROM media_asset a JOIN asset_metadata m USING (library_root_id, relative_path)
                    WHERE a.library_root_id = ? AND a.relative_path = ?
                        AND a.byte_size IS ? AND a.metadata_source_size IS ? AND a.metadata_source_mtime IS ?
                        AND NOT (\(EnrichmentClaimGateway.metadataStalenessSQLPredicate()))
                        AND COALESCE(m.extraction_revision, 0) < \(Self.currentExtractionRevisionSQL)
                    """,
                    arguments: arguments + [refresh.sourceSize, refresh.sourceSize, refresh.sourceMTimeSeconds]
                ) != nil else { continue }
                let overlaySQL = EnrichmentOverlayBeforeWrite.columnsSQL
                let oldRow = try Row.fetchOne(db, sql: overlaySQL, arguments: arguments)
                    .map(EnrichmentOverlayBeforeWrite.init(row:))
                try Self.writeMetadataProjection(
                    refresh.metadata,
                    enrichedKind: refresh.enrichedKind,
                    enrichedFormat: refresh.enrichedFormat,
                    sourceMTimeSeconds: refresh.sourceMTimeSeconds,
                    libraryRootID: rootID,
                    relativePath: refresh.id.relativePath,
                    db: db
                )
                let newRow = try Row.fetchOne(db, sql: overlaySQL, arguments: arguments)
                    .map(EnrichmentOverlayBeforeWrite.init(row:))
                if let oldRow, let newRow, oldRow.changesStructure(to: newRow) {
                    outcome.structureChanged = true
                }
                if oldRow?.captureWallCompact != newRow?.captureWallCompact {
                    outcome.namingChangedRoots.insert(refresh.id.libraryRootPath)
                }
                outcome.appliedCount += 1
            }
            return outcome
        }
        let outcome = timed.value
        OtosLog.metadata.noticeOperation("metadata.refresh.write", phase: "finish", fields: [
            "attempted": "\(refreshes.count)",
            "applied": "\(outcome.appliedCount)",
            "structureChanged": "\(outcome.structureChanged)",
            "writeMs": "\(timed.waitMs + timed.execMs)",
        ])
        if outcome.appliedCount > 0 {
            for rootPath in outcome.namingChangedRoots {
                _ = bumpNamingRevision(for: rootPath, reason: "metadataRefresh")
            }
            notifyCatalogChanged(outcome.structureChanged ? .catalogChanged : .assetsDetailChanged)
        }
        return outcome.appliedCount
    }

    private func discardStagedImages(_ images: [StagedDerivedImage]) {
        guard let thumbnailDirectory else {
            return
        }
        for image in images {
            ThumbnailStore.discard(image, in: thumbnailDirectory)
        }
    }

    private func deleteSupersededImages(_ paths: Set<String>) {
        guard let thumbnailDirectory else {
            return
        }
        for path in paths {
            ThumbnailStore.delete(path, in: thumbnailDirectory)
        }
    }

    private func recordEnrichmentBatchError(_ error: Error, count: Int) async {
        OtosLog.metadata.error(
            """
            Enrichment batch persist failed count=\(count, privacy: .public) \
            error=\(String(describing: error), privacy: .public)
            """
        )
        OtosLog.metadata.error(
            "op=catalog.enrichment.batch phase=error count=\(count, privacy: .public) error=\(String(describing: error), privacy: .public)"
        )
    }

    func addLibrary(url: URL) async throws {
        let path = try CatalogPath.normalizedExistingDirectoryPath(for: url)
        try await ensureStartedForMutation()
        let capabilities = await Self.probeCapabilities(of: path)
        try validateNoOverlap(path)
        try await insertLibraryRootAndStartScan(path, capabilities: capabilities, operation: "catalog.library.add")
    }

    func ensureLibrary(url: URL) async throws {
        let path = try CatalogPath.normalizedExistingDirectoryPath(for: url)
        try await ensureStartedForMutation()
        OtosLog.catalog.notice(
            "op=catalog.library.ensure phase=start rootPath=\(path.rawValue, privacy: .public)"
        )
        if roots[path] != nil {
            OtosLog.catalog.info("Smoke library root already saved path=\(path.rawValue, privacy: .public)")
            OtosLog.catalog.notice(
                "op=catalog.library.ensure phase=exists rootPath=\(path.rawValue, privacy: .public)"
            )
            return
        }
        let capabilities = await Self.probeCapabilities(of: path)
        guard roots[path] == nil else { return }
        try validateNoOverlap(path)
        try await insertLibraryRootAndStartScan(
            path,
            capabilities: capabilities,
            operation: "catalog.library.ensure",
            recordsStart: false
        )
    }

    /// Removes a library from the catalog: now when no other owner holds it, otherwise as
    /// soon as the import, reorganization or Move to Trash holding it releases it. The
    /// outcome says which, and names the holder the removal waits for.
    func removeLibrary(path: LibraryRootPath) async throws -> LibraryRemovalOutcome {
        try await ensureStartedForMutation()
        guard let rootState = roots[path] else {
            return .notInCatalog
        }
        if let holder = namespaceMutationLeases[path] {
            // A removal that already holds the root will remove it; nothing to record.
            if holder.owner != .libraryRemoval {
                deferredLibraryRemovals.insert(path)
            }
            OtosLog.catalog.noticeOperation("catalog.library.remove", phase: "deferred", fields: [
                "rootPath": path.rawValue,
                "heldBy": holder.owner.rawValue,
            ])
            return .waiting(for: holder.owner)
        }
        try await removeLibrary(rootState, holding: installNamespaceMutationLease(for: path, owner: .libraryRemoval))
        return .removed
    }

    /// The removal owns the root's namespace from the moment it starts: no import,
    /// reorganization or Move to Trash can begin on it, and the reconcile loop leaves its
    /// dirt alone. It stops watching the root and cancels its scan; a batch that scan
    /// delivers later is refused, because the scan no longer owns the root. If the delete
    /// fails the library stays, watched again and rescanned, and the error is thrown.
    private func removeLibrary(_ rootState: RootRuntimeState, holding lease: RootNamespaceMutationLease) async throws {
        let path = rootState.path
        deferredLibraryRemovals.remove(path)
        let root = rootState.root
        let rootRowID = rootState.rowID
        let state = OtosSignpost.persistence.beginInterval("CatalogRemoveRoot")
        defer { OtosSignpost.persistence.endInterval("CatalogRemoveRoot", state) }
        OtosLog.catalog.notice(
            "op=catalog.library.remove phase=start rootPath=\(path.rawValue, privacy: .public)"
        )

        filesystemWatcher.removeRoot(path)
        filesystemWatchingArmed.remove(path)
        cancelRuntimeWork(for: path)

        let purgedThumbnails: [String]
        do {
            let dbQueue = try database()
            purgedThumbnails = try await dbQueue.read { db in
                try Self.fetchExistingAssetRows(libraryRootID: rootRowID, db: db)
            }.flatMap(\.derivedImagePaths)
            try await dbQueue.write { db in
                try Self.deleteLibraryRoot(rootRowID: rootRowID, db: db)
            }
        } catch {
            OtosLog.catalog.errorOperation("catalog.library.remove", phase: "failed", fields: [
                "rootPath": path.rawValue,
                "error": String(describing: error),
            ])
            restoreAfterFailedRemoval(lease)
            throw error
        }

        namespaceMutationLeases.removeValue(forKey: path)
        removeRoot(path: path)
        if let thumbnailDirectory {
            for name in purgedThumbnails {
                ThumbnailStore.delete(name, in: thumbnailDirectory)
            }
        }
        deleteStagingIfNeeded(root)
        OtosLog.catalog.notice(
            "op=catalog.library.remove phase=finish rootPath=\(path.rawValue, privacy: .public)"
        )
        notifyCatalogChanged(.libraryRemoved(path))
        startNextScanIfNeeded()
    }

    /// Hands a library the user asked to remove to a removal lease the moment no other
    /// owner holds it, and rings the reconcile loop that runs the removal. Taking the
    /// lease here, synchronously with the release that freed the root, is what keeps a
    /// new import or Move to Trash from starting on it first.
    @discardableResult
    private func handOffDeferredLibraryRemoval(_ path: LibraryRootPath) -> Bool {
        guard deferredLibraryRemovals.contains(path),
              roots[path] != nil,
              namespaceMutationLeases[path] == nil
        else {
            return false
        }
        deferredLibraryRemovals.remove(path)
        handedOffLibraryRemovals[path] = installNamespaceMutationLease(for: path, owner: .libraryRemoval)
        OtosLog.catalog.noticeOperation("catalog.library.remove", phase: "handedOff", fields: [
            "rootPath": path.rawValue,
        ])
        requestReconcile()
        return true
    }

    /// Runs the removals a release handed over; each already holds its lease. A root that
    /// moved away from its lease's path since then is no longer under it, so that lease is
    /// dropped and the request has already followed the root (`moveRootRuntimeState`).
    private func runHandedOffLibraryRemovals() async {
        while let path = handedOffLibraryRemovals.keys.min(by: { $0.rawValue < $1.rawValue }),
              let lease = handedOffLibraryRemovals.removeValue(forKey: path)
        {
            guard let rootState = roots[path], ownsNamespaceMutationLease(lease) else {
                if namespaceMutationLeases[path]?.generation == lease.generation {
                    namespaceMutationLeases.removeValue(forKey: path)
                }
                continue
            }
            do {
                try await removeLibrary(rootState, holding: lease)
            } catch {
                OtosLog.catalog.errorOperation("catalog.library.remove", phase: "deferredFailed", fields: [
                    "rootPath": path.rawValue,
                    "error": String(describing: error),
                ])
            }
        }
    }

    /// A removal that could not delete the root's rows leaves the library as it was: its
    /// lease is released, it is watched again, and a full scan restores whatever changed
    /// while it was not watched.
    private func restoreAfterFailedRemoval(_ lease: RootNamespaceMutationLease) {
        let path = lease.libraryRootPath
        guard namespaceMutationLeases[path]?.generation == lease.generation else { return }
        namespaceMutationLeases.removeValue(forKey: path)
        filesystemWatchingArmed.insert(path)
        filesystemWatcher.addRoot(path)
        enqueueScans([path])
        notifyCatalogChanged()
    }

    /// Reorders library-kind roots, moving the one at `sourceIndex` (within the
    /// library-only, currently-displayed order) to `destinationIndex`. Settings →
    /// Libraries' drag, `Move Up`/`Move Down`, and ⌘↑/⌘↓ all call this one intent —
    /// one user action, one path. The first entry in the
    /// result becomes the deterministic import destination
    /// (`MediaOperationCoordinator.refreshSources`).
    /// Moves one library within the user's order. The move names libraries, not
    /// positions, and is applied to the order this actor holds now, so two quick moves
    /// compose and a move made against a list that changed since it was drawn still
    /// moves the library the user pointed at. A move that names a library no longer
    /// present, or that would not change the order, changes nothing.
    func moveLibrary(_ path: LibraryRootPath, _ move: LibraryOrderMove) async throws {
        try await ensureStartedForMutation()
        let current = currentLibraries().filter(\.kind.isInLibrariesSection).map(\.path)
        guard let orderedPaths = move.reordering(current, moving: path), orderedPaths != current else {
            OtosLog.catalog.noticeOperation("catalog.library.reorder", phase: "unchanged", fields: [
                "path": path.rawValue,
                "move": String(describing: move),
            ])
            return
        }

        // Apply to in-memory state before the write suspends, not after: a
        // concurrent second call must compute its own reorder against this
        // one's result, not against the pre-move snapshot it would otherwise
        // still see while this call awaits the DB write.
        for (index, path) in orderedPaths.enumerated() {
            guard var state = roots[path] else { continue }
            state.sortIndex = Int64(index)
            roots.upsert(state)
        }
        let dbQueue = try database()
        try await dbQueue.write { db in
            try Self.writeLibraryRootSortIndexes(orderedPaths, db: db)
        }
        OtosLog.catalog.notice(
            "op=catalog.library.reorder phase=finish count=\(orderedPaths.count, privacy: .public)"
        )
        notifyCatalogChanged()
    }

    private func rootForDeviceIdentity(_ identity: DeviceIdentity) -> LibraryRoot? {
        roots.rootForDeviceIdentity(identity)
    }

    /// Returns the scan task it cancelled, if the root's scan was running, so a caller
    /// that must know the root's files are no longer being read can await its exit.
    @discardableResult
    private func cancelRuntimeWork(for path: LibraryRootPath) -> Task<Void, Never>? {
        unrequestedLoadedRootPaths.removeAll { $0 == path }
        cancelFilesystemEventPass(for: path)
        filesystemDirty.removeValue(forKey: path)
        lastSuccessfulFullRootScanAt.removeValue(forKey: path)
        knownMaterializationSuppression.removeAll(under: path)
        guard let lane = scanLeases.cancelWork(for: path) else {
            return nil
        }
        let cancelledScan = scanTasks.removeValue(forKey: lane)
        cancelledScan?.cancel()
        return cancelledScan
    }

    private func releaseEnrichmentClaimsForRoot(_ rootRowID: Int64) async {
        guard let dbWriter else {
            return
        }
        do {
            try await dbWriter.write { db in
                try EnrichmentClaimGateway.releaseEnrichmentClaims(rootID: rootRowID, db: db)
            }
        } catch {
            OtosLog.metadata.error(
                "Root enrichment claim release failed error=\(String(describing: error), privacy: .public)"
            )
        }
    }

    private func deleteStagingIfNeeded(_ root: LibraryRoot) {
        guard root.kind.stagesOriginals else {
            return
        }
        do {
            try FileManager.default.removeItem(at: root.path.url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        } catch {
            // The staging folder is Otos's own; a removal that fails leaves it for the
            // launch-time staging sweep, and is logged so the leftover is explained.
            OtosLog.fileAccess.errorOperation("source.staging", phase: "removeFailed", fields: [
                "rootPath": root.path.rawValue,
                "error": String(describing: error),
            ])
        }
    }

    private func attachRemovableRoot(_ attachment: RemovableRootAttachment) async throws {
        let lastSeenAt = wallClock()
        let dbQueue = try database()
        if let existingRoot = rootForDeviceIdentity(attachment.identity),
           let rootRowID = roots[existingRoot.path]?.rowID
        {
            try await updateExistingRemovableRoot(
                attachment,
                existingRoot: existingRoot,
                rootRowID: rootRowID,
                lastSeenAt: lastSeenAt,
                dbWriter: dbQueue
            )
        } else if let existingState = roots[attachment.path] {
            // Same mount point reused with different identity after detach (e.g. card swap at same /Volumes/Card).
            // The old entry is still present as unavailable; reuse its row and update identity.
            try validateNoOverlap(attachment.path, ignoring: existingState.rowID)
            try await dbQueue.write { db in
                try db.execute(
                    sql: """
                    UPDATE library_root
                    SET device_identity = ?, display_name = ?, last_seen_at = ?,
                        case_sensitive_names = ?, device_model = ?
                    WHERE id = ?
                    """,
                    arguments: [
                        attachment.identity,
                        attachment.displayName,
                        lastSeenAt.timeIntervalSince1970,
                        attachment.capabilities.storedCaseSensitiveColumn,
                        attachment.deviceModel,
                        existingState.rowID,
                    ]
                )
            }
            moveRootRuntimeState(
                oldPath: existingState.root.path,
                newRoot: attachment.root(lastSeenAt: lastSeenAt),
                rootRowID: existingState.rowID
            )
        } else {
            try await insertRemovableRoot(attachment, lastSeenAt: lastSeenAt, dbWriter: dbQueue)
        }
        await markRetainedRowsAwaitingPresence(attachment, dbWriter: dbQueue)
        await finishRemovableRootAttachment(attachment)
    }

    /// What the source held when it was last read is not what it holds now: a card may
    /// have been erased, formatted or filled in a camera since. Its retained rows keep
    /// every overlay (ADR 0008) but stay out of sight until this attachment's scan or
    /// enumeration sees each file, so the grid fills as the source is read and never
    /// shows what it held last time. The completed read deletes what it never saw. A
    /// failed write is logged and the attachment goes on: the rows then show as last held.
    private func markRetainedRowsAwaitingPresence(
        _ attachment: RemovableRootAttachment,
        dbWriter: any DatabaseWriter
    ) async {
        guard let rootRowID = roots[attachment.path]?.rowID else {
            return
        }
        let marked: Int
        do {
            marked = try await dbWriter.write { db in
                try Self.setAwaitingPresence(true, rootRowID: rootRowID, db: db)
            }
        } catch {
            OtosLog.catalog.errorOperation("catalog.removable.attach", phase: "awaitingPresenceFailed", fields: [
                "rootPath": attachment.path.rawValue,
                "error": String(describing: error),
            ])
            return
        }
        OtosLog.catalog.noticeOperation("catalog.removable.attach", phase: "awaitingPresence", fields: [
            "rootPath": attachment.path.rawValue,
            "kind": attachment.kind.rawValue,
            "count": "\(marked)",
        ])
    }

    private func updateExistingRemovableRoot(
        _ attachment: RemovableRootAttachment,
        existingRoot: LibraryRoot,
        rootRowID: Int64,
        lastSeenAt: Date,
        dbWriter: any DatabaseWriter
    ) async throws {
        try validateNoOverlap(attachment.path, ignoring: rootRowID)
        var thumbnailMigrations: [ThumbnailPathMigration] = []
        if existingRoot.path != attachment.path {
            thumbnailMigrations = try await dbWriter.write { db in
                try Self.updateLibraryRootPath(rootRowID: rootRowID, path: attachment.path, db: db)
            }
        }
        try await dbWriter.write { db in
            try Self.updateLibraryRootSourceFacts(
                rootRowID: rootRowID,
                path: attachment.path,
                displayName: attachment.displayName,
                lastSeenAt: lastSeenAt,
                capabilities: attachment.capabilities,
                deviceModel: attachment.deviceModel,
                db: db
            )
        }
        migrateNormalizedRootThumbnails(thumbnailMigrations)
        moveRootRuntimeState(
            oldPath: existingRoot.path,
            newRoot: attachment.root(lastSeenAt: lastSeenAt),
            rootRowID: rootRowID
        )
    }

    private func insertRemovableRoot(
        _ attachment: RemovableRootAttachment,
        lastSeenAt: Date,
        dbWriter: any DatabaseWriter
    ) async throws {
        try validateNoOverlap(attachment.path)
        let storedRoot = try await dbWriter.write { db in
            try Self.insertLibraryRoot(
                path: attachment.path,
                kind: attachment.kind,
                deviceIdentity: attachment.identity,
                displayName: attachment.displayName,
                lastSeenAt: lastSeenAt,
                capabilities: attachment.capabilities,
                deviceModel: attachment.deviceModel,
                db: db
            )
        }
        let root = libraryRoot(from: storedRoot)
        upsert(RootRuntimeState(
            root: root,
            rowID: storedRoot.id,
            sortIndex: storedRoot.sortIndex,
            availability: .unknown,
            activity: .idle,
            isEjectable: false,
            capabilities: storedRoot.capabilities
        ))
    }

    private func finishRemovableRootAttachment(_ attachment: RemovableRootAttachment) async {
        guard var state = roots[attachment.path] else {
            return
        }
        state.availability = .available
        state.activity = attachment.activity
        state.isEjectable = attachment.isEjectable
        state.attachmentGeneration &+= 1
        state.capabilities = attachment.capabilities
        // Quiescence belongs to one attachment's pending unmount; a new attachment
        // starts unquiesced.
        state.isQuiesced = false
        upsert(state)
        if attachment.kind.hasFilesystemNamespace {
            filesystemWatcher.addRoot(attachment.path)
        }
        OtosLog.catalog.info(
            """
            Removable source attached kind=\(attachment.kind.rawValue, privacy: .public) \
            identity=\(attachment.identity, privacy: .public) path=\(attachment.path.rawValue, privacy: .public)
            """
        )
        OtosLog.catalog.notice(
            "op=catalog.removable.attach phase=finish kind=\(attachment.kind.rawValue, privacy: .public) identity=\(attachment.identity, privacy: .public) rootPath=\(attachment.path.rawValue, privacy: .public) displayName=\(attachment.displayName, privacy: .public) capabilities=\(String(describing: attachment.capabilities), privacy: .public) deviceModel=\(attachment.deviceModel ?? "unknown", privacy: .public) volumeFormat=\(attachment.volumeFormat ?? "unknown", privacy: .public)"
        )
        notifyCatalogChanged()
        if attachment.enqueuesScan {
            enqueueScans([attachment.path], priority: .front)
        }
    }

    private func moveRootRuntimeState(oldPath: LibraryRootPath, newRoot: LibraryRoot, rootRowID: Int64) {
        let previous = roots[oldPath]
        removeRoot(path: oldPath)
        filesystemWatchingArmed.remove(oldPath)
        scanLeases.removeRescanDeferral(oldPath)
        filesystemEventBatches.removeValue(forKey: oldPath)
        filesystemDirty.removeValue(forKey: oldPath)
        lastSuccessfulFullRootScanAt.removeValue(forKey: oldPath)
        // The root keeps every runtime fact it had (quiescence, epoch, revisions) and
        // changes only where it is. Moving it changes its namespace, so the revisions
        // and the mutation epoch advance: an observation taken before the move is stale.
        var state = previous ?? RootRuntimeState(
            root: newRoot,
            rowID: rootRowID,
            sortIndex: 0,
            availability: .unknown,
            activity: .idle,
            isEjectable: false,
            capabilities: .unknown
        )
        state.root = newRoot
        state.rowID = rootRowID
        state.planRevision &+= 1
        state.namespaceRevision &+= 1
        state.namespaceMutationEpoch &+= 1
        upsert(state)
        // A removal the user asked for follows the root to where it now is.
        if deferredLibraryRemovals.remove(oldPath) != nil {
            deferredLibraryRemovals.insert(newRoot.path)
            handOffDeferredLibraryRemoval(newRoot.path)
        }
    }

    /// A root's case sensitivity, read off this actor and before any write: the read is a
    /// filesystem call that can stall on a slow volume, and neither the actor nor the
    /// database's write lock is held across it.
    @concurrent
    private static func probeCapabilities(of path: LibraryRootPath) async -> VolumeNamespaceCapabilities {
        FilesystemNamespaceSemantics.probeVolumeCapabilities(rootURL: path.url)
    }

    private func insertLibraryRootAndStartScan(
        _ path: LibraryRootPath,
        capabilities: VolumeNamespaceCapabilities,
        operation: String,
        recordsStart: Bool = true
    ) async throws {
        let dbQueue = try database()

        let state = OtosSignpost.persistence.beginInterval("CatalogAddRoot")
        defer {
            OtosSignpost.persistence.endInterval("CatalogAddRoot", state)
        }
        if recordsStart {
            OtosLog.catalog.notice(
                "op=\(operation, privacy: .public) phase=start rootPath=\(path.rawValue, privacy: .public)"
            )
        }
        let storedRoot = try await dbQueue.write { db in
            try Self.insertLibraryRoot(
                path: path,
                capabilities: capabilities,
                db: db
            )
        }

        let root = libraryRoot(from: storedRoot)
        upsert(RootRuntimeState(
            root: root,
            rowID: storedRoot.id,
            sortIndex: storedRoot.sortIndex,
            availability: .available,
            activity: .idle,
            isEjectable: false,
            capabilities: storedRoot.capabilities
        ))
        OtosLog.catalog.info("Library root added path=\(root.path.rawValue, privacy: .public)")
        let message = "op=\(operation) phase=finish "
            + "rootPath=\(root.path.rawValue) "
            + "capabilities=\(storedRoot.capabilities)"
        OtosLog.catalog.notice("\(message, privacy: .public)")
        notifyCatalogChanged()
        filesystemWatcher.addRoot(root.path)
        enqueueScans([root.path])
    }

    func attachRemovableVolume(
        mountURL: URL,
        identity: DeviceIdentity,
        displayName: String,
        isEjectable: Bool,
        capabilities: VolumeNamespaceCapabilities,
        deviceModel: String? = nil,
        volumeFormat: String? = nil
    ) async throws {
        let path = try CatalogPath.normalizedExistingDirectoryPath(for: mountURL)
        try await ensureStartedForMutation()
        try await attachRemovableRoot(RemovableRootAttachment(
            kind: .removableVolume,
            path: path,
            identity: identity,
            displayName: displayName,
            isEjectable: isEjectable,
            activity: .idle,
            enqueuesScan: true,
            capabilities: capabilities,
            deviceModel: deviceModel,
            volumeFormat: volumeFormat
        ))
    }

    @discardableResult
    func attachDeviceMTP(
        stagingRootURL: URL,
        identity: DeviceIdentity,
        displayName: String
    ) async throws -> LibraryRootPath {
        let path = try CatalogPath.normalizedDirectoryPath(for: stagingRootURL)
        try FileManager.default.createDirectory(at: path.url, withIntermediateDirectories: true)
        try await ensureStartedForMutation()
        try await attachRemovableRoot(RemovableRootAttachment(
            kind: .deviceMTP,
            path: path,
            identity: identity,
            displayName: displayName,
            isEjectable: false,
            activity: .enumerating,
            enqueuesScan: false,
            capabilities: .unknown,
            deviceModel: nil,
            volumeFormat: nil
        ))
        return path
    }

    /// Adds one Immich account as a library (ADR 0046 §2): a root whose path is its own
    /// staging folder, named by the account's identity, and whose rows will come from its
    /// server's listing. Adding the same account again returns its existing root.
    @discardableResult
    func addImmichAccount(
        server: URL,
        userID: String,
        displayName: String
    ) async throws -> LibraryRootPath {
        guard let identity = DeviceIdentity.immichAccount(server: server, userID: userID),
              let serverURL = ImmichServerAddress.normalized(server)
        else {
            throw CatalogStoreError.invalidRemoteServer
        }
        try await ensureStartedForMutation()
        if let existing = roots.rootForDeviceIdentity(identity) {
            return existing.path
        }
        let stagingURL = stagingContainers.sessionRoot(in: .remote, identity: identity)
        try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        let path = try CatalogPath.normalizedDirectoryPath(for: stagingURL)
        try validateNoOverlap(path)
        let storedRoot = try await database().write { db in
            try Self.insertLibraryRoot(
                path: path,
                kind: .immichAccount,
                deviceIdentity: identity,
                displayName: displayName,
                // Otos lays the staging folder out by asset ID and probes no volume for it:
                // unknown keys compare case-insensitively, the choice that never splits a name.
                capabilities: .unknown,
                remoteBaseURL: serverURL,
                db: db
            )
        }
        upsert(RootRuntimeState(
            root: libraryRoot(from: storedRoot),
            rowID: storedRoot.id,
            sortIndex: storedRoot.sortIndex,
            availability: LibraryRootKind.immichAccount.availabilityAtLaunch,
            activity: .idle,
            isEjectable: false,
            capabilities: storedRoot.capabilities
        ))
        OtosLog.catalog.noticeOperation("catalog.immich.add", phase: "finish", fields: [
            "rootPath": path.rawValue,
            "server": serverURL.absoluteString,
        ])
        notifyCatalogChanged()
        return path
    }

    /// A source is last seen when it leaves, not only when it arrives: a card left in for
    /// weeks was seen all that time. Attach stamps the arrival; this stamps the departure.
    /// A source still attached when Otos quits keeps its arrival stamp, so retention can
    /// count from up to one session early — it would take a session 90 days long with
    /// the source attached throughout for that to forget a source too soon.
    private func recordLastSeen(of root: LibraryRoot, rootRowID: Int64) async {
        let lastSeenAt = wallClock()
        do {
            try await database().write { db in
                try Self.updateLibraryRootLastSeen(rootRowID: rootRowID, lastSeenAt: lastSeenAt, db: db)
            }
        } catch {
            OtosLog.catalog.errorOperation("catalog.removable.lastSeen", phase: "failed", fields: [
                "rootPath": root.path.rawValue,
                "error": String(describing: error),
            ])
            return
        }
        guard var state = roots[root.path], state.rowID == rootRowID else {
            return
        }
        state.root = LibraryRoot(
            path: state.root.path,
            kind: state.root.kind,
            deviceIdentity: state.root.deviceIdentity,
            displayName: state.root.displayNameOverride,
            lastSeenAt: lastSeenAt
        )
        upsert(state)
    }

    /// Ends the wait for a source's unseen files without the read that would have
    /// settled them (ADR 0013). On detach no attachment awaits them; when a read fails or
    /// ends incomplete it proved neither their presence nor their absence (ADR 0032 rule
    /// 4). Either way the source shows the rows it last held, as an offline card does.
    /// A failed write leaves them hidden until the next attach or launch, and is logged.
    private func releaseAwaitingPresence(of rootPath: LibraryRootPath, rootRowID: Int64, reason: String) async {
        do {
            let released = try await database().write { db in
                try Self.setAwaitingPresence(false, rootRowID: rootRowID, db: db)
            }
            if released > 0 {
                OtosLog.catalog.noticeOperation("catalog.removable.awaitingPresence", phase: "released", fields: [
                    "rootPath": rootPath.rawValue,
                    "reason": reason,
                    "count": "\(released)",
                ])
                bumpNamespaceRevision(for: rootPath)
                notifyCatalogChanged()
            }
        } catch {
            OtosLog.catalog.errorOperation("catalog.removable.awaitingPresence", phase: "releaseFailed", fields: [
                "rootPath": rootPath.rawValue,
                "reason": reason,
                "error": String(describing: error),
            ])
        }
    }

    /// Forgets every card and camera Otos has not seen for
    /// `RemovableSourceRetention.unseenPeriod`, exactly as Settings' Forget does: the
    /// source, its rows, its likes and its thumbnails (owner decision 2026-10-25,
    /// ADR 0013). It runs at launch, before any source re-attaches, so a source
    /// present now is judged by its stamp from an earlier session. A source with no
    /// last-seen stamp is kept: nothing says how long it has been away. Each removal
    /// re-reads the catalog, so a source that attaches meanwhile is not removed.
    func forgetRemovableSourcesUnseenForRetentionPeriod() async {
        let cutoff = wallClock().addingTimeInterval(-RemovableSourceRetention.unseenPeriod)
        let expired = roots.values.filter { state in
            state.root.kind.isRemovable
                && state.availability != .available
                && (state.root.lastSeenAt.map { $0 < cutoff } ?? false)
        }.map(\.root)
        for root in expired.sorted(by: { $0.path.rawValue < $1.path.rawValue }) {
            guard roots[root.path]?.availability != .available else {
                continue
            }
            do {
                let outcome = try await removeLibrary(path: root.path)
                OtosLog.catalog.noticeOperation("catalog.removable.retention", phase: "forgotten", fields: [
                    "rootPath": root.path.rawValue,
                    "kind": root.kind.rawValue,
                    "lastSeenAt": root.lastSeenAt.map { "\(Int64($0.timeIntervalSince1970))" } ?? "none",
                    "outcome": String(describing: outcome),
                ])
            } catch {
                OtosLog.catalog.errorOperation("catalog.removable.retention", phase: "failed", fields: [
                    "rootPath": root.path.rawValue,
                    "error": String(describing: error),
                ])
            }
        }
    }

    func detachRemovableSource(identity: DeviceIdentity, reason: RemovableSourceDetachReason) async throws {
        try await ensureStartedForMutation()
        guard let root = rootForDeviceIdentity(identity),
              root.kind.isRemovable,
              let rootRowID = roots[root.path]?.rowID
        else {
            return
        }
        if identity.isTransient {
            // A transient identity never comes back, so its source goes: now, or once the
            // import holding it releases it.
            _ = try await removeLibrary(path: root.path)
            return
        }

        cancelRuntimeWork(for: root.path)
        filesystemWatcher.removeRoot(root.path)
        filesystemWatchingArmed.remove(root.path)
        if var state = roots[root.path] {
            state.isEjectable = false
            state.activity = .idle
            upsert(state)
        }
        await releaseEnrichmentClaimsForRoot(rootRowID)
        await recordLastSeen(of: root, rootRowID: rootRowID)
        await releaseAwaitingPresence(of: root.path, rootRowID: rootRowID, reason: "detached")
        forgetUnreadableSources(under: root.path)
        setAvailability(.unavailable, for: root.path)
        // Detach keeps the staged bytes: they are already off the camera, and
        // discarding them here re-downloads the whole device on the next attach.
        // They are cleared at app close instead (APP-018).
        OtosLog.catalog.info(
            """
            Removable source detached identity=\(identity, privacy: .public) \
            reason=\(reason.rawValue, privacy: .public)
            """
        )
        OtosLog.catalog.notice(
            "op=catalog.removable.detach phase=finish identity=\(identity, privacy: .public) rootPath=\(root.path.rawValue, privacy: .public) kind=\(root.kind.rawValue, privacy: .public) reason=\(reason.rawValue, privacy: .public)"
        )
        notifyCatalogChanged()
        startNextScanIfNeeded()
    }

    func quiesceRemovableSource(identity: DeviceIdentity) async throws {
        try await ensureStartedForMutation()
        guard let root = rootForDeviceIdentity(identity),
              root.kind.isRemovable,
              let rootRowID = roots[root.path]?.rowID
        else {
            return
        }
        let cancelledScan = cancelRuntimeWork(for: root.path)
        if var state = roots[root.path] {
            state.activity = .idle
            state.isQuiesced = true
            upsert(state)
        }
        // The eject that follows needs the card's files closed: wait for the cancelled
        // scan to stop reading rather than assume it has.
        await cancelledScan?.value
        await releaseEnrichmentClaimsForRoot(rootRowID)
        forgetUnreadableSources(under: root.path)
        OtosLog.catalog.notice(
            "op=catalog.removable.quiesce phase=finish identity=\(identity, privacy: .public) rootPath=\(root.path.rawValue, privacy: .public) kind=\(root.kind.rawValue, privacy: .public)"
        )
    }

    /// An import batch starts copying from `source`. For a card this stops enrichment
    /// reading it until `endImportSourceRead`: no new claims there, and the claims already
    /// handed out are released, so the coordinator drops the work it queued for them
    /// (`EnrichmentCoordinator.dequeueEnrichmentWork`). Work already reading finishes.
    func beginImportSourceRead(_ batch: ImportBatchID, source: LibraryRootPath) async {
        guard var state = roots[source] else {
            return
        }
        let wasEnrichable = state.isEnrichable
        state.importingBatches.insert(batch)
        upsert(state)
        let paused = wasEnrichable && !state.isEnrichable
        if paused {
            await releaseEnrichmentClaimsForRoot(state.rowID)
            notifyCatalogChanged()
        }
        OtosLog.catalog.noticeOperation("import.sourceRead", phase: "begin", fields: [
            "rootPath": source.rawValue,
            "batch": "\(batch.unixMilliseconds)",
            "kind": state.root.kind.rawValue,
            "enrichmentPaused": "\(state.isCardBeingImported)",
        ])
    }

    /// The batch stopped copying from `source`, however it ended. When it was the last
    /// import reading a card, enrichment may claim the card again.
    func endImportSourceRead(_ batch: ImportBatchID, source: LibraryRootPath) async {
        guard var state = roots[source], state.importingBatches.contains(batch) else {
            return
        }
        let wasEnrichable = state.isEnrichable
        state.importingBatches.remove(batch)
        upsert(state)
        if !wasEnrichable, state.isEnrichable {
            notifyCatalogChanged()
        }
        OtosLog.catalog.noticeOperation("import.sourceRead", phase: "end", fields: [
            "rootPath": source.rawValue,
            "batch": "\(batch.unixMilliseconds)",
            "kind": state.root.kind.rawValue,
            "enrichmentResumed": "\(!wasEnrichable && state.isEnrichable)",
        ])
    }

    /// The roots enrichment may claim on now: one answer, read by the claim queries and
    /// by the coordinator's queue alike.
    /// Offers a row whose original a source's download just staged to enrichment ahead of
    /// other work, for every product it still owes (ADR 0046 §7): its rendering — RAW9
    /// for a RAW, lazily, when the user's work downloaded it — and its digest.
    func originalBecameLocal(_ id: MediaAssetID) {
        guard !localBytesAwaitingProducts.contains(id) else {
            return
        }
        localBytesAwaitingProducts.append(id)
        OtosLog.catalog.noticeOperation("enrichment.candidates", phase: "originalLocal", fields: [
            "rootPath": id.libraryRootPath.rawValue, "relativePath": id.relativePath.rawValue,
        ])
        notifyCatalogChanged()
    }

    /// Records whether the source behind `path` answers reads now (`RootRuntimeState.isSourceAnswering`).
    /// A source that stops answering has its enrichment claims released, so no read
    /// waits on it; one that answers again is claimable at the next pass.
    func setSourceAnswering(_ answering: Bool, for path: LibraryRootPath) async {
        guard var state = roots[path], state.isSourceAnswering != answering else {
            return
        }
        state.isSourceAnswering = answering
        upsert(state)
        OtosLog.catalog.noticeOperation("catalog.source.answering", phase: "changed", fields: [
            "rootPath": path.rawValue, "answering": "\(answering)",
        ])
        if !answering {
            await releaseEnrichmentClaimsForRoot(state.rowID)
        }
        notifyCatalogChanged()
    }

    func enrichableRootPaths() -> Set<LibraryRootPath> {
        Set(roots.values.filter(\.isEnrichable).map(\.path))
    }

    func resumeRemovableSource(identity: DeviceIdentity) async throws {
        try await ensureStartedForMutation()
        guard let root = rootForDeviceIdentity(identity),
              root.kind.isRemovable
        else {
            return
        }
        if var state = roots[root.path], state.isQuiesced {
            state.isQuiesced = false
            upsert(state)
        }
        let changed = setAvailability(.available, for: root.path)
        if changed {
            notifyCatalogChanged()
        }
        // The quiesce cancelled any scan reading the card, and rows that scan had not
        // reached are still awaiting presence; a card that stays mounted is read again.
        if root.kind.hasFilesystemNamespace {
            enqueueScans([root.path], priority: .front)
        }
        OtosLog.catalog.notice(
            "op=catalog.removable.resume phase=finish identity=\(identity, privacy: .public) rootPath=\(root.path.rawValue, privacy: .public) kind=\(root.kind.rawValue, privacy: .public)"
        )
    }

    func beginSourceListing(rootPath: LibraryRootPath) async throws -> ActiveScan {
        guard roots[rootPath]?.root.kind.rowsComeFromSourceListing == true,
              roots[rootPath]?.availability == .available,
              let rootRowID = roots[rootPath]?.rowID
        else {
            throw CancellationError()
        }
        let scan = scanLeases.makeActiveScan(
            rootPath: rootPath,
            rootRowID: rootRowID,
            startNamespaceMutationEpoch: roots[rootPath]?.namespaceMutationEpoch ?? 0
        )
        scanLeases.beginListingScan(scan)
        if var state = roots[rootPath] {
            state.activity = .enumerating
            upsert(state)
        }
        notifyCatalogChanged()
        return scan
    }

    func recordSourceListingBatch(_ batch: [ScannedMediaFile], scan: ActiveScan) async throws {
        try await ensureStartedForMutation()
        guard owns(scan),
              roots[scan.rootPath]?.root.kind.rowsComeFromSourceListing == true,
              roots[scan.rootPath]?.availability == .available
        else {
            throw CancellationError()
        }
        let dbQueue = try database()
        let scanCapabilities = roots[scan.rootPath]?.capabilities ?? .unknown
        let timed = try await timedWrite(dbQueue) { db in
            var rows = CatalogRowChanges()
            for file in batch {
                try rows.record(Self.upsertScannedFile(
                    file,
                    libraryRootPath: scan.rootPath,
                    libraryRootID: scan.rootRowID,
                    capabilities: scanCapabilities,
                    db: db
                ))
            }
            return rows
        }
        guard owns(scan) else {
            throw CancellationError()
        }
        if let change = timed.value.notification {
            // A device batch that actually changed rows is a real import-occupancy
            // change — same rule as the fixed/removable scan path (D2, D1: a plan
            // built from persisted rows before this fires is stale, and never
            // reprocessed without this bump).
            bumpNamespaceRevision(for: scan.rootPath)
            notifyCatalogChanged(change)
        }
        OtosLog.catalog.notice(
            "op=catalog.source.listing.batch phase=finish rootPath=\(scan.rootPath.rawValue, privacy: .public) count=\(batch.count, privacy: .public) inserted=\(timed.value.inserted, privacy: .public) updated=\(timed.value.updated, privacy: .public) waitMs=\(timed.waitMs, privacy: .public) execMs=\(timed.execMs, privacy: .public)"
        )
        await boundWAL(reason: "deviceListingBatch")
    }

    func completeSourceListing(
        scan: ActiveScan,
        observedPaths: Set<MediaRelativePath>,
        companions: [MediaCompanion] = []
    ) async throws {
        guard owns(scan),
              roots[scan.rootPath]?.root.kind.rowsComeFromSourceListing == true,
              roots[scan.rootPath]?.availability == .available
        else {
            throw CancellationError()
        }
        do {
            _ = try await reconcileMissingAssets(
                scan: scan,
                observedPaths: observedPaths
            )
            let dbQueue = try database()
            let scanCapabilities = roots[scan.rootPath]?.capabilities ?? .unknown
            _ = try await timedWrite(dbQueue) { db in
                var changed = 0
                for companion in companions {
                    let companionChanged = try Self.upsertCompanion(
                        companion,
                        libraryRootID: scan.rootRowID,
                        capabilities: scanCapabilities,
                        db: db
                    )
                    changed += companionChanged ? 1 : 0
                }
                changed += try Self.reconcileMissingCompanions(
                    libraryRootID: scan.rootRowID,
                    observedPaths: Set(companions.map(\.relativePath)),
                    capabilities: scanCapabilities,
                    db: db
                )
                return changed
            }
        } catch {
            OtosLog.catalog.error(
                "Device catalog reconciliation failed error=\(String(describing: error), privacy: .public)"
            )
            throw error
        }
        guard owns(scan) else {
            throw CancellationError()
        }
        // Always bump on completion, regardless of whether this run's reconciliation
        // changed any row: completion is the proof-of-stability signal the import
        // readiness gate depends on (ADR 0024) — a plan built while the device
        // was still enumerating must always be revalidated once enumeration proves
        // stable, even if it turns out nothing changed.
        bumpNamespaceRevision(for: scan.rootPath)
        await endSourceListing(scan: scan)
    }

    /// Applies one batch of a source's change stream under its listing lease, in one
    /// transaction (ADR 0046 §5): listed items are upserted, keeping a stored size the
    /// report does not carry; reported sizes update their item; a deleted item's rows and
    /// overlay are purged, as proof of deletion. Nothing unlisted is touched: an
    /// incremental report proves nothing about items it does not name. A full resync
    /// completes through `completeSourceListing`, which does.
    func applySourceListingChanges(_ changes: SourceListingChanges, scan: ActiveScan) async throws {
        try await ensureStartedForMutation()
        guard owns(scan),
              roots[scan.rootPath]?.root.kind.rowsComeFromSourceListing == true,
              roots[scan.rootPath]?.availability == .available
        else {
            throw CancellationError()
        }
        guard !changes.isEmpty else {
            return
        }
        let dbQueue = try database()
        let scanCapabilities = roots[scan.rootPath]?.capabilities ?? .unknown
        let rootRowID = scan.rootRowID
        let rootPath = scan.rootPath
        let timed = try await timedWrite(dbQueue) { db in
            try Self.writeSourceListingChanges(
                changes, rootRowID: rootRowID, rootPath: rootPath, capabilities: scanCapabilities, db: db
            )
        }
        guard owns(scan) else {
            throw CancellationError()
        }
        if let thumbnailDirectory {
            for name in timed.value.purgedImages {
                ThumbnailStore.delete(name, in: thumbnailDirectory)
            }
        }
        if let change = timed.value.rows.notification {
            bumpNamespaceRevision(for: scan.rootPath)
            notifyCatalogChanged(change)
        }
        OtosLog.catalog.noticeOperation("catalog.source.changes", phase: "finish", fields: [
            "rootPath": scan.rootPath.rawValue,
            "listed": "\(changes.listed.count)",
            "completeFolders": "\(changes.completeFolders.count)",
            "sizes": "\(changes.sizesBySourceItem.count)",
            "deleted": "\(changes.deletedSourceItems.count)",
            "inserted": "\(timed.value.rows.inserted)",
            "updated": "\(timed.value.rows.updated)",
            "waitMs": "\(timed.waitMs)",
            "execMs": "\(timed.execMs)",
        ])
        await boundWAL(reason: "sourceListingBatch")
    }

    /// The transaction of `applySourceListingChanges`: rows changed, and the derived
    /// images of purged rows, to delete once the transaction commits.
    private nonisolated static func writeSourceListingChanges(
        _ changes: SourceListingChanges,
        rootRowID: Int64,
        rootPath: LibraryRootPath,
        capabilities: VolumeNamespaceCapabilities,
        db: Database
    ) throws -> (rows: CatalogRowChanges, purgedImages: [String]) {
        var rows = CatalogRowChanges()
        for item in changes.listed {
            let file = try keepingStoredSize(item.file, libraryRootID: rootRowID, db: db)
            let upsert = try upsertScannedFile(
                file, libraryRootPath: rootPath, libraryRootID: rootRowID, capabilities: capabilities, db: db
            )
            rows.record(upsert)
            try db.execute(
                sql: """
                UPDATE media_asset SET hidden_by_source = ?
                WHERE library_root_id = ? AND relative_path = ? AND hidden_by_source IS NOT ?
                """,
                arguments: [item.isHiddenBySource, rootRowID, file.relativePath.rawValue, item.isHiddenBySource]
            )
            // A new row's hide is part of the new row; an existing one's is a change to it.
            if upsert != .inserted {
                rows.recordUpdated(db.changesCount)
            }
            // The source's name for the row: not shown, so not a change the window hears.
            try db.execute(
                sql: """
                UPDATE media_asset SET source_item_id = ?
                WHERE library_root_id = ? AND relative_path = ? AND source_item_id IS NOT ?
                """,
                arguments: [item.sourceItemID, rootRowID, file.relativePath.rawValue, item.sourceItemID]
            )
            // Whether the source has its own images of the row: what the product pass
            // asks for, not shown, so not a change the window hears either.
            try db.execute(
                sql: """
                UPDATE media_asset SET source_products_absent = ?
                WHERE library_root_id = ? AND relative_path = ? AND source_products_absent IS NOT ?
                """,
                arguments: [!item.sourceHasProducts, rootRowID, file.relativePath.rawValue, !item.sourceHasProducts]
            )
        }
        for (item, size) in changes.sizesBySourceItem {
            try db.execute(
                sql: """
                UPDATE media_asset SET byte_size = ?
                WHERE library_root_id = ? AND source_item_id = ? AND byte_size IS NOT ?
                """,
                arguments: [size, rootRowID, item, size]
            )
            rows.recordUpdated(db.changesCount)
        }
        var purged: [ExistingAssetRow] = []
        let listedPaths = Set(changes.listed.map(\.file.relativePath))
        for folder in changes.completeFolders {
            purged += try fetchExistingAssetRows(
                libraryRootID: rootRowID, underSubtree: MediaRelativePath(rawValue: folder), db: db
            ).filter { !listedPaths.contains($0.relativePath) }
        }
        for item in changes.deletedSourceItems {
            let named = try String.fetchAll(
                db,
                sql: "SELECT relative_path FROM media_asset WHERE library_root_id = ? AND source_item_id = ?",
                arguments: [rootRowID, item]
            )
            for path in [item] + named {
                purged += try fetchExistingAssetRows(
                    libraryRootID: rootRowID, underSubtree: MediaRelativePath(rawValue: path), db: db
                )
            }
        }
        var purgedImages: [String] = []
        var purgedPaths: Set<MediaRelativePath> = []
        for row in purged where purgedPaths.insert(row.relativePath).inserted {
            purgedImages += row.derivedImagePaths
            try rows.recordUpdated(deleteAssetRow(rootRowID: rootRowID, relativePath: row.relativePath, db: db) ? 1 : 0)
        }
        return (rows, purgedImages)
    }

    /// When the source at `rootPath` last listed in full (an Immich account's last complete
    /// pass, ADR 0046 §6); nil when it never has, or when the root is gone.
    func sourceLastSynced(rootPath: LibraryRootPath) async throws -> Date? {
        guard let rootID = roots.rowIDSnapshot()[rootPath] else {
            return nil
        }
        return try await database().read { db in
            try Double.fetchOne(
                db, sql: "SELECT last_synced_at FROM library_root WHERE id = ?", arguments: [rootID]
            ).map(Date.init(timeIntervalSince1970:))
        }
    }

    /// Records that the source at `rootPath` listed in full at `date`.
    func recordSourceSynced(at date: Date, rootPath: LibraryRootPath) async throws {
        guard let rootID = roots.rowIDSnapshot()[rootPath] else {
            return
        }
        try await database().write { db in
            try db.execute(
                sql: "UPDATE library_root SET last_synced_at = ? WHERE id = ?",
                arguments: [date.timeIntervalSince1970, rootID]
            )
        }
    }

    /// The full resync a source owes: its server reset the cursor, or a new session began,
    /// and no pass has read the stream from zero to its end since (ADR 0046 §5). Nil when
    /// none is owed, or for a root the catalog does not hold.
    func sourceResyncOwed(rootPath: LibraryRootPath) async throws -> SourceResyncDebt? {
        guard let rootID = roots.rowIDSnapshot()[rootPath] else {
            return nil
        }
        let revision = try await database().read { db in
            try Int64.fetchOne(db, sql: "SELECT resync_owed FROM library_root WHERE id = ?", arguments: [rootID])
        }
        return revision.flatMap { $0 > 0 ? SourceResyncDebt(revision: $0) : nil }
    }

    /// Records that a source owes a full resync, as a request newer than any before it, so a
    /// resync already running settles only the debt it started from. Nil for a root the
    /// catalog does not hold.
    @discardableResult
    func requestSourceResync(rootPath: LibraryRootPath) async throws -> SourceResyncDebt? {
        guard let rootID = roots.rowIDSnapshot()[rootPath] else {
            return nil
        }
        let revision = try await database().write { db in
            try db.execute(sql: "UPDATE library_root SET resync_owed = resync_owed + 1 WHERE id = ?", arguments: [rootID])
            return try Int64.fetchOne(db, sql: "SELECT resync_owed FROM library_root WHERE id = ?", arguments: [rootID])
        }
        OtosLog.catalog.noticeOperation("catalog.source.resync", phase: "requested", fields: [
            "rootPath": rootPath.rawValue, "revision": revision.map { "\($0)" } ?? "none",
        ])
        return revision.map(SourceResyncDebt.init(revision:))
    }

    /// Ends a source's full resync: a listing read from zero to its end under `scan`, which
    /// proves every row it did not observe deleted (ADR 0046 §1, §5). One transaction purges
    /// those rows with their overlay and settles `debt` when it is still the newest request,
    /// so the purge and the settling never part: neither a crash nor a failed write between
    /// them leaves the debt settled with rows unpurged, or the reverse.
    func completeSourceResync(
        scan: ActiveScan,
        observedPaths: Set<MediaRelativePath>,
        settling debt: SourceResyncDebt
    ) async throws {
        try await ensureStartedForMutation()
        guard owns(scan),
              roots[scan.rootPath]?.root.kind.rowsComeFromSourceListing == true,
              roots[scan.rootPath]?.availability == .available,
              scanCanDelete(scan)
        else {
            throw CancellationError()
        }
        let capabilities = roots[scan.rootPath]?.capabilities ?? .unknown
        let rootRowID = scan.rootRowID
        let observedKeys = Set(observedPaths.map {
            FilesystemNamespaceSemantics.nameKey(relativePath: $0, capabilities: capabilities)
        })
        let timed = try await timedWrite(database()) { db in
            let missing = try Self.fetchExistingAssetRows(libraryRootID: rootRowID, underSubtree: nil, db: db)
                .filter {
                    !observedKeys.contains(
                        FilesystemNamespaceSemantics.nameKey(relativePath: $0.relativePath, capabilities: capabilities)
                    )
                }
            for row in missing {
                try Self.deleteAssetRow(rootRowID: rootRowID, relativePath: row.relativePath, db: db)
            }
            try db.execute(
                sql: "UPDATE library_root SET resync_owed = 0 WHERE id = ? AND resync_owed = ?",
                arguments: [rootRowID, debt.revision]
            )
            return (images: missing.flatMap(\.derivedImagePaths), purged: missing.count, settled: db.changesCount > 0)
        }
        guard owns(scan) else {
            throw CancellationError()
        }
        if let thumbnailDirectory {
            for name in timed.value.images {
                ThumbnailStore.delete(name, in: thumbnailDirectory)
            }
        }
        OtosLog.catalog.noticeOperation("catalog.source.resync", phase: "complete", fields: [
            "rootPath": scan.rootPath.rawValue,
            "observed": "\(observedPaths.count)",
            "purged": "\(timed.value.purged)",
            "revision": "\(debt.revision)",
            "settled": "\(timed.value.settled)",
            "waitMs": "\(timed.waitMs)",
            "execMs": "\(timed.execMs)",
        ])
        bumpNamespaceRevision(for: scan.rootPath)
        await endSourceListing(scan: scan)
    }

    /// Records that the source answered it holds no images of these rows (ADR 0046 §7), so
    /// no product pass asks for them again until a later listing says it has them.
    func recordSourceProductsAbsent(_ paths: [MediaRelativePath], rootPath: LibraryRootPath) async throws {
        guard !paths.isEmpty, let rootID = roots.rowIDSnapshot()[rootPath] else {
            return
        }
        try await database().write { db in
            for path in paths {
                try db.execute(
                    sql: """
                    UPDATE media_asset SET source_products_absent = 1
                    WHERE library_root_id = ? AND relative_path = ?
                    """,
                    arguments: [rootID, path.rawValue]
                )
            }
        }
    }

    /// The source's own ID for the item `id` is (ADR 0046 §2), which a request for its
    /// bytes names; nil for a row the source never listed.
    func sourceItemID(for id: MediaAssetID) async throws -> String? {
        guard let rootID = roots.rowIDSnapshot()[id.libraryRootPath] else {
            return nil
        }
        return try await database().read { db in
            try String.fetchOne(
                db,
                sql: "SELECT source_item_id FROM media_asset WHERE library_root_id = ? AND relative_path = ?",
                arguments: [rootID, id.relativePath.rawValue]
            )
        }
    }

    /// The rows of `rootPath` named by each of `sourceItemIDs`, by that ID: where an item
    /// a source reports apart from its folder's own line already lives, and whether its
    /// source hides it.
    func sourceItemRows(
        _ sourceItemIDs: Set<String>,
        in rootPath: LibraryRootPath
    ) async throws -> [String: SourceItemRow] {
        guard let rootID = roots.rowIDSnapshot()[rootPath], !sourceItemIDs.isEmpty else {
            return [:]
        }
        let ids = sourceItemIDs.sorted()
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        return try await database().read { db in
            var rows: [String: SourceItemRow] = [:]
            for row in try Row.fetchAll(
                db,
                sql: """
                SELECT source_item_id, relative_path, hidden_by_source FROM media_asset
                WHERE library_root_id = ? AND source_item_id IN (\(placeholders))
                """,
                arguments: StatementArguments([rootID] as [any DatabaseValueConvertible] + ids)
            ) {
                rows[row["source_item_id"]] = SourceItemRow(
                    relativePath: MediaRelativePath(rawValue: row["relative_path"]),
                    isHiddenBySource: row["hidden_by_source"]
                )
            }
            return rows
        }
    }

    /// Rows of `rootPath` owed their source's own thumbnail and preview: visible, sized,
    /// showing the source's images (never edited, not yet rendered by Otos), and with no
    /// source products or older ones than the file (ADR 0046 §7). In path order after `cursor`, so a caller pages through them.
    func sourceProductCandidates(
        rootPath: LibraryRootPath,
        after cursor: MediaRelativePath?,
        limit: Int
    ) async throws -> [SourceProductCandidate] {
        guard let rootID = roots.rowIDSnapshot()[rootPath] else {
            return []
        }
        return try await database().read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT relative_path, source_item_id, kind, byte_size,
                       CAST(content_modified_at_unix AS INTEGER) AS mtime
                FROM media_asset
                WHERE library_root_id = ?
                  AND relative_path > ?
                  AND source_item_id IS NOT NULL
                  AND hidden_by_source = 0
                  AND byte_size IS NOT NULL
                  AND \(Self.showsSourceProductsSQL)
                  AND source_products_absent = 0
                  AND (
                      source_products_size IS NOT byte_size
                      OR source_products_mtime IS NOT CAST(content_modified_at_unix AS INTEGER)
                  )
                ORDER BY relative_path
                LIMIT ?
                """,
                arguments: [rootID, cursor?.rawValue ?? "", limit]
            ).map { row in
                let kind: String? = row["kind"]
                return SourceProductCandidate(
                    id: MediaAssetID(
                        libraryRootPath: rootPath, relativePath: MediaRelativePath(rawValue: row["relative_path"])
                    ),
                    sourceItemID: row["source_item_id"],
                    kind: kind.flatMap(MediaKind.init(rawValue:)),
                    byteSize: row["byte_size"],
                    contentModifiedAtSeconds: row["mtime"]
                )
            }
        }
    }

    /// `file` with the size its row already holds when the report carries none.
    private nonisolated static func keepingStoredSize(
        _ file: ScannedMediaFile,
        libraryRootID: Int64,
        db: Database
    ) throws -> ScannedMediaFile {
        guard file.byteSize == nil,
              let stored = try Int64.fetchOne(
                  db,
                  sql: "SELECT byte_size FROM media_asset WHERE library_root_id = ? AND relative_path = ?",
                  arguments: [libraryRootID, file.relativePath.rawValue]
              )
        else {
            return file
        }
        return ScannedMediaFile(
            relativePath: file.relativePath,
            name: file.name,
            contentTypeIdentifier: file.contentTypeIdentifier,
            byteSize: stored,
            createdAt: file.createdAt,
            contentModifiedAt: file.contentModifiedAt,
            kind: file.kind,
            format: file.format,
            fileIdentifier: file.fileIdentifier
        )
    }

    func endSourceListing(scan: ActiveScan) async {
        guard scanLeases.isCurrentListingScan(scan) else {
            return
        }
        scanLeases.endListingScan(scan)
        if var state = roots[scan.rootPath], state.root.kind.rowsComeFromSourceListing {
            state.activity = .idle
            upsert(state)
            notifyCatalogChanged()
        }
        // A completed enumeration has already deleted what it never saw; one that ended
        // without completing leaves its unseen rows to be shown as last held.
        if roots[scan.rootPath]?.rowID == scan.rootRowID {
            await releaseAwaitingPresence(of: scan.rootPath, rootRowID: scan.rootRowID, reason: "enumerationEnded")
        }
    }

    func applyProvisionalThumbnails(_ thumbnailsByID: [MediaAssetID: String]) async throws {
        guard !thumbnailsByID.isEmpty else {
            return
        }
        let rootIDsByPathBeforeWrite = roots.rowIDSnapshot()
        let dbQueue = try database()
        let changed = try await timedWrite(dbQueue) { db in
            var count = 0
            for (id, thumbnailPath) in thumbnailsByID {
                guard let rootID = rootIDsByPathBeforeWrite[id.libraryRootPath] else {
                    continue
                }
                try Self.updateThumbnailPath(
                    thumbnailPath,
                    libraryRootID: rootID,
                    relativePath: id.relativePath,
                    onlyWhenMissing: true,
                    db: db
                )
                count += db.changesCount
            }
            return count
        }
        if changed.value > 0 {
            notifyCatalogChanged(.assetsDetailChanged)
        }
    }

    func shutdown() {
        reconcileDoorbell?.finish()
        reconcileDoorbell = nil
        reconcileLoop?.cancel()
        reconcileLoop = nil
        reconcileCovered = reconcileRequested
        reconcilePassRunning = false
        deferredLibraryRemovals.removeAll()
        for (path, lease) in handedOffLibraryRemovals
            where namespaceMutationLeases[path]?.generation == lease.generation
        {
            namespaceMutationLeases.removeValue(forKey: path)
        }
        handedOffLibraryRemovals.removeAll()
        for task in scanTasks.values {
            task.cancel()
        }
        scanTasks.removeAll()
        integrityScanTask?.cancel()
        integrityScanTask = nil
        scanLeases.resetAll()
        cancelAllFilesystemEventPasses()
        filesystemDirty.removeAll()
        lastSuccessfulFullRootScanAt.removeAll()
        knownMaterializationSuppression.clear()
        filesystemWatcher.stop()
        filesystemEventSink?.finish()
        filesystemEventSink = nil
        filesystemEventConsumer?.cancel()
        filesystemEventConsumer = nil
        filesystemWatchingStarted = false
        filesystemWatchingArmed.removeAll()
        notifyCatalogChanged()
    }
}

extension CatalogStore {
    /// Where thumbnail files live, derived from the catalog location: beside the
    /// catalog in Application Support, or beside an explicit database file. In-memory
    /// catalogs have no thumbnail directory (nothing to purge).
    ///
    /// `nonisolated` because it reads only the immutable `location`: the ViewModel needs
    /// it synchronously to build the enricher, and tiles need it to resolve thumbnails.
    /// It lives in an internal (not `private`) extension so those owners can read it.
    nonisolated var thumbnailDirectory: URL? {
        switch location {
        case let .application(bundleIdentifier):
            Self.applicationThumbnailDirectory(bundleIdentifier: bundleIdentifier)
        case let .databaseFile(url):
            url.deletingLastPathComponent().appending(path: "Thumbnails", directoryHint: .isDirectory)
        case .inMemory:
            nil
        }
    }

    /// Where hand-offs put the full-size files they render (ADR 0037): beside
    /// the thumbnails in Application Support, never in a media folder. Its contents last
    /// until the next launch clears them. An in-memory catalog uses the temporary folder.
    nonisolated var handOffDirectory: URL {
        switch location {
        case let .application(bundleIdentifier):
            URL.applicationSupportDirectory
                .appending(path: bundleIdentifier, directoryHint: .isDirectory)
                .appending(path: "HandOff", directoryHint: .isDirectory)
        case let .databaseFile(url):
            url.deletingLastPathComponent().appending(path: "HandOff", directoryHint: .isDirectory)
        case .inMemory:
            URL.temporaryDirectory.appending(path: "OtosHandOff", directoryHint: .isDirectory)
        }
    }
}

private extension CatalogStore {
    private func timedRead<Value: Sendable>(
        _ dbWriter: any DatabaseWriter,
        _ body: @Sendable @escaping (Database) throws -> Value
    ) async throws -> DatabaseTimedValue<Value> {
        let start = ContinuousClock.now
        return try await dbWriter.read { db in
            let entered = ContinuousClock.now
            let value = try body(db)
            return DatabaseTimedValue(
                value: value,
                waitMs: DiagnosticsTiming.milliseconds(from: start, to: entered),
                execMs: DiagnosticsTiming.milliseconds(since: entered)
            )
        }
    }

    private func timedWrite<Value: Sendable>(
        _ dbWriter: any DatabaseWriter,
        _ body: @Sendable @escaping (Database) throws -> Value
    ) async throws -> DatabaseTimedValue<Value> {
        let start = ContinuousClock.now
        return try await dbWriter.write { db in
            let entered = ContinuousClock.now
            let value = try body(db)
            return DatabaseTimedValue(
                value: value,
                waitMs: DiagnosticsTiming.milliseconds(from: start, to: entered),
                execMs: DiagnosticsTiming.milliseconds(since: entered)
            )
        }
    }

    private func ensureStartedForMutation() async throws {
        try await loadIfNeeded()
    }

    private func database() throws -> any DatabaseWriter {
        if let dbWriter {
            return dbWriter
        }

        let state = OtosSignpost.persistence.beginInterval("CatalogOpenDatabase")
        defer {
            OtosSignpost.persistence.endInterval("CatalogOpenDatabase", state)
        }

        let openResult = try openDatabaseWriter()
        let dbWriter = openResult.dbWriter
        let compatibility = try dbWriter.read { db in
            try Self.catalogSchemaCompatibility(db)
        }
        guard compatibility.isSupported else {
            OtosLog.persistence.error(
                "Catalog schema refused problem=\(compatibility.errorDescription, privacy: .public)"
            )
            OtosLog.catalog.error(
                "op=catalog.start phase=schemaRefused problem=\(String(describing: compatibility), privacy: .public)"
            )
            throw CatalogStoreError.unsupportedCatalogSchema(compatibility)
        }
        try Self.migrator.migrate(dbWriter)
        performThumbnailStoreStartupMaintenance()
        self.dbWriter = dbWriter
        databaseFileURL = openResult.openedFileURL
        recordDatabaseOpenDiagnostics(dbWriter: dbWriter, storageKind: openResult.storageKind)
        OtosLog.persistence.info(
            "Catalog database opened storage=\(openResult.storageKind, privacy: .public)"
        )
        return dbWriter
    }

    private struct DatabaseOpenResult {
        let dbWriter: any DatabaseWriter
        let storageKind: String
        let openedFileURL: URL?
    }

    private func openDatabaseWriter() throws -> DatabaseOpenResult {
        switch location {
        case let .application(bundleIdentifier):
            let databaseURL = try Self.applicationDatabaseURL(bundleIdentifier: bundleIdentifier)
            return try DatabaseOpenResult(
                dbWriter: DatabasePool(
                    path: databaseURL.path(percentEncoded: false),
                    configuration: Self.fileBackedDatabaseConfiguration()
                ),
                storageKind: "application",
                openedFileURL: databaseURL
            )
        case let .databaseFile(url):
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            return try DatabaseOpenResult(
                dbWriter: DatabasePool(
                    path: url.path(percentEncoded: false),
                    configuration: Self.fileBackedDatabaseConfiguration()
                ),
                storageKind: "file",
                openedFileURL: url
            )
        case .inMemory:
            return try DatabaseOpenResult(
                dbWriter: DatabaseQueue(),
                storageKind: "memory",
                openedFileURL: nil
            )
        }
    }

    private func performThumbnailStoreStartupMaintenance() {
        guard let thumbnailDirectory else {
            return
        }
        let removed = ThumbnailStore.clearStaging(in: thumbnailDirectory)
        guard removed > 0 else {
            return
        }
        recordDiagnostic(
            operation: "catalog.thumbnails.staging",
            phase: "cleared",
            fields: ["count": "\(removed)"]
        )
    }

    private func recordDatabaseOpenDiagnostics(dbWriter: any DatabaseWriter, storageKind: String) {
        let synchronousValue = (try? dbWriter.read { db in
            try Int.fetchOne(db, sql: "PRAGMA synchronous") ?? -1
        }) ?? -1
        let synchronousLabel = Self.sqliteSynchronousLabel(synchronousValue)
        OtosLog.persistence.info(
            """
            Catalog database pragmas storage=\(storageKind, privacy: .public) \
            synchronous=\(synchronousLabel, privacy: .public)(\(synchronousValue, privacy: .public))
            """
        )
        recordDiagnostic(
            operation: "catalog.database.open",
            phase: "finish",
            fields: [
                "storage": storageKind,
                "synchronous": synchronousLabel,
                "synchronousValue": "\(synchronousValue)",
            ]
        )
    }

    private static func sqliteSynchronousLabel(_ value: Int) -> String {
        switch value {
        case 0:
            "OFF"
        case 1:
            "NORMAL"
        case 2:
            "FULL"
        case 3:
            "EXTRA"
        default:
            "unknown"
        }
    }

    private func applyLoadedCatalog(roots storedRoots: [StoredRoot]) {
        roots.removeAll()

        for storedRoot in storedRoots {
            let root = libraryRoot(from: storedRoot)
            // SQLite proves that a root was saved, not that it is reachable now; what a
            // launch knows before any source answers is the kind's own rule.
            roots.upsert(RootRuntimeState(
                root: root,
                rowID: storedRoot.id,
                sortIndex: storedRoot.sortIndex,
                availability: root.kind.availabilityAtLaunch,
                activity: .idle,
                isEjectable: false,
                capabilities: storedRoot.capabilities
            ))
        }
    }

    private func normalizeLoadedRoots(
        _ roots: [StoredRoot],
        dbWriter: any DatabaseWriter
    ) async -> [StoredRoot] {
        var normalizedRoots: [StoredRoot] = []
        for storedRoot in roots {
            let normalizedRoot = await normalizedLoadedRoot(storedRoot, dbWriter: dbWriter)
            normalizedRoots.append(normalizedRoot)
        }
        return normalizedRoots
    }

    /// The path `storedRoot` is at in this process: a user-chosen folder's spelling as the
    /// filesystem normalizes it, and a staging root's path derived from this build's
    /// containers and its identity (`StagingContainers`), so a root stored by another build,
    /// or before the containers were named by bundle identifier, moves into this build's own.
    /// A move keeps the root's row, so every overlay its assets hold — faces, people, search
    /// readings, edits, keyed by the row and the relative path — moves with it; derived images
    /// take the new identity's names, and an import or erase journaled against the old path
    /// follows it. Nothing on disk moves: staged bytes are a cache, re-fetched on demand, and
    /// the old folder is its own build's to sweep.
    private func loadedPath(of storedRoot: StoredRoot) -> LibraryRootPath? {
        if storedRoot.kind.isUserChosenFolder {
            return try? CatalogPath.normalizedExistingDirectoryPath(for: storedRoot.path.url)
        }
        guard let container = storedRoot.kind.stagingContainer, let identity = storedRoot.deviceIdentity else {
            return nil
        }
        return try? CatalogPath.normalizedDirectoryPath(
            for: stagingContainers.sessionRoot(in: container, identity: identity)
        )
    }

    private func normalizedLoadedRoot(
        _ storedRoot: StoredRoot,
        dbWriter: any DatabaseWriter
    ) async -> StoredRoot {
        guard let normalizedPath = loadedPath(of: storedRoot), normalizedPath != storedRoot.path else {
            return storedRoot
        }
        do {
            let oldPath = storedRoot.path
            let thumbnailMigrations = try await dbWriter.write { db in
                let migrations = try Self.updateLibraryRootPath(rootRowID: storedRoot.id, path: normalizedPath, db: db)
                try Self.moveJournaledSourceRoot(from: oldPath, to: normalizedPath, db: db)
                return migrations
            }
            migrateNormalizedRootThumbnails(thumbnailMigrations)
            OtosLog.persistence.info(
                """
                Library root normalized oldPath=\(storedRoot.path.rawValue, privacy: .public) \
                path=\(normalizedPath.rawValue, privacy: .public) \
                thumbnailMigrations=\(thumbnailMigrations.count, privacy: .public)
                """
            )
            OtosLog.catalog.notice(
                "op=catalog.library.normalize phase=finish kind=\(storedRoot.kind.rawValue, privacy: .public) oldRootPath=\(storedRoot.path.rawValue, privacy: .public) rootPath=\(normalizedPath.rawValue, privacy: .public) thumbnailMigrations=\(thumbnailMigrations.count, privacy: .public)"
            )
            return StoredRoot(
                id: storedRoot.id,
                path: normalizedPath,
                kind: storedRoot.kind,
                deviceIdentity: storedRoot.deviceIdentity,
                displayName: storedRoot.displayName,
                lastSeenAt: storedRoot.lastSeenAt,
                sortIndex: storedRoot.sortIndex,
                capabilities: storedRoot.capabilities,
                deviceModel: storedRoot.deviceModel,
                remoteBaseURL: storedRoot.remoteBaseURL
            )
        } catch {
            await recordRootNormalizationFailure(storedRoot, normalizedPath: normalizedPath, error: error)
            return storedRoot
        }
    }

    private func recordRootNormalizationFailure(
        _ storedRoot: StoredRoot,
        normalizedPath: LibraryRootPath,
        error: Error
    ) async {
        OtosLog.persistence.error(
            """
            Library root normalization failed oldPath=\(storedRoot.path.rawValue, privacy: .public) \
            path=\(normalizedPath.rawValue, privacy: .public) \
            error=\(String(describing: error), privacy: .public)
            """
        )
        OtosLog.catalog.error(
            "op=catalog.library.normalize phase=error oldRootPath=\(storedRoot.path.rawValue, privacy: .public) rootPath=\(normalizedPath.rawValue, privacy: .public) error=\(String(describing: error), privacy: .public)"
        )
    }

    private func migrateNormalizedRootThumbnails(_ migrations: [ThumbnailPathMigration]) {
        guard !migrations.isEmpty, let thumbnailDirectory else {
            return
        }

        var failureCount = 0
        for migration in migrations {
            do {
                try ThumbnailStore.move(
                    migration.oldRelativeName,
                    to: migration.newRelativeName,
                    in: thumbnailDirectory
                )
            } catch {
                failureCount += 1
                OtosLog.thumbnails.error(
                    """
                    Thumbnail migration failed old=\(migration.oldRelativeName, privacy: .public) \
                    new=\(migration.newRelativeName, privacy: .public) \
                    error=\(String(describing: error), privacy: .public)
                    """
                )
            }
        }

        OtosLog.thumbnails.info(
            """
            Thumbnail paths migrated for normalized root count=\(migrations.count, privacy: .public) \
            failures=\(failureCount, privacy: .public)
            """
        )
    }

    private func mediaAsset(from storedAsset: StoredAsset, rootPath: LibraryRootPath) -> MediaAsset {
        MediaAsset(
            libraryRootPath: rootPath,
            relativePath: storedAsset.relativePath,
            name: storedAsset.name,
            contentTypeIdentifier: storedAsset.contentTypeIdentifier,
            byteSize: storedAsset.byteSize,
            createdAt: storedAsset.createdAt,
            contentModifiedAt: storedAsset.contentModifiedAt,
            thumbnailPath: storedAsset.thumbnailPath,
            captureLocalTime: storedAsset.captureLocalTime,
            bestKind: storedAsset.bestKind,
            bestFormat: storedAsset.bestFormat,
            durationSeconds: storedAsset.durationSeconds,
            metadataSourceSize: storedAsset.metadataSourceSize,
            metadataSourceMTimeSeconds: storedAsset.metadataSourceMTimeSeconds,
            renderedSourceSize: storedAsset.renderedSourceSize,
            renderedSourceMTimeSeconds: storedAsset.renderedSourceMTimeSeconds,
            contentHash: storedAsset.contentHash,
            contentHashSourceSize: storedAsset.contentHashSourceSize,
            contentHashSourceMTimeSeconds: storedAsset.contentHashSourceMTimeSeconds,
            facesSourceSize: storedAsset.facesSourceSize,
            facesSourceMTimeSeconds: storedAsset.facesSourceMTimeSeconds,
            mediaChoice: storedAsset.mediaChoice
        )
    }

    private func mediaTileDetail(from storedDetail: StoredTileDetail, rootPath: LibraryRootPath) -> MediaTileDetail {
        MediaTileDetail(
            libraryRootPath: rootPath,
            relativePath: storedDetail.relativePath,
            byteSize: storedDetail.byteSize,
            thumbnailPath: storedDetail.thumbnailPath,
            previewPath: storedDetail.previewPath,
            nativePixelWidth: storedDetail.nativePixelSize.map { Int($0.width) },
            nativePixelHeight: storedDetail.nativePixelSize.map { Int($0.height) },
            editRecipe: storedDetail.editRecipe,
            renderedRevision: storedDetail.renderedRevision,
            bestKind: storedDetail.bestKind,
            durationSeconds: storedDetail.durationSeconds,
            renderedSourceSize: storedDetail.renderedSourceSize,
            renderedSourceMTimeSeconds: storedDetail.renderedSourceMTimeSeconds,
            mediaChoice: storedDetail.mediaChoice
        )
    }

    private func upsert(_ state: RootRuntimeState) {
        roots.upsert(state)
    }

    private func removeRoot(path: LibraryRootPath) {
        _ = roots.remove(path: path)
        scanLeases.removeListingScan(for: path)
    }

    private func catalogLibraryState(from state: RootRuntimeState) -> CatalogLibraryState {
        CatalogLibraryState(
            root: state.root,
            sortIndex: state.sortIndex,
            availability: state.availability,
            activity: activity(for: state.path),
            isEjectable: state.isEjectable,
            attachmentGeneration: state.attachmentGeneration
        )
    }

    private func activity(for path: LibraryRootPath) -> CatalogLibraryActivity {
        // Pending full-root scans must read as scanning. clearCurrentScan clears the
        // active lease before the reconcile loop starts the next pending root; without
        // this, waiters can observe a false idle gap and race.
        if scanLeases.hasActiveFilesystemScan(for: path)
            || scanLeases.pendingScanPaths.contains(path)
        {
            return .scanning
        }
        return roots[path]?.activity ?? .idle
    }

    private func libraryRoot(from storedRoot: StoredRoot) -> LibraryRoot {
        LibraryRoot(
            path: storedRoot.path,
            kind: storedRoot.kind,
            deviceIdentity: storedRoot.deviceIdentity,
            displayName: storedRoot.displayName,
            lastSeenAt: storedRoot.lastSeenAt,
            remoteBaseURL: storedRoot.remoteBaseURL
        )
    }

    private func scopePredicate(
        selection: SidebarSelection,
        availableLibraryPaths: Set<LibraryRootPath>
    ) -> CatalogScopePredicate {
        roots.scopePredicate(selection: selection, availableLibraryPaths: availableLibraryPaths)
    }

    private func validateNoOverlap(_ path: LibraryRootPath, ignoring existingRootRowID: Int64? = nil) throws {
        try roots.validateNoOverlap(path, ignoring: existingRootRowID)
    }

    private func enqueueScans(
        _ paths: [LibraryRootPath],
        priority: ScanLeaseController.QueuePriority = .normal
    ) {
        scanLeases.enqueue(paths, priority: priority) { roots[$0] != nil }
        startNextScanIfNeeded()
    }

    /// The lane a root's filesystem walks take (`ScanLeaseController.ScanLane`).
    private func scanLane(for path: LibraryRootPath) -> ScanLeaseController.ScanLane {
        roots[path]?.root.kind.isUserChosenFolder == true ? .fixedLibraries : .removableSource(path)
    }

    /// Starts every queued scan whose lane is free, in queue order: a card attached while
    /// a library rescans is read at once in its own lane.
    private func startNextScanIfNeeded() {
        guard !reconcilePassRunning else {
            return
        }
        while true {
            let busyLanes = Set(scanLeases.activeScans.keys)
            guard let nextPath = scanLeases.takeFirstPending(where: { !busyLanes.contains(scanLane(for: $0)) }) else {
                return
            }
            guard roots[nextPath] != nil,
                  let rootRowID = roots[nextPath]?.rowID
            else {
                continue
            }
            if namespaceMutationLeases[nextPath] != nil {
                // Defer until lease release; do not spin the pending queue.
                scanLeases.markRescanAfterCurrentScan(nextPath)
                continue
            }
            guard rootIsAvailable(nextPath) else {
                markRootUnavailableBeforeScan(nextPath)
                continue
            }
            setAvailability(.available, for: nextPath)
            let lane = scanLane(for: nextPath)
            let scan = scanLeases.makeActiveScan(
                rootPath: nextPath,
                rootRowID: rootRowID,
                startNamespaceMutationEpoch: roots[nextPath]?.namespaceMutationEpoch ?? 0
            )
            scanLeases.beginFilesystemScan(scan, lane: lane)
            filesystemWatchingArmed.insert(nextPath)
            filesystemWatcher.addRoot(nextPath)
            notifyCatalogChanged()
            OtosLog.catalog.info("Catalog scan started path=\(nextPath.rawValue, privacy: .public)")
            recordDiagnostic(
                operation: "catalog.scan",
                phase: "start",
                fields: ["rootPath": nextPath.rawValue, "lane": lane.diagnosticName]
            )
            scanTasks[lane] = Task.detached(priority: .utility) { [scanner, scanCadence] in
                do {
                    let observation = try await scanner.scanRoot(nextPath, scanCadence) { batch in
                        try await self.recordScannedBatch(batch, scan: scan)
                    }
                    await self.scanCompleted(scan: scan, observation: observation)
                } catch is CancellationError {
                    await self.scanCancelled(scan: scan)
                } catch {
                    await self.scanFailed(scan: scan, error: error)
                }
            }
        }
    }

    private func recordScannedBatch(_ batch: [ScannedMediaFile], scan: ActiveScan) async throws {
        guard owns(scan) else {
            await recordIgnoredStaleCallback(scan, callback: "batch.beforeWrite")
            throw CancellationError()
        }

        let dbQueue = try database()
        let scanCapabilities = roots[scan.rootPath]?.capabilities ?? .unknown
        let state = OtosSignpost.persistence.beginInterval("CatalogScanBatchWrite")
        let timedRows = try await timedWrite(dbQueue) { db in
            var rows = CatalogRowChanges()
            for file in batch {
                try rows.record(Self.upsertScannedFile(
                    file,
                    libraryRootPath: scan.rootPath,
                    libraryRootID: scan.rootRowID,
                    capabilities: scanCapabilities,
                    db: db
                ))
            }
            return rows
        }
        OtosSignpost.persistence.endInterval("CatalogScanBatchWrite", state)
        let rows = timedRows.value

        // The store actor can process remove/cancel messages while SQLite is
        // writing. Recheck ownership before notifying from this batch.
        guard owns(scan) else {
            await recordIgnoredStaleCallback(scan, callback: "batch.afterWrite")
            throw CancellationError()
        }

        // SQLite reported whether this batch inserted a new row or changed existing
        // filesystem facts. Identical rescans publish nothing; changed dates still
        // count because Date sort and enrichment priority fall back to them. A
        // changed batch is a real import-occupancy change (added row or resized
        // file), so it advances the occupancy revision; identical rescans do not,
        // which is what lets import planning settle against a churning cloud root.
        if let change = rows.notification {
            bumpNamespaceRevision(for: scan.rootPath)
            notifyCatalogChanged(change)
        }
        recordScanBatchWrite(scan: scan, scannedCount: batch.count, timed: timedRows)
        await boundWAL(reason: "scanBatch")
    }

    private func recordScanBatchWrite(
        scan: ActiveScan,
        scannedCount: Int,
        timed timing: DatabaseTimedValue<CatalogRowChanges>
    ) {
        let rows = timing.value
        let visibleChange = !rows.isEmpty
        let changedCount = rows.inserted + rows.updated
        OtosLog.catalog.debug(
            """
            Catalog scan batch path=\(scan.rootPath.rawValue, privacy: .public) \
            count=\(scannedCount, privacy: .public) changed=\(visibleChange, privacy: .public) \
            waitMs=\(timing.waitMs, privacy: .public) \
            execMs=\(timing.execMs, privacy: .public) \
            writeMs=\(timing.totalMs, privacy: .public)
            """
        )
        OtosLog.catalog.notice(
            "op=catalog.scan.batch phase=finish rootPath=\(scan.rootPath.rawValue, privacy: .public) count=\(scannedCount, privacy: .public) changed=\(visibleChange, privacy: .public) changedCount=\(changedCount, privacy: .public) inserted=\(rows.inserted, privacy: .public) updated=\(rows.updated, privacy: .public) waitMs=\(timing.waitMs, privacy: .public) execMs=\(timing.execMs, privacy: .public) writeMs=\(timing.totalMs, privacy: .public)"
        )
    }

    private func scanCompleted(scan: ActiveScan, observation: CatalogScanObservation) async {
        guard owns(scan) else {
            await recordIgnoredStaleCallback(scan, callback: "completion")
            return
        }

        do {
            let deletedCount = try await reconcileMissingAssets(
                scan: scan,
                observedPaths: observation.mediaPaths
            )
            let canReconcileCompanionDeletions = scanCanDelete(scan)
            let companionChanged = try await applyAndReconcileCompanions(
                scan: scan,
                companions: observation.companions,
                reconcileMissing: canReconcileCompanionDeletions && scanCanDelete(scan)
            )
            if var state = roots[scan.rootPath] {
                state.skippedPackageCount = observation.skippedPackageCount
                upsert(state)
            }
            // Media additions/resizes already advanced occupancy per changed batch.
            // Deletions and companion-inventory changes surface only at completion,
            // so bump occupancy here for those; an identical rescan (no deletions,
            // no companion change) advances only the general planRevision, which the
            // import coordinator treats as a cheap no-op wake.
            if deletedCount > 0 || companionChanged {
                bumpNamespaceRevision(for: scan.rootPath)
            } else {
                bumpPlanRevision(for: scan.rootPath)
            }
            if companionChanged || observation.skippedPackageCount > 0 {
                notifyCatalogChanged()
            }
            OtosLog.catalog.info(
                """
                Catalog scan completed path=\(scan.rootPath.rawValue, privacy: .public) \
                observed=\(observation.mediaPaths.count, privacy: .public) \
                companions=\(observation.companions.count, privacy: .public) \
                deleted=\(deletedCount, privacy: .public) \
                skippedPackages=\(observation.skippedPackageCount, privacy: .public)
                """
            )
            OtosLog.catalog.notice(
                "op=catalog.scan phase=finish rootPath=\(scan.rootPath.rawValue, privacy: .public) observed=\(observation.mediaPaths.count, privacy: .public) companionCount=\(observation.companions.count, privacy: .public) deleted=\(deletedCount, privacy: .public) skippedPackageCount=\(observation.skippedPackageCount, privacy: .public)"
            )
            if !canReconcileCompanionDeletions || !scanCanDelete(scan) {
                let dirty = filesystemDirty[scan.rootPath]
                recordDiagnostic(
                    operation: "catalog.scan.reconcile",
                    phase: "deferredStaleObservation",
                    fields: [
                        "rootPath": scan.rootPath.rawValue,
                        "rootRowID": "\(scan.rootRowID)",
                        "leaseGeneration": "\(scan.leaseGeneration)",
                        "startEpoch": "\(scan.startNamespaceMutationEpoch)",
                        "currentEpoch": "\(roots[scan.rootPath]?.namespaceMutationEpoch ?? 0)",
                        "fileScopeCount": "\(dirty?.fileCount ?? 0)",
                        "subtreeScopeCount": "\(dirty?.subtreeCount ?? 0)",
                        "rootScopeCount": dirty?.isRootDirty == true ? "1" : "0",
                    ]
                )
            }
            lastSuccessfulFullRootScanAt[scan.rootPath] = .now
        } catch is CancellationError {
            await recordIgnoredStaleCallback(scan, callback: "reconciliation")
            return
        } catch {
            OtosLog.catalog.error(
                """
                Catalog scan reconciliation failed path=\(scan.rootPath.rawValue, privacy: .public) \
                error=\(String(describing: error), privacy: .public)
                """
            )
            OtosLog.catalog.error(
                "op=catalog.scan.reconcile phase=error rootPath=\(scan.rootPath.rawValue, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
        }

        clearCurrentScan(scan, armFilesystemWatching: true)
    }

    private func applyAndReconcileCompanions(
        scan: ActiveScan,
        companions: [ScannedCompanionFile],
        underSubtree: MediaRelativePath? = nil,
        reconcileMissing: Bool = true
    ) async throws -> Bool {
        guard owns(scan) else {
            throw CancellationError()
        }
        if reconcileMissing {
            guard scanCanDelete(scan) else {
                return false
            }
        }
        let dbQueue = try database()
        let scanCapabilities = roots[scan.rootPath]?.capabilities ?? .unknown
        let timed = try await timedWrite(dbQueue) { db in
            let upserted = try Self.applyScannedCompanions(
                companions,
                libraryRootID: scan.rootRowID,
                capabilities: scanCapabilities,
                db: db
            )
            let deleted = if reconcileMissing {
                try Self.reconcileMissingCompanions(
                    libraryRootID: scan.rootRowID,
                    observedPaths: Set(companions.map(\.relativePath)),
                    capabilities: scanCapabilities,
                    underSubtree: underSubtree,
                    db: db
                )
            } else {
                0
            }
            return upserted + deleted
        }
        guard owns(scan) else {
            throw CancellationError()
        }
        return timed.value > 0
    }

    /// Reconciliation changes durable membership as one actor-owned operation.
    /// Projection validates membership directly through Store queries, so Store does not
    /// maintain a second per-asset cache-invalidation fact alongside SQLite.
    private func reconcileMissingAssets(
        scan: ActiveScan,
        observedPaths: Set<MediaRelativePath>,
        underSubtree: MediaRelativePath? = nil
    ) async throws -> Int {
        guard owns(scan) else {
            throw CancellationError()
        }
        guard scanCanDelete(scan) else {
            return 0
        }
        let scanCapabilities = roots[scan.rootPath]?.capabilities ?? .unknown
        let dbQueue = try database()
        let existingRows = try await dbQueue.read { db in
            try Self.fetchExistingAssetRows(
                libraryRootID: scan.rootRowID,
                underSubtree: underSubtree,
                db: db
            )
        }
        guard owns(scan) else {
            throw CancellationError()
        }
        guard scanCanDelete(scan) else {
            return 0
        }
        let observedKeys = Set(observedPaths.map {
            FilesystemNamespaceSemantics.nameKey(relativePath: $0, capabilities: scanCapabilities)
        })
        // A row whose file is in the system Trash is missing from its path but not proven
        // deleted: it stays until the Trash no longer holds the file (ADR 0022).
        let missingRows = existingRows.filter {
            !observedKeys.contains(
                FilesystemNamespaceSemantics.nameKey(relativePath: $0.relativePath, capabilities: scanCapabilities)
            ) && !Self.isHeldInTrash(trashPath: $0.trashPath)
        }
        guard !missingRows.isEmpty else {
            return 0
        }
        guard scanCanDelete(scan) else {
            return 0
        }
        // Capture the thumbnail files of soon-to-be-purged assets before their rows are
        // removed, so overlay is purged with the item (ADR 0008): the catalog rows and
        // thumbnail file all go together on proven deletion.
        let purgedThumbnails: [String] = missingRows.flatMap(\.derivedImagePaths)
        let loggedRows = Array(missingRows.prefix(20))
        for row in loggedRows {
            OtosLog.catalog.notice(
                "op=catalog.scan.reconcile phase=delete rootPath=\(scan.rootPath.rawValue, privacy: .public) relativePath=\(row.relativePath.rawValue, privacy: .public) derivedImages=\(row.derivedImagePaths.count, privacy: .public) hadEnrichment=\(row.hadEnrichment, privacy: .public)"
            )
        }
        let message = "op=catalog.scan.reconcile phase=deleteSummary "
            + "rootPath=\(scan.rootPath.rawValue) "
            + "count=\(missingRows.count) "
            + "logged=\(loggedRows.count)"
        OtosLog.catalog.notice("\(message, privacy: .public)")
        let state = OtosSignpost.persistence.beginInterval("CatalogScanReconcile")
        defer { OtosSignpost.persistence.endInterval("CatalogScanReconcile", state) }

        try await dbQueue.write { db in
            for row in missingRows {
                try Self.deleteAssetRow(rootRowID: scan.rootRowID, relativePath: row.relativePath, db: db)
            }
        }
        // Removal and same-path replacement can run while GRDB owns the writer.
        // Never treat an old row's reconciliation as proof about the replacement root.
        guard owns(scan) else {
            throw CancellationError()
        }
        if let thumbnailDirectory {
            for name in purgedThumbnails {
                ThumbnailStore.delete(name, in: thumbnailDirectory)
            }
        }
        return missingRows.count
    }

    private func scanCancelled(scan: ActiveScan) async {
        guard owns(scan) else {
            await recordIgnoredStaleCallback(scan, callback: "cancellation")
            return
        }
        OtosLog.catalog.info("Catalog scan cancelled path=\(scan.rootPath.rawValue, privacy: .public)")
        OtosLog.catalog.notice(
            "op=catalog.scan phase=cancel rootPath=\(scan.rootPath.rawValue, privacy: .public)"
        )
        clearCurrentScan(scan, armFilesystemWatching: false)
    }

    private func scanFailed(scan: ActiveScan, error: Error) async {
        guard owns(scan) else {
            await recordIgnoredStaleCallback(scan, callback: "failure")
            return
        }
        let errorDescription = if case CatalogScanError.filesystemErrorsEncountered = error {
            "filesystemErrorsEncountered"
        } else {
            String(describing: error)
        }
        let isStillAvailable = rootIsAvailable(scan.rootPath)
        if !isStillAvailable {
            setAvailability(.unavailable, for: scan.rootPath)
            OtosLog.catalog.error(
                "Catalog scan failed because root is unavailable path=\(scan.rootPath.rawValue, privacy: .public)"
            )
            OtosLog.catalog.notice(
                "op=catalog.library.availability phase=unavailable rootPath=\(scan.rootPath.rawValue, privacy: .public)"
            )
        } else {
            OtosLog.catalog.error(
                """
                Catalog scan failed path=\(scan.rootPath.rawValue, privacy: .public) \
                error=\(errorDescription, privacy: .public)
                """
            )
        }
        var diagnosticFields = [
            "rootPath": scan.rootPath.rawValue,
            "error": errorDescription,
        ]
        if case let CatalogScanError.filesystemErrorsEncountered(count, summaries) = error {
            OtosLog.fileAccess.error("Filesystem scan errors count=\(count, privacy: .public)")
            diagnosticFields["issueCount"] = "\(count)"
            for (index, summary) in summaries.enumerated() {
                let prefix = "issue\(index)"
                diagnosticFields["\(prefix).kind"] = summary.kind
                diagnosticFields["\(prefix).error"] = summary.errorDescription
                diagnosticFields["\(prefix).count"] = "\(summary.count)"
                diagnosticFields["\(prefix).examples"] = summary.examplePaths.joined(separator: " | ")
            }
        }
        OtosLog.catalog.error(
            "op=catalog.scan phase=error \(otosLogFields(diagnosticFields), privacy: .public)"
        )
        clearCurrentScan(scan, armFilesystemWatching: true)
        if roots[scan.rootPath]?.root.kind.isRemovable == true, roots[scan.rootPath]?.rowID == scan.rootRowID {
            await releaseAwaitingPresence(of: scan.rootPath, rootRowID: scan.rootRowID, reason: "scanFailed")
        }
    }

    private func clearCurrentScan(_ scan: ActiveScan, armFilesystemWatching: Bool) {
        guard scanLeases.isCurrentFilesystemScan(scan) else {
            return
        }
        let rootPath = scan.rootPath
        guard let cleared = scanLeases.clearFilesystemScan(scan) else {
            return
        }
        let needsRescan = cleared.needsRescan
        scanTasks.removeValue(forKey: cleared.lane)

        if armFilesystemWatching, roots[rootPath] != nil {
            filesystemWatchingArmed.insert(rootPath)
        }

        if needsRescan {
            // Reorganization (and other independently verified owners) still use
            // rescanAfterCurrentScan for an unconditional full-root follow-up.
            filesystemEventBatches.removeValue(forKey: rootPath)
            filesystemDirty[rootPath, default: FilesystemDirtyAccumulator()].insertRoot()
            enqueueScans([rootPath])
        }

        notifyCatalogChanged()
        // Drain every dirty root before starting the next queued full-root scan:
        // subtree/root dirt waits while any scan holds the global lease, so starting B
        // first would leave A's retained dirt waiting behind B.
        requestReconcile()
    }

    /// Rings the reconcile loop, starting it if this Store has none yet. The loop starts
    /// on first request rather than in `start()` because a Store that only adds and
    /// scans libraries still needs its queued scans advanced. It holds the Store weakly
    /// and ends when the Store does; after `shutdown()` no root is armed and no scan is
    /// queued, so a request then reconciles nothing. Each ring first runs the library
    /// removals a lease release handed over: like held-back dirt, they are work a lease
    /// kept from running, and a removed root has no dirt left to reconcile.
    private func requestReconcile() {
        reconcileRequested &+= 1
        if reconcileLoop == nil {
            let (bell, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            reconcileDoorbell = continuation
            reconcileLoop = Task { [weak self] in
                for await _ in bell {
                    guard let self else { return }
                    await runHandedOffLibraryRemovals()
                    await runReconcilePass()
                }
            }
        }
        reconcileDoorbell?.yield(())
    }

    private func runReconcilePass() async {
        guard reconcileRequested != reconcileCovered else {
            return
        }
        let startedFrom = reconcileRequested
        reconcilePassRunning = true
        for root in filesystemDirty.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            await drainDirtyReconcile(for: root)
        }
        reconcilePassRunning = false
        reconcileCovered = startedFrom
        startNextScanIfNeeded()
        if reconcileRequested != reconcileCovered {
            reconcileDoorbell?.yield(())
        }
    }

    private func notifyCatalogChanged(_ change: CatalogStoreChange = .catalogChanged) {
        let state = OtosSignpost.catalog.beginInterval("CatalogChangeNotify")
        defer {
            OtosSignpost.catalog.endInterval("CatalogChangeNotify", state)
        }
        for (id, continuation) in changeContinuations {
            continuation.yield(change)
            changeDeliveries[id]?.recordDelivery()
        }
    }

    private func emitPlanningChange(rootPath: LibraryRootPath, state: RootRuntimeState) {
        let change = RootPlanningChange(
            rootPath: rootPath,
            namespaceRevision: state.namespaceRevision,
            namingRevision: state.namingRevision
        )
        // Emit-side observability: a silence on the coordinator
        // side can now be attributed to "no events emitted" vs "events not received"
        // by matching this line against the coordinator's receive/refresh lines.
        let listenerCount = planningChangeContinuations.count
        OtosLog.catalog.noticeOperation(
            "catalog.planningChange",
            phase: "emit",
            fields: [
                "rootPath": rootPath.rawValue,
                "namespaceRevision": "\(state.namespaceRevision)",
                "namingRevision": "\(state.namingRevision)",
                "listeners": "\(listenerCount)",
            ]
        )
        for (id, continuation) in planningChangeContinuations {
            continuation.yield(change)
            planningChangeDeliveries[id]?.recordDelivery()
        }
    }

    private func removeChangeContinuation(_ id: UUID) {
        changeContinuations.removeValue(forKey: id)
        changeDeliveries.removeValue(forKey: id)
    }

    private func removePlanningChangeContinuation(_ id: UUID) {
        planningChangeContinuations.removeValue(forKey: id)
        planningChangeDeliveries.removeValue(forKey: id)
    }

    private func rootIsAvailable(_ path: LibraryRootPath) -> Bool {
        let state = OtosSignpost.fileAccess.beginInterval("CatalogRootAvailabilityCheck")
        defer {
            OtosSignpost.fileAccess.endInterval("CatalogRootAvailabilityCheck", state)
        }
        do {
            let values = try path.url.resourceValues(forKeys: [.isDirectoryKey])
            return values.isDirectory == true
        } catch {
            return false
        }
    }

    @discardableResult
    private func setAvailability(_ availability: LibraryAvailability, for path: LibraryRootPath) -> Bool {
        roots.setAvailability(availability, for: path)
    }

    private func markRootUnavailableBeforeScan(_ path: LibraryRootPath) {
        let changed = setAvailability(.unavailable, for: path)
        OtosLog.catalog.info("Library root unavailable before scan path=\(path.rawValue, privacy: .public)")
        recordDiagnostic(
            operation: "catalog.library.availability",
            phase: "unavailable",
            fields: ["rootPath": path.rawValue]
        )
        if changed {
            notifyCatalogChanged()
        }
    }

    /// Draining only the roots restored by the initial read keeps two automatic
    /// behaviors distinct: launch scans happen once, while a newly added root is
    /// scanned by its add intent and is never duplicated by a later `start()`.
    private func requestLoadedRootScansIfNeeded() {
        guard !unrequestedLoadedRootPaths.isEmpty else {
            return
        }
        let paths = unrequestedLoadedRootPaths
        unrequestedLoadedRootPaths.removeAll(keepingCapacity: false)
        enqueueScans(paths)
    }

    private func startFilesystemWatchingIfNeeded() {
        guard !filesystemWatchingStarted else {
            return
        }
        filesystemWatchingStarted = true
        // FSEvents reaches us through a synchronous C callback. Events travel one
        // ordered stream to one consumer on this actor (ADR 0032), which holds the Store
        // weakly while it waits and ends with it.
        let (events, sink) = AsyncStream<FilesystemEvent>.makeStream(bufferingPolicy: .unbounded)
        filesystemEventSink = sink
        filesystemEventConsumer = Task { [weak self] in
            for await event in events {
                guard let self else {
                    return
                }
                await handleFilesystemEvent(event)
            }
        }
        filesystemWatcher.start(watchedRootPaths) { event in
            sink.yield(event)
        }
    }

    private var watchedRootPaths: [LibraryRootPath] {
        roots.watchedRootPaths
    }

    private func handleFilesystemEvent(_ event: FilesystemEvent) {
        let signpost = OtosSignpost.catalog.beginInterval("FilesystemEventIntake")
        defer {
            handledFilesystemEventCount += 1
            OtosSignpost.catalog.endInterval("FilesystemEventIntake", signpost)
        }

        guard let root = CatalogPath.owningRoot(for: event.path, among: roots.keys) else {
            recordFilesystemEventDrop(path: event.path, root: nil, reason: "outsideRoots")
            return
        }

        let hasActiveScan = scanLeases.hasActiveFilesystemScan(for: root)
        // Arm watching as soon as the root is known and available, and never
        // drop events while a scan lease owns the root (ARC-041).
        if !filesystemWatchingArmed.contains(root) {
            if hasActiveScan || roots[root]?.availability == .available {
                filesystemWatchingArmed.insert(root)
                bumpPlanRevision(for: root)
            } else {
                recordFilesystemEventDrop(path: event.path, root: root, reason: "unarmed")
                return
            }
        }

        OtosLog.catalog.debug(
            "Filesystem event received path=\(event.path, privacy: .public) root=\(root.rawValue, privacy: .public)"
        )
        if namespaceMutationLeases[root] != nil {
            markNamespaceMutationLeaseDirty(for: root)
            bumpPlanRevision(for: root)
            filesystemEventBatches.removeValue(forKey: root)
            OtosLog.catalog.debug(
                "Filesystem reconcile deferred under reorganization lease path=\(root.rawValue, privacy: .public)"
            )
            return
        }
        filesystemEventBatches[root, default: []].append(event)
        startFilesystemEventPassIfIdle(for: root)
    }

    private func recordFilesystemEventDrop(path: String, root: LibraryRootPath?, reason: String) {
        if let root {
            OtosLog.catalog.debug(
                """
                Filesystem event ignored path=\(path, privacy: .public) \
                root=\(root.rawValue, privacy: .public) reason=\(reason, privacy: .public)
                """
            )
        } else {
            OtosLog.fileAccess.debug(
                "Filesystem event ignored outside library roots path=\(path, privacy: .public)"
            )
        }
        var fields: [String: String] = [
            "path": path,
            "reason": reason,
        ]
        if let root {
            fields["rootPath"] = root.rawValue
        }
        recordDiagnostic(
            operation: "catalog.filesystemEvent",
            phase: "drop",
            fields: fields
        )
    }

    private func startFilesystemEventPassIfIdle(for root: LibraryRootPath) {
        guard filesystemEventPasses[root] == nil else {
            return
        }
        let generation = (filesystemEventPassGenerations[root] ?? 0) &+ 1
        filesystemEventPassGenerations[root] = generation
        filesystemEventPasses[root] = Task { [root] in
            while !Task.isCancelled, filesystemEventBatches[root]?.isEmpty == false {
                await processFilesystemEventBatch(for: root)
            }
            // Checked and cleared with no await between them: an event that arrives
            // after this either finds the pass gone and starts one, or was taken above.
            if filesystemEventPassGenerations[root] == generation {
                filesystemEventPasses.removeValue(forKey: root)
            }
        }
    }

    /// Best-effort boundary log from synchronous Store branches. Captures only
    /// scalar strings — never catalog state or asset batches.
    private func recordDiagnostic(
        operation: String,
        phase: String,
        fields: [String: String] = [:]
    ) {
        OtosLog.catalog.notice(
            "op=\(operation, privacy: .public) phase=\(phase, privacy: .public) \(otosLogFields(fields), privacy: .public)"
        )
    }

    /// Keeps the WAL bounded after a bulk write. A log SQLite keeps resetting is reused
    /// from its start and its file stays near one write's pages; a starved one only
    /// grows, so the file's size is the fact that says so, and reading it costs a `stat`.
    /// Past `walByteBudget`, a truncating checkpoint behind GRDB's barrier empties the
    /// log: the barrier waits for the reads in flight and holds new ones until it is
    /// done, and its callback form runs on GRDB's own queue, so the wait never blocks a
    /// cooperative thread. A failed checkpoint is logged and leaves the log as it was;
    /// the next bulk write tries again.
    private func boundWAL(reason: String) async {
        guard databaseFileURL != nil, let walBytes = walFileSizeBytes() else {
            return
        }
        guard walBytes > walByteBudget else {
            OtosLog.catalog.noticeOperation("catalog.database.wal", phase: "sample", fields: [
                "reason": reason,
                "walBytes": "\(walBytes)",
            ])
            return
        }
        do {
            let dbWriter = try database()
            let start = ContinuousClock.now
            let checkpoint: (walFrameCount: Int, checkpointedFrameCount: Int) = try await withCheckedThrowingContinuation { continuation in
                dbWriter.asyncBarrierWriteWithoutTransaction { database in
                    continuation.resume(with: Result { try database.get().checkpoint(.truncate) })
                }
            }
            OtosLog.catalog.noticeOperation("catalog.database.wal", phase: "truncated", fields: [
                "reason": reason,
                "walBytesBefore": "\(walBytes)",
                "walBytes": "\(walFileSizeBytes() ?? -1)",
                "walFrames": "\(checkpoint.walFrameCount)",
                "barrierMs": "\(DiagnosticsTiming.milliseconds(since: start))",
            ])
        } catch {
            OtosLog.catalog.errorOperation("catalog.database.wal", phase: "checkpointFailed", fields: [
                "reason": reason,
                "walBytes": "\(walBytes)",
                "error": String(describing: error),
            ])
        }
    }

    private func walFileSizeBytes() -> Int64? {
        guard let databaseFileURL else {
            return nil
        }
        let walPath = databaseFileURL.path(percentEncoded: false) + "-wal"
        guard FileManager.default.fileExists(atPath: walPath) else {
            return 0
        }
        guard let size = try? FileManager.default.attributesOfItem(atPath: walPath)[.size] as? NSNumber else {
            return nil
        }
        return size.int64Value
    }

    private func processFilesystemEventBatch(for root: LibraryRootPath) async {
        let signpost = OtosSignpost.catalog.beginInterval("FilesystemEventBatch")
        defer {
            OtosSignpost.catalog.endInterval("FilesystemEventBatch", signpost)
        }

        let pendingEvents = filesystemEventBatches.removeValue(forKey: root) ?? []
        knownMaterializationSuppression.pruneExpired()
        let activeSuppression = knownMaterializationSuppression.activeExpiries()
        let now = ContinuousClock.now
        var keptEvents: [FilesystemEvent] = []
        keptEvents.reserveCapacity(pendingEvents.count)
        var suppressedCount = 0
        var stagingSuppressedCount = 0
        for event in pendingEvents {
            let flags = FilesystemEventFlags(event: event)
            let relativePath = CatalogPath.relativePath(rootPath: root, absolutePath: event.path)
            if let relativePath,
               KnownMaterializationSuppressionPolicy.isSuppressible(
                   flags: flags,
                   id: MediaAssetID(libraryRootPath: root, relativePath: relativePath),
                   active: activeSuppression,
                   now: now
               )
            {
                suppressedCount += 1
                continue
            }
            // Otos's own import staging files (`.otos-import-staging`, written into the
            // watched destination root while the import executor copies) are never
            // catalogued and must not record namespace mutations, bump occupancy, or
            // fire reconcile/replan churn.
            if let relativePath, relativePath.rawValue.hasSuffix(MediaImportExecutor.destinationTempSuffix) {
                stagingSuppressedCount += 1
                continue
            }
            keptEvents.append(event)
        }
        if suppressedCount > 0 {
            OtosLog.catalog.notice(
                "op=catalog.materializationEvent phase=suppress rootPath=\(root.rawValue, privacy: .public) count=\(suppressedCount, privacy: .public)"
            )
        }
        if stagingSuppressedCount > 0 {
            OtosLog.catalog.notice(
                "op=catalog.stagingEvent phase=suppress rootPath=\(root.rawValue, privacy: .public) count=\(stagingSuppressedCount, privacy: .public)"
            )
        }

        let decision = FilesystemReconciler.decide(
            events: keptEvents,
            root: root,
            rootExists: roots[root] != nil,
            isArmed: filesystemWatchingArmed.contains(root),
            isAvailable: rootIsAvailable(root)
        )
        classifiedFilesystemEventCount += pendingEvents.count

        switch decision {
        case let .drop(reason):
            await recordFilesystemEventDrop(root: root, reason: reason)
        case .noop:
            break
        case let .accumulate(scopes):
            var fileCount = 0
            var subtreeCount = 0
            var rootCount = 0
            for dirt in scopes {
                switch dirt.scope {
                case .root:
                    recordIndependentNamespaceMutation(root: root, scope: .root)
                    rootCount += dirt.eventCount
                case let .subtree(path):
                    recordIndependentNamespaceMutation(root: root, scope: .subtree(path))
                    subtreeCount += dirt.eventCount
                case let .file(path):
                    recordIndependentNamespaceMutation(
                        root: root,
                        scope: .file(path),
                        fileAction: dirt.fileAction ?? .upsert
                    )
                    fileCount += dirt.eventCount
                }
            }
            OtosLog.catalog.notice(
                "op=catalog.filesystemEvent phase=classify rootPath=\(root.rawValue, privacy: .public) eventCount=\(keptEvents.count, privacy: .public) file=\(fileCount, privacy: .public) subtree=\(subtreeCount, privacy: .public) root=\(rootCount, privacy: .public) suppressed=\(suppressedCount, privacy: .public)"
            )
            requestReconcile()
        }
    }

    /// Drains typed dirty scopes for one root.
    /// File dirt may settle while another root holds the global scan lease.
    /// Subtree/root dirt requires the global lease to be free. Loops so dirt that
    /// arrives mid-await is not lost.
    private func drainDirtyReconcile(for root: LibraryRootPath) async {
        while true {
            guard roots[root] != nil else {
                filesystemDirty.removeValue(forKey: root)
                return
            }
            guard namespaceMutationLeases[root] == nil else {
                return
            }
            guard !scanLeases.hasActiveFilesystemScan(for: root) else {
                return
            }
            guard filesystemWatchingArmed.contains(root), rootIsAvailable(root) else {
                return
            }
            guard var accumulator = filesystemDirty[root], !accumulator.isEmpty else {
                filesystemDirty.removeValue(forKey: root)
                return
            }
            let needsLease = accumulator.isRootDirty || !accumulator.subtrees.isEmpty
            let lane = scanLane(for: root)
            if needsLease, scanLeases.isLaneBusy(lane) || scanTasks[lane] != nil {
                return
            }
            let dirt = accumulator.take()
            filesystemDirty[root] = accumulator

            if dirt.isRootDirty {
                OtosLog.catalog.info("Filesystem rescan scheduled path=\(root.rawValue, privacy: .public)")
                OtosLog.catalog.notice(
                    "op=catalog.filesystemEvent phase=schedule mode=fullRoot rootPath=\(root.rawValue, privacy: .public) eventCount=\(dirt.fileCount + dirt.subtreeCount + 1, privacy: .public)"
                )
                enqueueScans([root])
                return
            }

            if !dirt.subtrees.isEmpty {
                await runScopedReconcile(root: root, dirt: dirt)
                continue
            }

            await reconcileFileDirt(root: root, files: dirt.files)
        }
    }

    /// Reconciles each dirty file from what the filesystem says now. The dirt was taken
    /// at the root's current epoch; a path whose write finds the root changed since is
    /// put back, with every path not yet reached, and the next pass observes it again.
    private func reconcileFileDirt(
        root: LibraryRootPath,
        files: [MediaRelativePath: SingleFileReconcileOperation]
    ) async {
        guard let rootState = roots[root] else {
            return
        }
        let rootRowID = rootState.rowID
        let witness = ReconcileWitness(root: root, epoch: rootState.namespaceMutationEpoch)
        let started = ContinuousClock.now
        var changedCount = 0
        var deferredCount = 0
        let ordered = files.keys.sorted(by: { $0.rawValue < $1.rawValue })
        for (index, path) in ordered.enumerated() {
            let result = await reconcileFile(
                path,
                action: files[path] ?? .upsert,
                root: root,
                rootRowID: rootRowID,
                witness: witness
            )
            if case .changed = result {
                changedCount += 1
            }
            if case .deferred = result {
                var dirty = filesystemDirty[root] ?? FilesystemDirtyAccumulator()
                for remaining in ordered[index...] {
                    dirty.insert(.file(remaining), fileAction: files[remaining] ?? .upsert)
                }
                filesystemDirty[root] = dirty
                deferredCount = ordered.count - index
                break
            }
        }
        if changedCount > 0 {
            bumpNamespaceRevision(for: root)
            notifyCatalogChanged()
        }
        let totalMs = DiagnosticsTiming.milliseconds(since: started)
        OtosLog.catalog.notice(
            "op=catalog.reconcile phase=finish mode=file rootPath=\(root.rawValue, privacy: .public) scopeCount=\(files.count, privacy: .public) changed=\(changedCount, privacy: .public) deferred=\(deferredCount, privacy: .public) totalMs=\(totalMs, privacy: .public)"
        )
    }

    private func runScopedReconcile(root: LibraryRootPath, dirt: FilesystemDirtyAccumulator) async {
        guard let rootRowID = roots[root]?.rowID else {
            return
        }
        let scan = scanLeases.makeActiveScan(
            rootPath: root,
            rootRowID: rootRowID,
            startNamespaceMutationEpoch: roots[root]?.namespaceMutationEpoch ?? 0
        )
        let lane = scanLane(for: root)
        scanLeases.beginFilesystemScan(scan, lane: lane)
        filesystemWatchingArmed.insert(root)
        filesystemWatcher.addRoot(root)
        notifyCatalogChanged()
        OtosLog.catalog.info(
            "Catalog scoped reconcile started path=\(root.rawValue, privacy: .public) subtrees=\(dirt.subtreeCount, privacy: .public)"
        )
        recordDiagnostic(
            operation: "catalog.reconcile",
            phase: "start",
            fields: [
                "rootPath": root.rawValue,
                "mode": "subtree",
                "subtreeCount": "\(dirt.subtreeCount)",
                "fileCount": "\(dirt.fileCount)",
            ]
        )

        // The directory walk must not run on this actor: a stored scanner closure and
        // `LiveCatalogScanner.scan` are `nonisolated async`, which under
        // `NonisolatedNonsendingByDefault` runs on the caller's actor. A detached task is the
        // same mechanism a full scan uses; every Store mutation below hops back through an
        // actor method that revalidates the scan lease first.
        scanTasks[lane] = Task.detached(priority: .utility) { [scanner, scanCadence] in
            do {
                var totalObserved = 0
                var totalDeleted = 0
                var catalogChanged = false
                for subtree in dirt.subtrees.sorted(by: { $0.rawValue < $1.rawValue }) {
                    try Task.checkCancellation()
                    guard await self.owns(scan) else {
                        return
                    }
                    let observation = try await scanner.scanSubtree(root, subtree, scanCadence) { batch in
                        try await self.recordScannedBatch(batch, scan: scan)
                    }
                    totalObserved += observation.mediaPaths.count
                    let deleted = try await self.reconcileMissingAssets(
                        scan: scan,
                        observedPaths: observation.mediaPaths,
                        underSubtree: subtree
                    )
                    totalDeleted += deleted
                    let companionChanged = try await self.applyAndReconcileCompanions(
                        scan: scan,
                        companions: observation.companions,
                        underSubtree: subtree
                    )
                    if deleted > 0 || companionChanged {
                        catalogChanged = true
                    }
                }
                await self.completeScopedReconcile(
                    scan: scan,
                    root: root,
                    dirt: dirt,
                    summary: ScopedReconcileSummary(
                        observed: totalObserved,
                        deleted: totalDeleted,
                        catalogChanged: catalogChanged
                    )
                )
            } catch is CancellationError {
                await self.endScopedReconcile(scan: scan, root: root, dirt: dirt, failure: nil)
            } catch {
                await self.endScopedReconcile(scan: scan, root: root, dirt: dirt, failure: error)
            }
        }
    }

    private struct ScopedReconcileSummary {
        let observed: Int
        let deleted: Int
        let catalogChanged: Bool
    }

    /// The post-walk half of a scoped reconcile, as one actor method so the lease check, the
    /// revision bump and the lease release cannot be interleaved by another message.
    private func completeScopedReconcile(
        scan: ActiveScan,
        root: LibraryRootPath,
        dirt: FilesystemDirtyAccumulator,
        summary: ScopedReconcileSummary
    ) async {
        guard owns(scan) else {
            return
        }
        if !dirt.files.isEmpty {
            await reconcileFileDirt(root: root, files: dirt.files)
        }
        if summary.catalogChanged {
            bumpNamespaceRevision(for: root)
        } else {
            bumpPlanRevision(for: root)
        }
        OtosLog.catalog.notice(
            "op=catalog.reconcile phase=finish mode=subtree rootPath=\(root.rawValue, privacy: .public) observed=\(summary.observed, privacy: .public) deleted=\(summary.deleted, privacy: .public)"
        )
        scopedReconcileFinished(scan: scan)
    }

    /// A scoped reconcile that did not finish. Cancellation hands the taken scopes back as
    /// they were; any other failure is an incomplete enumeration, which must not drop them:
    /// it escalates to the root so the next lease drains conservatively.
    private func endScopedReconcile(
        scan: ActiveScan,
        root: LibraryRootPath,
        dirt: FilesystemDirtyAccumulator,
        failure: Error?
    ) async {
        if let failure {
            restoreScopedDirt(root: root, dirt: dirt, escalateToRoot: true)
            await scanFailed(scan: scan, error: failure)
        } else {
            restoreScopedDirt(root: root, dirt: dirt)
            await scanCancelled(scan: scan)
        }
    }

    private func restoreScopedDirt(
        root: LibraryRootPath,
        dirt: FilesystemDirtyAccumulator,
        escalateToRoot: Bool = false
    ) {
        var accumulator = filesystemDirty[root] ?? FilesystemDirtyAccumulator()
        if escalateToRoot {
            accumulator.insertRoot()
        } else {
            for subtree in dirt.subtrees {
                accumulator.insertSubtree(subtree)
            }
            for (path, action) in dirt.files {
                accumulator.insertFile(path, action: action)
            }
        }
        filesystemDirty[root] = accumulator
    }

    private func scopedReconcileFinished(scan: ActiveScan) {
        clearCurrentScan(scan, armFilesystemWatching: true)
    }

    private func startIntegrityScanSchedulerIfNeeded() {
        guard integrityScanTask == nil else {
            return
        }
        // The loop holds the Store weakly across each 15-minute wait and ends once the
        // Store is gone, rather than outliving it as an idle sleeper.
        integrityScanTask = Task { [weak self] in
            while !Task.isCancelled {
                // time: schedule — the 24 h integrity scan, checked every 15 minutes
                try? await Task.sleep(for: CatalogStore.integrityScanPollInterval)
                guard !Task.isCancelled, let self else {
                    return
                }
                await scheduleOverdueIntegrityScans()
            }
        }
    }

    private func scheduleOverdueIntegrityScans() {
        let now = ContinuousClock.now
        for path in roots.keys {
            guard roots[path]?.root.kind.isUserChosenFolder == true else {
                continue
            }
            guard rootIsAvailable(path), filesystemWatchingArmed.contains(path) else {
                continue
            }
            guard namespaceMutationLeases[path] == nil else {
                continue
            }
            if scanLeases.hasActiveFilesystemScan(for: path)
                || scanLeases.pendingScanPaths.contains(path)
            {
                continue
            }
            if let accumulator = filesystemDirty[path], accumulator.isRootDirty {
                continue
            }
            // A root never fully scanned in this process is overdue.
            let age = lastSuccessfulFullRootScanAt[path].map { $0.duration(to: now) }
            if let age, age < Self.integrityScanInterval {
                continue
            }
            filesystemDirty[path, default: FilesystemDirtyAccumulator()].insertRoot()
            OtosLog.catalog.notice(
                "op=catalog.integrityScan phase=schedule rootPath=\(path.rawValue, privacy: .public) successfulScanAgeSec=\(age.map { "\(Int(DiagnosticsTiming.seconds($0)))" } ?? "never", privacy: .public)"
            )
            requestReconcile()
        }
    }

    /// What one file reconcile did. `deferred`: the root changed (or a namespace owner
    /// took it) after this reconcile observed the file, so the observation may be stale
    /// and nothing was written; the path stays dirty for the next pass.
    private enum FileReconcileResult {
        case changed
        case unchanged
        case deferred
    }

    /// A dirt-driven reconcile writes only while the observation it acts on is still the
    /// latest word on the root: no independent mutation since (`epoch`) and no namespace
    /// owner holding it. Checked synchronously right before each write is submitted, so a
    /// mutation's own write, submitted later, is ordered after this one by the writer.
    private struct ReconcileWitness {
        let root: LibraryRootPath
        let epoch: UInt64
    }

    private func isCurrent(_ witness: ReconcileWitness?) -> Bool {
        guard let witness else { return true }
        return roots[witness.root]?.namespaceMutationEpoch == witness.epoch
            && namespaceMutationLeases[witness.root] == nil
    }

    /// Reconciles one path from a single observation of it. An absent file is deleted
    /// from the catalog only when the dirt said it may be (`deleteIfMissing`); a present
    /// file that is not catalog media leaves the catalog; catalog media is upserted.
    /// A failed observation writes nothing and is logged; the next event or scan of the
    /// path observes it again.
    private func reconcileFile(
        _ relativePath: MediaRelativePath,
        action: SingleFileReconcileOperation,
        root: LibraryRootPath,
        rootRowID: Int64,
        witness: ReconcileWitness?
    ) async -> FileReconcileResult {
        let fileURL = root.url.appendingPathComponent(relativePath.rawValue, isDirectory: false)
        let observation: CatalogFileObservation
        do {
            observation = try await scanner.observeFile(fileURL, root)
        } catch {
            OtosLog.catalog.errorOperation("catalog.reconcile", phase: "observeFailed", fields: [
                "rootPath": root.rawValue,
                "path": relativePath.rawValue,
                "error": String(describing: error),
            ])
            return .unchanged
        }
        switch observation {
        case .absent:
            guard action == .deleteIfMissing else {
                return .unchanged
            }
            return await deleteCatalogedPath(relativePath: relativePath, rootRowID: rootRowID, witness: witness)
        case .present(nil):
            return await deleteCatalogedPath(relativePath: relativePath, rootRowID: rootRowID, witness: witness)
        case let .present(observed?):
            return await upsertObservedFile(observed, at: relativePath, root: root, rootRowID: rootRowID, witness: witness)
        }
    }

    private func upsertObservedFile(
        _ observed: CatalogScannedFileReader.ObservedItem,
        at relativePath: MediaRelativePath,
        root: LibraryRootPath,
        rootRowID: Int64,
        witness: ReconcileWitness?
    ) async -> FileReconcileResult {
        let dbQueue: any DatabaseWriter
        do {
            dbQueue = try database()
        } catch {
            OtosLog.catalog.errorOperation("catalog.reconcile", phase: "upsertFailed", fields: [
                "rootPath": root.rawValue,
                "path": relativePath.rawValue,
                "error": String(describing: error),
            ])
            return .unchanged
        }

        do {
            let rootCapabilities = roots[root]?.capabilities ?? .unknown
            guard isCurrent(witness) else {
                return .deferred
            }
            let changed = try await dbQueue.write { db in
                switch observed {
                case let .media(scannedFile):
                    // A path that was a companion and became media must leave the
                    // companion table so identity stays exclusive.
                    _ = try Self.deleteCompanionRow(
                        rootRowID: rootRowID,
                        relativePath: scannedFile.relativePath,
                        db: db
                    )
                    let mediaChanged = try Self.upsertScannedFile(
                        scannedFile,
                        libraryRootPath: root,
                        libraryRootID: rootRowID,
                        capabilities: rootCapabilities,
                        db: db
                    )
                    let pairingChanged = try Self.repairCompanionsInDirectory(
                        of: scannedFile.relativePath,
                        libraryRootID: rootRowID,
                        capabilities: rootCapabilities,
                        db: db
                    )
                    return mediaChanged != .unchanged || pairingChanged
                case let .companion(companion):
                    // A path that was media and became a companion must leave media.
                    let mediaDeleted = try Self.deleteAssetRow(
                        rootRowID: rootRowID,
                        relativePath: companion.relativePath,
                        db: db
                    )
                    let directoryKey = MediaCompanionPairing.directoryKey(of: companion.relativePath)
                    let primaries = try Self.fetchPrimariesInDirectory(
                        libraryRootID: rootRowID,
                        directoryKey: directoryKey,
                        db: db
                    )
                    let paired = MediaCompanionPairing.pair(
                        companions: [companion],
                        primaries: primaries,
                        capabilities: rootCapabilities
                    )
                    var companionChanged = false
                    for item in paired {
                        companionChanged = try Self.upsertCompanion(
                            item,
                            libraryRootID: rootRowID,
                            capabilities: rootCapabilities,
                            db: db
                        ) || companionChanged
                    }
                    return mediaDeleted || companionChanged
                }
            }
            return changed ? .changed : .unchanged
        } catch {
            OtosLog.catalog.errorOperation("catalog.reconcile", phase: "upsertFailed", fields: [
                "rootPath": root.rawValue,
                "path": relativePath.rawValue,
                "error": String(describing: error),
            ])
            return .unchanged
        }
    }

    private func deleteCatalogedPath(
        relativePath: MediaRelativePath,
        rootRowID: Int64,
        witness: ReconcileWitness?
    ) async -> FileReconcileResult {
        let dbQueue: any DatabaseWriter
        do {
            dbQueue = try database()
        } catch {
            OtosLog.catalog.errorOperation("catalog.reconcile", phase: "deleteFailed", fields: [
                "path": relativePath.rawValue,
                "error": String(describing: error),
            ])
            return .unchanged
        }

        let deletionTarget: CatalogedFileDeletionTarget?
        do {
            deletionTarget = try await dbQueue.read { db in
                try Self.catalogedFileDeletionTarget(relativePath: relativePath, rootRowID: rootRowID, db: db)
            }
            let capabilities = roots.values.first(where: { $0.rowID == rootRowID })?.capabilities
                ?? .unknown
            guard isCurrent(witness) else {
                return .deferred
            }
            // Its file is in the system Trash, not proven deleted: the row stays until a
            // scan finds the Trash no longer holds it.
            if Self.isHeldInTrash(trashPath: deletionTarget?.trashPath) {
                return .unchanged
            }
            let deleted = try await dbQueue.write { db -> Bool in
                try Self.purgeGonePath(
                    relativePath: relativePath,
                    rootRowID: rootRowID,
                    capabilities: capabilities,
                    db: db
                )
            }
            guard deleted else {
                return .unchanged
            }
        } catch {
            OtosLog.catalog.errorOperation("catalog.reconcile", phase: "deleteFailed", fields: [
                "path": relativePath.rawValue,
                "error": String(describing: error),
            ])
            return .unchanged
        }

        if let thumbnailDirectory {
            for path in deletionTarget?.derivedImagePaths ?? [] {
                ThumbnailStore.delete(path, in: thumbnailDirectory)
            }
        }
        return .changed
    }

    private func recordFilesystemEventDrop(root: LibraryRootPath, reason: String) async {
        OtosLog.catalog.debug(
            "Filesystem rescan dropped path=\(root.rawValue, privacy: .public) reason=\(reason, privacy: .public)"
        )
        OtosLog.catalog.notice(
            "op=catalog.filesystemEvent phase=drop rootPath=\(root.rawValue, privacy: .public) reason=\(reason, privacy: .public)"
        )
    }

    private func cancelFilesystemEventPass(for root: LibraryRootPath) {
        filesystemEventPasses[root]?.cancel()
        filesystemEventPasses.removeValue(forKey: root)
        filesystemEventPassGenerations[root] = (filesystemEventPassGenerations[root] ?? 0) &+ 1
        filesystemEventBatches.removeValue(forKey: root)
        filesystemDirty.removeValue(forKey: root)
    }

    private func cancelAllFilesystemEventPasses() {
        for task in filesystemEventPasses.values {
            task.cancel()
        }
        filesystemEventPasses.removeAll()
        for root in filesystemEventPassGenerations.keys {
            filesystemEventPassGenerations[root] = (filesystemEventPassGenerations[root] ?? 0) &+ 1
        }
        filesystemEventBatches.removeAll()
        filesystemDirty.removeAll()
    }

    private func owns(_ scan: ActiveScan) -> Bool {
        scanLeases.owns(scan) { path, rowID in
            roots.ownsLease(rootPath: path, rootRowID: rowID)
        }
    }

    private func scanCanDelete(_ scan: ActiveScan) -> Bool {
        guard owns(scan) else {
            return false
        }
        return roots[scan.rootPath]?.namespaceMutationEpoch == scan.startNamespaceMutationEpoch
    }

    private func recordIgnoredStaleCallback(_ scan: ActiveScan, callback: String) async {
        OtosLog.catalog.debug(
            """
            Ignoring stale scan callback path=\(scan.rootPath.rawValue, privacy: .public) \
            callback=\(callback, privacy: .public)
            """
        )
        OtosLog.catalog.notice(
            "op=catalog.scan.staleCallback phase=ignored rootPath=\(scan.rootPath.rawValue, privacy: .public) rootRowID=\(scan.rootRowID, privacy: .public) callback=\(callback, privacy: .public)"
        )
    }
}

/// Durable media-operation transitions remain actor-isolated with catalog truth.
/// Filesystem execution and recovery sequencing belong to their operation owners.
extension CatalogStore {
    // MARK: - Import journal / settlement

    func importBatchAssetCount(_ batch: ImportBatchID) async throws -> Int {
        let dbWriter = try database()
        return try await dbWriter.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM media_asset WHERE import_batch_unix_ms = ?",
                arguments: [batch.unixMilliseconds]
            ) ?? 0
        }
    }

    func activeImportOperations() async throws -> [ActiveFileOperation] {
        let dbWriter = try database()
        return try await dbWriter.read { db in
            try Self.fetchAllActiveFileOperations(db: db)
        }
    }

    func activeSourceEraseOperations() async throws -> [ActiveSourceEraseOperation] {
        let dbWriter = try database()
        return try await dbWriter.read { db in
            try Self.fetchAllActiveSourceErases(db: db)
        }
    }

    func beginSourceEraseOperation(_ operation: ActiveSourceEraseOperation) async throws {
        let dbWriter = try database()
        try Self.writeWithJournalDurability(dbWriter) { db in
            try Self.insertActiveSourceErase(operation, db: db)
        }
    }

    /// Settles an erase whose file the source no longer holds: the journal row and the
    /// item's catalog row go in one durable transaction, with its derived images after.
    /// The erase is the proof of deletion (ADR 0008), so the catalog follows the card as
    /// each file goes rather than waiting for a rescan the user's Eject usually cancels.
    /// A root that is no longer registered has no row to remove; its journal still clears.
    func recordSourceFileErased(_ operation: ActiveSourceEraseOperation) async throws {
        let dbWriter = try database()
        let rootState = roots[operation.sourceRootPath]
        let derivedImagePaths = try Self.writeWithJournalDurability(dbWriter) { db -> [String]? in
            try Self.deleteActiveSourceErase(key: operation.key, db: db)
            guard let rootState else {
                return nil
            }
            let target = try Self.catalogedFileDeletionTarget(
                relativePath: operation.sourceRelativePath,
                rootRowID: rootState.rowID,
                db: db
            )
            let removed = try Self.purgeGonePath(
                relativePath: operation.sourceRelativePath,
                rootRowID: rootState.rowID,
                capabilities: rootState.capabilities,
                db: db
            )
            return removed ? target?.derivedImagePaths ?? [] : nil
        }
        guard let derivedImagePaths else {
            return
        }
        if let thumbnailDirectory {
            for path in derivedImagePaths {
                ThumbnailStore.delete(path, in: thumbnailDirectory)
            }
        }
        OtosLog.catalog.noticeOperation("import.erase.catalog", phase: "removed", fields: [
            "rootPath": operation.sourceRootPath.rawValue,
            "relativePath": operation.sourceRelativePath.rawValue,
            "derivedImages": "\(derivedImagePaths.count)",
        ])
        bumpNamespaceRevision(for: operation.sourceRootPath)
        notifyCatalogChanged()
    }

    func beginImportOperation(_ operation: ActiveFileOperation) async throws {
        try importJournalFailure?(.begin)
        let dbWriter = try database()
        try Self.writeWithJournalDurability(dbWriter) { db in
            try Self.insertActiveFileOperation(operation, db: db)
        }
    }

    func recordImportOperationProgress(_ operation: ActiveFileOperation) async throws {
        try importJournalFailure?(.progress(operation.phase))
        let dbWriter = try database()
        try Self.writeWithJournalDurability(dbWriter) { db in
            try Self.updateActiveFileOperation(operation, db: db)
        }
    }

    /// The entry ended without publishing and a staging file it journaled could not be
    /// removed: the row stays, marked so startup recovery removes the file and the row,
    /// and so nothing reads it as work in flight.
    func markImportOperationAbandoned(key: ActiveFileOperationKey) async throws {
        try importJournalFailure?(.progress(.abandoned))
        let dbWriter = try database()
        try Self.writeWithJournalDurability(dbWriter) { db in
            try db.execute(
                sql: "UPDATE active_file_operation SET phase = ?, updated_at = ? WHERE operation_key = ?",
                arguments: [ActiveFileOperationPhase.abandoned.rawValue, Date().timeIntervalSince1970, key.rawValue]
            )
            guard db.changesCount == 1 else {
                throw CatalogStoreError.importOperationMissing(key)
            }
        }
    }

    func abandonImportOperation(key: ActiveFileOperationKey) async throws {
        try importJournalFailure?(.abandon)
        let dbWriter = try database()
        try Self.writeWithJournalDurability(dbWriter) { db in
            try Self.deleteActiveFileOperation(key: key, db: db)
        }
    }

    /// Settles a published copy: its row, its companions, and each of its products (ADR
    /// 0009). The copy is the source file, byte for byte, so each of the source's products
    /// current for the bytes the import copied is the copy's — the same freshness rule
    /// enrichment applies to every row. Failing a rendering, the source's thumbnail is
    /// carried as a provisional one. Nothing is made here: a product the copy still lacks
    /// stays owed, and the copy is offered to enrichment ahead of other background work
    /// while its bytes are local (`localBytesAwaitingProducts`).
    @discardableResult
    func settleImportedAsset(
        operation: ActiveFileOperation,
        byteSize: Int64,
        contentModifiedAt: Date,
        companions: [MediaCompanion]
    ) async throws -> ImportProductsResult {
        guard let rootRowID = roots[operation.destinationRootPath]?.rowID else {
            throw CatalogStoreError.catalogUnavailable
        }
        recordIndependentNamespaceMutation(
            root: operation.destinationRootPath,
            scope: .file(operation.destinationRelativePath),
            fileAction: .upsert
        )
        let dbWriter = try database()
        let sourceRootID = roots[operation.sourceRootPath]?.rowID
        var overlay: ReusableEnrichmentOverlay?
        if let sourceRootID {
            overlay = try await dbWriter.read { db in
                try Self.fetchReusableEnrichmentOverlay(
                    sourceRootID: sourceRootID,
                    sourceRelativePath: operation.sourceRelativePath,
                    db: db
                )
            }
        }
        let sourceMTime = MediaAsset.mtimeSeconds(operation.sourceModifiedAt)
        let destinationID = MediaAssetID(
            libraryRootPath: operation.destinationRootPath,
            relativePath: operation.destinationRelativePath
        )

        var metadata: EnrichedMetadata?
        var metadataOrigin = ImportProductOrigin.owed
        if let overlay, overlay.metadataCurrent(size: operation.sourceByteSize, mtimeSeconds: sourceMTime) {
            metadata = overlay.metadata
            metadataOrigin = .reused
        }

        // The rendering's images, staged for the copy: copies of the source's.
        var rendering: StagedRendering?
        var renderingOrigin = ImportProductOrigin.owed
        if let overlay, overlay.renderingCurrent(size: operation.sourceByteSize, mtimeSeconds: sourceMTime),
           let copied = stageCopies(of: overlay, for: destinationID, preview: true)
        {
            rendering = StagedRendering(
                thumbnail: copied.thumbnail, preview: copied.preview, stamped: true, renderedRevision: overlay.renderedRevision
            )
            renderingOrigin = .reused
        }
        if renderingOrigin == .owed, let overlay, overlay.thumbnailPath != nil,
           let copied = stageCopies(of: overlay, for: destinationID, preview: false)
        {
            rendering = StagedRendering(thumbnail: copied.thumbnail, preview: nil, stamped: false, renderedRevision: 0)
            renderingOrigin = .provisional
        }

        let directory = thumbnailDirectory
        try Self.writeWithJournalDurability(dbWriter) { db in
            var landedRendering: LandedRendering?
            if let rendering {
                let staged = [rendering.thumbnail, rendering.preview].compactMap(\.self)
                do {
                    // Staged images exist only where the catalog has a derived-image
                    // directory; a rendering with no images (nothing could be drawn) needs none.
                    let promote: (StagedDerivedImage) throws -> String = { image in
                        guard let directory else {
                            throw CatalogStoreError.catalogUnavailable
                        }
                        return try ThumbnailStore.promote(image, in: directory)
                    }
                    let thumbnailPath = try rendering.thumbnail.map(promote)
                    let previewPath = try rendering.preview.map(promote)
                    landedRendering = LandedRendering(
                        thumbnailPath: thumbnailPath,
                        previewPath: previewPath,
                        stamped: rendering.stamped,
                        renderedRevision: rendering.renderedRevision
                    )
                } catch {
                    if let directory {
                        for image in staged {
                            ThumbnailStore.discard(image, in: directory)
                        }
                    }
                    OtosLog.thumbnails.errorOperation("mediaOperation.settle", phase: "renderingPromotionFailed", fields: [
                        "destination": operation.destinationRelativePath.rawValue,
                        "error": String(describing: error),
                    ])
                    renderingOrigin = .owed
                }
            }
            try Self.settleImportedAsset(LandedImport(
                operation: operation,
                destinationRootID: rootRowID,
                sourceRootID: sourceRootID,
                byteSize: byteSize,
                contentModifiedAt: contentModifiedAt,
                companions: companions,
                metadata: metadata,
                rendering: landedRendering
            ), db: db)
            try Self.deleteActiveFileOperation(key: operation.operationKey, db: db)
        }
        if metadataOrigin != .reused || renderingOrigin != .reused {
            localBytesAwaitingProducts.append(destinationID)
        }
        _ = bumpNamespaceRevision(for: operation.destinationRootPath)
        notifyCatalogChanged()
        requestReconcile()
        OtosLog.catalog.noticeOperation("mediaOperation.settle", phase: "finish", fields: [
            "destination": operation.destinationRelativePath.rawValue,
            "batch": "\(operation.importBatch.unixMilliseconds)",
            "metadata": metadataOrigin.rawValue,
            "rendering": renderingOrigin.rawValue,
        ])
        return ImportProductsResult(metadata: metadataOrigin, rendering: renderingOrigin)
    }

    /// Stages copies of the source's thumbnail and, when `preview`, its preview under the
    /// copy's names; nil when a copy fails, after discarding what it staged, or when there
    /// are files to copy and no derived-image directory to copy them in.
    private func stageCopies(
        of overlay: ReusableEnrichmentOverlay,
        for destinationID: MediaAssetID,
        preview: Bool
    ) -> (thumbnail: StagedDerivedImage?, preview: StagedDerivedImage?)? {
        let sourcePreview = preview ? overlay.previewPath : nil
        guard overlay.thumbnailPath != nil || sourcePreview != nil else {
            return (nil, nil)
        }
        guard let thumbnailDirectory else {
            return nil
        }
        var stagedThumbnail: StagedDerivedImage?
        do {
            stagedThumbnail = try overlay.thumbnailPath.map {
                try ThumbnailStore.stageCopy(
                    sourceRelativeName: $0,
                    destinationRelativeName: ThumbnailStore.relativeName(for: destinationID),
                    in: thumbnailDirectory
                )
            }
            let stagedPreview = try sourcePreview.map {
                try ThumbnailStore.stageCopy(
                    sourceRelativeName: $0,
                    destinationRelativeName: ThumbnailStore.previewRelativeName(for: destinationID),
                    in: thumbnailDirectory
                )
            }
            return (stagedThumbnail, stagedPreview)
        } catch {
            if let stagedThumbnail {
                ThumbnailStore.discard(stagedThumbnail, in: thumbnailDirectory)
            }
            OtosLog.thumbnails.errorOperation("mediaOperation.settle", phase: "derivedImageCopyFailed", fields: [
                "destination": destinationID.relativePath.rawValue,
                "error": String(describing: error),
            ])
            return nil
        }
    }

    func recordForeignOccupant(root: LibraryRootPath, relativePath: MediaRelativePath) async {
        recordIndependentNamespaceMutation(root: root, scope: .file(relativePath), fileAction: .upsert)
        OtosLog.catalog.notice(
            "op=mediaOperation.publish phase=foreignOccupant rootPath=\(root.rawValue, privacy: .public) relative=\(relativePath.rawValue, privacy: .public)"
        )
        _ = bumpNamespaceRevision(for: root)
    }

    /// Acquires the existing root namespace lease only when no other namespace
    /// mutation owns it. Reorganization recovery remains idempotent through its
    /// original API; Trash uses this atomic variant so two destructive commands
    /// cannot both believe they own one root between separate actor awaits.
    ///
    /// Registration is catalog truth, so this awaits the shared initial load like
    /// every mutation entry point: startup journal recovery reaches here from its
    /// own task, independent of `start()`, and before the load `roots` is empty
    /// for every persisted root. The load is the only suspension; the registry
    /// check and the lease install below stay atomic.
    func acquireNamespaceMutationLease(
        for rootPath: LibraryRootPath,
        owner: RootNamespaceMutationOwner
    ) async -> RootNamespaceLeaseAcquisition {
        do {
            try await ensureStartedForMutation()
        } catch {
            OtosLog.catalog.noticeOperation("namespaceMutation.lease", phase: "denied", fields: [
                "reason": "catalogUnavailable",
                "rootPath": rootPath.rawValue,
                "owner": owner.rawValue,
                "error": String(describing: error),
            ])
            return .catalogUnavailable
        }
        guard roots[rootPath] != nil else {
            OtosLog.catalog.noticeOperation("namespaceMutation.lease", phase: "denied", fields: [
                "reason": "rootNotRegistered",
                "rootPath": rootPath.rawValue,
                "owner": owner.rawValue,
            ])
            return .rootNotRegistered
        }
        if let current = namespaceMutationLeases[rootPath] {
            OtosLog.catalog.noticeOperation("namespaceMutation.lease", phase: "denied", fields: [
                "reason": "busy",
                "rootPath": rootPath.rawValue,
                "owner": owner.rawValue,
                "heldBy": current.owner.rawValue,
            ])
            return .busy(owner: current.owner)
        }
        let lease = installNamespaceMutationLease(for: rootPath, owner: owner)
        OtosLog.catalog.notice(
            """
            op=namespaceMutation.lease phase=acquire rootPath=\(rootPath.rawValue, privacy: .public) \
            owner=\(owner.rawValue, privacy: .public) generation=\(lease.generation, privacy: .public)
            """
        )
        return .acquired(lease)
    }

    /// Installs a new lease on a root the caller has checked no owner holds.
    @discardableResult
    private func installNamespaceMutationLease(
        for rootPath: LibraryRootPath,
        owner: RootNamespaceMutationOwner
    ) -> RootNamespaceMutationLease {
        nextNamespaceMutationLeaseGeneration &+= 1
        let lease = RootNamespaceMutationLease(
            libraryRootPath: rootPath,
            generation: nextNamespaceMutationLeaseGeneration,
            owner: owner,
            markedDirtyByExternalEvents: false
        )
        namespaceMutationLeases[rootPath] = lease
        return lease
    }

    func ownsNamespaceMutationLease(_ lease: RootNamespaceMutationLease) -> Bool {
        guard roots[lease.libraryRootPath] != nil,
              let current = namespaceMutationLeases[lease.libraryRootPath]
        else {
            return false
        }
        return current.generation == lease.generation && current.owner == lease.owner
    }

    /// Follows the paths the trash queue reports as gone from their roots. A media row whose
    /// file went to the system Trash is kept, hidden under the item's command, with the
    /// file's place in the Trash: the item is not proven deleted, so its overlay stays
    /// (ADR 0008, ADR 0022), and a scan purges the row only once that file is gone. A
    /// companion, or a file deleted immediately (no Trash location), leaves the catalog.
    /// Unmoved members are not passed in and stay cataloged for the next retry.
    func reconcileTrashedPaths(_ paths: [MediaTrashPathResult], batch: MediaTrashBatchID) async {
        var changed = false
        for path in paths where path.succeeded {
            guard let rootRowID = roots[path.rootPath]?.rowID else {
                continue
            }
            recordIndependentNamespaceMutation(
                root: path.rootPath,
                scope: .file(path.relativePath),
                fileAction: .deleteIfMissing
            )
            if let trashURL = path.trashURL, path.role != .companion {
                do {
                    let marked = try await database().write { db in
                        try db.execute(
                            sql: """
                            UPDATE media_asset
                            SET trash_path = ?, pending_trash_batch_unix_ms = ?, enrichment_claimed = NULL
                            WHERE library_root_id = ? AND relative_path = ?
                            """,
                            arguments: [
                                trashURL.path(percentEncoded: false),
                                batch.unixMilliseconds,
                                rootRowID,
                                path.relativePath.rawValue,
                            ]
                        )
                        return db.changesCount > 0
                    }
                    if marked {
                        changed = true
                        continue
                    }
                } catch {
                    OtosLog.catalog.errorOperation("mediaTrash.reconcile", phase: "markFailed", fields: [
                        "path": path.relativePath.rawValue,
                        "error": String(describing: error),
                    ])
                    // The file is gone from its path; the next scan sees that and keeps or
                    // purges the row by the same rule, so nothing is left wrong for good.
                    continue
                }
            }
            changed = await deleteCatalogedPath(
                relativePath: path.relativePath,
                rootRowID: rootRowID,
                witness: nil
            ) == .changed || changed
        }
        if changed {
            notifyCatalogChanged()
        }
    }

    // MARK: - Reorganization lease and journal settlement

    private func markNamespaceMutationLeaseDirty(for rootPath: LibraryRootPath) {
        guard var lease = namespaceMutationLeases[rootPath] else { return }
        lease.markedDirtyByExternalEvents = true
        namespaceMutationLeases[rootPath] = lease
    }

    @discardableResult
    func releaseNamespaceMutationLease(_ lease: RootNamespaceMutationLease) -> Bool {
        guard let current = namespaceMutationLeases[lease.libraryRootPath],
              current.generation == lease.generation,
              current.owner == lease.owner
        else {
            return false
        }
        let dirty = current.markedDirtyByExternalEvents
        namespaceMutationLeases.removeValue(forKey: lease.libraryRootPath)
        OtosLog.catalog.notice(
            """
            op=namespaceMutation.lease phase=release rootPath=\(lease.libraryRootPath.rawValue, privacy: .public) \
            owner=\(lease.owner.rawValue, privacy: .public) dirty=\(dirty, privacy: .public)
            """
        )
        // A library the user asked to remove meanwhile goes now; scanning it first is
        // work its removal discards.
        if handOffDeferredLibraryRemoval(lease.libraryRootPath) {
            return true
        }
        if dirty || scanLeases.takeRescanAfterCurrentScan(lease.libraryRootPath) {
            enqueueScans([lease.libraryRootPath])
        } else {
            startNextScanIfNeeded()
        }
        // Dirt the lease held back may be reconciled now.
        requestReconcile()
        return true
    }

    func hasNamespaceMutationLease(for rootPath: LibraryRootPath) -> Bool {
        namespaceMutationLeases[rootPath] != nil
    }

    func activeReorganizationComponents() async throws -> [ActiveReorganizationComponent] {
        let dbWriter = try database()
        return try await dbWriter.read { db in
            try Self.fetchAllActiveReorganizationComponents(db: db)
        }
    }

    func prepareReorganizationComponent(
        _ component: ActiveReorganizationComponent
    ) async throws {
        let dbWriter = try database()
        try Self.writeWithJournalDurability(dbWriter) { db in
            try Self.insertActiveReorganizationComponent(component, db: db)
        }
    }

    func recordReorganizationMoveIntent(
        key: ReorganizationComponentKey,
        stepIndex: Int
    ) async throws {
        let dbWriter = try database()
        try Self.writeWithJournalDurability(dbWriter) { db in
            try Self.updateStepPhase(key: key, stepIndex: stepIndex, phase: .willMove, db: db)
            try Self.updateComponentPhase(
                key: key,
                phase: .moving,
                nextStepIndex: stepIndex,
                updatedAt: Date(),
                db: db
            )
        }
    }

    func recordReorganizationMoveCompletion(
        key: ReorganizationComponentKey,
        step: ActiveReorganizationStep,
        nextStepIndex: Int
    ) async throws {
        let dbWriter = try database()
        try Self.writeWithJournalDurability(dbWriter) { db in
            try Self.updateStepPhase(key: key, stepIndex: step.stepIndex, phase: .didMove, db: db)
            try Self.updateMemberCurrentPath(
                key: key,
                memberIndex: step.memberIndex,
                currentRelativePath: step.destinationRelativePath,
                db: db
            )
            try Self.updateComponentPhase(
                key: key,
                phase: .moving,
                nextStepIndex: nextStepIndex,
                updatedAt: Date(),
                db: db
            )
        }
    }

    func recordReorganizationFilesystemCompletion(
        key: ReorganizationComponentKey,
        nextStepIndex: Int
    ) async throws {
        let dbWriter = try database()
        try Self.writeWithJournalDurability(dbWriter) { db in
            try Self.updateComponentPhase(
                key: key,
                phase: .filesystemComplete,
                nextStepIndex: nextStepIndex,
                updatedAt: Date(),
                db: db
            )
        }
    }

    /// A directory the component needed did not exist and the executor created it, so
    /// a rollback may remove it again once it is empty.
    func recordReorganizationDirectoryCreated(
        key: ReorganizationComponentKey,
        relativePath: MediaRelativePath
    ) async throws {
        let dbWriter = try database()
        try Self.writeWithJournalDurability(dbWriter) { db in
            try Self.updateDirectoryPhase(key: key, relativePath: relativePath, phase: .created, db: db)
        }
    }

    /// The component will not finish: from here its completed steps are undone.
    func recordReorganizationRollbackStart(key: ReorganizationComponentKey, nextStepIndex: Int) async throws {
        let dbWriter = try database()
        try Self.writeWithJournalDurability(dbWriter) { db in
            try Self.updateComponentPhase(
                key: key,
                phase: .rollingBack,
                nextStepIndex: nextStepIndex,
                updatedAt: Date(),
                db: db
            )
        }
    }

    /// One completed step was moved back: its member is at the step's source again.
    func recordReorganizationStepRolledBack(
        key: ReorganizationComponentKey,
        step: ActiveReorganizationStep
    ) async throws {
        let dbWriter = try database()
        try Self.writeWithJournalDurability(dbWriter) { db in
            try Self.updateStepPhase(key: key, stepIndex: step.stepIndex, phase: .rolledBack, db: db)
            try Self.updateMemberCurrentPath(
                key: key,
                memberIndex: step.memberIndex,
                currentRelativePath: step.sourceRelativePath,
                db: db
            )
        }
    }

    /// A rollback could not move a file back. The journal stays, so the next launch's
    /// recovery tries the rollback again, and the root stays under the lease until then.
    func recordReorganizationBlocked(key: ReorganizationComponentKey) async throws {
        let dbWriter = try database()
        try Self.writeWithJournalDurability(dbWriter) { db in
            guard let component = try Self.fetchActiveReorganizationComponent(key: key, db: db) else {
                throw CatalogStoreError.catalogUnavailable
            }
            try Self.updateComponentPhase(
                key: key,
                phase: .blocked,
                nextStepIndex: component.nextStepIndex,
                updatedAt: Date(),
                db: db
            )
        }
    }

    /// Every step the component made was undone: the library is as it was before the
    /// component, so its journal goes and no catalog row changes.
    func discardRolledBackReorganizationComponent(key: ReorganizationComponentKey) async throws {
        let dbWriter = try database()
        try Self.writeWithJournalDurability(dbWriter) { db in
            try Self.deleteActiveReorganizationComponent(key: key, db: db)
        }
    }

    /// Remaps the catalog rows a component moved and records the remaps as a pending
    /// batch for the window, in one transaction (ARC-051, ARC-052).
    func settleReorganizationComponent(key: ReorganizationComponentKey) async throws {
        let dbWriter = try database()
        let component = try await dbWriter.read { db in
            try Self.fetchActiveReorganizationComponent(key: key, db: db)
        }
        guard let component else {
            throw CatalogStoreError.catalogUnavailable
        }
        recordIndependentNamespaceMutation(root: component.libraryRootPath, scope: .root)
        let settled: CatalogIdentityRemapBatch = try Self.writeWithJournalDurability(dbWriter) { db in
            guard let currentComponent = try Self.fetchActiveReorganizationComponent(key: key, db: db),
                  let rootRowID = try Int64.fetchOne(
                      db,
                      sql: "SELECT id FROM library_root WHERE path = ?",
                      arguments: [currentComponent.libraryRootPath.rawValue]
                  )
            else {
                throw CatalogStoreError.catalogUnavailable
            }
            return try Self.settleRelocationComponent(
                rootRowID: rootRowID,
                component: currentComponent,
                db: db
            )
        }
        // Relocation moves media on disk: advance occupancy so import planning
        // against this root replans. Reorg's own `rootRevision` stays the general
        // planRevision, which the occupancy bump also advances.
        bumpNamespaceRevision(for: settled.libraryRootPath)
        notifyCatalogChanged()
        OtosLog.catalog.notice(
            "op=reorganization.settle phase=finish rootPath=\(settled.libraryRootPath.rawValue, privacy: .public) remapCount=\(settled.remaps.count, privacy: .public) batch=\(settled.id, privacy: .public)"
        )
    }

    /// The window applied these batches; they no longer travel with published states.
    func acknowledgeIdentityRemaps(_ batchIDs: [Int64]) async throws {
        let dbWriter = try database()
        try await dbWriter.write { db in
            try Self.deletePendingIdentityRemapBatches(ids: batchIDs, db: db)
        }
        OtosLog.catalog.noticeOperation("reorganization.remapAcknowledged", phase: "finish", fields: [
            "batches": batchIDs.map(String.init).joined(separator: ","),
        ])
    }
}

// MARK: - Duplicates (ADR 0042)

extension CatalogStore {
    /// Every visible copy whose current digest another visible copy shares, and every
    /// remembered "Keep All Copies" pair among them.
    func duplicateCopies(
        availableLibraryPaths: Set<LibraryRootPath>
    ) async throws -> (copies: [DuplicateCopyFacts], keptPairs: Set<DuplicateKeptPair>) {
        let libraries = roots.values.filter { $0.root.kind.isMemberOfAllMedia && availableLibraryPaths.contains($0.path) }
        guard !libraries.isEmpty else {
            return ([], [])
        }
        let rootIDs = libraries.map(\.rowID).sorted()
        let pathsByRowID = roots.pathsByRowID
        let librariesByPath = Dictionary(uniqueKeysWithValues: libraries.map { ($0.path, DuplicateLibrary($0.root)) })
        return try await database().read { db in
            let copies = try DuplicatesGateway.fetchDuplicateCopies(rootIDs: rootIDs, db: db).compactMap { row in
                row.facts(pathsByRowID: pathsByRowID, librariesByPath: librariesByPath)
            }
            let keptPairs = try DuplicatesGateway.fetchKeptPairs(rootIDs: rootIDs, db: db).compactMap { row in
                row.pair(pathsByRowID: pathsByRowID)
            }
            return (copies, Set(keptPairs))
        }
    }

    /// Keep All Copies: remembers every pair of copies in each group as kept together.
    /// Returns the pairs this call added, so undo can forget exactly those.
    func keepCopiesTogether(_ groups: [[MediaAssetID]]) async throws -> Set<DuplicateKeptPair> {
        var pairs: Set<DuplicateKeptPair> = []
        for members in groups {
            for (index, left) in members.enumerated() {
                for right in members[(index + 1)...] {
                    pairs.insert(DuplicateKeptPair(left, right))
                }
            }
        }
        let rowIDs = roots.rowIDSnapshot()
        let requested = pairs
        let added = try await database().write { db -> Set<DuplicateKeptPair> in
            var added: Set<DuplicateKeptPair> = []
            for pair in requested {
                guard let firstRoot = rowIDs[pair.first.libraryRootPath],
                      let secondRoot = rowIDs[pair.second.libraryRootPath]
                else {
                    continue
                }
                try db.execute(
                    sql: """
                    INSERT OR IGNORE INTO duplicate_kept_pair (first_root_id, first_path, second_root_id, second_path)
                    VALUES (?, ?, ?, ?)
                    """,
                    arguments: [firstRoot, pair.first.relativePath.rawValue, secondRoot, pair.second.relativePath.rawValue]
                )
                if db.changesCount > 0 {
                    added.insert(pair)
                }
            }
            return added
        }
        OtosLog.catalog.noticeOperation("duplicates.keepAll", phase: "written", fields: [
            "groups": "\(groups.count)", "pairs": "\(added.count)",
        ])
        if !added.isEmpty {
            notifyCatalogChanged()
        }
        return added
    }

    /// Undo of Keep All Copies: forgets exactly the pairs it added.
    func forgetKeptPairs(_ pairs: Set<DuplicateKeptPair>) async throws {
        let rowIDs = roots.rowIDSnapshot()
        try await database().write { db in
            for pair in pairs {
                guard let firstRoot = rowIDs[pair.first.libraryRootPath],
                      let secondRoot = rowIDs[pair.second.libraryRootPath]
                else {
                    continue
                }
                try db.execute(
                    sql: """
                    DELETE FROM duplicate_kept_pair
                    WHERE first_root_id = ? AND first_path = ? AND second_root_id = ? AND second_path = ?
                    """,
                    arguments: [firstRoot, pair.first.relativePath.rawValue, secondRoot, pair.second.relativePath.rawValue]
                )
            }
        }
        OtosLog.catalog.noticeOperation("duplicates.keepAll", phase: "forgotten", fields: ["pairs": "\(pairs.count)"])
        notifyCatalogChanged()
    }
}

// MARK: - Same photo (ADR 0042)

extension CatalogStore {
    /// Visible stills in the fixed libraries whose thumbnail has no current render signature.
    func renderSignatureCandidates(limit: Int) async throws -> [RenderSignatureCandidate] {
        let libraries = roots.values.filter { $0.root.kind.isMemberOfAllMedia && $0.availability == .available }
        guard !libraries.isEmpty else {
            return []
        }
        let rootIDs = libraries.map(\.rowID).sorted()
        let pathsByRowID = roots.pathsByRowID
        let placeholders = Array(repeating: "?", count: rootIDs.count).joined(separator: ", ")
        return try await database().read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT library_root_id, relative_path, thumbnail_path, \(StoredThumbnailSQL.identity("media_asset")) AS source
                FROM media_asset
                WHERE library_root_id IN (\(placeholders))
                  AND thumbnail_path IS NOT NULL
                  AND kind IN ('image', 'raw')
                  AND pending_trash_batch_unix_ms IS NULL
                  AND trash_path IS NULL
                  AND render_signature_source IS NOT \(StoredThumbnailSQL.identity("media_asset"))
                ORDER BY library_root_id, relative_path
                LIMIT ?
                """,
                arguments: StatementArguments(rootIDs + [limit])
            ).compactMap { row in
                guard let root = pathsByRowID[row["library_root_id"]] else { return nil }
                return RenderSignatureCandidate(
                    id: MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: row["relative_path"])),
                    thumbnailPath: row["thumbnail_path"],
                    source: row["source"]
                )
            }
        }
    }

    /// Writes render signatures for rows whose thumbnail is still the one they were read from.
    @discardableResult
    func applyRenderSignatures(_ results: [RenderSignatureResult]) async throws -> Int {
        let rowIDs = roots.rowIDSnapshot()
        let written = try await database().write { db -> Int in
            var written = 0
            for result in results {
                guard let rootID = rowIDs[result.id.libraryRootPath] else { continue }
                try db.execute(
                    sql: """
                    UPDATE media_asset
                    SET render_dhash = ?, render_gray = ?, render_signature_source = ?
                    WHERE library_root_id = ? AND relative_path = ?
                      AND \(StoredThumbnailSQL.identity("media_asset")) = ?
                    """,
                    arguments: [
                        result.signature.map { Int64(bitPattern: $0.differenceHash) },
                        result.signature.map { Data($0.gray) },
                        result.source,
                        rootID,
                        result.id.relativePath.rawValue,
                        result.source,
                    ]
                )
                written += db.changesCount
            }
            return written
        }
        if written > 0 {
            notifyCatalogChanged()
        }
        return written
    }

    /// Assets whose stored thumbnail has no current search embedding (ADR 0048), newest
    /// capture first so the photos a person is likeliest to look for are searchable first.
    /// Every available root is read: search covers whatever scope is shown. A Live Photo's
    /// movie is left out, because its still stands for the item. `excluding`: assets a pass
    /// already tried and could not read, which it pages past.
    func searchEmbeddingCandidates(limit: Int, excluding: Set<MediaAssetID> = []) async throws -> [SearchEmbeddingCandidate] {
        let rootIDs = availableRootRowIDs()
        guard !rootIDs.isEmpty else {
            return []
        }
        let pathsByRowID = roots.pathsByRowID
        return try await database().read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT a.library_root_id, a.relative_path, a.thumbnail_path,
                       \(SearchEmbeddingStorage.currentSource("a")) AS source
                \(SearchEmbeddingStorage.owedFrom(rootCount: rootIDs.count))
                ORDER BY a.best_capture_local DESC, a.library_root_id, a.relative_path
                LIMIT ?
                """,
                arguments: StatementArguments(rootIDs + [limit + excluding.count])
            ).compactMap { row -> SearchEmbeddingCandidate? in
                guard let root = pathsByRowID[row["library_root_id"]] else { return nil }
                let id = MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: row["relative_path"]))
                guard !excluding.contains(id) else { return nil }
                return SearchEmbeddingCandidate(id: id, thumbnailPath: row["thumbnail_path"], source: row["source"])
            }
            .prefix(limit)
            .map(\.self)
        }
    }

    /// How many assets are owed a search embedding: what the empty search result says
    /// search has not read yet.
    func searchEmbeddingPendingCount() async throws -> Int {
        let rootIDs = availableRootRowIDs()
        guard !rootIDs.isEmpty else {
            return 0
        }
        return try await database().read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) \(SearchEmbeddingStorage.owedFrom(rootCount: rootIDs.count))",
                arguments: StatementArguments(rootIDs)
            ) ?? 0
        }
    }

    private func availableRootRowIDs() -> [Int64] {
        roots.values.filter { $0.availability == .available }.map(\.rowID).sorted()
    }

    /// Writes search embeddings for assets whose thumbnail is still the one they were read
    /// from, and returns the ones written. `PhotoSearchIndex` keeps what it wrote, so a write
    /// notifies only when it puts a photo into or out of On This Day (`OnThisDayPicks`: a
    /// confident screenshot or document label), a catalog change that scope is read again for.
    func applySearchEmbeddings(_ results: [SearchEmbeddingResult]) async throws -> [SearchEmbeddingResult] {
        let rowIDs = roots.rowIDSnapshot()
        let leftOut = "SELECT \(OnThisDayPicks.leftOutLabelSQL) FROM search_embedding WHERE library_root_id = ? AND relative_path = ?"
        let (applied, changesOnThisDay) = try await database().write { db -> ([SearchEmbeddingResult], Bool) in
            var written: [SearchEmbeddingResult] = []
            var changesOnThisDay = false
            for result in results {
                guard let rootID = rowIDs[result.id.libraryRootPath] else { continue }
                let path = result.id.relativePath.rawValue
                guard try Bool.fetchOne(
                    db,
                    sql: """
                    SELECT \(SearchEmbeddingStorage.currentSource("media_asset")) = ?
                    FROM media_asset WHERE library_root_id = ? AND relative_path = ?
                    """,
                    arguments: [result.source, rootID, path]
                ) == true else {
                    continue
                }
                let wasLeftOut = try Bool.fetchOne(db, sql: leftOut, arguments: [rootID, path]) ?? false
                try db.execute(
                    sql: """
                    INSERT INTO search_embedding (library_root_id, relative_path, source, embedding, labels, confident_labels)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT (library_root_id, relative_path)
                    DO UPDATE SET source = excluded.source, embedding = excluded.embedding, labels = excluded.labels,
                        confident_labels = excluded.confident_labels
                    """,
                    arguments: [
                        rootID, path, result.source, SearchEmbeddingStorage.data(result.embedding),
                        SearchEmbeddingStorage.labelsText(result.labels),
                        SearchEmbeddingStorage.confidentLabelsText(result.confidentLabels),
                    ]
                )
                if try (Bool.fetchOne(db, sql: leftOut, arguments: [rootID, path]) ?? false) != wasLeftOut {
                    changesOnThisDay = true
                }
                written.append(result)
            }
            return (written, changesOnThisDay)
        }
        if changesOnThisDay {
            notifyCatalogChanged()
        }
        return applied
    }

    /// The assets in available roots that have a current search embedding, without the
    /// vectors: what `PhotoSearchIndex` reconciles its memory against after a catalog change.
    func currentSearchEmbeddingIDs() async throws -> Set<MediaAssetID> {
        try await readSearchEmbeddings(vectors: false).reduce(into: Set()) { $0.insert($1.id) }
    }

    /// Current search embeddings, all of them or those of `ids`.
    func currentSearchEmbeddings(for ids: Set<MediaAssetID>? = nil) async throws -> [StoredSearchEmbedding] {
        try await readSearchEmbeddings(vectors: true, only: ids)
    }

    private func readSearchEmbeddings(vectors: Bool, only ids: Set<MediaAssetID>? = nil) async throws -> [StoredSearchEmbedding] {
        let rootIDs = availableRootRowIDs()
        guard !rootIDs.isEmpty, ids?.isEmpty != true else {
            return []
        }
        let pathsByRowID = roots.pathsByRowID
        return try await database().read { db in
            let rows = try Row.fetchCursor(
                db,
                sql: SearchEmbeddingStorage.currentEmbeddingsSQL(rootCount: rootIDs.count, vectors: vectors),
                arguments: StatementArguments(rootIDs)
            )
            var out: [StoredSearchEmbedding] = []
            while let row = try rows.next() {
                guard let root = pathsByRowID[row[0]] else { continue }
                let id = MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: row[1]))
                if let ids, !ids.contains(id) {
                    continue
                }
                if vectors {
                    guard let data: Data = row[2], let embedding = SearchEmbeddingStorage.embedding(from: data) else { continue }
                    out.append(StoredSearchEmbedding(id: id, embedding: embedding, labels: SearchEmbeddingStorage.labels(from: row[3])))
                } else {
                    out.append(StoredSearchEmbedding(id: id, embedding: []))
                }
            }
            return out
        }
    }

    /// The people the user has named and not hidden, for search to match in a query
    /// (ADR 0048): a hidden person is found only in the People gallery.
    func namedPeople() async throws -> [SearchPerson] {
        try await database().read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT id, name FROM person WHERE name IS NOT NULL AND name <> '' AND is_hidden = 0"
            ).map { row in
                SearchPerson(id: PersonID(rawValue: row["id"]), name: row["name"])
            }
        }
    }

    /// The assets in available roots that `facts` allow (ADR 0048): captured within the date
    /// span, located within the place, holding a face confirmed as every person named.
    func searchFactMatches(_ facts: SearchFactFilter) async throws -> Set<MediaAssetID> {
        let rootIDs = availableRootRowIDs()
        guard !rootIDs.isEmpty else { return [] }
        let pathsByRowID = roots.pathsByRowID
        var clauses = ["a.library_root_id IN (\(Array(repeating: "?", count: rootIDs.count).joined(separator: ", ")))"]
        var arguments: [DatabaseValue] = rootIDs.map(\.databaseValue)
        if let date = facts.dateSpan {
            // The span is days on this Mac's calendar, so its ends are the readings of its
            // clock at them: a photo taken that day anywhere matches it.
            clauses.append("a.best_capture_local >= ? AND a.best_capture_local < ?")
            arguments += [
                CaptureLocalTime(readingOf: date.start).seconds.databaseValue,
                CaptureLocalTime(readingOf: date.end).seconds.databaseValue,
            ]
        }
        if let place = facts.place {
            // A box first, so SQLite reads few rows; the exact distance after.
            let latitudeDelta = place.radiusMeters / 111_000
            let longitudeDelta = latitudeDelta / max(cos(place.latitude * .pi / 180), 0.01)
            clauses.append("m.primary_latitude BETWEEN ? AND ? AND m.primary_longitude BETWEEN ? AND ?")
            arguments += [
                place.latitude - latitudeDelta, place.latitude + latitudeDelta,
                place.longitude - longitudeDelta, place.longitude + longitudeDelta,
            ].map(\.databaseValue)
        }
        for person in facts.people {
            clauses.append("""
            EXISTS (SELECT 1 FROM face AS f WHERE f.library_root_id = a.library_root_id
                AND f.relative_path = a.relative_path AND f.person_id = ?)
            """)
            arguments.append(person.rawValue.databaseValue)
        }
        let sql = """
        SELECT a.library_root_id, a.relative_path, m.primary_latitude, m.primary_longitude
        FROM media_asset AS a
        LEFT JOIN asset_metadata AS m ON m.library_root_id = a.library_root_id AND m.relative_path = a.relative_path
        WHERE \(clauses.joined(separator: " AND "))
        """
        let place = facts.place
        let statementArguments = StatementArguments(arguments)
        return try await database().read { db in
            let rows = try Row.fetchCursor(db, sql: sql, arguments: statementArguments)
            var allowed: Set<MediaAssetID> = []
            while let row = try rows.next() {
                guard let root = pathsByRowID[row[0]] else { continue }
                if let place {
                    guard let latitude: Double = row[2], let longitude: Double = row[3],
                          place.contains(latitude: latitude, longitude: longitude) else { continue }
                }
                allowed.insert(MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: row[1])))
            }
            return allowed
        }
    }

    /// Stills whose stored preview has no current text reading (ADR 0048), newest first, but
    /// those in `excluding`, which a pass already tried and could not read.
    func searchTextCandidates(limit: Int, excluding: Set<MediaAssetID> = []) async throws -> [SearchTextCandidate] {
        let rootIDs = availableRootRowIDs()
        guard !rootIDs.isEmpty else { return [] }
        let pathsByRowID = roots.pathsByRowID
        return try await database().read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT a.library_root_id, a.relative_path, a.preview_path, \(SearchTextStorage.currentSource("a")) AS source
                \(SearchTextStorage.owedFrom(rootCount: rootIDs.count))
                ORDER BY a.best_capture_local DESC, a.library_root_id, a.relative_path
                LIMIT ?
                """,
                arguments: StatementArguments(rootIDs + [limit + excluding.count])
            ).compactMap { row -> SearchTextCandidate? in
                guard let root = pathsByRowID[row["library_root_id"]] else { return nil }
                let id = MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: row["relative_path"]))
                guard !excluding.contains(id) else { return nil }
                return SearchTextCandidate(id: id, previewPath: row["preview_path"], source: row["source"])
            }
            .prefix(limit)
            .map(\.self)
        }
    }

    /// Writes text readings for stills whose preview is still the one read; returns those written.
    func applySearchTexts(_ results: [SearchTextResult]) async throws -> [SearchTextResult] {
        let rowIDs = roots.rowIDSnapshot()
        return try await database().write { db -> [SearchTextResult] in
            var written: [SearchTextResult] = []
            for result in results {
                guard let rootID = rowIDs[result.id.libraryRootPath] else { continue }
                let path = result.id.relativePath.rawValue
                guard try Bool.fetchOne(
                    db,
                    sql: """
                    SELECT \(SearchTextStorage.currentSource("media_asset")) = ?
                    FROM media_asset WHERE library_root_id = ? AND relative_path = ?
                    """,
                    arguments: [result.source, rootID, path]
                ) == true else {
                    continue
                }
                try db.execute(
                    sql: """
                    INSERT INTO search_text (library_root_id, relative_path, source, lines) VALUES (?, ?, ?, ?)
                    ON CONFLICT (library_root_id, relative_path) DO UPDATE SET source = excluded.source, lines = excluded.lines
                    """,
                    arguments: [rootID, path, result.source, SearchTextStorage.linesJSON(result.lines)]
                )
                written.append(result)
            }
            return written
        }
    }

    /// The assets in available roots with a current, non-empty text reading, without the
    /// lines: what `PhotoSearchIndex` reconciles its memory against after a catalog change.
    func currentSearchTextIDs() async throws -> Set<MediaAssetID> {
        try await Set(readSearchTexts(lines: false).keys)
    }

    /// The current, non-empty text readings of `ids`, as search matches them
    /// (`SearchTextReading.searchable`); only theirs are decoded.
    func currentSearchTexts(for ids: Set<MediaAssetID>) async throws -> [MediaAssetID: String] {
        guard !ids.isEmpty else { return [:] }
        return try await readSearchTexts(lines: true, only: ids)
    }

    private func readSearchTexts(lines: Bool, only ids: Set<MediaAssetID>? = nil) async throws -> [MediaAssetID: String] {
        let rootIDs = availableRootRowIDs()
        guard !rootIDs.isEmpty else { return [:] }
        let pathsByRowID = roots.pathsByRowID
        return try await database().read { db in
            let rows = try Row.fetchCursor(
                db,
                sql: SearchTextStorage.currentReadingsSQL(rootCount: rootIDs.count, lines: lines),
                arguments: StatementArguments(rootIDs)
            )
            var texts: [MediaAssetID: String] = [:]
            while let row = try rows.next() {
                guard let root = pathsByRowID[row[0]] else { continue }
                let id = MediaAssetID(libraryRootPath: root, relativePath: MediaRelativePath(rawValue: row[1]))
                if let ids, !ids.contains(id) {
                    continue
                }
                texts[id] = lines ? try SearchTextReading.searchable(SearchTextStorage.lines(fromJSON: row[2])) : ""
            }
            return texts
        }
    }

    /// Visible stills with a current render signature, with the column facts the same-photo
    /// rule proposes pairs from. Renders and record facts are read separately, only for the
    /// stills a proposed pair names (`samePhotoDetails`).
    func samePhotoCandidates(availableLibraryPaths: Set<LibraryRootPath>) async throws -> [SamePhotoCandidate] {
        let libraries = roots.values.filter { $0.root.kind.isMemberOfAllMedia && availableLibraryPaths.contains($0.path) }
        guard !libraries.isEmpty else {
            return []
        }
        let rootIDs = libraries.map(\.rowID).sorted()
        let pathsByRowID = Dictionary(uniqueKeysWithValues: libraries.map { ($0.rowID, $0.path) })
        return try await database().read { db in
            try DuplicatesGateway.fetchSamePhotoCandidates(rootIDs: rootIDs, pathsByRowID: pathsByRowID, db: db)
        }
    }

    /// The details of these stills, which are in proposed pairs: the copy a group lists,
    /// the render signature, and the capture facts kept in the metadata record. A still
    /// whose library is gone or that has no stored signature has no detail.
    func samePhotoDetails(for ids: [MediaAssetID]) async throws -> [MediaAssetID: SamePhotoDetail] {
        let libraries = Dictionary(uniqueKeysWithValues: roots.values.map {
            ($0.path, (rowID: $0.rowID, library: DuplicateLibrary($0.root)))
        })
        return try await database().read { db in
            var details: [MediaAssetID: SamePhotoDetail] = [:]
            for id in ids {
                guard let library = libraries[id.libraryRootPath],
                      let detail = try DuplicatesGateway.fetchSamePhotoDetail(
                          rootID: library.rowID,
                          id: id,
                          library: library.library,
                          db: db
                      )
                else {
                    continue
                }
                details[id] = detail
            }
            return details
        }
    }
}
