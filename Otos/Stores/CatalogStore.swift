import Foundation
import GRDB
import OSLog

// swiftlint:disable file_length

/// Catalog Store guide
///
/// This actor is the only runtime owner of catalog truth. SQLite provides durable
/// overlay storage, while the nested dictionaries below are the complete working
/// set used during the process lifetime. Filesystem scans write SQLite and then
/// mirror the same facts into memory before notifying consumers. Views never
/// access either representation directly.
///
/// Store notifications are intentionally content-free. They only mark Projection
/// dirty; Projection pulls one immutable snapshot on its 10 Hz cadence and owns
/// presentation. Awaited GRDB calls make this actor reentrant, so scan code
/// rechecks root and cancellation ownership after each database await before
/// mutating memory. Completed scans reconcile missing paths; failed or cancelled
/// scans preserve prior rows because incomplete observation cannot prove removal.
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

    private let location: Location
    private let scanner: CatalogScanner
    private let scanCadence: Duration
    private let diagnostics: CatalogDiagnostics?
    private var dbQueue: DatabaseQueue?
    private var started = false
    private var rootsByPath: [LibraryRootPath: LibraryRoot] = [:]
    private var rootRowIDsByPath: [LibraryRootPath: Int64] = [:]
    private var rootPathsByRowID: [Int64: LibraryRootPath] = [:]
    private var assetsByRootPath: [LibraryRootPath: [MediaRelativePath: MediaAsset]] = [:]
    private var availabilityByRootPath: [LibraryRootPath: LibraryAvailability] = [:]
    private var changeContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var pendingScanPaths: [LibraryRootPath] = []
    private var currentScanRootPath: LibraryRootPath?
    private var currentScanTask: Task<Void, Never>?

    init(
        location: Location = .application(bundleIdentifier: Bundle.main.bundleIdentifier ?? "net.melisma.Otos"),
        scanner: CatalogScanner = .live,
        scanCadence: Duration = .milliseconds(100),
        diagnostics: CatalogDiagnostics? = .shared
    ) {
        self.location = location
        self.scanner = scanner
        self.scanCadence = scanCadence
        self.diagnostics = diagnostics
    }
}

extension CatalogStore {
    func changeNotifications() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
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
        guard !started else {
            notifyCatalogChanged()
            return
        }
        let state = OtosSignpost.persistence.beginInterval("CatalogStart")
        await diagnostics?.record(operation: "catalog.start", phase: "start")
        defer {
            OtosSignpost.persistence.endInterval("CatalogStart", state)
        }

        let dbQueue = try database()
        let loaded = try await dbQueue.read { db in
            try Self.fetchCatalog(db)
        }
        let applyState = OtosSignpost.catalog.beginInterval("CatalogApplyLoadedCatalog")
        applyLoadedCatalog(roots: loaded.roots, assets: loaded.assets)
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
        if scansSavedLibraries {
            enqueueScans(Array(rootsByPath.keys))
        }
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

        if currentScanRootPath == path {
            currentScanTask?.cancel()
            currentScanTask = nil
            currentScanRootPath = nil
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
        notifyCatalogChanged()
        startNextScanIfNeeded()
    }

    func shutdown() {
        currentScanTask?.cancel()
        currentScanTask = nil
        currentScanRootPath = nil
        pendingScanPaths.removeAll()
        notifyCatalogChanged()
    }
}

private extension CatalogStore {
    private func ensureStartedForMutation() async throws {
        if !started {
            try await start(scansSavedLibraries: false)
        }
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
            if currentScanRootPath == path || pendingScanPaths.contains(path) {
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
            guard rootsByPath[nextPath] != nil else {
                continue
            }
            guard rootIsAvailable(nextPath) else {
                markRootUnavailableBeforeScan(nextPath)
                continue
            }
            setAvailability(.available, for: nextPath)
            currentScanRootPath = nextPath
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
                        try await self.recordScannedBatch(batch, rootPath: nextPath)
                    }
                    await self.scanCompleted(rootPath: nextPath, observedPaths: observedPaths)
                } catch is CancellationError {
                    await self.scanCancelled(rootPath: nextPath)
                } catch {
                    await self.scanFailed(rootPath: nextPath, error: error)
                }
            }
            return
        }
    }

    private func recordScannedBatch(_ batch: [ScannedMediaFile], rootPath: LibraryRootPath) async throws {
        guard currentScanRootPath == rootPath,
              let root = rootsByPath[rootPath],
              let rootRowID = rootRowIDsByPath[rootPath]
        else {
            throw CancellationError()
        }

        let dbQueue = try database()
        let state = OtosSignpost.persistence.beginInterval("CatalogScanBatchWrite")
        try await dbQueue.write { db in
            for file in batch {
                try Self.upsertScannedFile(file, libraryRootID: rootRowID, db: db)
            }
        }
        OtosSignpost.persistence.endInterval("CatalogScanBatchWrite", state)

        // The store actor can process remove/cancel messages while SQLite is
        // writing. Recheck ownership before mirroring the batch into memory.
        guard currentScanRootPath == rootPath,
              rootsByPath[rootPath] != nil
        else {
            throw CancellationError()
        }

        let memoryState = OtosSignpost.catalog.beginInterval("CatalogScanBatchApplyMemory")
        applyScannedBatchToMemory(batch, root: root, rootPath: rootPath)
        OtosSignpost.catalog.endInterval("CatalogScanBatchApplyMemory", memoryState)
        OtosLog.catalog.debug(
            "Catalog scan batch path=\(rootPath.rawValue, privacy: .public) count=\(batch.count, privacy: .public)"
        )
        await diagnostics?.record(
            operation: "catalog.scan.batch",
            phase: "finish",
            fields: [
                "rootPath": rootPath.rawValue,
                "count": "\(batch.count)",
            ]
        )
        notifyCatalogChanged()
    }

    private func applyScannedBatchToMemory(
        _ batch: [ScannedMediaFile],
        root: LibraryRoot,
        rootPath: LibraryRootPath
    ) {
        for file in batch {
            assetsByRootPath[rootPath, default: [:]][file.relativePath] = MediaAsset(
                libraryRootPath: root.path,
                relativePath: file.relativePath,
                name: file.name,
                contentTypeIdentifier: file.contentTypeIdentifier,
                byteSize: file.byteSize,
                createdAt: file.createdAt,
                contentModifiedAt: file.contentModifiedAt
            )
        }
    }

    private func scanCompleted(rootPath: LibraryRootPath, observedPaths: Set<MediaRelativePath>) async {
        guard currentScanRootPath == rootPath,
              let rootRowID = rootRowIDsByPath[rootPath]
        else {
            return
        }

        do {
            let deletedCount = try await reconcileMissingAssets(
                rootPath: rootPath,
                rootRowID: rootRowID,
                observedPaths: observedPaths
            )
            OtosLog.catalog.info(
                """
                Catalog scan completed path=\(rootPath.rawValue, privacy: .public) \
                observed=\(observedPaths.count, privacy: .public) deleted=\(deletedCount, privacy: .public)
                """
            )
            await diagnostics?.record(
                operation: "catalog.scan",
                phase: "finish",
                fields: [
                    "rootPath": rootPath.rawValue,
                    "observed": "\(observedPaths.count)",
                    "deleted": "\(deletedCount)",
                ]
            )
        } catch {
            OtosLog.catalog.error("Catalog scan reconciliation failed path=\(rootPath.rawValue, privacy: .public)")
            await diagnostics?.record(
                operation: "catalog.scan.reconcile",
                phase: "error",
                fields: [
                    "rootPath": rootPath.rawValue,
                    "error": String(describing: error),
                ]
            )
        }

        clearCurrentScan(rootPath: rootPath)
    }

    /// Reconciliation changes durable and in-memory membership as one actor-owned
    /// operation. Projection validates membership directly, so Store does not
    /// maintain a second cache-invalidation fact alongside its source maps.
    private func reconcileMissingAssets(
        rootPath: LibraryRootPath,
        rootRowID: Int64,
        observedPaths: Set<MediaRelativePath>
    ) async throws -> Int {
        let existingPaths = Set(assetsByRootPath[rootPath, default: [:]].keys)
        let missingPaths = existingPaths.subtracting(observedPaths)
        let dbQueue = try database()
        let state = OtosSignpost.persistence.beginInterval("CatalogScanReconcile")
        defer { OtosSignpost.persistence.endInterval("CatalogScanReconcile", state) }

        try await dbQueue.write { db in
            for relativePath in missingPaths {
                try db.execute(
                    sql: "DELETE FROM media_asset WHERE library_root_id = ? AND relative_path = ?",
                    arguments: [rootRowID, relativePath.rawValue]
                )
            }
        }
        for relativePath in missingPaths {
            assetsByRootPath[rootPath]?.removeValue(forKey: relativePath)
        }
        return missingPaths.count
    }

    private func scanCancelled(rootPath: LibraryRootPath) async {
        if rootsByPath[rootPath] != nil {
            OtosLog.catalog.info("Catalog scan cancelled path=\(rootPath.rawValue, privacy: .public)")
        } else {
            OtosLog.catalog.info("Catalog scan cancelled for removed root")
        }
        await diagnostics?.record(
            operation: "catalog.scan",
            phase: "cancel",
            fields: ["rootPath": rootPath.rawValue]
        )
        clearCurrentScan(rootPath: rootPath)
    }

    private func scanFailed(rootPath: LibraryRootPath, error: Error) async {
        let isStillAvailable = rootIsAvailable(rootPath)
        if rootsByPath[rootPath] != nil, !isStillAvailable {
            setAvailability(.unavailable, for: rootPath)
            OtosLog.catalog.error(
                "Catalog scan failed because root is unavailable path=\(rootPath.rawValue, privacy: .public)"
            )
            await diagnostics?.record(
                operation: "catalog.library.availability",
                phase: "unavailable",
                fields: ["rootPath": rootPath.rawValue]
            )
        } else if rootsByPath[rootPath] != nil {
            OtosLog.catalog.error("Catalog scan failed path=\(rootPath.rawValue, privacy: .public)")
        } else {
            OtosLog.catalog.error("Catalog scan failed for removed root")
        }
        if case let CatalogScanError.filesystemErrorsEncountered(count) = error {
            OtosLog.fileAccess.error("Filesystem scan errors count=\(count, privacy: .public)")
        }
        await diagnostics?.record(
            operation: "catalog.scan",
            phase: "error",
            fields: [
                "rootPath": rootPath.rawValue,
                "error": String(describing: error),
            ]
        )
        clearCurrentScan(rootPath: rootPath)
    }

    private func clearCurrentScan(rootPath: LibraryRootPath) {
        if currentScanRootPath == rootPath {
            currentScanRootPath = nil
            currentScanTask = nil
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
                activity: root.path == currentScanRootPath ? .scanning : .idle
            )
        }
        return CatalogSnapshot(
            libraries: libraries,
            assetsByID: assetsByID
        )
    }

    private func notifyCatalogChanged() {
        let state = OtosSignpost.catalog.beginInterval("CatalogChangeNotify")
        defer {
            OtosSignpost.catalog.endInterval("CatalogChangeNotify", state)
        }
        for continuation in changeContinuations.values {
            continuation.yield(())
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
}
