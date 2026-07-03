import Foundation
import GRDB
import OSLog

// swiftlint:disable file_length

/// Store notifications remain cheap invalidation signals. Most changes carry no
/// payload; root removal carries its typed path because a remove followed by a
/// same-path add can otherwise coalesce into a queried state where Projection cannot
/// observe that the selected library instance disappeared.
nonisolated enum CatalogStoreChange: Equatable {
    case catalogChanged
    case assetsDetailChanged
    case libraryRemoved(LibraryRootPath)
}

/// Catalog Store guide
///
/// This actor is the only runtime owner of catalog truth. SQLite provides durable
/// overlay storage and the per-asset working set; the actor keeps only root identity,
/// root availability, scan lifecycle, and notification state resident. Filesystem scans
/// write SQLite and notify consumers only when those writes actually inserted, updated,
/// or deleted rows. While the app runs, `CatalogFilesystemWatcher` forwards macOS
/// events to per-root debounced reconciliation: safe single-file events update one
/// row and unsafe events fall back to the full scan pipeline. Views never access
/// persistence directly.
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
/// make this actor reentrant, so active scans carry the root path and private root-row
/// instance they own and revalidate both after each database await. Completed scans
/// reconcile missing paths; failed, cancelled, or stale scans preserve prior rows because
/// incomplete observation cannot prove removal. A single regular-file remove event
/// proves deletion only after Store checks that exact path is absent under an armed
/// available root.
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
    }

    struct StoredAsset {
        let libraryRootID: Int64
        let relativePath: MediaRelativePath
        let name: String?
        let contentTypeIdentifier: String?
        let byteSize: Int64?
        let createdAt: Date?
        let contentModifiedAt: Date?
        var thumbnailPath: String?
        var bestCaptureDate: Date?
        var bestKind: MediaKind?
        var bestFormat: MediaFormatToken?
        var enrichedSourceSize: Int64?
        var enrichedSourceMTimeSeconds: Int?
    }

    struct ThumbnailPathMigration {
        let oldRelativeName: String
        let newRelativeName: String
    }

    /// This value is a process-local ownership lease, not scan identity. The
    /// normalized path identifies the domain root, while the private row ID
    /// distinguishes a removed root from a later root added at the same path.
    private struct ActiveScan: Equatable {
        let rootPath: LibraryRootPath
        let rootRowID: Int64
    }

    private struct EnrichmentBatchWriteOutcome {
        var appliedCount = 0
        var promotionFailed = false
        var discardedThumbnails: [GeneratedThumbnail] = []

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
    }

    private let location: Location
    private let scanner: CatalogScanner
    private let filesystemWatcher: CatalogFilesystemWatcher
    private let scanCadence: Duration
    private let filesystemEventDebounce: Duration
    private let filesystemEventSleep: @Sendable (Duration) async -> Void
    private let diagnostics: CatalogDiagnostics?
    private let initialLoadDidRead: (@Sendable () async -> Void)?
    private var dbWriter: (any DatabaseWriter)?
    private var started = false
    private var startupTask: Task<Void, Error>?
    private var unrequestedLoadedRootPaths: [LibraryRootPath] = []
    private var rootsByPath: [LibraryRootPath: LibraryRoot] = [:]
    private var rootRowIDsByPath: [LibraryRootPath: Int64] = [:]
    private var rootPathsByRowID: [Int64: LibraryRootPath] = [:]
    private var availabilityByRootPath: [LibraryRootPath: LibraryAvailability] = [:]
    private var changeContinuations: [UUID: AsyncStream<CatalogStoreChange>.Continuation] = [:]
    private var pendingScanPaths: [LibraryRootPath] = []
    private var activeScan: ActiveScan?
    private var currentScanTask: Task<Void, Never>?
    private var filesystemWatchingStarted = false
    private var filesystemWatchingArmed: Set<LibraryRootPath> = []
    private var rescanAfterCurrentScan: Set<LibraryRootPath> = []
    private var filesystemDebounceTasks: [LibraryRootPath: Task<Void, Never>] = [:]
    private var filesystemEventBatches: [LibraryRootPath: [FilesystemEvent]] = [:]

    private static let enrichmentClaimLease: TimeInterval = 300

    init(
        location: Location = .application(bundleIdentifier: Bundle.main.bundleIdentifier ?? "net.melisma.Otos"),
        scanner: CatalogScanner = .live,
        filesystemWatcher: CatalogFilesystemWatcher = .live,
        scanCadence: Duration = .seconds(1),
        filesystemEventDebounce: Duration = .seconds(1),
        filesystemEventSleep: @escaping @Sendable (Duration) async -> Void = { duration in
            try? await Task.sleep(for: duration)
        },
        diagnostics: CatalogDiagnostics? = .shared,
        initialLoadDidRead: (@Sendable () async -> Void)? = nil
    ) {
        self.location = location
        self.scanner = scanner
        self.filesystemWatcher = filesystemWatcher
        self.scanCadence = scanCadence
        self.filesystemEventDebounce = filesystemEventDebounce
        self.filesystemEventSleep = filesystemEventSleep
        self.diagnostics = diagnostics
        self.initialLoadDidRead = initialLoadDidRead
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

    func currentLibraries() -> [CatalogLibraryState] {
        rootsByPath.values.map { root in
            CatalogLibraryState(
                root: root,
                availability: availabilityByRootPath[root.path] ?? .unknown,
                activity: root.path == activeScan?.rootPath ? .scanning : .idle
            )
        }
    }

    func orderedAssetIDs(
        for descriptor: CatalogQueryDescriptor,
        availableLibraryPaths: Set<LibraryRootPath>
    ) async throws -> [MediaAssetID] {
        let rootIDs = rootIDsForQuery(selection: descriptor.scope, availableLibraryPaths: availableLibraryPaths)
        guard !rootIDs.isEmpty else {
            return []
        }

        let queryStart = Date()
        let signpost = OtosSignpost.persistence.beginInterval("CatalogStoreOrderedAssetIDQuery")
        let dbWriter = try database()
        let rows = try await dbWriter.read { db in
            try Self.fetchOrderedAssetIDRows(descriptor: descriptor, rootIDs: rootIDs, db: db)
        }
        OtosSignpost.persistence.endInterval("CatalogStoreOrderedAssetIDQuery", signpost)

        let validRootPathsByRowID = rootPathsByRowID.filter { rowID, path in
            rootIDs.contains(rowID) && availableLibraryPaths.contains(path)
        }
        let ids = rows.compactMap { rootRowID, relativePath -> MediaAssetID? in
            guard let rootPath = validRootPathsByRowID[rootRowID] else {
                return nil
            }
            return MediaAssetID(libraryRootPath: rootPath, relativePath: relativePath)
        }
        let queryMs = DiagnosticsTiming.milliseconds(since: queryStart)
        OtosLog.catalog.debug(
            """
            Catalog ordered asset IDs queried descriptor=\(descriptor.diagnosticDescription, privacy: .public) \
            roots=\(rootIDs.count, privacy: .public) count=\(ids.count, privacy: .public) \
            queryMs=\(queryMs, privacy: .public)
            """
        )
        await diagnostics?.record(
            operation: "catalog.store.query.order",
            phase: "finish",
            fields: [
                "descriptor": descriptor.diagnosticDescription,
                "rootCount": "\(rootIDs.count)",
                "count": "\(ids.count)",
                "queryMs": "\(queryMs)",
            ]
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

    func catalogedAssetCount(for selection: SidebarSelection) async throws -> Int {
        let rootIDs = rootIDsForQuery(selection: selection, availableLibraryPaths: Set(rootsByPath.keys))
        guard !rootIDs.isEmpty else {
            return 0
        }
        let dbWriter = try database()
        return try await dbWriter.read { db in
            try Self.countAssets(rootIDs: rootIDs, db: db)
        }
    }

    func visibleAssetCount(
        for selection: SidebarSelection,
        availableLibraryPaths: Set<LibraryRootPath>
    ) async throws -> Int {
        let rootIDs = rootIDsForQuery(selection: selection, availableLibraryPaths: availableLibraryPaths)
        guard !rootIDs.isEmpty else {
            return 0
        }
        let dbWriter = try database()
        return try await dbWriter.read { db in
            try Self.countAssets(rootIDs: rootIDs, db: db)
        }
    }

    func filterOptions(
        for selection: SidebarSelection,
        availableLibraryPaths: Set<LibraryRootPath>
    ) async throws -> CatalogFilterOptions {
        let rootIDs = rootIDsForQuery(selection: selection, availableLibraryPaths: availableLibraryPaths)
        guard !rootIDs.isEmpty else {
            return .empty
        }
        let dbWriter = try database()
        return try await dbWriter.read { db in
            try Self.filterOptions(rootIDs: rootIDs, db: db)
        }
    }

    func mediaAssets(for ids: [MediaAssetID]) async throws -> [MediaAssetID: MediaAsset] {
        guard !ids.isEmpty else {
            return [:]
        }

        let queryStart = Date()
        let signpost = OtosSignpost.persistence.beginInterval("CatalogStoreTileDetailQuery")
        let rootIDsBeforeRead = rootRowIDsByPath
        let dbWriter = try database()
        let storedAssets = try await dbWriter.read { db in
            try Self.fetchStoredAssets(ids: ids, rootIDsByPath: rootIDsBeforeRead, db: db)
        }
        OtosSignpost.persistence.endInterval("CatalogStoreTileDetailQuery", signpost)

        var assetsByID: [MediaAssetID: MediaAsset] = [:]
        assetsByID.reserveCapacity(storedAssets.count)
        for storedAsset in storedAssets {
            guard let rootPath = rootPathsByRowID[storedAsset.libraryRootID],
                  rootRowIDsByPath[rootPath] == storedAsset.libraryRootID
            else {
                continue
            }
            let asset = mediaAsset(from: storedAsset, rootPath: rootPath)
            assetsByID[asset.id] = asset
        }

        let queryMs = DiagnosticsTiming.milliseconds(since: queryStart)
        if queryMs > Self.slowQueryDiagnosticThresholdMs {
            OtosLog.catalog.debug(
                """
                Catalog slow tile details query requested=\(ids.count, privacy: .public) \
                returned=\(assetsByID.count, privacy: .public) queryMs=\(queryMs, privacy: .public)
                """
            )
            await diagnostics?.record(
                operation: "catalog.store.query.tileDetail",
                phase: "finish",
                fields: [
                    "requested": "\(ids.count)",
                    "returned": "\(assetsByID.count)",
                    "queryMs": "\(queryMs)",
                    "thresholdMs": "\(Self.slowQueryDiagnosticThresholdMs)",
                ]
            )
        }
        return assetsByID
    }

    /// On-demand metadata read retained for the future tile/inspector metadata surface
    /// owned by ADR 0009. It is test-exercised today but stays out of the hot grid path.
    func metadata(for id: MediaAssetID) async throws -> AssetMetadata? {
        guard let rootID = rootRowIDsByPath[id.libraryRootPath] else {
            return nil
        }

        let queryStart = Date()
        let signpost = OtosSignpost.persistence.beginInterval("CatalogStoreMetadataQuery")
        let dbWriter = try database()
        let metadata = try await dbWriter.read { db in
            try Self.metadataExtra(libraryRootID: rootID, relativePath: id.relativePath, db: db)
        }
        OtosSignpost.persistence.endInterval("CatalogStoreMetadataQuery", signpost)

        guard rootRowIDsByPath[id.libraryRootPath] == rootID else {
            return nil
        }
        let queryMs = DiagnosticsTiming.milliseconds(since: queryStart)
        OtosLog.catalog.debug(
            """
            Catalog metadata queried returned=\(metadata == nil ? 0 : 1, privacy: .public) \
            queryMs=\(queryMs, privacy: .public)
            """
        )
        await diagnostics?.record(
            operation: "catalog.store.query.metadata",
            phase: "finish",
            fields: [
                "returned": metadata == nil ? "0" : "1",
                "queryMs": "\(queryMs)",
            ]
        )
        return metadata
    }

    func enrichmentCandidates(
        prioritizing priorityIDs: [MediaAssetID],
        limit: Int
    ) async throws -> [MediaAsset] {
        guard limit > 0 else {
            return []
        }

        let queryStart = Date()
        let signpost = OtosSignpost.persistence.beginInterval("CatalogStoreEnrichmentCandidateQuery")
        defer {
            OtosSignpost.persistence.endInterval("CatalogStoreEnrichmentCandidateQuery", signpost)
        }

        var candidates: [MediaAsset] = []
        candidates.reserveCapacity(limit)
        var claimedIDs = Set<MediaAssetID>()
        let uniquePriorityIDs = unclaimedPriorityIDs(priorityIDs, claimedIDs: &claimedIDs)

        if !uniquePriorityIDs.isEmpty {
            try await candidates.append(contentsOf: priorityEnrichmentCandidates(
                ids: uniquePriorityIDs,
                limit: limit
            ))
            for asset in candidates {
                claimedIDs.insert(asset.id)
            }
        }

        if candidates.count < limit {
            let remaining = limit - candidates.count
            let queriedCandidates = try await claimedEnrichmentCandidates(limit: remaining)
            for asset in queriedCandidates where candidates.count < limit && !claimedIDs.contains(asset.id) {
                claimedIDs.insert(asset.id)
                candidates.append(asset)
            }
        }

        let queryMs = DiagnosticsTiming.milliseconds(since: queryStart)
        if queryMs > Self.slowQueryDiagnosticThresholdMs {
            OtosLog.catalog.debug(
                """
                Catalog slow enrichment candidates query priority=\(priorityIDs.count, privacy: .public) \
                returned=\(candidates.count, privacy: .public) \
                queryMs=\(queryMs, privacy: .public)
                """
            )
            await diagnostics?.record(
                operation: "catalog.store.query.enrichment",
                phase: "finish",
                fields: [
                    "priority": "\(priorityIDs.count)",
                    "returned": "\(candidates.count)",
                    "queryMs": "\(queryMs)",
                    "thresholdMs": "\(Self.slowQueryDiagnosticThresholdMs)",
                ]
            )
        }
        return candidates
    }

    func releaseEnrichmentClaims(_ ids: [MediaAssetID]) async throws {
        guard !ids.isEmpty else {
            return
        }
        let rootIDsByPathBeforeWrite = rootRowIDsByPath
        let dbWriter = try database()
        try await dbWriter.write { db in
            try Self.releaseEnrichmentClaims(ids: ids, rootIDsByPath: rootIDsByPathBeforeWrite, db: db)
        }
    }

    func refreshEnrichmentClaims(_ ids: [MediaAssetID]) async throws {
        guard !ids.isEmpty else {
            return
        }
        let rootIDsByPathBeforeWrite = rootRowIDsByPath
        let claimedUntil = Date().timeIntervalSince1970 + Self.enrichmentClaimLease
        let dbWriter = try database()
        try await dbWriter.write { db in
            try Self.refreshEnrichmentClaims(
                ids: ids,
                rootIDsByPath: rootIDsByPathBeforeWrite,
                claimedUntil: claimedUntil,
                db: db
            )
        }
    }

    private func unclaimedPriorityIDs(
        _ priorityIDs: [MediaAssetID],
        claimedIDs: inout Set<MediaAssetID>
    ) -> [MediaAssetID] {
        priorityIDs.reduce(into: [MediaAssetID]()) { result, id in
            guard !claimedIDs.contains(id) else {
                return
            }
            claimedIDs.insert(id)
            result.append(id)
        }
    }

    private func priorityEnrichmentCandidates(ids: [MediaAssetID], limit: Int) async throws -> [MediaAsset] {
        let priorityAssetsByID = try await mediaAssets(for: ids)
        let rootIDsByPathBeforeWrite = rootRowIDsByPath
        let claimedUntil = Date().timeIntervalSince1970 + Self.enrichmentClaimLease
        let dbWriter = try database()
        var candidates: [MediaAsset] = []
        candidates.reserveCapacity(limit)
        for id in ids {
            guard candidates.count < limit else {
                break
            }
            guard let asset = priorityAssetsByID[id],
                  asset.needsEnrichment,
                  availabilityByRootPath[asset.libraryRootPath] == .available,
                  let rootID = rootIDsByPathBeforeWrite[asset.libraryRootPath]
            else {
                continue
            }
            let claimed = try await dbWriter.write { db in
                try Self.claimEnrichmentAsset(
                    libraryRootID: rootID,
                    relativePath: asset.relativePath,
                    claimedUntil: claimedUntil,
                    db: db
                )
            }
            guard claimed else {
                continue
            }
            candidates.append(asset)
        }
        return candidates
    }

    private func claimedEnrichmentCandidates(limit: Int) async throws -> [MediaAsset] {
        let availableRootIDs = availableLibraryRootIDs()
        let claimedUntil = Date().timeIntervalSince1970 + Self.enrichmentClaimLease
        let dbWriter = try database()
        let storedAssets = try await dbWriter.write { db in
            try Self.fetchStoredAssetsNeedingEnrichment(
                rootIDs: availableRootIDs,
                claimNotAfter: claimedUntil,
                limit: limit,
                db: db
            )
        }
        return storedAssets.compactMap { storedAsset in
            guard let rootPath = rootPathsByRowID[storedAsset.libraryRootID],
                  rootRowIDsByPath[rootPath] == storedAsset.libraryRootID,
                  availabilityByRootPath[rootPath] == .available
            else {
                return nil
            }
            return mediaAsset(from: storedAsset, rootPath: rootPath)
        }
    }

    func start(scansSavedLibraries: Bool = true) async throws {
        try await loadIfNeeded()
        if scansSavedLibraries {
            requestLoadedRootScansIfNeeded()
        }
        startFilesystemWatchingIfNeeded()
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
            await diagnostics?.record(operation: "catalog.start", phase: "coalesced")
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
        await diagnostics?.record(operation: "catalog.start", phase: "start")
        defer {
            OtosSignpost.persistence.endInterval("CatalogStart", state)
        }

        let dbQueue = try database()
        let loaded = try await dbQueue.read { db in
            try Self.fetchCatalog(db)
        }
        // Tests pause precisely at this real suspension boundary to prove that
        // concurrent mutation callers join this load. Production leaves the
        // hook nil and performs no additional work.
        await initialLoadDidRead?()
        let normalizedRoots = await normalizeLoadedRoots(loaded.roots, dbWriter: dbQueue)
        let applyState = OtosSignpost.catalog.beginInterval("CatalogApplyLoadedCatalog")
        applyLoadedCatalog(roots: normalizedRoots)
        unrequestedLoadedRootPaths = normalizedRoots.map(\.path)
        OtosSignpost.catalog.endInterval("CatalogApplyLoadedCatalog", applyState)
        started = true
        OtosLog.persistence.info(
            """
            Catalog loaded roots=\(normalizedRoots.count, privacy: .public) \
            assets=\(loaded.assetCount, privacy: .public)
            """
        )
        await diagnostics?.record(
            operation: "catalog.start",
            phase: "finish",
            fields: [
                "roots": "\(normalizedRoots.count)",
                "assets": "\(loaded.assetCount)",
            ]
        )
        notifyCatalogChanged()
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
        let rootIDsByPathBeforeWrite = rootRowIDsByPath
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

        await diagnostics?.record(
            operation: "catalog.enrichment.batch",
            phase: "finish",
            fields: [
                "count": "\(writeOutcome.appliedCount)",
                "discardedThumbnails": "\(writeOutcome.discardedThumbnails.count)",
                "promotionFailed": "\(writeOutcome.promotionFailed)",
            ]
        )
        if writeOutcome.appliedCount > 0 {
            notifyCatalogChanged(.assetsDetailChanged)
        }
        await releaseEnrichmentClaimsAfterBatch(resultIDs)
        if writeOutcome.promotionFailed {
            return .writeFailed
        }
        return .applied(count: writeOutcome.appliedCount)
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
        try await dbWriter.write { db in
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
        try writeEnrichmentOverlay(result, libraryRootID: rootID, db: db)
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

    private func recordEnrichmentBatchError(_ error: Error, count: Int) async {
        OtosLog.metadata.error(
            """
            Enrichment batch persist failed count=\(count, privacy: .public) \
            error=\(String(describing: error), privacy: .public)
            """
        )
        await diagnostics?.record(
            operation: "catalog.enrichment.batch",
            phase: "error",
            fields: ["count": "\(count)", "error": String(describing: error)]
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
        await diagnostics?.record(
            operation: "catalog.library.ensure",
            phase: "start",
            fields: ["rootPath": path.rawValue]
        )
        if rootsByPath[path] != nil {
            OtosLog.catalog.info("Smoke library root already saved path=\(path.rawValue, privacy: .public)")
            await diagnostics?.record(
                operation: "catalog.library.ensure",
                phase: "exists",
                fields: ["rootPath": path.rawValue]
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
        guard let root = rootsByPath[path],
              let rootRowID = rootRowIDsByPath[path]
        else {
            return
        }

        unrequestedLoadedRootPaths.removeAll { $0 == path }
        cancelFilesystemDebounce(for: path)
        filesystemWatcher.removeRoot(path)
        rescanAfterCurrentScan.remove(path)
        filesystemWatchingArmed.remove(path)
        if activeScan?.rootPath == path {
            currentScanTask?.cancel()
            currentScanTask = nil
            activeScan = nil
        }
        pendingScanPaths.removeAll { $0 == path }

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
        await diagnostics?.record(
            operation: "catalog.library.remove",
            phase: "start",
            fields: ["rootPath": path.rawValue]
        )
        try await dbQueue.write { db in
            try Self.deleteLibraryRoot(rootRowID: rootRowID, db: db)
        }
        OtosSignpost.persistence.endInterval("CatalogRemoveRoot", state)

        removeRootRuntimeState(path: path, rootRowID: rootRowID)
        if let thumbnailDirectory {
            for name in purgedThumbnails {
                ThumbnailStore.delete(name, in: thumbnailDirectory)
            }
        }
        OtosLog.catalog.info("Library root removed path=\(root.path.rawValue, privacy: .public)")
        await diagnostics?.record(
            operation: "catalog.library.remove",
            phase: "finish",
            fields: ["rootPath": path.rawValue]
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
            guard rootsByPath[path] == root,
                  rootRowIDsByPath[path] == rootRowID
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

    private func removeRootRuntimeState(path: LibraryRootPath, rootRowID: Int64) {
        rootsByPath.removeValue(forKey: path)
        availabilityByRootPath.removeValue(forKey: path)
        rootRowIDsByPath.removeValue(forKey: path)
        rootPathsByRowID.removeValue(forKey: rootRowID)
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
            await diagnostics?.record(
                operation: operation,
                phase: "start",
                fields: ["rootPath": path.rawValue]
            )
        }
        let storedRoot = try await dbQueue.write { db in
            try Self.insertLibraryRoot(path: path, db: db)
        }

        let root = LibraryRoot(path: storedRoot.path)
        rootsByPath[root.path] = root
        availabilityByRootPath[root.path] = .available
        rootRowIDsByPath[root.path] = storedRoot.id
        rootPathsByRowID[storedRoot.id] = root.path
        OtosLog.catalog.info("Library root added path=\(root.path.rawValue, privacy: .public)")
        await diagnostics?.record(
            operation: operation,
            phase: "finish",
            fields: ["rootPath": root.path.rawValue]
        )
        notifyCatalogChanged()
        filesystemWatcher.addRoot(root.path)
        enqueueScans([root.path])
    }

    func shutdown() {
        currentScanTask?.cancel()
        currentScanTask = nil
        activeScan = nil
        pendingScanPaths.removeAll()
        cancelAllFilesystemDebounces()
        filesystemWatcher.stop()
        filesystemWatchingStarted = false
        filesystemWatchingArmed.removeAll()
        rescanAfterCurrentScan.removeAll()
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

        let dbWriter: any DatabaseWriter
        var storageKind = "memory"
        switch location {
        case let .application(bundleIdentifier):
            let databaseURL = try Self.applicationDatabaseURL(bundleIdentifier: bundleIdentifier)
            dbWriter = try DatabasePool(
                path: databaseURL.path(percentEncoded: false),
                configuration: Self.fileBackedDatabaseConfiguration()
            )
            storageKind = "application"
        case let .databaseFile(url):
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            dbWriter = try DatabasePool(
                path: url.path(percentEncoded: false),
                configuration: Self.fileBackedDatabaseConfiguration()
            )
            storageKind = "file"
        case .inMemory:
            dbWriter = try DatabaseQueue()
        }

        let needsCleanReset = try dbWriter.read { db in
            try Self.databaseNeedsCleanSchemaReset(db)
        }
        try Self.migrator.migrate(dbWriter)
        if needsCleanReset, let thumbnailDirectory {
            ThumbnailStore.deleteAll(in: thumbnailDirectory)
            OtosLog.thumbnails.info("Thumbnail directory purged after clean catalog schema reset")
        }
        self.dbWriter = dbWriter
        OtosLog.persistence.info(
            "Catalog database opened storage=\(storageKind, privacy: .public)"
        )
        return dbWriter
    }

    private func applyLoadedCatalog(roots: [StoredRoot]) {
        rootsByPath = [:]
        rootRowIDsByPath = [:]
        rootPathsByRowID = [:]
        availabilityByRootPath = [:]

        for storedRoot in roots {
            let root = LibraryRoot(path: storedRoot.path)
            rootsByPath[root.path] = root
            // SQLite proves that the root was saved, not that its volume is
            // reachable now. The pre-scan check resolves this unknown before
            // cached media from the root becomes visible.
            availabilityByRootPath[root.path] = .unknown
            rootRowIDsByPath[root.path] = storedRoot.id
            rootPathsByRowID[storedRoot.id] = root.path
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
            await diagnostics?.record(
                operation: "catalog.library.normalize",
                phase: "finish",
                fields: [
                    "oldRootPath": storedRoot.path.rawValue,
                    "rootPath": normalizedPath.rawValue,
                    "thumbnailMigrations": "\(thumbnailMigrations.count)",
                ]
            )
            return StoredRoot(id: storedRoot.id, path: normalizedPath)
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
        await diagnostics?.record(
            operation: "catalog.library.normalize",
            phase: "error",
            fields: [
                "oldRootPath": storedRoot.path.rawValue,
                "rootPath": normalizedPath.rawValue,
                "error": String(describing: error),
            ]
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
            enrichedSourceSize: storedAsset.enrichedSourceSize,
            enrichedSourceMTimeSeconds: storedAsset.enrichedSourceMTimeSeconds
        )
    }

    private func rootIDsForQuery(
        selection: SidebarSelection,
        availableLibraryPaths: Set<LibraryRootPath>
    ) -> [Int64] {
        switch selection {
        case .allMedia:
            return availableLibraryPaths.compactMap { rootRowIDsByPath[$0] }.sorted()
        case let .library(path):
            guard availableLibraryPaths.contains(path),
                  let rootID = rootRowIDsByPath[path]
            else {
                return []
            }
            return [rootID]
        }
    }

    private func availableLibraryRootIDs() -> [Int64] {
        rootsByPath.keys.compactMap { path in
            guard availabilityByRootPath[path] == .available else {
                return nil
            }
            return rootRowIDsByPath[path]
        }.sorted()
    }

    private func validateNoOverlap(_ path: LibraryRootPath) throws {
        for existingPath in rootsByPath.keys {
            if let relationship = CatalogPath.relationship(candidate: path, existing: existingPath) {
                throw CatalogStoreError.overlappingRoot(existingPath: existingPath, relationship: relationship)
            }
        }
    }

    private func enqueueScans(_ paths: [LibraryRootPath]) {
        for path in paths where rootsByPath[path] != nil {
            if activeScan?.rootPath == path || pendingScanPaths.contains(path) {
                continue
            }
            pendingScanPaths.append(path)
        }
        startNextScanIfNeeded()
    }

    private func startNextScanIfNeeded() {
        guard currentScanTask == nil else {
            return
        }
        while let nextPath = pendingScanPaths.first {
            pendingScanPaths.removeFirst()
            guard rootsByPath[nextPath] != nil,
                  let rootRowID = rootRowIDsByPath[nextPath]
            else {
                continue
            }
            guard rootIsAvailable(nextPath) else {
                markRootUnavailableBeforeScan(nextPath)
                continue
            }
            setAvailability(.available, for: nextPath)
            let scan = ActiveScan(rootPath: nextPath, rootRowID: rootRowID)
            activeScan = scan
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
            currentScanTask = Task.detached(priority: .utility) { [scanner, scanCadence, diagnostics] in
                do {
                    let observedPaths = try await scanner.scanRoot(nextPath, scanCadence, diagnostics) { batch in
                        try await self.recordScannedBatch(batch, scan: scan)
                    }
                    await self.scanCompleted(scan: scan, observedPaths: observedPaths)
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
        let changedCount = try await dbQueue.write { db in
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

        // The store actor can process remove/cancel messages while SQLite is
        // writing. Recheck ownership before notifying from this batch.
        guard owns(scan) else {
            await recordIgnoredStaleCallback(scan, callback: "batch.afterWrite")
            throw CancellationError()
        }

        let visibleChange = changedCount > 0
        OtosLog.catalog.debug(
            """
            Catalog scan batch path=\(scan.rootPath.rawValue, privacy: .public) \
            count=\(batch.count, privacy: .public) changed=\(visibleChange, privacy: .public)
            """
        )
        await diagnostics?.record(
            operation: "catalog.scan.batch",
            phase: "finish",
            fields: [
                "rootPath": scan.rootPath.rawValue,
                "count": "\(batch.count)",
                "changed": "\(visibleChange)",
            ]
        )
        // SQLite reported whether this batch inserted a new row or changed existing
        // filesystem facts. Identical rescans publish nothing; changed dates now count
        // because tile detail exposes the best filesystem date when metadata is absent.
        if visibleChange {
            notifyCatalogChanged()
        }
    }

    private func scanCompleted(scan: ActiveScan, observedPaths: Set<MediaRelativePath>) async {
        guard owns(scan) else {
            await recordIgnoredStaleCallback(scan, callback: "completion")
            return
        }

        do {
            let deletedCount = try await reconcileMissingAssets(
                scan: scan,
                observedPaths: observedPaths
            )
            OtosLog.catalog.info(
                """
                Catalog scan completed path=\(scan.rootPath.rawValue, privacy: .public) \
                observed=\(observedPaths.count, privacy: .public) deleted=\(deletedCount, privacy: .public)
                """
            )
            await diagnostics?.record(
                operation: "catalog.scan",
                phase: "finish",
                fields: [
                    "rootPath": scan.rootPath.rawValue,
                    "observed": "\(observedPaths.count)",
                    "deleted": "\(deletedCount)",
                ]
            )
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
            await diagnostics?.record(
                operation: "catalog.scan.reconcile",
                phase: "error",
                fields: [
                    "rootPath": scan.rootPath.rawValue,
                    "error": String(describing: error),
                ]
            )
        }

        clearCurrentScan(scan, armFilesystemWatching: true)
    }

    /// Reconciliation changes durable membership as one actor-owned operation.
    /// Projection validates membership directly through Store queries, so Store does not
    /// maintain a second per-asset cache-invalidation fact alongside SQLite.
    private func reconcileMissingAssets(
        scan: ActiveScan,
        observedPaths: Set<MediaRelativePath>
    ) async throws -> Int {
        guard owns(scan) else {
            throw CancellationError()
        }
        let dbQueue = try database()
        let existingRows = try await dbQueue.read { db in
            try Self.fetchExistingAssetRows(libraryRootID: scan.rootRowID, db: db)
        }
        guard owns(scan) else {
            throw CancellationError()
        }
        let missingRows = existingRows.filter { !observedPaths.contains($0.relativePath) }
        guard !missingRows.isEmpty else {
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
        await diagnostics?.record(
            operation: "catalog.scan",
            phase: "cancel",
            fields: ["rootPath": scan.rootPath.rawValue]
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
            await diagnostics?.record(
                operation: "catalog.library.availability",
                phase: "unavailable",
                fields: ["rootPath": scan.rootPath.rawValue]
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
        await diagnostics?.record(
            operation: "catalog.scan",
            phase: "error",
            fields: diagnosticFields
        )
        clearCurrentScan(scan, armFilesystemWatching: true)
    }

    private func clearCurrentScan(_ scan: ActiveScan, armFilesystemWatching: Bool) {
        guard activeScan == scan else {
            return
        }
        let rootPath = scan.rootPath
        activeScan = nil
        currentScanTask = nil

        if armFilesystemWatching, rootsByPath[rootPath] != nil {
            filesystemWatchingArmed.insert(rootPath)
        }

        if rescanAfterCurrentScan.remove(rootPath) != nil {
            filesystemEventBatches.removeValue(forKey: rootPath)
            enqueueScans([rootPath])
        }

        notifyCatalogChanged()
        startNextScanIfNeeded()
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

    private func removeChangeContinuation(_ id: UUID) {
        changeContinuations.removeValue(forKey: id)
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
        guard rootsByPath[path] != nil,
              availabilityByRootPath[path] != availability
        else {
            return false
        }
        availabilityByRootPath[path] = availability
        return true
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
        let roots = Array(rootsByPath.keys)
        filesystemWatcher.start(roots) { [weak self] event in
            // FSEvents reaches us through a synchronous C callback. The Store
            // actor is still the owner of debounce and scan scheduling, so the
            // callback performs only this actor hop.
            Task {
                await self?.handleFilesystemEvent(event)
            }
        }
    }

    private func handleFilesystemEvent(_ event: FilesystemEvent) {
        let signpost = OtosSignpost.catalog.beginInterval("FilesystemEventDebounce")
        defer {
            OtosSignpost.catalog.endInterval("FilesystemEventDebounce", signpost)
        }

        guard let root = CatalogPath.owningRoot(for: event.path, among: rootsByPath.keys) else {
            recordFilesystemEventDrop(path: event.path, root: nil, reason: "outsideRoots")
            return
        }

        guard filesystemWatchingArmed.contains(root) else {
            recordFilesystemEventDrop(path: event.path, root: root, reason: "unarmed")
            return
        }

        OtosLog.catalog.debug(
            "Filesystem event received path=\(event.path, privacy: .public) root=\(root.rawValue, privacy: .public)"
        )
        recordDiagnostic(
            operation: "catalog.filesystemEvent",
            phase: "receive",
            fields: [
                "rootPath": root.rawValue,
                "path": event.path,
                "flags": "\(event.flags)",
            ]
        )
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
        recordDiagnostic(
            operation: "catalog.filesystemEvent",
            phase: "debounce",
            fields: ["rootPath": root.rawValue]
        )
    }

    /// Actor-isolated methods often need to record optional, bounded JSONL
    /// diagnostics from synchronous branches. This is the one best-effort
    /// fire-and-forget diagnostics escape in Store: it captures only scalar
    /// strings and the diagnostics actor, never catalog state or asset batches.
    private func recordDiagnostic(
        operation: String,
        phase: String,
        fields: [String: String] = [:]
    ) {
        guard let diagnostics else {
            return
        }
        Task { [diagnostics, operation, phase, fields] in
            await diagnostics.record(operation: operation, phase: phase, fields: fields)
        }
    }

    // swiftlint:disable:next function_body_length
    private func processFilesystemEventBatch(for root: LibraryRootPath) async {
        let signpost = OtosSignpost.catalog.beginInterval("FilesystemEventBatch")
        defer {
            OtosSignpost.catalog.endInterval("FilesystemEventBatch", signpost)
        }

        guard rootsByPath[root] != nil else {
            filesystemEventBatches.removeValue(forKey: root)
            await recordFilesystemEventDrop(root: root, reason: "removed")
            return
        }
        guard filesystemWatchingArmed.contains(root) else {
            filesystemEventBatches.removeValue(forKey: root)
            await recordFilesystemEventDrop(root: root, reason: "unarmed")
            return
        }
        guard rootIsAvailable(root) else {
            filesystemEventBatches.removeValue(forKey: root)
            await recordFilesystemEventDrop(root: root, reason: "unavailable")
            return
        }

        if activeScan?.rootPath == root {
            rescanAfterCurrentScan.insert(root)
            filesystemEventBatches.removeValue(forKey: root)
            OtosLog.catalog.debug(
                "Filesystem reconcile deferred until active scan finishes path=\(root.rawValue, privacy: .public)"
            )
            await diagnostics?.record(
                operation: "catalog.filesystemEvent",
                phase: "schedule",
                fields: [
                    "rootPath": root.rawValue,
                    "deferred": "true",
                ]
            )
            return
        }

        let events = filesystemEventBatches.removeValue(forKey: root) ?? []
        guard !events.isEmpty else {
            return
        }

        if events.contains(where: { FilesystemEventFlags(event: $0).requiresFullRootScan }) {
            enqueueScans([root])
            OtosLog.catalog.info("Filesystem rescan scheduled path=\(root.rawValue, privacy: .public)")
            await diagnostics?.record(
                operation: "catalog.filesystemEvent",
                phase: "schedule",
                fields: [
                    "rootPath": root.rawValue,
                    "mode": "fullRoot",
                ]
            )
            return
        }

        var catalogChanged = false
        for event in events {
            guard await reconcileFilesystemEvent(event, root: root) else {
                continue
            }
            catalogChanged = true
        }
        if catalogChanged {
            notifyCatalogChanged()
        }
        await diagnostics?.record(
            operation: "catalog.filesystemEvent",
            phase: "reconcile",
            fields: [
                "rootPath": root.rawValue,
                "eventCount": "\(events.count)",
                "catalogChanged": "\(catalogChanged)",
            ]
        )
    }

    @discardableResult
    private func reconcileFilesystemEvent(_ event: FilesystemEvent, root: LibraryRootPath) async -> Bool {
        let flags = FilesystemEventFlags(event: event)
        guard let action = flags.singleFileAction,
              let rootRowID = rootRowIDsByPath[root]
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

        return await deleteCatalogedFile(relativePath: relativePath, rootRowID: rootRowID)
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
        let scannedFile: ScannedMediaFile?
        do {
            scannedFile = try CatalogScannedFileReader.scannedFile(fileURL: fileURL, rootPath: root)
        } catch {
            return false
        }
        guard let scannedFile else {
            guard let relativePath = CatalogPath.relativePath(rootPath: root, fileURL: fileURL) else {
                return false
            }
            return await deleteCatalogedFile(relativePath: relativePath, rootRowID: rootRowID)
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
                try Self.upsertScannedFile(
                    scannedFile,
                    libraryRootPath: root,
                    libraryRootID: rootRowID,
                    db: db
                )
            }
        } catch {
            return false
        }
    }

    private func deleteCatalogedFile(relativePath: MediaRelativePath, rootRowID: Int64) async -> Bool {
        guard let dbQueue = try? database() else {
            return false
        }

        let deletionTarget: CatalogedFileDeletionTarget
        do {
            guard let target = try await dbQueue.read({ db in
                try Self.catalogedFileDeletionTarget(relativePath: relativePath, rootRowID: rootRowID, db: db)
            }) else {
                return false
            }
            deletionTarget = target
            let deleted = try await dbQueue.write { db in
                try Self.deleteAssetRow(rootRowID: rootRowID, relativePath: relativePath, db: db)
            }
            guard deleted else {
                return false
            }
        } catch {
            return false
        }

        if let thumbnailPath = deletionTarget.thumbnailPath, let thumbnailDirectory {
            ThumbnailStore.delete(thumbnailPath, in: thumbnailDirectory)
        }
        return true
    }

    private func recordFilesystemEventDrop(root: LibraryRootPath, reason: String) async {
        OtosLog.catalog.debug(
            "Filesystem rescan dropped path=\(root.rawValue, privacy: .public) reason=\(reason, privacy: .public)"
        )
        await diagnostics?.record(
            operation: "catalog.filesystemEvent",
            phase: "drop",
            fields: [
                "rootPath": root.rawValue,
                "reason": reason,
            ]
        )
    }

    private func cancelFilesystemDebounce(for root: LibraryRootPath) {
        filesystemDebounceTasks[root]?.cancel()
        filesystemDebounceTasks.removeValue(forKey: root)
        filesystemEventBatches.removeValue(forKey: root)
    }

    private func cancelAllFilesystemDebounces() {
        for task in filesystemDebounceTasks.values {
            task.cancel()
        }
        filesystemDebounceTasks.removeAll()
    }

    private func owns(_ scan: ActiveScan) -> Bool {
        activeScan == scan
            && rootsByPath[scan.rootPath] != nil
            && rootRowIDsByPath[scan.rootPath] == scan.rootRowID
            && rootPathsByRowID[scan.rootRowID] == scan.rootPath
    }

    private func recordIgnoredStaleCallback(_ scan: ActiveScan, callback: String) async {
        OtosLog.catalog.debug(
            """
            Ignoring stale scan callback path=\(scan.rootPath.rawValue, privacy: .public) \
            callback=\(callback, privacy: .public)
            """
        )
        await diagnostics?.record(
            operation: "catalog.scan.staleCallback",
            phase: "ignored",
            fields: [
                "rootPath": scan.rootPath.rawValue,
                "rootRowID": "\(scan.rootRowID)",
                "callback": callback,
            ]
        )
    }
}
