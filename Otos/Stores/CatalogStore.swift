import Foundation
import GRDB
import OSLog

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
    private var continuations: [UUID: AsyncStream<CatalogSnapshot>.Continuation] = [:]
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
    func snapshots() -> AsyncStream<CatalogSnapshot> {
        let (stream, continuation) = AsyncStream<CatalogSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let id = UUID()
        continuations[id] = continuation
        continuation.yield(makeSnapshot())
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeContinuation(id)
            }
        }
        return stream
    }

    func start(scansSavedLibraries: Bool = true) async throws {
        guard !started else {
            publishSnapshot()
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
        applyLoadedCatalog(roots: loaded.roots, assets: loaded.assets)
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
        publishSnapshot()
        if scansSavedLibraries {
            enqueueScans(Array(rootsByPath.keys))
        }
    }

    func currentSnapshot() -> CatalogSnapshot {
        makeSnapshot()
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
        rootRowIDsByPath[root.path] = storedRoot.id
        rootPathsByRowID[storedRoot.id] = root.path
        assetsByRootPath[root.path] = assetsByRootPath[root.path] ?? [:]
        OtosLog.catalog.info("Library root added path=\(root.path.rawValue, privacy: .public)")
        await diagnostics?.record(
            operation: "catalog.library.add",
            phase: "finish",
            fields: ["rootPath": root.path.rawValue]
        )
        publishSnapshot()
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
        rootRowIDsByPath.removeValue(forKey: path)
        rootPathsByRowID.removeValue(forKey: rootRowID)
        assetsByRootPath.removeValue(forKey: path)
        OtosLog.catalog.info("Library root removed path=\(root.path.rawValue, privacy: .public)")
        await diagnostics?.record(
            operation: "catalog.library.remove",
            phase: "finish",
            fields: ["rootPath": path.rawValue]
        )
        publishSnapshot()
        startNextScanIfNeeded()
    }

    func shutdown() {
        currentScanTask?.cancel()
        currentScanTask = nil
        currentScanRootPath = nil
        pendingScanPaths.removeAll()
        publishSnapshot()
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

        for storedRoot in roots {
            let root = LibraryRoot(path: storedRoot.path)
            rootsByPath[root.path] = root
            rootRowIDsByPath[root.path] = storedRoot.id
            rootPathsByRowID[storedRoot.id] = root.path
            assetsByRootPath[root.path] = [:]
        }

        for asset in assets {
            guard let rootPath = rootPathsByRowID[asset.libraryRootID],
                  let root = rootsByPath[rootPath]
            else {
                continue
            }
            assetsByRootPath[rootPath, default: [:]][asset.relativePath] = MediaAsset(
                libraryRootPath: root.path,
                libraryDisplayName: root.displayName,
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
            currentScanRootPath = nextPath
            publishSnapshot()
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

        applyScannedBatchToMemory(batch, root: root, rootPath: rootPath)
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
        publishSnapshot()
    }

    private func applyScannedBatchToMemory(
        _ batch: [ScannedMediaFile],
        root: LibraryRoot,
        rootPath: LibraryRootPath
    ) {
        for file in batch {
            assetsByRootPath[rootPath, default: [:]][file.relativePath] = MediaAsset(
                libraryRootPath: root.path,
                libraryDisplayName: root.displayName,
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
            let dbQueue = try database()
            let existingPaths = Set(assetsByRootPath[rootPath, default: [:]].keys)
            let missingPaths = existingPaths.subtracting(observedPaths)
            let state = OtosSignpost.persistence.beginInterval("CatalogScanReconcile")
            try await dbQueue.write { db in
                for relativePath in missingPaths {
                    try db.execute(
                        sql: "DELETE FROM media_asset WHERE library_root_id = ? AND relative_path = ?",
                        arguments: [rootRowID, relativePath.rawValue]
                    )
                }
            }
            OtosSignpost.persistence.endInterval("CatalogScanReconcile", state)
            for relativePath in missingPaths {
                assetsByRootPath[rootPath]?.removeValue(forKey: relativePath)
            }
            OtosLog.catalog.info(
                """
                Catalog scan completed path=\(rootPath.rawValue, privacy: .public) \
                observed=\(observedPaths.count, privacy: .public) deleted=\(missingPaths.count, privacy: .public)
                """
            )
            await diagnostics?.record(
                operation: "catalog.scan",
                phase: "finish",
                fields: [
                    "rootPath": rootPath.rawValue,
                    "observed": "\(observedPaths.count)",
                    "deleted": "\(missingPaths.count)",
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
        if rootsByPath[rootPath] != nil {
            OtosLog.catalog.error("Catalog scan failed path=\(rootPath.rawValue, privacy: .public)")
        } else {
            OtosLog.catalog.error("Catalog scan failed for unavailable root")
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
        publishSnapshot()
        startNextScanIfNeeded()
    }

    private func makeSnapshot() -> CatalogSnapshot {
        let assets = assetsByRootPath.values.flatMap(\.values)
        return CatalogSnapshot(
            roots: Array(rootsByPath.values),
            assets: assets,
            scanningRootPaths: Set([currentScanRootPath].compactMap(\.self))
        )
    }

    private func publishSnapshot() {
        let snapshot = makeSnapshot()
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
