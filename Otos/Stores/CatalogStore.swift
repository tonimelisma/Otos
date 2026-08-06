import Foundation
import GRDB
import OSLog

/// Store notifications remain cheap invalidation signals. Most changes carry no
/// payload; root removal carries its typed path because a remove followed by a
/// same-path add can otherwise coalesce into a queried state where Projection cannot
/// observe that the selected library instance disappeared.
nonisolated enum CatalogStoreChange: Equatable {
    case catalogChanged
    case assetsDetailChanged
    case libraryRemoved(LibraryRootPath)
}

/// An asset the Store has claimed for enrichment, together with the claim-time
/// `hashRequired` fact — decided once, by the owner of root kind, at the moment the row
/// is claimed under a specific partial-index predicate (ADR 0018/plan 0062). Carried
/// rather than re-derived downstream: a later re-derivation reads root kind from a
/// possibly-staler cache and can disagree with the predicate the row was actually
/// claimed under (plan 0065 Stage 2b).
nonisolated struct ClaimedEnrichmentCandidate: Sendable {
    let asset: MediaAsset
    let hashRequired: Bool
}

/// Catalog Store guide
///
/// This actor is the only runtime owner of catalog truth. SQLite provides durable
/// overlay storage and the per-asset working set; the actor keeps only root identity,
/// source metadata, per-root runtime facts via `RootRegistry` / `RootRuntimeState`,
/// scan/enumeration leases via `ScanLeaseController`, and notification state resident. Fixed libraries, removable volumes, and MTP cameras share the root
/// table because the current filesystem or staging path remains the asset identity
/// boundary, while `LibraryRootKind` controls lifecycle rules such as All Media
/// membership, launch scans, detach, and Forget. Filesystem scans and device catalog
/// batches write SQLite and notify consumers only when those writes actually inserted,
/// updated, or deleted rows. While the app runs, `CatalogFilesystemWatcher` forwards
/// macOS events to per-root debounced reconciliation via `FilesystemReconciler`
/// (pure batch classification) plus Store-owned debounce/execution: safe single-file
/// events update one row and unsafe events fall back to the full scan pipeline. Views
/// never access persistence directly.
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
/// keeps `currentScanTask` and all spawn/await orchestration. Completed scans reconcile missing paths; failed, cancelled, or
/// stale scans preserve prior rows because incomplete observation cannot prove
/// removal. Device enumerations use the same process-local lease before they may
/// reconcile missing rows, so a stale camera flow cannot delete rows written by a
/// newer attach. A single regular-file remove
/// event proves deletion only after Store checks that exact path is absent under an
/// armed available root.
actor CatalogStore {
    private nonisolated static let slowQueryDiagnosticThresholdMs = 50

    enum Location {
        case application(bundleIdentifier: String)
        case databaseFile(URL)
        case inMemory
    }

    struct StoredRoot {
        let id: Int64
        let path: LibraryRootPath
        let kind: LibraryRootKind
        let deviceIdentity: String?
        let displayName: String?
        let lastSeenAt: Date?
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
        let identity: String
        let displayName: String
        let isEjectable: Bool
        let activity: CatalogLibraryActivity
        let enqueuesScan: Bool

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
        /// ordering/scope columns (`best_capture_unix`, `best_kind`, `best_format`).
        /// A batch that changed none of these is detail-only: the projection can skip
        /// the full order query and re-sort (plan 0064 Stage 3).
        var structureChanged = false
        var promotionFailed = false
        var discardedThumbnails: [GeneratedThumbnail] = []
        var supersededThumbnailPaths: Set<String> = []
        var waitMs = 0
        var execMs = 0

        mutating func discard(_ thumbnail: GeneratedThumbnail?) {
            guard let thumbnail else {
                return
            }
            discardedThumbnails.append(thumbnail)
        }

        mutating func failPromotion(_ thumbnail: GeneratedThumbnail?) {
            promotionFailed = true
            discard(thumbnail)
        }

        mutating func replaceThumbnail(oldPath: String?, newPath: String?) {
            if let newPath {
                supersededThumbnailPaths.remove(newPath)
            }
            if let oldPath, oldPath != newPath {
                supersededThumbnailPaths.insert(oldPath)
            }
        }
    }

    /// Ordering/scope-relevant STORED generated columns, read either before or after an
    /// enrichment overwrite, so the batch can tell a detail-only apply from one that
    /// actually changes the effective `best_capture`/`best_kind`/`best_format` (plan
    /// 0064 Stage 3) by comparing what SQLite actually stored, not a Swift guess at what
    /// it would store (plan 0065 Stage 2a — the guess had no fallback path matching the
    /// generated column's own COALESCE chain and could silently disagree with it).
    private struct EnrichmentOverlayBeforeWrite {
        let bestCaptureUnix: Double?
        let bestKind: String?
        let bestFormat: String?
        let thumbnailPath: String?

        init(row: Row) {
            bestCaptureUnix = row["best_capture_unix"]
            bestKind = row["best_kind"]
            bestFormat = row["best_format"]
            thumbnailPath = row["thumbnail_path"]
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
    private let scanner: CatalogScanner
    private let filesystemWatcher: CatalogFilesystemWatcher
    private let scanCadence: Duration
    private let filesystemEventDebounce: Duration
    private let filesystemEventSleep: @Sendable (Duration) async -> Void
    private let initialLoadDidRead: (@Sendable () async -> Void)?
    private let importJournalFailure: (@Sendable (ImportJournalTransition) throws -> Void)?
    private var dbWriter: (any DatabaseWriter)?
    private var databaseFileURL: URL?
    private var started = false
    private var startupTask: Task<Void, Error>?
    private var unrequestedLoadedRootPaths: [LibraryRootPath] = []
    private var roots = RootRegistry()
    private var changeContinuations: [UUID: AsyncStream<CatalogStoreChange>.Continuation] = [:]
    private var planningChangeContinuations: [UUID: AsyncStream<RootPlanningChange>.Continuation] = [:]
    private var scanLeases = ScanLeaseController()
    private var currentScanTask: Task<Void, Never>?
    private var filesystemWatchingStarted = false
    /// True while `afterFilesystemLeaseCleared` revisits every dirty root so a
    /// mid-pass `enqueueScans` cannot start the next full-root scan early.
    private var isRevisitingDirtyRoots = false
    private var filesystemWatchingArmed: Set<LibraryRootPath> = []
    private var filesystemDebounceTasks: [LibraryRootPath: Task<Void, Never>] = [:]
    private var filesystemEventBatches: [LibraryRootPath: [FilesystemEvent]] = [:]
    /// Per-root typed dirty-scope accumulator. Events that arrive while a lease
    /// owns the root retain file/subtree/root granularity here instead of being
    /// collapsed into an unconditional full-root rescan.
    private var filesystemDirty: [LibraryRootPath: FilesystemDirtyAccumulator] = [:]
    /// Last successful completed full-root reconciliation per root. Launch/add
    /// scans count; used only for the long-running-session integrity sweep.
    private var lastSuccessfulFullRootScanAt: [LibraryRootPath: Date] = [:]
    private var integrityScanTask: Task<Void, Never>?
    private var knownMaterializationSuppression = KnownMaterializationSuppressionState()
    /// Typed reorganization lease per fixed root (plan 0055 §9.7). Spans one
    /// execution run; deferred dirty-only reconciliation runs at release.
    private var reorganizationLeases: [LibraryRootPath: ReorganizationLease] = [:]
    private var nextReorganizationLeaseGeneration: UInt64 = 0

    /// Long-running-session integrity interval. Launch scans already repair after
    /// process death; this bounds residual FSEvents/provider misses while the app
    /// stays open. Chosen as 24h for measurement/review (plan 0056).
    static let integrityScanInterval: Duration = .seconds(60 * 60 * 24)
    static let integrityScanPollInterval: Duration = .seconds(60 * 15)

    init(
        location: Location,
        scanner: CatalogScanner = .live,
        filesystemWatcher: CatalogFilesystemWatcher = .live,
        scanCadence: Duration = .seconds(1),
        filesystemEventDebounce: Duration = .seconds(1),
        filesystemEventSleep: @escaping @Sendable (Duration) async -> Void = { duration in
            try? await Task.sleep(for: duration)
        },
        initialLoadDidRead: (@Sendable () async -> Void)? = nil,
        importJournalFailure: (@Sendable (ImportJournalTransition) throws -> Void)? = nil
    ) {
        self.location = location
        self.scanner = scanner
        self.filesystemWatcher = filesystemWatcher
        self.scanCadence = scanCadence
        self.filesystemEventDebounce = filesystemEventDebounce
        self.filesystemEventSleep = filesystemEventSleep
        self.initialLoadDidRead = initialLoadDidRead
        self.importJournalFailure = importJournalFailure
    }
}

extension CatalogStore {
    func changeNotifications() -> AsyncStream<CatalogStoreChange> {
        let (stream, continuation) = AsyncStream<CatalogStoreChange>.makeStream(
            // Root-removal signals cannot be dropped: a same-path add may follow
            // before Projection gets another executor turn. Events are tiny and
            // Projection coalesces their expensive work on its existing cadence.
            bufferingPolicy: .unbounded
        )
        let id = UUID()
        changeContinuations[id] = continuation
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

    /// Lossless planning-input revision stream (plan 0055 §6.1). Separate from
    /// coarse `CatalogStoreChange` so thumbnail-only mutations do not replan.
    func planningChangeNotifications() -> AsyncStream<RootPlanningChange> {
        let (stream, continuation) = AsyncStream<RootPlanningChange>.makeStream(
            bufferingPolicy: .unbounded
        )
        let id = UUID()
        planningChangeContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removePlanningChangeContinuation(id)
            }
        }
        let listenerCount = planningChangeContinuations.count
        OtosLog.catalog.notice(
            // swiftlint:disable:next line_length
            "op=catalog.planningChange phase=subscribed listeners=\(listenerCount, privacy: .public)"
        )
        return stream
    }

    func planRevision(for rootPath: LibraryRootPath) -> UInt64? {
        roots[rootPath]?.planRevision
    }

    func occupancyRevision(for rootPath: LibraryRootPath) -> UInt64? {
        roots[rootPath]?.occupancyRevision
    }

    /// General planning revision bump for changes that may invalidate reorganization
    /// planning but never change import occupancy (no-op rescans, event deferrals,
    /// watch arming). Wakes the import coordinator with an unchanged
    /// `occupancyRevision`, which the coordinator treats as a cheap no-op.
    @discardableResult
    func bumpPlanRevision(for path: LibraryRootPath) -> UInt64? {
        guard var state = roots[path] else {
            return nil
        }
        state.planRevision &+= 1
        upsert(state)
        emitPlanningChange(rootPath: path, occupancyRevision: state.occupancyRevision)
        OtosLog.catalog.notice(
            // swiftlint:disable:next line_length
            "op=catalog.planRevision phase=bump rootPath=\(path.rawValue, privacy: .public) planRevision=\(state.planRevision, privacy: .public)"
        )
        return state.planRevision
    }

    /// Occupancy bump for a real import-namespace change (media added/removed/
    /// renamed/resized, companion inventory change, import/reorg settlement, foreign
    /// occupant). Also advances `planRevision` — an occupancy change is a superset
    /// planning change — and wakes the import coordinator with the advanced
    /// `occupancyRevision` so it replans.
    @discardableResult
    func bumpOccupancyRevision(for path: LibraryRootPath) -> UInt64? {
        guard var state = roots[path] else {
            return nil
        }
        state.occupancyRevision &+= 1
        state.planRevision &+= 1
        upsert(state)
        emitPlanningChange(rootPath: path, occupancyRevision: state.occupancyRevision)
        OtosLog.catalog.notice(
            // swiftlint:disable:next line_length
            "op=catalog.occupancyRevision phase=bump rootPath=\(path.rawValue, privacy: .public) occupancyRevision=\(state.occupancyRevision, privacy: .public) planRevision=\(state.planRevision, privacy: .public)"
        )
        return state.occupancyRevision
    }

    /// Records a namespace mutation before its owner crosses a database await.
    /// The epoch invalidates any older destructive scan observation while the typed
    /// dirty scope gives the normal post-lease reconciler enough work to restore
    /// filesystem truth without guessing about deletion.
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
            return try await dbWriter.read { db in
                try MediaOperationGateway.fetchPlanningSourceMedia(
                    libraryRootID: state.rowID,
                    sourceRoot: rootPath,
                    companionsByPrimary: companionsByPrimary,
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
        let sourceMedia = try await dbWriter.read { db in
            try MediaOperationGateway.fetchPlanningSourceMedia(
                libraryRootID: sourceRowID,
                sourceRoot: source,
                companionsByPrimary: companionsByPrimary,
                db: db
            )
        }
        let destinationOccupants = try await dbWriter.read { db in
            try MediaOperationGateway.fetchDestinationOccupants(
                libraryRootID: destinationRowID,
                db: db
            )
        }
        return ImportPlanningSnapshot(
            generation: generation,
            sourceRoot: source,
            destinationRoot: destination,
            sourceOccupancyRevision: sourceState.occupancyRevision,
            destinationOccupancyRevision: destinationState.occupancyRevision,
            sourceMedia: sourceMedia,
            destinationOccupants: destinationOccupants,
            policy: policy,
            calendar: calendar,
            timeZone: timeZone
        )
    }

    func currentLibraries() -> [CatalogLibraryState] {
        roots.values.map { catalogLibraryState(from: $0) }
    }

    /// Nonempty import batches newest-first. Projection publishes these for the
    /// Imports sidebar section.
    func importBatches() async throws -> [ImportBatchSummary] {
        let dbWriter = try database()
        return try await dbWriter.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT import_batch_unix_ms AS batch_ms, COUNT(*) AS asset_count
                FROM media_asset
                WHERE import_batch_unix_ms IS NOT NULL
                GROUP BY import_batch_unix_ms
                ORDER BY import_batch_unix_ms DESC
                """
            ).map { row in
                let batchMs: Int64 = row["batch_ms"]
                let count: Int = row["asset_count"]
                return ImportBatchSummary(
                    batchID: ImportBatchID(unixMilliseconds: batchMs),
                    assetCount: count
                )
            }
        }
    }

    /// Surviving assets that carry the given import batch stamp, across fixed libraries.
    func assetIDs(inImportBatch batchID: ImportBatchID) async throws -> [MediaAssetID] {
        let dbWriter = try database()
        let pathsByRowID = roots.pathsByRowID
        return try await dbWriter.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT library_root_id, relative_path
                FROM media_asset
                WHERE import_batch_unix_ms = ?
                ORDER BY library_root_id, relative_path
                """,
                arguments: [batchID.unixMilliseconds]
            ).compactMap { row in
                let rootRowID: Int64 = row["library_root_id"]
                let relativePath: String = row["relative_path"]
                guard let rootPath = pathsByRowID[rootRowID] else {
                    return nil
                }
                return MediaAssetID(
                    libraryRootPath: rootPath,
                    relativePath: MediaRelativePath(rawValue: relativePath)
                )
            }
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
            try Row.fetchAll(
                db,
                sql: """
                SELECT library_root_id, relative_path
                FROM media_asset
                WHERE best_capture_unix IS NULL
                ORDER BY library_root_id, relative_path
                """
            ).compactMap { row in
                let rootRowID: Int64 = row["library_root_id"]
                let relativePath: String = row["relative_path"]
                guard let rootPath = pathsByRowID[rootRowID] else {
                    return nil
                }
                return MediaAssetID(
                    libraryRootPath: rootPath,
                    relativePath: MediaRelativePath(rawValue: relativePath)
                )
            }
        }
    }

    /// Capture-wall naming fact for one asset, when enrichment selected a local-authority timestamp.
    func captureWall(for id: MediaAssetID) async throws -> CaptureWallClock.Selection? {
        guard let rootRowID = roots[id.libraryRootPath]?.rowID else {
            return nil
        }
        let dbWriter = try database()
        return try await dbWriter.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT capture_wall_compact, capture_wall_precision
                FROM media_asset
                WHERE library_root_id = ? AND relative_path = ?
                """,
                arguments: [rootRowID, id.relativePath.rawValue]
            ) else {
                return nil
            }
            let compact: Int64? = row["capture_wall_compact"]
            let precision: String? = row["capture_wall_precision"]
            guard let compact, let precision else {
                return nil
            }
            return CaptureWallClock.Selection(compact: compact, precision: precision)
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

    func skippedPackageCount(for rootPath: LibraryRootPath) -> Int {
        roots[rootPath]?.skippedPackageCount ?? 0
    }

    func orderedAssetIDs(
        for descriptor: CatalogQueryDescriptor,
        availableLibraryPaths: Set<LibraryRootPath>
    ) async throws -> [MediaAssetID] {
        let scope = scopePredicate(selection: descriptor.scope, availableLibraryPaths: availableLibraryPaths)
        guard !scope.selectsNothing else {
            return []
        }

        let signpost = OtosSignpost.persistence.beginInterval("CatalogStoreOrderedAssetIDQuery")
        let dbWriter = try database()
        let timedRows = try await timedRead(dbWriter) { db in
            try CatalogQueryGateway.fetchOrderedAssetIDRows(
                descriptor: descriptor,
                scope: scope,
                db: db
            )
        }
        OtosSignpost.persistence.endInterval("CatalogStoreOrderedAssetIDQuery", signpost)

        let validRootPathsByRowID = roots.pathsByRowID.filter { rowID, path in
            scope.rootIDs.contains(rowID) && availableLibraryPaths.contains(path)
        }
        let ids = timedRows.value.compactMap { rootRowID, relativePath -> MediaAssetID? in
            guard let rootPath = validRootPathsByRowID[rootRowID] else {
                return nil
            }
            return MediaAssetID(libraryRootPath: rootPath, relativePath: relativePath)
        }
        let queryMs = timedRows.totalMs
        OtosLog.catalog.debug(
            """
            Catalog ordered asset IDs queried descriptor=\(descriptor.diagnosticDescription, privacy: .public) \
            roots=\(scope.rootIDs.count, privacy: .public) count=\(ids.count, privacy: .public) \
            waitMs=\(timedRows.waitMs, privacy: .public) \
            execMs=\(timedRows.execMs, privacy: .public) queryMs=\(queryMs, privacy: .public)
            """
        )
        OtosLog.catalog.notice(
            // swiftlint:disable:next line_length
            "op=catalog.store.query.order phase=finish descriptor=\(descriptor.diagnosticDescription, privacy: .public) rootCount=\(scope.rootIDs.count, privacy: .public) count=\(ids.count, privacy: .public) waitMs=\(timedRows.waitMs, privacy: .public) execMs=\(timedRows.execMs, privacy: .public) queryMs=\(queryMs, privacy: .public)"
        )
        return ids
    }

    func orderedAssetIDs(
        for selection: SidebarSelection,
        availableLibraryPaths: Set<LibraryRootPath>
    ) async throws -> [MediaAssetID] {
        try await orderedAssetIDs(
            for: CatalogQueryDescriptor(scope: selection),
            availableLibraryPaths: availableLibraryPaths
        )
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
            // swiftlint:disable:next line_length
            "op=catalog.store.query.catalogedCount phase=finish selection=\(selection.diagnosticDescription, privacy: .public) rootCount=\(scope.rootIDs.count, privacy: .public) count=\(timedCount.value, privacy: .public) waitMs=\(timedCount.waitMs, privacy: .public) execMs=\(timedCount.execMs, privacy: .public) queryMs=\(timedCount.totalMs, privacy: .public)"
        )
        return timedCount.value
    }

    /// Rows this scope holds in currently reachable roots, ignoring the user filter.
    /// Projection uses it to tell an empty scope from a scope the filter emptied.
    func visibleAssetCount(
        for selection: SidebarSelection,
        availableLibraryPaths: Set<LibraryRootPath>
    ) async throws -> Int {
        let scope = scopePredicate(selection: selection, availableLibraryPaths: availableLibraryPaths)
        guard !scope.selectsNothing else {
            return 0
        }
        let dbWriter = try database()
        let timedCount = try await timedRead(dbWriter) { db in
            try CatalogQueryGateway.countAssets(scope: scope, db: db)
        }
        OtosLog.catalog.notice(
            // swiftlint:disable:next line_length
            "op=catalog.store.query.visibleCount phase=finish selection=\(selection.diagnosticDescription, privacy: .public) rootCount=\(scope.rootIDs.count, privacy: .public) count=\(timedCount.value, privacy: .public) waitMs=\(timedCount.waitMs, privacy: .public) execMs=\(timedCount.execMs, privacy: .public) queryMs=\(timedCount.totalMs, privacy: .public)"
        )
        return timedCount.value
    }

    /// Kinds and formats the filter menu may offer, drawn from the rows this scope
    /// actually holds — so a scope can never offer a filter value that matches
    /// nothing in it.
    func filterOptions(
        for selection: SidebarSelection,
        availableLibraryPaths: Set<LibraryRootPath>
    ) async throws -> CatalogFilterOptions {
        let scope = scopePredicate(selection: selection, availableLibraryPaths: availableLibraryPaths)
        guard !scope.selectsNothing else {
            return .empty
        }
        let dbWriter = try database()
        let timedOptions = try await timedRead(dbWriter) { db in
            try CatalogQueryGateway.filterOptions(scope: scope, db: db)
        }
        OtosLog.catalog.notice(
            // swiftlint:disable:next line_length
            "op=catalog.store.query.filterOptions phase=finish selection=\(selection.diagnosticDescription, privacy: .public) rootCount=\(scope.rootIDs.count, privacy: .public) kindCount=\(timedOptions.value.availableKinds.count, privacy: .public) formatCount=\(timedOptions.value.formatsByKind.values.reduce(0) { $0 + $1.count }, privacy: .public) waitMs=\(timedOptions.waitMs, privacy: .public) execMs=\(timedOptions.execMs, privacy: .public) queryMs=\(timedOptions.totalMs, privacy: .public)"
        )
        return timedOptions.value
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
            // swiftlint:disable:next line_length
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
            // swiftlint:disable:next line_length
            "op=catalog.store.query.metadata phase=finish 0=1 returned=\(timedMetadata.value == nil ? "0" : "1", privacy: .public) waitMs=\(timedMetadata.waitMs, privacy: .public) execMs=\(timedMetadata.execMs, privacy: .public) queryMs=\(queryMs, privacy: .public)"
        )
        return timedMetadata.value
    }

    func enrichmentCandidates(
        prioritizing priorityIDs: [MediaAssetID],
        limit: Int
    ) async throws -> [ClaimedEnrichmentCandidate] {
        guard limit > 0 else {
            return []
        }

        let queryStart = Date()
        let signpost = OtosSignpost.persistence.beginInterval("CatalogStoreEnrichmentCandidateQuery")
        defer {
            OtosSignpost.persistence.endInterval("CatalogStoreEnrichmentCandidateQuery", signpost)
        }

        var candidates: [ClaimedEnrichmentCandidate] = []
        candidates.reserveCapacity(limit)
        var claimedIDs = Set<MediaAssetID>()
        let uniquePriorityIDs = EnrichmentLeaseGateway.unclaimedPriorityIDs(priorityIDs, claimedIDs: &claimedIDs)
        var waitMs = 0
        var execMs = 0

        if !uniquePriorityIDs.isEmpty {
            let priorityClaims = try await priorityEnrichmentCandidates(
                ids: uniquePriorityIDs,
                limit: limit
            )
            candidates.append(contentsOf: priorityClaims.value)
            waitMs += priorityClaims.waitMs
            execMs += priorityClaims.execMs
            for candidate in candidates {
                claimedIDs.insert(candidate.asset.id)
            }
        }

        if candidates.count < limit {
            let remaining = limit - candidates.count
            let queriedClaims = try await claimedEnrichmentCandidates(limit: remaining)
            waitMs += queriedClaims.waitMs
            execMs += queriedClaims.execMs
            for candidate in queriedClaims.value
                where candidates.count < limit && !claimedIDs.contains(candidate.asset.id)
            {
                claimedIDs.insert(candidate.asset.id)
                candidates.append(candidate)
            }
        }

        let queryMs = waitMs + execMs
        let wallMs = DiagnosticsTiming.milliseconds(since: queryStart)
        if queryMs > Self.slowQueryDiagnosticThresholdMs {
            await recordSlowEnrichmentCandidateQuery(
                priorityCount: priorityIDs.count,
                returnedCount: candidates.count,
                waitMs: waitMs,
                execMs: execMs,
                wallMs: wallMs
            )
        }
        return candidates
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
            // swiftlint:disable:next line_length
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
            try EnrichmentLeaseGateway.releaseEnrichmentClaims(ids: ids, rootIDsByPath: rootIDsByPathBeforeWrite, db: db)
        }
    }

    @discardableResult
    func refreshEnrichmentClaims(_ ids: [MediaAssetID]) async throws -> Date? {
        guard !ids.isEmpty else {
            return nil
        }
        let rootIDsByPathBeforeWrite = roots.rowIDSnapshot()
        let claimedUntil = EnrichmentLeaseGateway.claimedUntil()
        let dbWriter = try database()
        try await dbWriter.write { db in
            try EnrichmentLeaseGateway.refreshEnrichmentClaims(
                ids: ids,
                rootIDsByPath: rootIDsByPathBeforeWrite,
                claimedUntil: claimedUntil,
                db: db
            )
        }
        return Date(timeIntervalSince1970: claimedUntil)
    }

    private func priorityEnrichmentCandidates(
        ids: [MediaAssetID],
        limit: Int
    ) async throws -> DatabaseTimedValue<[ClaimedEnrichmentCandidate]> {
        let priorityAssetsByID = try await mediaAssets(for: ids)
        let rootIDsByPathBeforeWrite = roots.rowIDSnapshot()
        let claimedUntil = EnrichmentLeaseGateway.claimedUntil()
        let dbWriter = try database()
        let eligibleClaims = EnrichmentLeaseGateway.priorityClaimInputs(
            ids: ids,
            assetsByID: priorityAssetsByID,
            rootIDsByPath: rootIDsByPathBeforeWrite,
            isRootAvailable: { [roots] path in roots[path]?.availability == .available },
            isHashRequired: { [roots] path in roots[path]?.root.isContentHashRequired == true }
        )
        guard !eligibleClaims.isEmpty else {
            return DatabaseTimedValue(value: [], waitMs: 0, execMs: 0)
        }
        let timedClaim = try await timedWrite(dbWriter) { db in
            var candidates: [ClaimedEnrichmentCandidate] = []
            candidates.reserveCapacity(min(limit, eligibleClaims.count))
            for (asset, rootID, hashRequired) in eligibleClaims {
                guard candidates.count < limit else {
                    break
                }
                guard try EnrichmentLeaseGateway.claimEnrichmentAsset(
                    libraryRootID: rootID,
                    relativePath: asset.relativePath,
                    claimedUntil: claimedUntil,
                    hashRequired: hashRequired,
                    db: db
                ) else {
                    continue
                }
                candidates.append(ClaimedEnrichmentCandidate(asset: asset, hashRequired: hashRequired))
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
            // swiftlint:disable:next line_length
            "op=catalog.store.query.enrichment.priorityClaim phase=finish priority=\(priorityCount, privacy: .public) eligible=\(eligibleCount, privacy: .public) returned=\(result.value.count, privacy: .public) waitMs=\(result.waitMs, privacy: .public) execMs=\(result.execMs, privacy: .public) queryMs=\(result.totalMs, privacy: .public) thresholdMs=\(Self.slowQueryDiagnosticThresholdMs, privacy: .public)"
        )
    }

    private func claimedEnrichmentCandidates(limit: Int) async throws -> DatabaseTimedValue<[ClaimedEnrichmentCandidate]> {
        let claimedUntil = EnrichmentLeaseGateway.claimedUntil()
        let prioritizedRootIDs = availableRootIDsByRemovablePriority()
        let (hashRequiredRootIDs, hashNotRequiredRootIDs) = roots.availableRootIDsByHashRequirement()
        let dbWriter = try database()
        let timedStoredAssets = try await timedWrite(dbWriter) { db in
            var storedAssets: [(asset: StoredAsset, hashRequired: Bool)] = []
            // The fallback spans roots of mixed kinds (ADR 0018): `.removableVolume`
            // is claimed with the metadata-only predicate and index, every other kind
            // with the broad predicate. `INDEXED BY` forbids one statement across both,
            // so partition by hash requirement within each priority tier. `.deviceMTP`
            // is removable-priority but hash-required, `.removableVolume` is
            // removable-priority and hash-not-required, `.library` is fixed and
            // hash-required; the tiers therefore claim in that order.
            let removableRoots = Set(prioritizedRootIDs.removable)
            let fixedRoots = Set(prioritizedRootIDs.fixed)
            let claimGroups: [(rootIDs: [Int64], hashRequired: Bool)] = [
                (removableRoots.intersection(hashRequiredRootIDs).sorted(), true),
                (removableRoots.intersection(hashNotRequiredRootIDs).sorted(), false),
                (fixedRoots.intersection(hashRequiredRootIDs).sorted(), true),
                (fixedRoots.intersection(hashNotRequiredRootIDs).sorted(), false),
            ]
            for group in claimGroups where storedAssets.count < limit && !group.rootIDs.isEmpty {
                let remaining = limit - storedAssets.count
                let claimed = try EnrichmentLeaseGateway.fetchStoredAssetsNeedingEnrichment(
                    rootIDs: group.rootIDs,
                    claimNotAfter: claimedUntil,
                    limit: remaining,
                    hashRequired: group.hashRequired,
                    db: db
                )
                storedAssets.append(contentsOf: claimed.map { (asset: $0, hashRequired: group.hashRequired) })
            }
            return storedAssets
        }
        // `hashRequired` here is the claim predicate the row was just claimed under
        // (carried from the `claimGroups` entry above), not re-derived from current
        // root kind — plan 0065 Stage 2b. A root's kind cannot change between the claim
        // above and this mapping since both run inside the same actor-isolated call, but
        // carrying the value keeps one owner rather than inviting a second opinion later.
        let candidates: [ClaimedEnrichmentCandidate] = timedStoredAssets.value.compactMap { entry in
            guard let rootPath = roots.pathsByRowID[entry.asset.libraryRootID],
                  roots[rootPath]?.rowID == entry.asset.libraryRootID,
                  roots[rootPath]?.availability == .available
            else {
                return nil
            }
            return ClaimedEnrichmentCandidate(
                asset: mediaAsset(from: entry.asset, rootPath: rootPath),
                hashRequired: entry.hashRequired
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
            // swiftlint:disable:next line_length
            "op=catalog.store.query.enrichment.claim phase=finish limit=\(limit, privacy: .public) availableRootCount=\(removableRootCount + fixedRootCount, privacy: .public) removableRootCount=\(removableRootCount, privacy: .public) returned=\(result.value.count, privacy: .public) waitMs=\(result.waitMs, privacy: .public) execMs=\(result.execMs, privacy: .public) queryMs=\(result.totalMs, privacy: .public) thresholdMs=\(Self.slowQueryDiagnosticThresholdMs, privacy: .public)"
        )
    }

    func start(scansSavedLibraries: Bool = true) async throws {
        try await loadIfNeeded()
        try await LibraryReorganizationRunner.recoverJournal(store: self)
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
        // Tests pause precisely at this real suspension boundary to prove that
        // concurrent mutation callers join this load. Production leaves the
        // hook nil and performs no additional work.
        await initialLoadDidRead?()
        let normalizedRoots = await normalizeLoadedRoots(loaded.roots, dbWriter: dbQueue)
        let applyState = OtosSignpost.catalog.beginInterval("CatalogApplyLoadedCatalog")
        applyLoadedCatalog(roots: normalizedRoots)
        unrequestedLoadedRootPaths = normalizedRoots
            .filter { $0.kind == .library }
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

    private func clearAbandonedEnrichmentClaims(_ dbQueue: any DatabaseWriter) async throws {
        let clearedCount = try await dbQueue.write { db in
            try EnrichmentLeaseGateway.clearEnrichmentClaims(db: db)
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

    /// Applies a batch of completed enrichments in one transaction and one notification.
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
            discardGeneratedThumbnails(results.compactMap(\.generatedThumbnail))
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
            discardGeneratedThumbnails(results.compactMap(\.generatedThumbnail))
            await recordEnrichmentBatchError(error, count: results.count)
            await releaseEnrichmentClaimsAfterBatch(resultIDs)
            return .writeFailed
        }
        OtosSignpost.persistence.endInterval("CatalogEnrichmentBatchWrite", state)
        discardGeneratedThumbnails(writeOutcome.discardedThumbnails)
        deleteSupersededThumbnails(writeOutcome.supersededThumbnailPaths)

        await recordEnrichmentBatchWrite(resultsCount: results.count, writeOutcome: writeOutcome)
        await recordWALDiagnostics(reason: "enrichmentBatch")
        if writeOutcome.appliedCount > 0 {
            // An enrichment batch that changed no effective ordering/scope column is a
            // detail-only change: the projection refreshes visible detail but skips the
            // full order re-query (plan 0064 Stage 3). Any `best_capture`/`best_kind`/
            // `best_format` change is structural and keeps the full rebuild.
            notifyCatalogChanged(writeOutcome.structureChanged ? .catalogChanged : .assetsDetailChanged)
        }
        await releaseEnrichmentClaimsAfterBatch(resultIDs)
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
            // swiftlint:disable:next line_length
            "op=catalog.enrichment.batch phase=finish attempted=\(resultsCount, privacy: .public) count=\(writeOutcome.appliedCount, privacy: .public) discardedThumbnails=\(writeOutcome.discardedThumbnails.count, privacy: .public) supersededThumbnails=\(writeOutcome.supersededThumbnailPaths.count, privacy: .public) promotionFailed=\(writeOutcome.promotionFailed, privacy: .public) waitMs=\(writeOutcome.waitMs, privacy: .public) execMs=\(writeOutcome.execMs, privacy: .public) writeMs=\(writeOutcome.waitMs + writeOutcome.execMs, privacy: .public)"
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
        guard let rootID = rootIDsByPath[result.id.libraryRootPath] else {
            outcome.discard(result.generatedThumbnail)
            return
        }
        guard result.generatedThumbnail == nil || thumbnailDirectory != nil else {
            outcome.failPromotion(result.generatedThumbnail)
            return
        }
        guard try enrichmentResultMatchesCurrentRow(result, libraryRootID: rootID, db: db) else {
            outcome.discard(result.generatedThumbnail)
            return
        }
        if let generatedThumbnail = result.generatedThumbnail, let thumbnailDirectory {
            do {
                try ThumbnailStore.promote(generatedThumbnail, in: thumbnailDirectory)
            } catch {
                outcome.failPromotion(generatedThumbnail)
                return
            }
        }
        let overlayColumnsSQL = """
        SELECT best_capture_unix, best_kind, best_format, thumbnail_path
        FROM media_asset
        WHERE library_root_id = ? AND relative_path = ?
        """
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
        if let old = oldRow, let newRow,
           old.bestCaptureUnix != newRow.bestCaptureUnix
           || old.bestKind != newRow.bestKind
           || old.bestFormat != newRow.bestFormat
        {
            outcome.structureChanged = true
        }
        outcome.replaceThumbnail(oldPath: oldRow?.thumbnailPath, newPath: result.thumbnailPath)
        outcome.appliedCount += 1
    }

    private func discardGeneratedThumbnails(_ thumbnails: [GeneratedThumbnail]) {
        guard let thumbnailDirectory else {
            return
        }
        for thumbnail in thumbnails {
            ThumbnailStore.discard(thumbnail, in: thumbnailDirectory)
        }
    }

    private func deleteSupersededThumbnails(_ paths: Set<String>) {
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
        try validateNoOverlap(path)
        try await insertLibraryRootAndStartScan(path, operation: "catalog.library.add")
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
        try validateNoOverlap(path)
        try await insertLibraryRootAndStartScan(
            path,
            operation: "catalog.library.ensure",
            recordsStart: false
        )
    }

    func removeLibrary(path: LibraryRootPath) async throws {
        try await ensureStartedForMutation()
        guard let rootState = roots[path] else {
            return
        }
        let root = rootState.root
        let rootRowID = rootState.rowID

        cancelRuntimeWork(for: path)
        filesystemWatcher.removeRoot(path)
        filesystemWatchingArmed.remove(path)

        let dbQueue = try database()
        guard let purgedThumbnails = try await thumbnailPathsForLibraryRemoval(
            path: path,
            root: root,
            rootRowID: rootRowID,
            dbWriter: dbQueue
        ) else {
            return
        }

        let state = OtosSignpost.persistence.beginInterval("CatalogRemoveRoot")
        OtosLog.catalog.notice(
            "op=catalog.library.remove phase=start rootPath=\(path.rawValue, privacy: .public)"
        )
        try await dbQueue.write { db in
            try Self.deleteLibraryRoot(rootRowID: rootRowID, db: db)
        }
        OtosSignpost.persistence.endInterval("CatalogRemoveRoot", state)

        removeRoot(path: path)
        if let thumbnailDirectory {
            for name in purgedThumbnails {
                ThumbnailStore.delete(name, in: thumbnailDirectory)
            }
        }
        deleteDeviceStagingIfNeeded(root)
        OtosLog.catalog.info("Library root removed path=\(root.path.rawValue, privacy: .public)")
        OtosLog.catalog.notice(
            "op=catalog.library.remove phase=finish rootPath=\(path.rawValue, privacy: .public)"
        )
        notifyCatalogChanged(.libraryRemoved(path))
        startNextScanIfNeeded()
    }

    private func thumbnailPathsForLibraryRemoval(
        path: LibraryRootPath,
        root: LibraryRoot,
        rootRowID: Int64,
        dbWriter: any DatabaseWriter
    ) async throws -> [String]? {
        do {
            let deletionFacts = try await dbWriter.read { db in
                try Self.fetchExistingAssetRows(libraryRootID: rootRowID, db: db)
            }
            guard roots[path]?.root == root,
                  roots[path]?.rowID == rootRowID
            else {
                return nil
            }
            return deletionFacts.compactMap(\.thumbnailPath)
        } catch {
            OtosLog.persistence.error(
                "Catalog remove root thumbnail lookup failed error=\(String(describing: error), privacy: .public)"
            )
            throw error
        }
    }

    private func rootForDeviceIdentity(_ identity: String) -> LibraryRoot? {
        roots.rootForDeviceIdentity(identity)
    }

    private func isTransientDeviceIdentity(_ identity: String) -> Bool {
        identity.hasPrefix("volume:path:")
            || identity.contains("#path:")
            || identity.hasPrefix("camera:transient:")
    }

    private func cancelRuntimeWork(for path: LibraryRootPath) {
        unrequestedLoadedRootPaths.removeAll { $0 == path }
        cancelFilesystemDebounce(for: path)
        filesystemDirty.removeValue(forKey: path)
        lastSuccessfulFullRootScanAt.removeValue(forKey: path)
        knownMaterializationSuppression.removeAll(under: path)
        if scanLeases.cancelWork(for: path) {
            currentScanTask?.cancel()
            currentScanTask = nil
        }
    }

    private func releaseEnrichmentClaimsForRoot(_ rootRowID: Int64) async {
        guard let dbWriter else {
            return
        }
        do {
            try await dbWriter.write { db in
                try EnrichmentLeaseGateway.releaseEnrichmentClaims(rootID: rootRowID, db: db)
            }
        } catch {
            OtosLog.metadata.error(
                "Root enrichment claim release failed error=\(String(describing: error), privacy: .public)"
            )
        }
    }

    private func deleteDeviceStagingIfNeeded(_ root: LibraryRoot) {
        guard root.kind == .deviceMTP else {
            return
        }
        try? FileManager.default.removeItem(at: root.path.url)
    }

    private func attachRemovableRoot(_ attachment: RemovableRootAttachment) async throws {
        let lastSeenAt = Date()
        let dbQueue = try database()
        if let existingRoot = rootForDeviceIdentity(attachment.identity),
           let rootRowID = roots[existingRoot.path]?.rowID
        { // swiftlint:disable:this opening_brace
            try await updateExistingRemovableRoot(
                attachment,
                existingRoot: existingRoot,
                rootRowID: rootRowID,
                lastSeenAt: lastSeenAt,
                dbWriter: dbQueue
            )
        } else {
            try await insertRemovableRoot(attachment, lastSeenAt: lastSeenAt, dbWriter: dbQueue)
        }
        await finishRemovableRootAttachment(attachment)
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
                db: db
            )
        }
        let root = libraryRoot(from: storedRoot)
        upsert(RootRuntimeState(
            root: root,
            rowID: storedRoot.id,
            availability: .unknown,
            activity: .idle,
            isEjectable: false
        ))
    }

    private func finishRemovableRootAttachment(_ attachment: RemovableRootAttachment) async {
        guard var state = roots[attachment.path] else {
            return
        }
        state.availability = .available
        state.activity = attachment.activity
        state.isEjectable = attachment.isEjectable
        upsert(state)
        if attachment.kind == .removableVolume {
            filesystemWatcher.addRoot(attachment.path)
        }
        OtosLog.catalog.info(
            """
            Removable source attached kind=\(attachment.kind.rawValue, privacy: .public) \
            identity=\(attachment.identity, privacy: .public) path=\(attachment.path.rawValue, privacy: .public)
            """
        )
        OtosLog.catalog.notice(
            // swiftlint:disable:next line_length
            "op=catalog.removable.attach phase=finish kind=\(attachment.kind.rawValue, privacy: .public) identity=\(attachment.identity, privacy: .public) rootPath=\(attachment.path.rawValue, privacy: .public) displayName=\(attachment.displayName, privacy: .public)"
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
        upsert(RootRuntimeState(
            root: newRoot,
            rowID: rootRowID,
            availability: previous?.availability ?? .unknown,
            activity: previous?.activity ?? .idle,
            isEjectable: previous?.isEjectable ?? false,
            skippedPackageCount: previous?.skippedPackageCount ?? 0,
            planRevision: (previous?.planRevision ?? 0) &+ 1,
            occupancyRevision: (previous?.occupancyRevision ?? 0) &+ 1
        ))
    }

    private func insertLibraryRootAndStartScan(
        _ path: LibraryRootPath,
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
            try Self.insertLibraryRoot(path: path, db: db)
        }

        let root = libraryRoot(from: storedRoot)
        upsert(RootRuntimeState(
            root: root,
            rowID: storedRoot.id,
            availability: .available,
            activity: .idle,
            isEjectable: false
        ))
        OtosLog.catalog.info("Library root added path=\(root.path.rawValue, privacy: .public)")
        OtosLog.catalog.notice(
            "op=\(operation, privacy: .public) phase=finish rootPath=\(root.path.rawValue, privacy: .public)"
        )
        notifyCatalogChanged()
        filesystemWatcher.addRoot(root.path)
        enqueueScans([root.path])
    }

    func attachRemovableVolume(
        mountURL: URL,
        identity: String,
        displayName: String,
        isEjectable: Bool
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
            enqueuesScan: true
        ))
    }

    @discardableResult
    func attachDeviceMTP(
        stagingRootURL: URL,
        identity: String,
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
            enqueuesScan: false
        ))
        return path
    }

    func detachRemovableSource(identity: String, reason: RemovableSourceDetachReason) async throws {
        try await ensureStartedForMutation()
        guard let root = rootForDeviceIdentity(identity),
              root.kind != .library,
              let rootRowID = roots[root.path]?.rowID
        else {
            return
        }
        if isTransientDeviceIdentity(identity) {
            try await removeLibrary(path: root.path)
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
        setAvailability(.unavailable, for: root.path)
        if root.kind == .deviceMTP {
            deleteDeviceStagingIfNeeded(root)
        }
        OtosLog.catalog.info(
            """
            Removable source detached identity=\(identity, privacy: .public) \
            reason=\(reason.rawValue, privacy: .public)
            """
        )
        OtosLog.catalog.notice(
            // swiftlint:disable:next line_length
            "op=catalog.removable.detach phase=finish identity=\(identity, privacy: .public) rootPath=\(root.path.rawValue, privacy: .public) kind=\(root.kind.rawValue, privacy: .public) reason=\(reason.rawValue, privacy: .public)"
        )
        notifyCatalogChanged()
        startNextScanIfNeeded()
    }

    func quiesceRemovableSource(identity: String) async throws {
        try await ensureStartedForMutation()
        guard let root = rootForDeviceIdentity(identity),
              root.kind != .library,
              let rootRowID = roots[root.path]?.rowID
        else {
            return
        }
        cancelRuntimeWork(for: root.path)
        if var state = roots[root.path] {
            state.activity = .idle
            upsert(state)
        }
        await releaseEnrichmentClaimsForRoot(rootRowID)
        OtosLog.catalog.notice(
            // swiftlint:disable:next line_length
            "op=catalog.removable.quiesce phase=finish identity=\(identity, privacy: .public) rootPath=\(root.path.rawValue, privacy: .public) kind=\(root.kind.rawValue, privacy: .public)"
        )
    }

    func resumeRemovableSource(identity: String) async throws {
        try await ensureStartedForMutation()
        guard let root = rootForDeviceIdentity(identity),
              root.kind != .library
        else {
            return
        }
        let changed = setAvailability(.available, for: root.path)
        if changed {
            notifyCatalogChanged()
        }
        OtosLog.catalog.notice(
            // swiftlint:disable:next line_length
            "op=catalog.removable.resume phase=finish identity=\(identity, privacy: .public) rootPath=\(root.path.rawValue, privacy: .public) kind=\(root.kind.rawValue, privacy: .public)"
        )
    }

    func beginDeviceCatalogEnumeration(rootPath: LibraryRootPath) async throws -> ActiveScan {
        guard roots[rootPath]?.root.kind == .deviceMTP,
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
        scanLeases.beginDeviceScan(scan)
        if var state = roots[rootPath] {
            state.activity = .enumerating
            upsert(state)
        }
        notifyCatalogChanged()
        return scan
    }

    func recordDeviceCatalogBatch(_ batch: [ScannedMediaFile], scan: ActiveScan) async throws {
        try await ensureStartedForMutation()
        guard owns(scan),
              roots[scan.rootPath]?.root.kind == .deviceMTP,
              roots[scan.rootPath]?.availability == .available
        else {
            throw CancellationError()
        }
        let dbQueue = try database()
        let timedChangedCount = try await timedWrite(dbQueue) { db in
            var count = 0
            for file in batch {
                let changed = try Self.upsertScannedFile(
                    file,
                    libraryRootPath: scan.rootPath,
                    libraryRootID: scan.rootRowID,
                    db: db
                )
                if changed {
                    count += 1
                }
            }
            return count
        }
        guard owns(scan) else {
            throw CancellationError()
        }
        if timedChangedCount.value > 0 {
            notifyCatalogChanged()
        }
        OtosLog.catalog.notice(
            // swiftlint:disable:next line_length
            "op=catalog.device.scan.batch phase=finish rootPath=\(scan.rootPath.rawValue, privacy: .public) count=\(batch.count, privacy: .public) changedCount=\(timedChangedCount.value, privacy: .public) waitMs=\(timedChangedCount.waitMs, privacy: .public) execMs=\(timedChangedCount.execMs, privacy: .public)"
        )
    }

    func completeDeviceCatalogEnumeration(
        scan: ActiveScan,
        observedPaths: Set<MediaRelativePath>,
        companions: [MediaCompanion] = []
    ) async throws {
        guard owns(scan),
              roots[scan.rootPath]?.root.kind == .deviceMTP,
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
            _ = try await timedWrite(dbQueue) { db in
                var changed = 0
                for companion in companions {
                    if try Self.upsertCompanion(companion, libraryRootID: scan.rootRowID, db: db) {
                        changed += 1
                    }
                }
                changed += try Self.reconcileMissingCompanions(
                    libraryRootID: scan.rootRowID,
                    observedPaths: Set(companions.map(\.relativePath)),
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
        await endDeviceCatalogEnumeration(scan: scan)
    }

    func endDeviceCatalogEnumeration(scan: ActiveScan) async {
        guard scanLeases.isCurrentDeviceScan(scan) else {
            return
        }
        scanLeases.endDeviceScan(scan)
        if var state = roots[scan.rootPath], state.root.kind == .deviceMTP {
            state.activity = .idle
            upsert(state)
            notifyCatalogChanged()
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
        currentScanTask?.cancel()
        currentScanTask = nil
        integrityScanTask?.cancel()
        integrityScanTask = nil
        scanLeases.resetAll()
        cancelAllFilesystemDebounces()
        filesystemDirty.removeAll()
        lastSuccessfulFullRootScanAt.removeAll()
        knownMaterializationSuppression.clear()
        filesystemWatcher.stop()
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
            try? Self.applicationThumbnailDirectory(bundleIdentifier: bundleIdentifier)
        case let .databaseFile(url):
            url.deletingLastPathComponent().appending(path: "Thumbnails", directoryHint: .isDirectory)
        case .inMemory:
            nil
        }
    }
}

private extension CatalogStore {
    private func timedRead<Value: Sendable>(
        _ dbWriter: any DatabaseWriter,
        _ body: @Sendable @escaping (Database) throws -> Value
    ) async throws -> DatabaseTimedValue<Value> {
        let start = Date()
        return try await dbWriter.read { db in
            let entered = Date()
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
        let start = Date()
        return try await dbWriter.write { db in
            let entered = Date()
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
        let removedTemps = ThumbnailStore.deleteStagedTemporaryFiles(in: thumbnailDirectory)
        guard removedTemps > 0 else {
            return
        }
        OtosLog.thumbnails.info(
            "Staged thumbnail temp cleanup removed count=\(removedTemps, privacy: .public)"
        )
        recordDiagnostic(
            operation: "catalog.thumbnails.stagedTempCleanup",
            phase: "finish",
            fields: ["count": "\(removedTemps)"]
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
            // SQLite proves that a root was saved, not that it is reachable now.
            // Fixed libraries are checked by launch scans; removable roots are
            // event-driven and start unavailable until a monitor re-attaches them.
            roots.upsert(RootRuntimeState(
                root: root,
                rowID: storedRoot.id,
                availability: root.kind == .library ? .unknown : .unavailable,
                activity: .idle,
                isEjectable: false
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

    private func normalizedLoadedRoot(
        _ storedRoot: StoredRoot,
        dbWriter: any DatabaseWriter
    ) async -> StoredRoot {
        guard storedRoot.kind == .library else {
            return storedRoot
        }
        guard let normalizedPath = try? CatalogPath.normalizedExistingDirectoryPath(for: storedRoot.path.url),
              normalizedPath != storedRoot.path
        else {
            return storedRoot
        }
        do {
            let thumbnailMigrations = try await dbWriter.write { db in
                try Self.updateLibraryRootPath(rootRowID: storedRoot.id, path: normalizedPath, db: db)
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
                // swiftlint:disable:next line_length
                "op=catalog.library.normalize phase=finish oldRootPath=\(storedRoot.path.rawValue, privacy: .public) rootPath=\(normalizedPath.rawValue, privacy: .public) thumbnailMigrations=\(thumbnailMigrations.count, privacy: .public)"
            )
            return StoredRoot(
                id: storedRoot.id,
                path: normalizedPath,
                kind: storedRoot.kind,
                deviceIdentity: storedRoot.deviceIdentity,
                displayName: storedRoot.displayName,
                lastSeenAt: storedRoot.lastSeenAt
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
            // swiftlint:disable:next line_length
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
            bestCaptureDate: storedAsset.bestCaptureDate,
            bestKind: storedAsset.bestKind,
            bestFormat: storedAsset.bestFormat,
            durationSeconds: storedAsset.durationSeconds,
            enrichedSourceSize: storedAsset.enrichedSourceSize,
            enrichedSourceMTimeSeconds: storedAsset.enrichedSourceMTimeSeconds,
            contentHash: storedAsset.contentHash,
            contentHashSourceSize: storedAsset.contentHashSourceSize,
            contentHashSourceMTimeSeconds: storedAsset.contentHashSourceMTimeSeconds
        )
    }

    private func mediaTileDetail(from storedDetail: StoredTileDetail, rootPath: LibraryRootPath) -> MediaTileDetail {
        MediaTileDetail(
            libraryRootPath: rootPath,
            relativePath: storedDetail.relativePath,
            thumbnailPath: storedDetail.thumbnailPath,
            bestKind: storedDetail.bestKind,
            durationSeconds: storedDetail.durationSeconds,
            enrichedSourceSize: storedDetail.enrichedSourceSize,
            enrichedSourceMTimeSeconds: storedDetail.enrichedSourceMTimeSeconds
        )
    }

    private func upsert(_ state: RootRuntimeState) {
        roots.upsert(state)
    }

    private func removeRoot(path: LibraryRootPath) {
        _ = roots.remove(path: path)
        scanLeases.removeDeviceScan(for: path)
    }

    private func catalogLibraryState(from state: RootRuntimeState) -> CatalogLibraryState {
        CatalogLibraryState(
            root: state.root,
            availability: state.availability,
            activity: activity(for: state.path),
            isEjectable: state.isEjectable
        )
    }

    private func activity(for path: LibraryRootPath) -> CatalogLibraryActivity {
        // Pending full-root scans must read as scanning. clearCurrentScan clears the
        // active lease before the async dirty-revisit Task starts the next pending
        // root; without this, waiters can observe a false idle gap and race.
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
            lastSeenAt: storedRoot.lastSeenAt
        )
    }

    private func scopePredicate(
        selection: SidebarSelection,
        availableLibraryPaths: Set<LibraryRootPath>
    ) -> CatalogScopePredicate {
        roots.scopePredicate(selection: selection, availableLibraryPaths: availableLibraryPaths)
    }

    private func availableRootIDsByRemovablePriority() -> (removable: [Int64], fixed: [Int64]) {
        roots.availableRootIDsByRemovablePriority()
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

    private func startNextScanIfNeeded() {
        guard !isRevisitingDirtyRoots else {
            return
        }
        guard currentScanTask == nil else {
            return
        }
        while let nextPath = scanLeases.popPending() {
            guard roots[nextPath] != nil,
                  let rootRowID = roots[nextPath]?.rowID
            else {
                continue
            }
            if reorganizationLeases[nextPath] != nil {
                // Defer until lease release; do not spin the pending queue.
                scanLeases.markRescanAfterCurrentScan(nextPath)
                continue
            }
            guard rootIsAvailable(nextPath) else {
                markRootUnavailableBeforeScan(nextPath)
                continue
            }
            setAvailability(.available, for: nextPath)
            let scan = scanLeases.makeActiveScan(
                rootPath: nextPath,
                rootRowID: rootRowID,
                startNamespaceMutationEpoch: roots[nextPath]?.namespaceMutationEpoch ?? 0
            )
            scanLeases.beginFilesystemScan(scan)
            filesystemWatchingArmed.insert(nextPath)
            filesystemWatcher.addRoot(nextPath)
            notifyCatalogChanged()
            OtosLog.catalog.info("Catalog scan started path=\(nextPath.rawValue, privacy: .public)")
            recordDiagnostic(
                operation: "catalog.scan",
                phase: "start",
                fields: ["rootPath": nextPath.rawValue]
            )
            // The scan task is retained in `currentScanTask`, cancelled when
            // the owning root goes away, and every callback revalidates the
            // `ActiveScan` lease before mutating actor state.
            currentScanTask = Task.detached(priority: .utility) { [scanner, scanCadence] in
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
            return
        }
    }

    private func recordScannedBatch(_ batch: [ScannedMediaFile], scan: ActiveScan) async throws {
        guard owns(scan) else {
            await recordIgnoredStaleCallback(scan, callback: "batch.beforeWrite")
            throw CancellationError()
        }

        let dbQueue = try database()
        let state = OtosSignpost.persistence.beginInterval("CatalogScanBatchWrite")
        let timedChangedCount = try await timedWrite(dbQueue) { db in
            var count = 0
            for file in batch {
                let changed = try Self.upsertScannedFile(
                    file,
                    libraryRootPath: scan.rootPath,
                    libraryRootID: scan.rootRowID,
                    db: db
                )
                if changed {
                    count += 1
                }
            }
            return count
        }
        OtosSignpost.persistence.endInterval("CatalogScanBatchWrite", state)
        let changedCount = timedChangedCount.value

        // The store actor can process remove/cancel messages while SQLite is
        // writing. Recheck ownership before notifying from this batch.
        guard owns(scan) else {
            await recordIgnoredStaleCallback(scan, callback: "batch.afterWrite")
            throw CancellationError()
        }

        let visibleChange = changedCount > 0
        // SQLite reported whether this batch inserted a new row or changed existing
        // filesystem facts. Identical rescans publish nothing; changed dates still
        // count because Date sort and enrichment priority fall back to them. A
        // changed batch is a real import-occupancy change (added row or resized
        // file), so it advances the occupancy revision; identical rescans do not,
        // which is what lets import planning settle against a churning cloud root.
        if visibleChange {
            bumpOccupancyRevision(for: scan.rootPath)
            notifyCatalogChanged()
        }
        await recordScanBatchWrite(
            scan: scan,
            scannedCount: batch.count,
            changedCount: changedCount,
            timing: timedChangedCount
        )
        await recordWALDiagnostics(reason: "scanBatch")
    }

    private func recordScanBatchWrite(
        scan: ActiveScan,
        scannedCount: Int,
        changedCount: Int,
        timing: DatabaseTimedValue<Int>
    ) async {
        let visibleChange = changedCount > 0
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
            // swiftlint:disable:next line_length
            "op=catalog.scan.batch phase=finish rootPath=\(scan.rootPath.rawValue, privacy: .public) count=\(scannedCount, privacy: .public) changed=\(visibleChange, privacy: .public) changedCount=\(changedCount, privacy: .public) waitMs=\(timing.waitMs, privacy: .public) execMs=\(timing.execMs, privacy: .public) writeMs=\(timing.totalMs, privacy: .public)"
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
                bumpOccupancyRevision(for: scan.rootPath)
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
                // swiftlint:disable:next line_length
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
            lastSuccessfulFullRootScanAt[scan.rootPath] = Date()
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
                // swiftlint:disable:next line_length
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
        let timed = try await timedWrite(dbQueue) { db in
            let upserted = try Self.applyScannedCompanions(
                companions,
                libraryRootID: scan.rootRowID,
                db: db
            )
            let deleted = if reconcileMissing {
                try Self.reconcileMissingCompanions(
                    libraryRootID: scan.rootRowID,
                    observedPaths: Set(companions.map(\.relativePath)),
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
        let missingRows = existingRows.filter { !observedPaths.contains($0.relativePath) }
        guard !missingRows.isEmpty else {
            return 0
        }
        guard scanCanDelete(scan) else {
            return 0
        }
        // Capture the thumbnail files of soon-to-be-purged assets before their rows are
        // removed, so overlay is purged with the item (ADR 0008): the catalog rows and
        // thumbnail file all go together on proven deletion.
        let purgedThumbnails: [String] = missingRows.compactMap(\.thumbnailPath)
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
    }

    private func clearCurrentScan(_ scan: ActiveScan, armFilesystemWatching: Bool) {
        guard scanLeases.isCurrentFilesystemScan(scan) else {
            return
        }
        let rootPath = scan.rootPath
        let needsRescan = scanLeases.clearFilesystemScan(scan)
        currentScanTask = nil

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
        // Drain every dirty root before starting the next queued full-root scan.
        // Starting B first used to strand A's retained file/subtree dirt because
        // drainDirtyReconcile exited on the global currentScanTask.
        Task { await self.afterFilesystemLeaseCleared() }
    }

    /// Store-owned reconciliation scheduler: revisit all dirty roots whenever the
    /// single filesystem scan lease clears, then start the next queued full scan.
    private func afterFilesystemLeaseCleared() async {
        // Suppress startNextScanIfNeeded while revisiting dirty roots so a
        // root-dirty enqueue mid-pass cannot start scan B before file/subtree
        // dirt for other roots has been considered.
        isRevisitingDirtyRoots = true
        await drainAllDirtyRoots()
        isRevisitingDirtyRoots = false
        startNextScanIfNeeded()
    }

    private func drainAllDirtyRoots() async {
        let rootsToDrain = filesystemDirty.keys.sorted { $0.rawValue < $1.rawValue }
        for root in rootsToDrain {
            await drainDirtyReconcile(for: root)
        }
    }

    private func notifyCatalogChanged(_ change: CatalogStoreChange = .catalogChanged) {
        let state = OtosSignpost.catalog.beginInterval("CatalogChangeNotify")
        defer {
            OtosSignpost.catalog.endInterval("CatalogChangeNotify", state)
        }
        for continuation in changeContinuations.values {
            continuation.yield(change)
        }
    }

    private func emitPlanningChange(rootPath: LibraryRootPath, occupancyRevision: UInt64) {
        let change = RootPlanningChange(rootPath: rootPath, occupancyRevision: occupancyRevision)
        // Emit-side observability (plan 0064 Stage 4): a silence on the coordinator
        // side can now be attributed to "no events emitted" vs "events not received"
        // by matching this line against the coordinator's receive/refresh lines.
        let listenerCount = planningChangeContinuations.count
        OtosLog.catalog.noticeOperation(
            "catalog.planningChange",
            phase: "emit",
            fields: [
                "rootPath": rootPath.rawValue,
                "occupancyRevision": "\(occupancyRevision)",
                "listeners": "\(listenerCount)",
            ]
        )
        for continuation in planningChangeContinuations.values {
            continuation.yield(change)
        }
    }

    private func removeChangeContinuation(_ id: UUID) {
        changeContinuations.removeValue(forKey: id)
    }

    private func removePlanningChangeContinuation(_ id: UUID) {
        planningChangeContinuations.removeValue(forKey: id)
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
        filesystemWatcher.start(watchedRootPaths) { [weak self] event in
            // FSEvents reaches us through a synchronous C callback. The Store
            // actor is still the owner of debounce and scan scheduling, so the
            // callback performs only this actor hop.
            Task {
                await self?.handleFilesystemEvent(event)
            }
        }
    }

    private var watchedRootPaths: [LibraryRootPath] {
        roots.watchedRootPaths
    }

    private func handleFilesystemEvent(_ event: FilesystemEvent) {
        let signpost = OtosSignpost.catalog.beginInterval("FilesystemEventDebounce")
        defer {
            OtosSignpost.catalog.endInterval("FilesystemEventDebounce", signpost)
        }

        guard let root = CatalogPath.owningRoot(for: event.path, among: roots.keys) else {
            recordFilesystemEventDrop(path: event.path, root: nil, reason: "outsideRoots")
            return
        }

        let hasActiveScan = scanLeases.hasActiveFilesystemScan(for: root)
        // Arm watching as soon as the root is known and available, and never
        // drop events while a scan lease owns the root (plan 0055 §6.2).
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
        if reorganizationLeases[root] != nil {
            markReorganizationLeaseDirty(for: root)
            bumpPlanRevision(for: root)
            filesystemEventBatches.removeValue(forKey: root)
            OtosLog.catalog.debug(
                "Filesystem reconcile deferred under reorganization lease path=\(root.rawValue, privacy: .public)"
            )
            return
        }
        filesystemEventBatches[root, default: []].append(event)
        debounceFilesystemReconcile(for: root)
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

    private func debounceFilesystemReconcile(for root: LibraryRootPath) {
        filesystemDebounceTasks[root]?.cancel()
        let debounce = filesystemEventDebounce
        let sleep = filesystemEventSleep
        filesystemDebounceTasks[root] = Task { [root, sleep] in
            await sleep(debounce)
            guard !Task.isCancelled else {
                return
            }
            await processFilesystemEventBatch(for: root)
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

    private func recordWALDiagnostics(reason: String) async {
        guard databaseFileURL != nil else {
            return
        }
        let walBytes = walFileSizeBytes() ?? -1
        OtosLog.catalog.notice(
            "op=catalog.database.wal phase=sample reason=\(reason, privacy: .public) walBytes=\(walBytes, privacy: .public)"
        )
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
        let now = Date()
        var keptEvents: [FilesystemEvent] = []
        keptEvents.reserveCapacity(pendingEvents.count)
        var suppressedCount = 0
        var stagingSuppressedCount = 0
        for event in pendingEvents {
            let flags = FilesystemEventFlags(event: event)
            let relativePath = CatalogPath.relativePath(
                rootPath: root,
                fileURL: URL(fileURLWithPath: event.path)
            )
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
            // fire reconcile/replan churn (plan 0064 Stage 2).
            if let relativePath, relativePath.rawValue.hasSuffix(MediaImportExecutor.importStagingSuffix) {
                stagingSuppressedCount += 1
                continue
            }
            keptEvents.append(event)
        }
        if suppressedCount > 0 {
            OtosLog.catalog.notice(
                // swiftlint:disable:next line_length
                "op=catalog.materializationEvent phase=suppress rootPath=\(root.rawValue, privacy: .public) count=\(suppressedCount, privacy: .public)"
            )
        }
        if stagingSuppressedCount > 0 {
            OtosLog.catalog.notice(
                // swiftlint:disable:next line_length
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
                // swiftlint:disable:next line_length
                "op=catalog.filesystemEvent phase=classify rootPath=\(root.rawValue, privacy: .public) eventCount=\(keptEvents.count, privacy: .public) file=\(fileCount, privacy: .public) subtree=\(subtreeCount, privacy: .public) root=\(rootCount, privacy: .public) suppressed=\(suppressedCount, privacy: .public)"
            )
            await drainDirtyReconcile(for: root)
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
            guard reorganizationLeases[root] == nil else {
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
            if needsLease, scanLeases.activeScan != nil || currentScanTask != nil {
                return
            }
            let dirt = accumulator.take()
            filesystemDirty[root] = accumulator

            if dirt.isRootDirty {
                OtosLog.catalog.info("Filesystem rescan scheduled path=\(root.rawValue, privacy: .public)")
                OtosLog.catalog.notice(
                    // swiftlint:disable:next line_length
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

    private func reconcileFileDirt(
        root: LibraryRootPath,
        files: [MediaRelativePath: SingleFileReconcileOperation]
    ) async {
        guard let rootRowID = roots[root]?.rowID else {
            return
        }
        let started = Date()
        var catalogChanged = false
        var changedCount = 0
        for path in files.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            let action = files[path] ?? .upsert
            let absolute = root.url.appendingPathComponent(path.rawValue, isDirectory: false)
                .path(percentEncoded: false)
            let changed: Bool = switch action {
            case .deleteIfMissing:
                await reconcileDeletedFile(at: absolute, root: root, rootRowID: rootRowID)
            case .upsert:
                await reconcileUpsertedFile(at: absolute, root: root, rootRowID: rootRowID)
            }
            if changed {
                catalogChanged = true
                changedCount += 1
            }
        }
        if catalogChanged {
            bumpOccupancyRevision(for: root)
            notifyCatalogChanged()
        }
        let totalMs = Int(Date().timeIntervalSince(started) * 1000)
        OtosLog.catalog.notice(
            // swiftlint:disable:next line_length
            "op=catalog.reconcile phase=finish mode=file rootPath=\(root.rawValue, privacy: .public) scopeCount=\(files.count, privacy: .public) changed=\(changedCount, privacy: .public) totalMs=\(totalMs, privacy: .public)"
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
        scanLeases.beginFilesystemScan(scan)
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

        currentScanTask = Task { [scanner, scanCadence] in
            do {
                var totalObserved = 0
                var totalDeleted = 0
                var catalogChanged = false
                for subtree in dirt.subtrees.sorted(by: { $0.rawValue < $1.rawValue }) {
                    try Task.checkCancellation()
                    guard self.owns(scan) else {
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
                guard self.owns(scan) else {
                    return
                }
                if !dirt.files.isEmpty {
                    await self.reconcileFileDirt(root: root, files: dirt.files)
                }
                if catalogChanged {
                    self.bumpOccupancyRevision(for: root)
                } else {
                    self.bumpPlanRevision(for: root)
                }
                OtosLog.catalog.notice(
                    // swiftlint:disable:next line_length
                    "op=catalog.reconcile phase=finish mode=subtree rootPath=\(root.rawValue, privacy: .public) observed=\(totalObserved, privacy: .public) deleted=\(totalDeleted, privacy: .public)"
                )
                self.scopedReconcileFinished(scan: scan)
            } catch is CancellationError {
                self.restoreScopedDirt(root: root, dirt: dirt)
                await self.scanCancelled(scan: scan)
            } catch {
                // Incomplete enumeration must not drop taken scopes: escalate to
                // root so the next lease drains conservatively.
                self.restoreScopedDirt(root: root, dirt: dirt, escalateToRoot: true)
                await self.scanFailed(scan: scan, error: error)
            }
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
        integrityScanTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: CatalogStore.integrityScanPollInterval)
                guard !Task.isCancelled else {
                    return
                }
                await self?.scheduleOverdueIntegrityScans()
            }
        }
    }

    private func scheduleOverdueIntegrityScans() {
        let now = Date()
        let interval = DiagnosticsTiming.seconds(Self.integrityScanInterval)
        for path in roots.keys {
            guard roots[path]?.root.kind == .library else {
                continue
            }
            guard rootIsAvailable(path), filesystemWatchingArmed.contains(path) else {
                continue
            }
            guard reorganizationLeases[path] == nil else {
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
            let last = lastSuccessfulFullRootScanAt[path]
            let age = last.map { now.timeIntervalSince($0) } ?? interval
            guard age >= interval else {
                continue
            }
            filesystemDirty[path, default: FilesystemDirtyAccumulator()].insertRoot()
            OtosLog.catalog.notice(
                // swiftlint:disable:next line_length
                "op=catalog.integrityScan phase=schedule rootPath=\(path.rawValue, privacy: .public) successfulScanAgeSec=\(Int(age), privacy: .public)"
            )
            Task { await self.drainDirtyReconcile(for: path) }
        }
    }

    @discardableResult
    private func reconcileFilesystemEvent(_ event: FilesystemEvent, root: LibraryRootPath) async -> Bool {
        let flags = FilesystemEventFlags(event: event)
        guard let action = flags.singleFileAction,
              let rootRowID = roots[root]?.rowID
        else {
            return false
        }

        switch action {
        case .deleteIfMissing:
            return await reconcileDeletedFile(at: event.path, root: root, rootRowID: rootRowID)
        case .upsert:
            return await reconcileUpsertedFile(at: event.path, root: root, rootRowID: rootRowID)
        }
    }

    private func reconcileDeletedFile(
        at absolutePath: String,
        root: LibraryRootPath,
        rootRowID: Int64
    ) async -> Bool {
        let fileURL = URL(fileURLWithPath: absolutePath, isDirectory: false)
        if FileManager.default.fileExists(atPath: absolutePath) {
            return await reconcileUpsertedFile(at: absolutePath, root: root, rootRowID: rootRowID)
        }
        guard let relativePath = CatalogPath.relativePath(rootPath: root, fileURL: fileURL) else {
            return false
        }

        return await deleteCatalogedPath(relativePath: relativePath, rootRowID: rootRowID)
    }

    private func reconcileUpsertedFile(
        at absolutePath: String,
        root: LibraryRootPath,
        rootRowID: Int64
    ) async -> Bool {
        let fileURL = URL(fileURLWithPath: absolutePath, isDirectory: false)
        guard FileManager.default.fileExists(atPath: absolutePath) else {
            return false
        }
        let observed: CatalogScannedFileReader.ObservedItem?
        do {
            observed = try CatalogScannedFileReader.observedItem(fileURL: fileURL, rootPath: root)
        } catch {
            return false
        }
        guard let observed else {
            guard let relativePath = CatalogPath.relativePath(rootPath: root, fileURL: fileURL) else {
                return false
            }
            return await deleteCatalogedPath(relativePath: relativePath, rootRowID: rootRowID)
        }

        let dbQueue: (any DatabaseWriter)?
        do {
            dbQueue = try database()
        } catch {
            return false
        }
        guard let dbQueue else {
            return false
        }

        do {
            return try await dbQueue.write { db in
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
                        db: db
                    )
                    let pairingChanged = try Self.repairCompanionsInDirectory(
                        of: scannedFile.relativePath,
                        libraryRootID: rootRowID,
                        db: db
                    )
                    return mediaChanged || pairingChanged
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
                        primaries: primaries
                    )
                    var companionChanged = false
                    for item in paired {
                        if try Self.upsertCompanion(item, libraryRootID: rootRowID, db: db) {
                            companionChanged = true
                        }
                    }
                    return mediaDeleted || companionChanged
                }
            }
        } catch {
            return false
        }
    }

    private func deleteCatalogedPath(relativePath: MediaRelativePath, rootRowID: Int64) async -> Bool {
        guard let dbQueue = try? database() else {
            return false
        }

        let deletionTarget: CatalogedFileDeletionTarget?
        do {
            deletionTarget = try await dbQueue.read { db in
                try Self.catalogedFileDeletionTarget(relativePath: relativePath, rootRowID: rootRowID, db: db)
            }
            let deleted = try await dbQueue.write { db -> Bool in
                var changed = false
                if try Self.deleteAssetRow(rootRowID: rootRowID, relativePath: relativePath, db: db) {
                    changed = true
                }
                if try Self.deleteCompanionRow(rootRowID: rootRowID, relativePath: relativePath, db: db) {
                    changed = true
                }
                if try Self.repairCompanionsInDirectory(
                    of: relativePath,
                    libraryRootID: rootRowID,
                    db: db
                ) {
                    changed = true
                }
                return changed
            }
            guard deleted else {
                return false
            }
        } catch {
            return false
        }

        if let thumbnailPath = deletionTarget?.thumbnailPath, let thumbnailDirectory {
            ThumbnailStore.delete(thumbnailPath, in: thumbnailDirectory)
        }
        return true
    }

    private func recordFilesystemEventDrop(root: LibraryRootPath, reason: String) async {
        OtosLog.catalog.debug(
            "Filesystem rescan dropped path=\(root.rawValue, privacy: .public) reason=\(reason, privacy: .public)"
        )
        OtosLog.catalog.notice(
            "op=catalog.filesystemEvent phase=drop rootPath=\(root.rawValue, privacy: .public) reason=\(reason, privacy: .public)"
        )
    }

    private func cancelFilesystemDebounce(for root: LibraryRootPath) {
        filesystemDebounceTasks[root]?.cancel()
        filesystemDebounceTasks.removeValue(forKey: root)
        filesystemEventBatches.removeValue(forKey: root)
        filesystemDirty.removeValue(forKey: root)
    }

    private func cancelAllFilesystemDebounces() {
        for task in filesystemDebounceTasks.values {
            task.cancel()
        }
        filesystemDebounceTasks.removeAll()
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
            // swiftlint:disable:next line_length
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

    func abandonImportOperation(key: ActiveFileOperationKey) async throws {
        try importJournalFailure?(.abandon)
        let dbWriter = try database()
        try Self.writeWithJournalDurability(dbWriter) { db in
            try Self.deleteActiveFileOperation(key: key, db: db)
        }
    }

    func completeImportOperation(key: ActiveFileOperationKey) async throws {
        try importJournalFailure?(.complete)
        let dbWriter = try database()
        try Self.writeWithJournalDurability(dbWriter) { db in
            try Self.deleteActiveFileOperation(key: key, db: db)
        }
    }

    @discardableResult
    // swiftlint:disable:next function_body_length
    func settleImportedAsset(
        operation: ActiveFileOperation,
        byteSize: Int64,
        contentModifiedAt: Date,
        batch: ImportBatchID,
        companions: [MediaCompanion]
    ) async throws -> ImportOverlayReuseResult {
        guard let rootRowID = roots[operation.destinationRootPath]?.rowID else {
            throw CatalogStoreError.catalogUnavailable
        }
        recordIndependentNamespaceMutation(
            root: operation.destinationRootPath,
            scope: .file(operation.destinationRelativePath),
            fileAction: .upsert
        )
        let dbWriter = try database()
        var reusableOverlay: ReusableEnrichmentOverlay?
        var stagedThumbnail: GeneratedThumbnail?
        var reuseResult = ImportOverlayReuseResult.notReused
        if let sourceRootID = roots[operation.sourceRootPath]?.rowID {
            if operation.sourceKind == .removableVolume {
                // ADR 0018/plan 0062: a `.removableVolume` source is never hashed in
                // place, so it can have no source digest to validate a reuse against.
                // Short-circuit to a typed miss without fetching the overlay or
                // attempting the digest comparison; the destination is enriched
                // normally after import.
                reuseResult = ImportOverlayReuseResult(
                    metadataCloned: false,
                    thumbnailCopied: false,
                    miss: .removableSourceNotHashed
                )
            } else if let sourceOverlay = try await dbWriter.read({ db in
                try Self.fetchReusableEnrichmentOverlay(
                    sourceRootID: sourceRootID,
                    sourceRelativePath: operation.sourceRelativePath,
                    db: db
                )
            }) {
                let sourceMTime = MediaAsset.mtimeSeconds(operation.sourceModifiedAt)
                let sourceFactsCurrent = sourceOverlay.sourceByteSize != nil
                    && sourceOverlay.sourceMTimeSeconds != nil
                    && sourceOverlay.sourceByteSize == operation.sourceByteSize
                    && sourceOverlay.sourceMTimeSeconds == sourceMTime
                let hashMatches = operation.contentHash != nil
                    && sourceOverlay.contentHash == operation.contentHash
                    && sourceOverlay.contentHashSourceSize != nil
                    && sourceOverlay.contentHashSourceMTimeSeconds != nil
                    && sourceOverlay.contentHashSourceSize == sourceOverlay.sourceByteSize
                    && sourceOverlay.contentHashSourceMTimeSeconds == sourceOverlay.sourceMTimeSeconds
                if sourceFactsCurrent, hashMatches {
                    if let sourceThumbnail = sourceOverlay.thumbnailPath {
                        if let thumbnailDirectory {
                            do {
                                stagedThumbnail = try ThumbnailStore.stageCopy(
                                    sourceRelativeName: sourceThumbnail,
                                    destinationID: MediaAssetID(
                                        libraryRootPath: operation.destinationRootPath,
                                        relativePath: operation.destinationRelativePath
                                    ),
                                    in: thumbnailDirectory
                                )
                                reusableOverlay = sourceOverlay
                            } catch {
                                reuseResult = ImportOverlayReuseResult(
                                    metadataCloned: false,
                                    thumbnailCopied: false,
                                    miss: .thumbnailCopyFailed
                                )
                            }
                        } else {
                            reuseResult = ImportOverlayReuseResult(
                                metadataCloned: false,
                                thumbnailCopied: false,
                                miss: .missingThumbnail
                            )
                            reusableOverlay = nil
                            stagedThumbnail = nil
                            // In-memory catalogs intentionally have no reusable files.
                        }
                    } else {
                        reusableOverlay = sourceOverlay
                    }
                } else if sourceFactsCurrent {
                    reuseResult = ImportOverlayReuseResult(
                        metadataCloned: false,
                        thumbnailCopied: false,
                        miss: .missingOrMismatchedHash
                    )
                } else {
                    reuseResult = ImportOverlayReuseResult(
                        metadataCloned: false,
                        thumbnailCopied: false,
                        miss: .staleSourceOverlay
                    )
                }
            } else {
                reuseResult = .notReused
            }
        } else {
            reuseResult = ImportOverlayReuseResult(
                metadataCloned: false,
                thumbnailCopied: false,
                miss: .detachedSource
            )
        }
        var overlayToWrite = reusableOverlay
        var thumbnailPathToWrite: String?
        try Self.writeWithJournalDurability(dbWriter) { db in
            if let staged = stagedThumbnail, let thumbnailDirectory {
                do {
                    thumbnailPathToWrite = try ThumbnailStore.promote(staged, in: thumbnailDirectory)
                    reuseResult = ImportOverlayReuseResult(
                        metadataCloned: overlayToWrite != nil,
                        thumbnailCopied: overlayToWrite?.thumbnailPath != nil,
                        miss: nil
                    )
                } catch {
                    ThumbnailStore.discard(staged, in: thumbnailDirectory)
                    overlayToWrite = nil
                    stagedThumbnail = nil
                    reuseResult = ImportOverlayReuseResult(
                        metadataCloned: false,
                        thumbnailCopied: false,
                        miss: .thumbnailCopyFailed
                    )
                }
            } else if overlayToWrite != nil {
                reuseResult = ImportOverlayReuseResult(metadataCloned: true, thumbnailCopied: false, miss: nil)
            }
            try Self.settleImportedAsset(
                operation: operation,
                destinationRootID: rootRowID,
                destinationRootPath: operation.destinationRootPath,
                relativePath: operation.destinationRelativePath,
                byteSize: byteSize,
                contentModifiedAt: contentModifiedAt,
                batch: batch,
                companions: companions,
                reusableOverlay: overlayToWrite,
                destinationThumbnailPath: thumbnailPathToWrite,
                db: db
            )
            if operation.deleteSourceRequested {
                var pendingDeletion = operation
                pendingDeletion.phase = .sourceDeletionPending
                pendingDeletion.stagingPath = nil
                pendingDeletion.updatedAt = Date()
                try Self.updateActiveFileOperation(pendingDeletion, db: db)
            } else {
                try Self.deleteActiveFileOperation(key: operation.operationKey, db: db)
            }
        }
        _ = bumpOccupancyRevision(for: operation.destinationRootPath)
        notifyCatalogChanged()
        Task { await self.drainDirtyReconcile(for: operation.destinationRootPath) }
        OtosLog.catalog.notice(
            // swiftlint:disable:next line_length
            "op=mediaOperation.settle phase=finish destination=\(operation.destinationRelativePath.rawValue, privacy: .public) batch=\(batch.unixMilliseconds, privacy: .public)"
        )
        if reuseResult.metadataCloned {
            OtosLog.catalog.notice(
                // swiftlint:disable:next line_length
                "op=mediaOperation.settle phase=overlayReuse destination=\(operation.destinationRelativePath.rawValue, privacy: .public) overlaySource=reusedImport thumbnailCopied=\(reuseResult.thumbnailCopied, privacy: .public)"
            )
        }
        return reuseResult
    }

    func recordForeignOccupant(root: LibraryRootPath, relativePath: MediaRelativePath) async {
        recordIndependentNamespaceMutation(root: root, scope: .file(relativePath), fileAction: .upsert)
        OtosLog.catalog.notice(
            // swiftlint:disable:next line_length
            "op=mediaOperation.publish phase=foreignOccupant rootPath=\(root.rawValue, privacy: .public) relative=\(relativePath.rawValue, privacy: .public)"
        )
        _ = bumpOccupancyRevision(for: root)
        Task { await self.drainDirtyReconcile(for: root) }
    }

    // MARK: - Reorganization lease and journal settlement

    func acquireReorganizationLease(for rootPath: LibraryRootPath) -> ReorganizationLease? {
        guard roots[rootPath] != nil else { return nil }
        if let existing = reorganizationLeases[rootPath] {
            return existing
        }
        nextReorganizationLeaseGeneration &+= 1
        let lease = ReorganizationLease(
            libraryRootPath: rootPath,
            generation: nextReorganizationLeaseGeneration,
            markedDirtyByExternalEvents: false
        )
        reorganizationLeases[rootPath] = lease
        OtosLog.catalog.notice(
            // swiftlint:disable:next line_length
            "op=reorganization.lease phase=acquire rootPath=\(rootPath.rawValue, privacy: .public) generation=\(lease.generation, privacy: .public)"
        )
        return lease
    }

    private func markReorganizationLeaseDirty(for rootPath: LibraryRootPath) {
        guard var lease = reorganizationLeases[rootPath] else { return }
        lease.markedDirtyByExternalEvents = true
        reorganizationLeases[rootPath] = lease
    }

    @discardableResult
    func releaseReorganizationLease(_ lease: ReorganizationLease) -> Bool {
        guard reorganizationLeases[lease.libraryRootPath]?.generation == lease.generation else {
            return false
        }
        let dirty = reorganizationLeases[lease.libraryRootPath]?.markedDirtyByExternalEvents == true
        reorganizationLeases.removeValue(forKey: lease.libraryRootPath)
        OtosLog.catalog.notice(
            // swiftlint:disable:next line_length
            "op=reorganization.lease phase=release rootPath=\(lease.libraryRootPath.rawValue, privacy: .public) dirty=\(dirty, privacy: .public)"
        )
        if dirty || scanLeases.takeRescanAfterCurrentScan(lease.libraryRootPath) {
            enqueueScans([lease.libraryRootPath])
        } else {
            startNextScanIfNeeded()
        }
        return true
    }

    func hasReorganizationLease(for rootPath: LibraryRootPath) -> Bool {
        reorganizationLeases[rootPath] != nil
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

    func settleReorganizationComponent(
        key: ReorganizationComponentKey,
        remaps: [CatalogIdentityRemap]
    ) async throws -> CatalogIdentityRemapBatch {
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
                libraryRootPath: currentComponent.libraryRootPath,
                component: currentComponent,
                remaps: remaps,
                db: db
            )
        }
        // Relocation moves media on disk: advance occupancy so import planning
        // against this root replans. Reorg's own `rootRevision` stays the general
        // planRevision, which the occupancy bump also advances.
        bumpOccupancyRevision(for: settled.libraryRootPath)
        Task { await self.drainDirtyReconcile(for: settled.libraryRootPath) }
        let revision = planRevision(for: settled.libraryRootPath) ?? 0
        notifyCatalogChanged()
        OtosLog.catalog.notice(
            // swiftlint:disable:next line_length
            "op=reorganization.settle phase=finish rootPath=\(settled.libraryRootPath.rawValue, privacy: .public) remapCount=\(settled.remaps.count, privacy: .public)"
        )
        return CatalogIdentityRemapBatch(
            libraryRootPath: settled.libraryRootPath,
            remaps: settled.remaps,
            rootRevision: revision
        )
    }

    func discardCommittedReorganizationComponent(_ key: ReorganizationComponentKey) async throws {
        let dbWriter = try database()
        try Self.writeWithJournalDurability(dbWriter) { db in
            guard try Self.fetchActiveReorganizationComponent(key: key, db: db)?.phase == .catalogCommitted else {
                throw CatalogStoreError.catalogUnavailable
            }
            try Self.deleteActiveReorganizationComponent(key: key, db: db)
        }
    }
}
