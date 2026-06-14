import Foundation
import GRDB
import OSLog

actor CatalogStore {
    enum Location {
        case application(bundleIdentifier: String)
        case databaseFile(URL)
        case inMemory
    }

    private struct StoredRoot {
        let id: Int64
        let path: String
    }

    private struct StoredAsset {
        let libraryRootID: Int64
        let relativePath: String
        let contentTypeIdentifier: String?
        let byteSize: Int64?
        let contentModifiedAt: Date?
    }

    private let location: Location
    private let scanner: CatalogScanner
    private let scanCadence: Duration
    private var dbQueue: DatabaseQueue?
    private var started = false
    private var rootsByPath: [String: LibraryRoot] = [:]
    private var rootPathsByStorageID: [Int64: String] = [:]
    private var assetsByRootPath: [String: [String: MediaAsset]] = [:]
    private var continuations: [UUID: AsyncStream<CatalogSnapshot>.Continuation] = [:]
    private var pendingScanPaths: [String] = []
    private var currentScanRootPath: String?
    private var currentScanTask: Task<Void, Never>?

    init(
        location: Location = .application(bundleIdentifier: Bundle.main.bundleIdentifier ?? "net.melisma.Otos"),
        scanner: CatalogScanner = .live,
        scanCadence: Duration = .milliseconds(100)
    ) {
        self.location = location
        self.scanner = scanner
        self.scanCadence = scanCadence
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

    func start(scansSavedLibraries: Bool = true) throws {
        guard !started else {
            publishSnapshot()
            return
        }
        let state = OtosSignpost.persistence.beginInterval("CatalogStart")
        defer {
            OtosSignpost.persistence.endInterval("CatalogStart", state)
        }

        let dbQueue = try database()
        let loaded = try dbQueue.read { db in
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
        publishSnapshot()
        if scansSavedLibraries {
            enqueueScans(rootsByPath.keys.sorted())
        }
    }

    func currentSnapshot() -> CatalogSnapshot {
        makeSnapshot()
    }

    func addLibrary(url: URL) throws {
        let path = try CatalogPath.normalizedExistingDirectoryPath(for: url)
        try ensureStartedForMutation()
        try validateNoOverlap(path)
        let dbQueue = try database()

        let state = OtosSignpost.persistence.beginInterval("CatalogAddRoot")
        let storedRoot = try dbQueue.write { db in
            try db.execute(sql: "INSERT INTO library_root (path) VALUES (?)", arguments: [path])
            return StoredRoot(id: db.lastInsertedRowID, path: path)
        }
        OtosSignpost.persistence.endInterval("CatalogAddRoot", state)

        let root = LibraryRoot(storageID: storedRoot.id, path: storedRoot.path)
        rootsByPath[root.path] = root
        rootPathsByStorageID[root.storageID] = root.path
        assetsByRootPath[root.path] = assetsByRootPath[root.path] ?? [:]
        OtosLog.catalog.info("Library root added rootID=\(root.storageID, privacy: .public)")
        publishSnapshot()
        enqueueScans([root.path])
    }

    func removeLibrary(path: String) throws {
        try ensureStartedForMutation()
        guard let root = rootsByPath[path] else {
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
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM library_root WHERE id = ?", arguments: [root.storageID])
        }
        OtosSignpost.persistence.endInterval("CatalogRemoveRoot", state)

        rootsByPath.removeValue(forKey: path)
        rootPathsByStorageID.removeValue(forKey: root.storageID)
        assetsByRootPath.removeValue(forKey: path)
        OtosLog.catalog.info("Library root removed rootID=\(root.storageID, privacy: .public)")
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
    private func ensureStartedForMutation() throws {
        if !started {
            try start(scansSavedLibraries: false)
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

    private static func applicationDatabaseURL(bundleIdentifier: String) throws -> URL {
        let fileManager = FileManager.default
        let appSupportURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directoryURL = appSupportURL
            .appending(path: bundleIdentifier, directoryHint: .isDirectory)
            .appending(path: "Catalog", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL.appending(path: "catalog.sqlite")
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_library_roots_and_media_assets") { db in
            try db.create(table: "library_root") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("path", .text).notNull().unique()
            }

            try db.create(table: "media_asset") { table in
                table.column("library_root_id", .integer)
                    .notNull()
                    .references("library_root", onDelete: .cascade)
                table.column("relative_path", .text).notNull()
                table.column("content_type_identifier", .text)
                table.column("byte_size", .integer)
                table.column("content_modified_at_unix", .double)
                table.primaryKey(["library_root_id", "relative_path"])
            }
        }
        return migrator
    }

    private static func fetchCatalog(_ db: Database) throws -> (roots: [StoredRoot], assets: [StoredAsset]) {
        let roots = try Row.fetchAll(
            db,
            sql: "SELECT id, path FROM library_root ORDER BY path COLLATE NOCASE, path"
        ).map { row in
            StoredRoot(id: row["id"], path: row["path"])
        }

        let assets = try Row.fetchAll(
            db,
            sql: """
            SELECT library_root_id, relative_path, content_type_identifier, byte_size, content_modified_at_unix
            FROM media_asset
            ORDER BY library_root_id, relative_path COLLATE NOCASE, relative_path
            """
        ).map { row in
            let modifiedUnix: Double? = row["content_modified_at_unix"]
            return StoredAsset(
                libraryRootID: row["library_root_id"],
                relativePath: row["relative_path"],
                contentTypeIdentifier: row["content_type_identifier"],
                byteSize: row["byte_size"],
                contentModifiedAt: modifiedUnix.map(Date.init(timeIntervalSince1970:))
            )
        }

        return (roots, assets)
    }

    private func applyLoadedCatalog(roots: [StoredRoot], assets: [StoredAsset]) {
        rootsByPath = [:]
        rootPathsByStorageID = [:]
        assetsByRootPath = [:]

        for storedRoot in roots {
            let root = LibraryRoot(storageID: storedRoot.id, path: storedRoot.path)
            rootsByPath[root.path] = root
            rootPathsByStorageID[root.storageID] = root.path
            assetsByRootPath[root.path] = [:]
        }

        for asset in assets {
            guard let rootPath = rootPathsByStorageID[asset.libraryRootID],
                  let root = rootsByPath[rootPath]
            else {
                continue
            }
            assetsByRootPath[rootPath, default: [:]][asset.relativePath] = MediaAsset(
                libraryPath: root.path,
                libraryDisplayName: root.displayName,
                relativePath: asset.relativePath,
                contentTypeIdentifier: asset.contentTypeIdentifier,
                byteSize: asset.byteSize,
                contentModifiedAt: asset.contentModifiedAt
            )
        }
    }

    private func validateNoOverlap(_ path: String) throws {
        for existingPath in rootsByPath.keys {
            if let relationship = CatalogPath.relationship(candidate: path, existing: existingPath) {
                throw CatalogStoreError.overlappingRoot(existingPath: existingPath, relationship: relationship)
            }
        }
    }

    private func enqueueScans(_ paths: [String]) {
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
            guard let root = rootsByPath[nextPath] else {
                continue
            }
            currentScanRootPath = nextPath
            publishSnapshot()
            OtosLog.catalog.info("Catalog scan started rootID=\(root.storageID, privacy: .public)")
            currentScanTask = Task.detached(priority: .utility) { [scanner, scanCadence] in
                do {
                    let observedPaths = try await scanner.scanRoot(nextPath, scanCadence) { batch in
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

    private func recordScannedBatch(_ batch: [ScannedMediaFile], rootPath: String) throws {
        guard currentScanRootPath == rootPath,
              let root = rootsByPath[rootPath]
        else {
            throw CancellationError()
        }

        let dbQueue = try database()
        let state = OtosSignpost.persistence.beginInterval("CatalogScanBatchWrite")
        try dbQueue.write { db in
            for file in batch {
                try db.execute(
                    sql: """
                    INSERT INTO media_asset (
                        library_root_id,
                        relative_path,
                        content_type_identifier,
                        byte_size,
                        content_modified_at_unix
                    )
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(library_root_id, relative_path) DO UPDATE SET
                        content_type_identifier = excluded.content_type_identifier,
                        byte_size = excluded.byte_size,
                        content_modified_at_unix = excluded.content_modified_at_unix
                    """,
                    arguments: [
                        root.storageID,
                        file.relativePath,
                        file.contentTypeIdentifier,
                        file.byteSize,
                        file.contentModifiedAt?.timeIntervalSince1970,
                    ]
                )
            }
        }
        OtosSignpost.persistence.endInterval("CatalogScanBatchWrite", state)

        for file in batch {
            assetsByRootPath[rootPath, default: [:]][file.relativePath] = MediaAsset(
                libraryPath: root.path,
                libraryDisplayName: root.displayName,
                relativePath: file.relativePath,
                contentTypeIdentifier: file.contentTypeIdentifier,
                byteSize: file.byteSize,
                contentModifiedAt: file.contentModifiedAt
            )
        }
        OtosLog.catalog.debug(
            "Catalog scan batch rootID=\(root.storageID, privacy: .public) count=\(batch.count, privacy: .public)"
        )
        publishSnapshot()
    }

    private func scanCompleted(rootPath: String, observedPaths: Set<String>) {
        guard currentScanRootPath == rootPath,
              let root = rootsByPath[rootPath]
        else {
            return
        }

        do {
            let dbQueue = try database()
            let existingPaths = Set(assetsByRootPath[rootPath, default: [:]].keys)
            let missingPaths = existingPaths.subtracting(observedPaths)
            let state = OtosSignpost.persistence.beginInterval("CatalogScanReconcile")
            try dbQueue.write { db in
                for relativePath in missingPaths {
                    try db.execute(
                        sql: "DELETE FROM media_asset WHERE library_root_id = ? AND relative_path = ?",
                        arguments: [root.storageID, relativePath]
                    )
                }
            }
            OtosSignpost.persistence.endInterval("CatalogScanReconcile", state)
            for relativePath in missingPaths {
                assetsByRootPath[rootPath]?.removeValue(forKey: relativePath)
            }
            OtosLog.catalog.info(
                """
                Catalog scan completed rootID=\(root.storageID, privacy: .public) \
                observed=\(observedPaths.count, privacy: .public) deleted=\(missingPaths.count, privacy: .public)
                """
            )
        } catch {
            OtosLog.catalog.error("Catalog scan reconciliation failed rootID=\(root.storageID, privacy: .public)")
        }

        clearCurrentScan(rootPath: rootPath)
    }

    private func scanCancelled(rootPath: String) {
        if let root = rootsByPath[rootPath] {
            OtosLog.catalog.info("Catalog scan cancelled rootID=\(root.storageID, privacy: .public)")
        } else {
            OtosLog.catalog.info("Catalog scan cancelled for removed root")
        }
        clearCurrentScan(rootPath: rootPath)
    }

    private func scanFailed(rootPath: String, error: Error) {
        if let root = rootsByPath[rootPath] {
            OtosLog.catalog.error("Catalog scan failed rootID=\(root.storageID, privacy: .public)")
        } else {
            OtosLog.catalog.error("Catalog scan failed for unavailable root")
        }
        if case let CatalogScanError.filesystemErrorsEncountered(count) = error {
            OtosLog.fileAccess.error("Filesystem scan errors count=\(count, privacy: .public)")
        }
        clearCurrentScan(rootPath: rootPath)
    }

    private func clearCurrentScan(rootPath: String) {
        if currentScanRootPath == rootPath {
            currentScanRootPath = nil
            currentScanTask = nil
        }
        publishSnapshot()
        startNextScanIfNeeded()
    }

    private func makeSnapshot() -> CatalogSnapshot {
        let roots = rootsByPath.values.sorted { left, right in
            if left.displayName.localizedStandardCompare(right.displayName) == .orderedSame {
                return left.path.localizedStandardCompare(right.path) == .orderedAscending
            }
            return left.displayName.localizedStandardCompare(right.displayName) == .orderedAscending
        }

        let assets = roots.flatMap { root in
            assetsByRootPath[root.path, default: [:]].values.sorted { left, right in
                left.relativePath.localizedStandardCompare(right.relativePath) == .orderedAscending
            }
        }

        return CatalogSnapshot(
            roots: roots,
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
