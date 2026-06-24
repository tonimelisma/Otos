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
/// mirror the same facts into memory before notifying consumers. Views never
/// access either representation directly.
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
    private let scanCadence: Duration
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

    init(
        location: Location = .application(bundleIdentifier: Bundle.main.bundleIdentifier ?? "net.melisma.Otos"),
        scanner: CatalogScanner = .live,
        scanCadence: Duration = .milliseconds(100),
        diagnostics: CatalogDiagnostics? = .shared,
        initialLoadDidRead: (@Sendable () async -> Void)? = nil
    ) {
        self.location = location
        self.scanner = scanner
        self.scanCadence = scanCadence
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
        notifyCatalogChanged()
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
                contentModifiedAt: asset.contentModifiedAt
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
        let memoryChanged = applyScannedBatchToMemory(batch, root: currentRoot, rootPath: scan.rootPath)
        OtosSignpost.catalog.endInterval("CatalogScanBatchApplyMemory", memoryState)
        OtosLog.catalog.debug(
            """
            Catalog scan batch path=\(scan.rootPath.rawValue, privacy: .public) \
            count=\(batch.count, privacy: .public) changed=\(memoryChanged, privacy: .public)
            """
        )
        await diagnostics?.record(
            operation: "catalog.scan.batch",
            phase: "finish",
            fields: [
                "rootPath": scan.rootPath.rawValue,
                "count": "\(batch.count)",
                "changed": "\(memoryChanged)",
            ]
        )
        // A re-scan that re-observes identical files changes nothing, so skip the
        // notification that would otherwise wake the whole sort/scope/publish
        // pipeline for a no-op batch.
        if memoryChanged {
            notifyCatalogChanged()
        }
    }

    /// Returns whether the batch changed any in-memory asset. A re-scan that
    /// re-observes identical files returns false, which lets the caller skip the
    /// projection-waking notification. Change detection compares the exactly
    /// comparable filesystem facts (name, content type, size); dates round-trip
    /// through SQLite as `Double` seconds, so comparing them risks float epsilon
    /// that would make every re-scan look changed, and a real content change moves
    /// the size anyway.
    private func applyScannedBatchToMemory(
        _ batch: [ScannedMediaFile],
        root: LibraryRoot,
        rootPath: LibraryRootPath
    ) -> Bool {
        var changed = false
        for file in batch {
            let existing = assetsByRootPath[rootPath]?[file.relativePath]
            let isNewOrChanged = existing == nil
                || existing?.name != file.name
                || existing?.contentTypeIdentifier != file.contentTypeIdentifier
                || existing?.byteSize != file.byteSize
            guard isNewOrChanged else {
                continue
            }
            assetsByRootPath[rootPath, default: [:]][file.relativePath] = MediaAsset(
                libraryRootPath: root.path,
                relativePath: file.relativePath,
                name: file.name,
                contentTypeIdentifier: file.contentTypeIdentifier,
                byteSize: file.byteSize,
                createdAt: file.createdAt,
                contentModifiedAt: file.contentModifiedAt
            )
            changed = true
        }
        return changed
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

        clearCurrentScan(scan)
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
        clearCurrentScan(scan)
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
        clearCurrentScan(scan)
    }

    private func clearCurrentScan(_ scan: ActiveScan) {
        guard activeScan == scan else {
            return
        }
        activeScan = nil
        currentScanTask = nil
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
