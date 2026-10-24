import Foundation
import GRDB
@testable import OtosKit
import Testing

struct CatalogStoreTests {
    @Test func changeNotificationsAreCheapTypedSignals() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let scanner = CatalogScanner { _, _, _ in .empty }
        let store = CatalogStore(location: .inMemory, scanner: scanner)
        let recorder = ChangeRecorder()
        let stream = await store.changeNotifications()
        let recordingTask = Task {
            for await change in stream {
                await recorder.append(change)
            }
        }
        defer {
            recordingTask.cancel()
        }

        try await store.start(scansSavedLibraries: false)
        await recorder.waitForCount(1)
        #expect(await recorder.snapshot().first == .catalogChanged)

        let snapshot = try await catalogStoreTestState(store)
        #expect(snapshot.libraries.isEmpty)
        #expect(snapshot.testAssets.isEmpty)

        try await store.addLibrary(url: root)
        let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)
        try await store.removeLibrary(path: rootPath)
        await recorder.waitForEvent(.libraryRemoved(rootPath))
    }

    @Test func incompatibleLegacyDatabaseIsRefusedWithoutErase() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appending(path: "legacy.jpg", directoryHint: .notDirectory)
        try writeCatalogStoreFile(original, contents: "jpeg")
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let thumbnailDirectory = databaseURL.deletingLastPathComponent()
            .appending(path: "Thumbnails", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: thumbnailDirectory, withIntermediateDirectories: true)
        let staleThumbnail = thumbnailDirectory.appending(path: "stale.jpg", directoryHint: .notDirectory)
        try Data("stale".utf8).write(to: staleThumbnail)

        let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)
        let dbQueue = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
        try Self.createLegacyV1Schema(dbQueue)
        try await dbQueue.write { db in
            try db.execute(sql: "INSERT INTO library_root (path) VALUES (?)", arguments: [rootPath.rawValue])
            let rootID = db.lastInsertedRowID
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
                """,
                arguments: [rootID, "legacy.jpg", "public.jpeg", 12, Date().timeIntervalSince1970]
            )
        }

        let store = CatalogStore(location: .databaseFile(databaseURL))
        do {
            try await store.start(scansSavedLibraries: false)
            Issue.record("Expected unsupportedCatalogSchema for legacy v1")
        } catch let CatalogStoreError.unsupportedCatalogSchema(problem) {
            #expect(problem == .writtenByNewerOtos || problem == .unrecognized)
        }

        #expect(FileManager.default.fileExists(atPath: original.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: staleThumbnail.path(percentEncoded: false)))

        let rootCount = try await DatabaseQueue(path: databaseURL.path(percentEncoded: false)).read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM library_root") ?? 0
        }
        #expect(rootCount == 1)
    }

    @Test func addLibraryScansRegularFilesAndReloadsFromDisk() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let nested = root.appending(path: "Nested", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try writeCatalogStoreFile(root.appending(path: "a.jpg"), contents: "jpeg")
        try writeCatalogStoreFile(nested.appending(path: "b.txt"), contents: "text")
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "linked.jpg"),
            withDestinationURL: root.appending(path: "a.jpg")
        )

        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        let store = CatalogStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)

        let scanned = try await waitForCatalogStoreState(store) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.count == 1
        }
        #expect(try scanned.libraries.map(\.path) == [CatalogPath.normalizedDirectoryPath(for: root)])
        #expect(scanned.libraries.allSatisfy { !$0.isScanning })
        #expect(scanned.testAssets.map(\.relativePath.rawValue) == ["a.jpg"])
        #expect(scanned.testAssets.map(\.name) == ["a.jpg"])
        #expect(scanned.testAssets.allSatisfy { $0.byteSize != nil })
        #expect(scanned.testAssets.allSatisfy { $0.createdAt != nil })

        let reloadedStore = CatalogStore(location: .databaseFile(databaseURL))
        try await reloadedStore.start(scansSavedLibraries: false)
        let reloaded = try await catalogStoreTestState(reloadedStore)
        #expect(reloaded.libraries.count == 1)
        #expect(reloaded.testAssets.map(\.relativePath.rawValue) == ["a.jpg"])
        #expect(reloaded.testAssets.map(\.name) == ["a.jpg"])
    }

    /// APP-003: library order is a stored property of the root,
    /// user-owned via `moveLibrary(_:_:)` — not derived, and not a parallel
    /// list in preferences that would drift when a root is removed.
    @Test func moveLibraryReordersAndSurvivesReload() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let urls = ["Zebra", "Alpha", "Middle"].map { temp.appending(path: $0, directoryHint: .isDirectory) }
        for url in urls {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        let store = CatalogStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        for url in urls {
            try await store.addLibrary(url: url)
        }
        _ = try await waitForCatalogStoreState(store) { snapshot in
            snapshot.libraries.count == 3 && snapshot.libraries.allSatisfy { !$0.isScanning }
        }
        let paths = try urls.map { try CatalogPath.normalizedDirectoryPath(for: $0) }
        #expect(await store.currentLibraries().map(\.path) == paths, "New libraries append in add order")

        // Move "Middle" to the front.
        try await store.moveLibrary(paths[2], .before(paths[0]))
        let reordered = [paths[2], paths[0], paths[1]]
        #expect(await store.currentLibraries().map(\.path) == reordered)

        // Moves that would not change the order (first up, before itself) change nothing.
        try await store.moveLibrary(paths[2], .up)
        try await store.moveLibrary(paths[0], .before(paths[0]))
        #expect(await store.currentLibraries().map(\.path) == reordered)

        let reloadedStore = CatalogStore(location: .databaseFile(databaseURL))
        try await reloadedStore.start(scansSavedLibraries: false)
        #expect(await reloadedStore.currentLibraries().map(\.path) == reordered)
    }

    /// Two quick ⌘↓ presses on the same library each apply to the order the Store holds
    /// when they arrive, so the library moves down twice — not down and back up, which
    /// is what two moves computed as positions from the same stale list would do.
    @Test func successiveMovesComposeAgainstTheStoreOrder() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let urls = ["A", "B", "C", "D"].map { temp.appending(path: $0, directoryHint: .isDirectory) }
        for url in urls {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let store = CatalogStore(location: .inMemory, filesystemWatcher: .noop)
        try await store.start(scansSavedLibraries: false)
        for url in urls {
            try await store.addLibrary(url: url)
        }
        let paths = try urls.map { try CatalogPath.normalizedDirectoryPath(for: $0) }

        try await store.moveLibrary(paths[1], .down)
        try await store.moveLibrary(paths[1], .down)
        #expect(await store.currentLibraries().map(\.path) == [paths[0], paths[2], paths[3], paths[1]])

        // A move drawn against a list that still showed a removed library moves the
        // library the user pointed at, and one naming a removed library changes nothing.
        try await store.removeLibrary(path: paths[2])
        try await store.moveLibrary(paths[1], .before(paths[0]))
        #expect(await store.currentLibraries().map(\.path) == [paths[1], paths[0], paths[3]])
        try await store.moveLibrary(paths[2], .up)
        #expect(await store.currentLibraries().map(\.path) == [paths[1], paths[0], paths[3]])
        await store.shutdown()
    }

    @Test func mediaChoiceDefaultsPersistsAcceptsSameValueAndSurvivesReload() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeCatalogStoreFile(root.appending(path: "a.jpg"), contents: "jpeg")
        try writeCatalogStoreFile(root.appending(path: "b.jpg"), contents: "jpeg")

        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        let store = CatalogStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        let scanned = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 2 }
        let ids = scanned.testAssets.map(\.id).sorted { $0.relativePath.rawValue < $1.relativePath.rawValue }
        #expect(ids.count == 2)
        #expect(try await store.mediaAssets(for: ids).values.allSatisfy { $0.mediaChoice == .notRated })

        let firstWrite = try await store.setMediaChoice(.liked, for: ids)
        #expect(firstWrite.existingCount == 2)
        #expect(firstWrite.changedCount == 2)
        let repeatedWrite = try await store.setMediaChoice(.liked, for: ids)
        #expect(repeatedWrite.accepted)
        #expect(repeatedWrite.changedCount == 0)
        #expect(try await store.mediaAssets(for: ids).values.allSatisfy { $0.mediaChoice == .liked })

        let reloadedStore = CatalogStore(location: .databaseFile(databaseURL))
        try await reloadedStore.start(scansSavedLibraries: false)
        let reloaded = try await reloadedStore.mediaAssets(for: ids)
        #expect(reloaded.values.allSatisfy { $0.mediaChoice == .liked })
    }

    @Test func importSettlementCarriesChoiceFromCatalogedSource() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let sourceRoot = temp.appending(path: "Source", directoryHint: .isDirectory)
        let destinationRoot = temp.appending(path: "Destination", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        try writeCatalogStoreFile(sourceRoot.appending(path: "source.jpg"), contents: "jpeg")

        let store = CatalogStore(location: .databaseFile(temp.appending(path: "db/catalog.sqlite")))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: sourceRoot)
        try await store.addLibrary(url: destinationRoot)
        let scanned = try await waitForCatalogStoreState(store) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.count == 1
        }
        let sourcePath = try CatalogPath.normalizedDirectoryPath(for: sourceRoot)
        let destinationPath = try CatalogPath.normalizedDirectoryPath(for: destinationRoot)
        let sourceID = MediaAssetID(
            libraryRootPath: sourcePath,
            relativePath: MediaRelativePath(rawValue: "source.jpg")
        )
        #expect(scanned.testAssets.contains(where: { $0.id == sourceID }))
        #expect(try await store.setMediaChoice(.liked, for: [sourceID]).changedCount == 1)

        let operation = ActiveFileOperation(
            operationKey: .make(),
            mode: "test",
            sourceKind: .library,
            sourceDeviceIdentity: nil,
            sourceRootPath: sourcePath,
            sourceRelativePath: sourceID.relativePath,
            destinationRootPath: destinationPath,
            destinationRelativePath: MediaRelativePath(rawValue: "imported.jpg"),
            stagingPath: nil,
            contentHash: nil,
            importBatchUnixMs: 1,
            sourceByteSize: 4,
            sourceModifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            destinationModifiedAt: Date(timeIntervalSince1970: 1_700_000_001),
            phase: .publishedPendingSettlement,
            deleteSourceRequested: false,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
        try await store.beginImportOperation(operation)
        _ = try await store.settleImportedAsset(
            operation: operation,
            byteSize: 4,
            contentModifiedAt: operation.destinationModifiedAt ?? operation.sourceModifiedAt,
            batch: ImportBatchID(unixMilliseconds: 1),
            companions: []
        )

        let destinationID = MediaAssetID(
            libraryRootPath: destinationPath,
            relativePath: MediaRelativePath(rawValue: "imported.jpg")
        )
        #expect(try await store.mediaAssets(for: [destinationID])[destinationID]?.mediaChoice == .liked)
    }

    @Test func scanSkipsPackageDescendantsAndRecordsDiagnostics() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let package = root.appending(path: "Photos Library.photoslibrary", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try writeCatalogStoreFile(root.appending(path: "visible.jpg"), contents: "jpeg")
        try writeCatalogStoreFile(package.appending(path: "hidden-inside-package.jpg"), contents: "jpeg")

        let store = CatalogStore(
            location: .databaseFile(temp.appending(path: "db/catalog.sqlite")),
            scanCadence: .milliseconds(10)
        )
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)

        let scanned = try await waitForCatalogStoreState(store) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.map(\.relativePath.rawValue) == ["visible.jpg"]
        }
        #expect(scanned.testAssets.map(\.relativePath.rawValue) == ["visible.jpg"])
    }

    @Test func addLibraryRejectsDuplicateAncestorAndDescendantRoots() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let parent = temp.appending(path: "Parent", directoryHint: .isDirectory)
        let child = parent.appending(path: "Child", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: parent)

        try await expectOverlap {
            try await store.addLibrary(url: parent)
        }
        try await expectOverlap {
            try await store.addLibrary(url: child)
        }
        try await expectOverlap {
            try await store.addLibrary(url: temp)
        }

        let snapshot = try await catalogStoreTestState(store)
        #expect(snapshot.libraries.count == 1)
    }

    @Test func removeLibraryDeletesCatalogRowsAndLeavesOriginalsUntouched() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appending(path: "a.jpg")
        try writeCatalogStoreFile(original, contents: "jpeg")

        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        let store = CatalogStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.count == 1
        }

        let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)
        let assetID = MediaAssetID(
            libraryRootPath: rootPath,
            relativePath: MediaRelativePath(rawValue: "a.jpg")
        )
        #expect(try await store.setMediaChoice(.disliked, for: [assetID]).changedCount == 1)
        try await store.removeLibrary(path: rootPath)

        let snapshot = try await catalogStoreTestState(store)
        #expect(snapshot.libraries.isEmpty)
        #expect(snapshot.testAssets.isEmpty)
        #expect(FileManager.default.fileExists(atPath: original.path(percentEncoded: false)))

        let reloadedStore = CatalogStore(location: .databaseFile(databaseURL))
        try await reloadedStore.start(scansSavedLibraries: false)
        let reloaded = try await catalogStoreTestState(reloadedStore)
        #expect(reloaded.libraries.isEmpty)
        #expect(reloaded.testAssets.isEmpty)
    }

    @Test func completedLaunchScanDeletesRowsForMissingFiles() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = root.appending(path: "a.jpg")
        try writeCatalogStoreFile(first, contents: "jpeg")

        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        let firstStore = CatalogStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
        try await firstStore.start(scansSavedLibraries: false)
        try await firstStore.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(firstStore) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.map(\.relativePath.rawValue) == ["a.jpg"]
        }

        try FileManager.default.removeItem(at: first)
        try writeCatalogStoreFile(root.appending(path: "b.jpg"), contents: "jpeg")

        let secondStore = CatalogStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
        try await secondStore.start()
        let reconciled = try await waitForCatalogStoreState(secondStore) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.map(\.relativePath.rawValue) == ["b.jpg"]
        }
        #expect(reconciled.testAssets.map(\.relativePath.rawValue) == ["b.jpg"])
    }

    @Test func failedLaunchScanDoesNotDeletePreviouslyCatalogedRows() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = root.appending(path: "a.jpg")
        try writeCatalogStoreFile(first, contents: "jpeg")

        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        let firstStore = CatalogStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
        try await firstStore.start(scansSavedLibraries: false)
        try await firstStore.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(firstStore) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.map(\.relativePath.rawValue) == ["a.jpg"]
        }

        try FileManager.default.removeItem(at: first)
        let failingScanner = CatalogScanner { _, _, batchHandler in
            try await batchHandler([
                ScannedMediaFile(
                    relativePath: MediaRelativePath(rawValue: "b.jpg"),
                    name: "b.jpg",
                    contentTypeIdentifier: "public.jpeg",
                    byteSize: 1,
                    createdAt: Date(),
                    contentModifiedAt: Date()
                ),
            ])
            throw CatalogScanError.filesystemErrorsEncountered(count: 1, summaries: [])
        }

        let secondStore = CatalogStore(
            location: .databaseFile(databaseURL),
            scanner: failingScanner,
            scanCadence: .milliseconds(10)
        )
        try await secondStore.start()
        let failed = try await waitForCatalogStoreState(secondStore) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.contains { $0.relativePath.rawValue == "a.jpg" }
        }
        #expect(failed.testAssets.contains { $0.relativePath.rawValue == "a.jpg" })
        #expect(failed.libraries.first?.availability == .available)
    }

    @Test func cancelledLaunchScanDoesNotDeletePreviouslyCatalogedRows() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeCatalogStoreFile(root.appending(path: "a.jpg"), contents: "jpeg")

        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        let firstStore = CatalogStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
        try await firstStore.start(scansSavedLibraries: false)
        try await firstStore.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(firstStore) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.map(\.relativePath.rawValue) == ["a.jpg"]
        }

        let hangingScanner = CatalogScanner { _, _, _ in
            await suspendUntilCancelled()
            throw CancellationError()
        }
        let secondStore = CatalogStore(
            location: .databaseFile(databaseURL),
            scanner: hangingScanner,
            scanCadence: .milliseconds(10)
        )
        try await secondStore.start()
        _ = try await waitForCatalogStoreState(secondStore) { snapshot in
            snapshot.isScanning
        }
        await secondStore.shutdown()

        let reloadedStore = CatalogStore(location: .databaseFile(databaseURL))
        try await reloadedStore.start(scansSavedLibraries: false)
        let reloaded = try await catalogStoreTestState(reloadedStore)
        #expect(reloaded.testAssets.map(\.relativePath.rawValue) == ["a.jpg"])
    }
}

private extension CatalogStoreTests {
    static func createLegacyV1Schema(_ dbQueue: DatabaseQueue) throws {
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
        try migrator.migrate(dbQueue)
    }
}

private enum CatalogStoreTestError: Error {
    case expectedOverlap
    case invalidUTF8
}

private typealias ChangeRecorder = AsyncValueRecorder<CatalogStoreChange>

private extension AsyncValueRecorder where Value == CatalogStoreChange {
    func waitForCount(_ expectedCount: Int) async {
        _ = await waitForValues { values in
            values.count >= expectedCount
        }
    }

    func waitForEvent(_ expectedEvent: CatalogStoreChange) async {
        _ = await waitForValues { values in
            values.contains(expectedEvent)
        }
    }
}

private func expectOverlap(_ expression: () async throws -> Void) async throws {
    do {
        try await expression()
    } catch let error as CatalogStoreError {
        if case .overlappingRoot = error {
            return
        }
        throw error
    }
    throw CatalogStoreTestError.expectedOverlap
}

func waitForCatalogStoreState(
    _ store: CatalogStore,
    predicate: @escaping @Sendable (CatalogStoreTestState) -> Bool
) async throws -> CatalogStoreTestState {
    let changes = await store.changeNotifications()
    let initial = try await catalogStoreTestState(store)
    if predicate(initial) {
        return initial
    }

    for await _ in changes {
        let snapshot = try await catalogStoreTestState(store)
        if predicate(snapshot) {
            return snapshot
        }
    }
    throw AsyncTestTimeoutError.streamEnded("catalog store changes")
}

func makeCatalogStoreTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "OtosTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func writeCatalogStoreFile(_ url: URL, contents: String) throws {
    try Data(contents.utf8).write(to: url)
}

private extension String {
    static func decodedUTF8(_ data: Data) throws -> String {
        guard let string = String(data: data, encoding: .utf8) else {
            throw CatalogStoreTestError.invalidUTF8
        }
        return string
    }
}
