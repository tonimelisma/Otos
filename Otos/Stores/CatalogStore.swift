import Foundation
import GRDB
import OSLog

// swiftlint:disable file_length

/// Store notifications remain cheap invalidation signals. Most changes carry no
/// payload; root removal carries its typed path because a remove followed by a
/// same-path add can otherwise coalesce into a snapshot where Projection cannot
/// observe that the selected library instance disappeared.
nonisolated enum CatalogStoreChange: Equatable {
    case catalogChanged
    case libraryRemoved(LibraryRootPath)
}

/// Catalog Store guide
///
/// This actor is the only runtime owner of catalog truth. SQLite provides durable
/// overlay storage, while the nested dictionaries below are the complete working
/// set used during the process lifetime. Filesystem scans write SQLite and then
/// mirror the same facts into memory before notifying consumers. While the app
/// runs, `CatalogFilesystemWatcher` forwards macOS events to per-root debounced
/// full-root rescans through the same scan pipeline. Views never access either
/// representation directly.
///
/// Why an actor: the database, the in-memory catalog, and background scans all
/// touch the same state, and a scan streams in thousands of files concurrently with
/// user actions. Actor isolation serializes every access to that state
/// automatically, so the catalog cannot be corrupted by two operations at once and
/// we never reach for a lock. The cost is that `await` is a yield point — the actor
/// can run another message mid-operation — which is exactly why scans carry the
/// ownership lease described below.
///
/// Store notifications are intentionally lightweight. Ordinary events only mark
/// Projection dirty; successful root removal additionally carries its typed path
/// so same-path replacement cannot hide selection invalidation. Projection pulls
/// one immutable snapshot on its 10 Hz cadence and owns presentation. Initial
/// loading is represented by one finite task so every
/// concurrent caller observes the same load instead of applying competing
/// snapshots. Awaited GRDB calls make this actor reentrant, so active scans carry
/// the root path and private root-row instance they own and revalidate both after
/// each database await. Completed scans reconcile missing paths; failed,
/// cancelled, or stale scans preserve prior rows because incomplete observation
/// cannot prove removal.
actor CatalogStore {
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
        var captureDate: Date?
        var enrichedSourceSize: Int64?
        var enrichedSourceMTimeSeconds: Int?
    }

    /// This value is a process-local ownership lease, not scan identity. The
    /// normalized path identifies the domain root, while the private row ID
    /// distinguishes a removed root from a later root added at the same path.
    private struct ActiveScan: Equatable {
        let rootPath: LibraryRootPath
        let rootRowID: Int64
    }

    private let location: Location
    private let scanner: CatalogScanner
    private let filesystemWatcher: CatalogFilesystemWatcher
    private let scanCadence: Duration
    private let filesystemEventDebounce: Duration
    private let diagnostics: CatalogDiagnostics?
    private let initialLoadDidRead: (@Sendable () async -> Void)?
    private var dbQueue: DatabaseQueue?
    private var started = false
    private var startupTask: Task<Void, Error>?
    private var unrequestedLoadedRootPaths: [LibraryRootPath] = []
    private var rootsByPath: [LibraryRootPath: LibraryRoot] = [:]
    private var rootRowIDsByPath: [LibraryRootPath: Int64] = [:]
    private var rootPathsByRowID: [Int64: LibraryRootPath] = [:]
    private var assetsByRootPath: [LibraryRootPath: [MediaRelativePath: MediaAsset]] = [:]
    private var availabilityByRootPath: [LibraryRootPath: LibraryAvailability] = [:]
    private var changeContinuations: [UUID: AsyncStream<CatalogStoreChange>.Continuation] = [:]
    private var pendingScanPaths: [LibraryRootPath] = []
    private var activeScan: ActiveScan?
    private var currentScanTask: Task<Void, Never>?
    private var filesystemWatchingStarted = false
    private var filesystemWatchingArmed: Set<LibraryRootPath> = []
    private var rescanAfterCurrentScan: Set<LibraryRootPath> = []
    private var filesystemDebounceTasks: [LibraryRootPath: Task<Void, Never>] = [:]

    init(
        location: Location = .application(bundleIdentifier: Bundle.main.bundleIdentifier ?? "net.melisma.Otos"),
        scanner: CatalogScanner = .live,
        filesystemWatcher: CatalogFilesystemWatcher = .live,
        scanCadence: Duration = .milliseconds(100),
        filesystemEventDebounce: Duration = .milliseconds(500),
        diagnostics: CatalogDiagnostics? = .shared,
        initialLoadDidRead: (@Sendable () async -> Void)? = nil
    ) {
        self.location = location
        self.scanner = scanner
        self.filesystemWatcher = filesystemWatcher
        self.scanCadence = scanCadence
        self.filesystemEventDebounce = filesystemEventDebounce
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
            Task {
                await self?.removeChangeContinuation(id)
            }
        }
        return stream
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
    /// database snapshots.
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
        let applyState = OtosSignpost.catalog.beginInterval("CatalogApplyLoadedCatalog")
        applyLoadedCatalog(roots: loaded.roots, assets: loaded.assets)
        unrequestedLoadedRootPaths = loaded.roots.map(\.path)
        OtosSignpost.catalog.endInterval("CatalogApplyLoadedCatalog", applyState)
        started = true
        OtosLog.persistence.info(
            """
            Catalog loaded roots=\(loaded.roots.count, privacy: .public) \
            assets=\(loaded.assets.count, privacy: .public)
            """
        )
        await diagnostics?.record(
            operation: "catalog.start",
            phase: "finish",
            fields: [
                "roots": "\(loaded.roots.count)",
                "assets": "\(loaded.assets.count)",
            ]
        )
        notifyCatalogChanged()
    }

    func currentSnapshot() -> CatalogSnapshot {
        let state = OtosSignpost.catalog.beginInterval("CatalogCurrentSnapshot")
        defer {
            OtosSignpost.catalog.endInterval("CatalogCurrentSnapshot", state)
        }
        return makeSnapshot()
    }

    /// Applies a batch of completed enrichments in one transaction and one notification.
    /// Batching mirrors `recordScannedBatch`: a per-asset transaction across a whole
    /// library would crawl, and a notification per asset would re-sort the catalog in
    /// Projection per completion. Enrichment writes only enrichment columns/fields,
    /// disjoint from facts; a row that was proven-deleted between extraction and this
    /// write is skipped (the lease), so a removed asset is never resurrected.
    func applyEnrichmentBatch(_ results: [EnrichmentResult]) async {
        guard !results.isEmpty else {
            return
        }
        let writable = currentlyWritableEnrichments(results)
        guard !writable.isEmpty else {
            return
        }

        let state = OtosSignpost.persistence.beginInterval("CatalogEnrichmentBatchWrite")
        do {
            let dbQueue = try database()
            try await dbQueue.write { db in
                for item in writable {
                    try Self.updateEnrichment(item.result, libraryRootID: item.rootRowID, db: db)
                }
            }
        } catch {
            OtosSignpost.persistence.endInterval("CatalogEnrichmentBatchWrite", state)
            await recordEnrichmentBatchError(error, count: writable.count)
            return
        }
        OtosSignpost.persistence.endInterval("CatalogEnrichmentBatchWrite", state)

        let appliedCount = mergeEnrichmentIntoMemory(writable)
        await diagnostics?.record(
            operation: "catalog.enrichment.batch",
            phase: "finish",
            fields: ["count": "\(appliedCount)"]
        )
        if appliedCount > 0 {
            notifyCatalogChanged()
        }
    }

    /// The subset of results whose asset still exists right now (the lease): a row that
    /// was proven-deleted between extraction and this call is dropped, never resurrected.
    private func currentlyWritableEnrichments(
        _ results: [EnrichmentResult]
    ) -> [(rootRowID: Int64, result: EnrichmentResult)] {
        var writable: [(rootRowID: Int64, result: EnrichmentResult)] = []
        for result in results {
            let rootPath = result.id.libraryRootPath
            guard let rootRowID = rootRowIDsByPath[rootPath],
                  assetsByRootPath[rootPath]?[result.id.relativePath] != nil
            else {
                continue
            }
            writable.append((rootRowID, result))
        }
        return writable
    }

    /// Mirrors the cheap enrichment fields into the resident assets after the write,
    /// preserving filesystem facts. Re-validates existence (a row removed during the
    /// write is skipped); the metadata blob is never held resident.
    private func mergeEnrichmentIntoMemory(
        _ writable: [(rootRowID: Int64, result: EnrichmentResult)]
    ) -> Int {
        var appliedCount = 0
        for item in writable {
            let rootPath = item.result.id.libraryRootPath
            guard let existing = assetsByRootPath[rootPath]?[item.result.id.relativePath] else {
                continue
            }
            assetsByRootPath[rootPath]?[item.result.id.relativePath] = existing.applyingEnrichment(
                thumbnailPath: item.result.thumbnailPath,
                captureDate: item.result.captureDate,
                sourceSize: item.result.sourceSize,
                sourceMTimeSeconds: item.result.sourceMTimeSeconds
            )
            appliedCount += 1
        }
        OtosLog.metadata.debug("Enrichment batch applied count=\(appliedCount, privacy: .public)")
        return appliedCount
    }

    private func recordEnrichmentBatchError(_ error: Error, count: Int) async {
        OtosLog.metadata.error("Enrichment batch persist failed count=\(count, privacy: .public)")
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
        let dbQueue = try database()

        let state = OtosSignpost.persistence.beginInterval("CatalogAddRoot")
        await diagnostics?.record(
            operation: "catalog.library.add",
            phase: "start",
            fields: ["rootPath": path.rawValue]
        )
        let storedRoot = try await dbQueue.write { db in
            try db.execute(sql: "INSERT INTO library_root (path) VALUES (?)", arguments: [path.rawValue])
            return StoredRoot(id: db.lastInsertedRowID, path: path)
        }
        OtosSignpost.persistence.endInterval("CatalogAddRoot", state)

        let root = LibraryRoot(path: storedRoot.path)
        rootsByPath[root.path] = root
        availabilityByRootPath[root.path] = .available
        rootRowIDsByPath[root.path] = storedRoot.id
        rootPathsByRowID[storedRoot.id] = root.path
        assetsByRootPath[root.path] = assetsByRootPath[root.path] ?? [:]
        OtosLog.catalog.info("Library root added path=\(root.path.rawValue, privacy: .public)")
        await diagnostics?.record(
            operation: "catalog.library.add",
            phase: "finish",
            fields: ["rootPath": root.path.rawValue]
        )
        notifyCatalogChanged()
        filesystemWatcher.addRoot(root.path)
        enqueueScans([root.path])
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
        let state = OtosSignpost.persistence.beginInterval("CatalogRemoveRoot")
        await diagnostics?.record(
            operation: "catalog.library.remove",
            phase: "start",
            fields: ["rootPath": path.rawValue]
        )
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM library_root WHERE id = ?", arguments: [rootRowID])
        }
        OtosSignpost.persistence.endInterval("CatalogRemoveRoot", state)

        rootsByPath.removeValue(forKey: path)
        availabilityByRootPath.removeValue(forKey: path)
        rootRowIDsByPath.removeValue(forKey: path)
        rootPathsByRowID.removeValue(forKey: rootRowID)
        assetsByRootPath.removeValue(forKey: path)
        OtosLog.catalog.info("Library root removed path=\(root.path.rawValue, privacy: .public)")
        await diagnostics?.record(
            operation: "catalog.library.remove",
            phase: "finish",
            fields: ["rootPath": path.rawValue]
        )
        notifyCatalogChanged(.libraryRemoved(path))
        startNextScanIfNeeded()
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

    private func database() throws -> DatabaseQueue {
        if let dbQueue {
            return dbQueue
        }

        let state = OtosSignpost.persistence.beginInterval("CatalogOpenDatabase")
        defer {
            OtosSignpost.persistence.endInterval("CatalogOpenDatabase", state)
        }

        let dbQueue: DatabaseQueue
        switch location {
        case let .application(bundleIdentifier):
            let databaseURL = try Self.applicationDatabaseURL(bundleIdentifier: bundleIdentifier)
            dbQueue = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
        case let .databaseFile(url):
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            dbQueue = try DatabaseQueue(path: url.path(percentEncoded: false))
        case .inMemory:
            dbQueue = try DatabaseQueue()
        }

        try Self.migrator.migrate(dbQueue)
        self.dbQueue = dbQueue
        return dbQueue
    }

    private func applyLoadedCatalog(roots: [StoredRoot], assets: [StoredAsset]) {
        rootsByPath = [:]
        rootRowIDsByPath = [:]
        rootPathsByRowID = [:]
        assetsByRootPath = [:]
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
            assetsByRootPath[root.path] = [:]
        }

        for asset in assets {
            guard let rootPath = rootPathsByRowID[asset.libraryRootID],
                  rootsByPath[rootPath] != nil
            else {
                continue
            }
            assetsByRootPath[rootPath, default: [:]][asset.relativePath] = MediaAsset(
                libraryRootPath: rootPath,
                relativePath: asset.relativePath,
                name: asset.name,
                contentTypeIdentifier: asset.contentTypeIdentifier,
                byteSize: asset.byteSize,
                createdAt: asset.createdAt,
                contentModifiedAt: asset.contentModifiedAt,
                thumbnailPath: asset.thumbnailPath,
                captureDate: asset.captureDate,
                enrichedSourceSize: asset.enrichedSourceSize,
                enrichedSourceMTimeSeconds: asset.enrichedSourceMTimeSeconds
            )
        }
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
            Task {
                await diagnostics?.record(
                    operation: "catalog.scan",
                    phase: "start",
                    fields: ["rootPath": nextPath.rawValue]
                )
            }
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
        try await dbQueue.write { db in
            for file in batch {
                try Self.upsertScannedFile(file, libraryRootID: scan.rootRowID, db: db)
            }
        }
        OtosSignpost.persistence.endInterval("CatalogScanBatchWrite", state)

        // The store actor can process remove/cancel messages while SQLite is
        // writing. Recheck ownership before mirroring the batch into memory.
        guard owns(scan), let currentRoot = rootsByPath[scan.rootPath] else {
            await recordIgnoredStaleCallback(scan, callback: "batch.afterWrite")
            throw CancellationError()
        }

        let memoryState = OtosSignpost.catalog.beginInterval("CatalogScanBatchApplyMemory")
        // Use the post-await root value. The pre-write value belongs to the same
        // lease, but retaining it across suspension would obscure that proof.
        let visibleChange = applyScannedBatchToMemory(batch, root: currentRoot, rootPath: scan.rootPath)
        OtosSignpost.catalog.endInterval("CatalogScanBatchApplyMemory", memoryState)
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
        // Memory was refreshed above regardless. Only a user-visible change (a new
        // file or a name/type/size change) wakes the sort/scope/publish pipeline; a
        // re-scan that re-observes identical files publishes nothing, and a
        // date-only change refreshes memory without a publication because dates are
        // not a current sort, scope, or display input.
        if visibleChange {
            notifyCatalogChanged()
        }
    }

    /// Mirrors the freshly scanned filesystem facts into the in-memory catalog and
    /// returns whether the batch carried a user-visible change. The in-memory asset
    /// is always replaced with the latest scanned values, so `currentSnapshot()`
    /// never serves stale facts: a same-size content edit or a timestamp-only touch
    /// changes only `createdAt`/`contentModifiedAt`, which `recordScannedBatch`
    /// already upserted into SQLite, and the in-memory copy must match the
    /// filesystem truth rather than wait for the next launch reload.
    ///
    /// The returned flag drives the projection-waking notification and is computed
    /// from the exactly comparable facts only (name, content type, size). Dates are
    /// deliberately excluded from this comparison: they round-trip through SQLite as
    /// `Double` seconds, so comparing a fresh `Date` against a reloaded one risks
    /// float epsilon that would make every re-scan look changed and defeat no-op
    /// suppression, and dates are not a current sort, scope, or display input.
    private func applyScannedBatchToMemory(
        _ batch: [ScannedMediaFile],
        root: LibraryRoot,
        rootPath: LibraryRootPath
    ) -> Bool {
        var visibleChange = false
        // The tile now shows `bestCaptureDate`, which falls back to the filesystem
        // createdAt/contentModifiedAt, so a date change is a visible change that must
        // republish. Compared at whole-second resolution (via `mtimeSeconds`) so the
        // SQLite `Double` round-trip epsilon — the reason spec 0017 rejected a date
        // comparison — cannot make every unchanged re-scan look changed.
        let seconds = MediaAsset.mtimeSeconds
        for file in batch {
            let existing = assetsByRootPath[rootPath]?[file.relativePath]
            let isVisibleChange = existing == nil
                || existing?.name != file.name
                || existing?.contentTypeIdentifier != file.contentTypeIdentifier
                || existing?.byteSize != file.byteSize
                || seconds(existing?.createdAt) != seconds(file.createdAt)
                || seconds(existing?.contentModifiedAt) != seconds(file.contentModifiedAt)
            if isVisibleChange {
                visibleChange = true
            }
            // Disjoint ownership: the scan refreshes facts and preserves the enrichment
            // overlay. A new file is built fresh (no overlay yet); a re-observed file
            // merges so metadata and the thumbnail survive the re-scan, while a changed
            // `(size, mtime)` makes the merged asset report `needsEnrichment` again.
            let merged = existing?.mergingFacts(
                name: file.name,
                contentTypeIdentifier: file.contentTypeIdentifier,
                byteSize: file.byteSize,
                createdAt: file.createdAt,
                contentModifiedAt: file.contentModifiedAt
            ) ?? MediaAsset(
                libraryRootPath: root.path,
                relativePath: file.relativePath,
                name: file.name,
                contentTypeIdentifier: file.contentTypeIdentifier,
                byteSize: file.byteSize,
                createdAt: file.createdAt,
                contentModifiedAt: file.contentModifiedAt
            )
            assetsByRootPath[rootPath, default: [:]][file.relativePath] = merged
        }
        return visibleChange
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
            OtosLog.catalog.error("Catalog scan reconciliation failed path=\(scan.rootPath.rawValue, privacy: .public)")
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

    /// Reconciliation changes durable and in-memory membership as one actor-owned
    /// operation. Projection validates membership directly, so Store does not
    /// maintain a second cache-invalidation fact alongside its source maps.
    private func reconcileMissingAssets(
        scan: ActiveScan,
        observedPaths: Set<MediaRelativePath>
    ) async throws -> Int {
        guard owns(scan) else {
            throw CancellationError()
        }
        let existingPaths = Set(assetsByRootPath[scan.rootPath, default: [:]].keys)
        let missingPaths = existingPaths.subtracting(observedPaths)
        // Capture the thumbnail files of soon-to-be-purged assets before their rows are
        // removed, so overlay is purged with the item (ADR 0008): the row, its blob, and
        // the thumbnail file all go together on proven deletion.
        let purgedThumbnails: [String] = missingPaths.compactMap {
            assetsByRootPath[scan.rootPath]?[$0]?.thumbnailPath
        }
        let dbQueue = try database()
        let state = OtosSignpost.persistence.beginInterval("CatalogScanReconcile")
        defer { OtosSignpost.persistence.endInterval("CatalogScanReconcile", state) }

        try await dbQueue.write { db in
            for relativePath in missingPaths {
                try db.execute(
                    sql: "DELETE FROM media_asset WHERE library_root_id = ? AND relative_path = ?",
                    arguments: [scan.rootRowID, relativePath.rawValue]
                )
            }
        }
        // Removal and same-path replacement can run while GRDB owns the writer.
        // Never mirror an old row's reconciliation into the replacement root.
        guard owns(scan) else {
            throw CancellationError()
        }
        for relativePath in missingPaths {
            assetsByRootPath[scan.rootPath]?.removeValue(forKey: relativePath)
        }
        if let thumbnailDirectory {
            for name in purgedThumbnails {
                ThumbnailStore.delete(name, in: thumbnailDirectory)
            }
        }
        return missingPaths.count
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
            OtosLog.catalog.error("Catalog scan failed path=\(scan.rootPath.rawValue, privacy: .public)")
        }
        if case let CatalogScanError.filesystemErrorsEncountered(count) = error {
            OtosLog.fileAccess.error("Filesystem scan errors count=\(count, privacy: .public)")
        }
        await diagnostics?.record(
            operation: "catalog.scan",
            phase: "error",
            fields: [
                "rootPath": scan.rootPath.rawValue,
                "error": String(describing: error),
            ]
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
            enqueueScans([rootPath])
        }

        notifyCatalogChanged()
        startNextScanIfNeeded()
    }

    private func makeSnapshot() -> CatalogSnapshot {
        var assetsByID: [MediaAssetID: MediaAsset] = [:]
        assetsByID.reserveCapacity(assetsByRootPath.values.reduce(0) { $0 + $1.count })
        for assetsForRoot in assetsByRootPath.values {
            for asset in assetsForRoot.values {
                assetsByID[asset.id] = asset
            }
        }
        let libraries = rootsByPath.values.map { root in
            CatalogLibraryState(
                root: root,
                // Unknown is the only truthful fallback if transient state is
                // ever missing; absence cannot prove filesystem reachability.
                availability: availabilityByRootPath[root.path] ?? .unknown,
                activity: root.path == activeScan?.rootPath ? .scanning : .idle
            )
        }
        return CatalogSnapshot(
            libraries: libraries,
            assetsByID: assetsByID
        )
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
        Task {
            await diagnostics?.record(
                operation: "catalog.library.availability",
                phase: "unavailable",
                fields: ["rootPath": path.rawValue]
            )
        }
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
        Task {
            await diagnostics?.record(
                operation: "catalog.filesystemEvent",
                phase: "receive",
                fields: [
                    "rootPath": root.rawValue,
                    "path": event.path,
                    "flags": "\(event.flags)",
                ]
            )
        }
        debounceFilesystemRescan(for: root)
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
        Task {
            var fields: [String: String] = [
                "path": path,
                "reason": reason,
            ]
            if let root {
                fields["rootPath"] = root.rawValue
            }
            await diagnostics?.record(
                operation: "catalog.filesystemEvent",
                phase: "drop",
                fields: fields
            )
        }
    }

    private func debounceFilesystemRescan(for root: LibraryRootPath) {
        filesystemDebounceTasks[root]?.cancel()
        let debounce = filesystemEventDebounce
        filesystemDebounceTasks[root] = Task { [root] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else {
                return
            }
            await scheduleFilesystemRescan(root)
        }
        Task {
            await diagnostics?.record(
                operation: "catalog.filesystemEvent",
                phase: "debounce",
                fields: ["rootPath": root.rawValue]
            )
        }
    }

    private func scheduleFilesystemRescan(_ root: LibraryRootPath) async {
        let signpost = OtosSignpost.catalog.beginInterval("FilesystemRescanScheduled")
        defer {
            OtosSignpost.catalog.endInterval("FilesystemRescanScheduled", signpost)
        }

        guard rootsByPath[root] != nil else {
            await recordFilesystemEventDrop(root: root, reason: "removed")
            return
        }
        guard filesystemWatchingArmed.contains(root) else {
            await recordFilesystemEventDrop(root: root, reason: "unarmed")
            return
        }
        guard rootIsAvailable(root) else {
            await recordFilesystemEventDrop(root: root, reason: "unavailable")
            return
        }

        if activeScan?.rootPath == root {
            rescanAfterCurrentScan.insert(root)
            OtosLog.catalog.debug(
                "Filesystem rescan deferred until active scan finishes path=\(root.rawValue, privacy: .public)"
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

        enqueueScans([root])
        OtosLog.catalog.info("Filesystem rescan scheduled path=\(root.rawValue, privacy: .public)")
        await diagnostics?.record(
            operation: "catalog.filesystemEvent",
            phase: "schedule",
            fields: [
                "rootPath": root.rawValue,
                "deferred": "false",
            ]
        )
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
