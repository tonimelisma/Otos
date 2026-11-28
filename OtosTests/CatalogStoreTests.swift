import Foundation
import GRDB
@testable import OtosKit
import Testing

@Suite(.testScope)
struct CatalogStoreTests {
    // Validates: ARC-003, ARC-018, ARC-038
    @Test func changeNotificationsAreCheapTypedSignals() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let scanner = CatalogScanner { _, _, _ in .empty }
        let store = makeTestStore(location: .inMemory, scanner: scanner)
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
        // The load names which roots the Store reaches, no row; an empty catalog writes nothing.
        #expect(await recorder.snapshot().first == .changed(.membership))

        let snapshot = try await catalogStoreTestState(store)
        #expect(snapshot.libraries.isEmpty)
        #expect(snapshot.testAssets.isEmpty)

        try await store.addLibrary(url: root)
        let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)
        #expect(try await store.removeLibrary(path: rootPath) == .removed)
        await recorder.waitForEvent(.libraryRemoved(rootPath))
    }

    // Validates: APP-007
    /// APP-007: a library another owner is changing is not removed while it changes. The
    /// removal says who it waits for, the library stays cataloged and watched meanwhile,
    /// and the release of that owner's lease removes it — with no window in which another
    /// owner can start on it first.
    @Test func removingABusyLibraryWaitsForItsHolderAndRemovesItOnRelease() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeCatalogStoreFile(root.appending(path: "a.jpg"), contents: "jpeg")
        let watcher = CatalogFilesystemWatcher.testingWithRootInspection()
        let store = makeTestStore(location: .inMemory, filesystemWatcher: watcher.watcher, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 1 }
        guard case let .acquired(lease) = await store.acquireNamespaceMutationLease(
            for: rootPath,
            owner: .importPublication
        ) else {
            Issue.record("Expected to hold the library's namespace for this test")
            return
        }

        #expect(try await store.removeLibrary(path: rootPath) == .waiting(for: .importPublication))
        let kept = try await catalogStoreTestState(store)
        #expect(kept.libraries.map(\.path) == [rootPath])
        #expect(kept.testAssets.count == 1)
        #expect(watcher.roots().contains(rootPath))

        #expect(await store.releaseNamespaceMutationLease(lease))
        // The release handed the root to the removal: a Move to Trash asking in the same
        // breath finds it held by the removal, or already gone.
        let competing = await store.acquireNamespaceMutationLease(for: rootPath, owner: .mediaTrash)
        #expect(competing == .busy(owner: .libraryRemoval) || competing == .rootNotRegistered)
        let removed = try await waitForCatalogStoreState(store) { $0.libraries.isEmpty }
        #expect(removed.testAssets.isEmpty)
        #expect(!watcher.roots().contains(rootPath))
        #expect(await !store.hasNamespaceMutationLease(for: rootPath))
        await store.shutdown()
    }

    // Validates: ARC-043
    @Test func incompatibleLegacyDatabaseIsRefusedWithoutErase() async throws {
        let temp = try makeTestDirectory()
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
        let dbQueue = try makeTestDatabaseQueue(path: databaseURL.path(percentEncoded: false))
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

        let store = makeTestStore(location: .databaseFile(databaseURL))
        do {
            try await store.start(scansSavedLibraries: false)
            Issue.record("Expected unsupportedCatalogSchema for legacy v1")
        } catch let CatalogStoreError.unsupportedCatalogSchema(problem) {
            #expect(problem == .writtenByOtherOtos)
        }

        #expect(FileManager.default.fileExists(atPath: original.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: staleThumbnail.path(percentEncoded: false)))

        let rootCount = try await makeTestDatabaseQueue(path: databaseURL.path(percentEncoded: false)).read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM library_root") ?? 0
        }
        #expect(rootCount == 1)
    }

    // Validates: ARC-035, APP-004, APP-005
    @Test func addLibraryScansRegularFilesAndReloadsFromDisk() async throws {
        let temp = try makeTestDirectory()
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
        let store = makeTestStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
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

        let reloadedStore = makeTestStore(location: .databaseFile(databaseURL))
        try await reloadedStore.start(scansSavedLibraries: false)
        let reloaded = try await catalogStoreTestState(reloadedStore)
        #expect(reloaded.libraries.count == 1)
        #expect(reloaded.testAssets.map(\.relativePath.rawValue) == ["a.jpg"])
        #expect(reloaded.testAssets.map(\.name) == ["a.jpg"])
    }

    // Validates: APP-003
    /// APP-003: library order is a stored property of the root,
    /// user-owned via `moveLibrary(_:_:)` — not derived, and not a parallel
    /// list in preferences that would drift when a root is removed.
    @Test func moveLibraryReordersAndSurvivesReload() async throws {
        let temp = try makeTestDirectory()
        let urls = ["Zebra", "Alpha", "Middle"].map { temp.appending(path: $0, directoryHint: .isDirectory) }
        for url in urls {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        let store = makeTestStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
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

        let reloadedStore = makeTestStore(location: .databaseFile(databaseURL))
        try await reloadedStore.start(scansSavedLibraries: false)
        #expect(await reloadedStore.currentLibraries().map(\.path) == reordered)
    }

    // Validates: APP-003
    /// Two quick ⌘↓ presses on the same library each apply to the order the Store holds
    /// when they arrive, so the library moves down twice — not down and back up, which
    /// is what two moves computed as positions from the same stale list would do.
    @Test func successiveMovesComposeAgainstTheStoreOrder() async throws {
        let temp = try makeTestDirectory()
        let urls = ["A", "B", "C", "D"].map { temp.appending(path: $0, directoryHint: .isDirectory) }
        for url in urls {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let store = makeTestStore(location: .inMemory, filesystemWatcher: .noop)
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
        #expect(try await store.removeLibrary(path: paths[2]) == .removed)
        try await store.moveLibrary(paths[1], .before(paths[0]))
        #expect(await store.currentLibraries().map(\.path) == [paths[1], paths[0], paths[3]])
        try await store.moveLibrary(paths[2], .up)
        #expect(await store.currentLibraries().map(\.path) == [paths[1], paths[0], paths[3]])
        await store.shutdown()
    }

    // Validates: ARC-054, APP-024
    @Test func mediaChoiceDefaultsPersistsAcceptsSameValueAndSurvivesReload() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeCatalogStoreFile(root.appending(path: "a.jpg"), contents: "jpeg")
        try writeCatalogStoreFile(root.appending(path: "b.jpg"), contents: "jpeg")

        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        let store = makeTestStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        let scanned = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 2 }
        let ids = scanned.testAssets.map(\.id).sorted { $0.relativePath.rawValue < $1.relativePath.rawValue }
        #expect(ids.count == 2)
        #expect(try await store.windowReads.mediaAssets(for: ids).values.allSatisfy { $0.mediaChoice == .notRated })

        let firstWrite = try await store.setMediaChoice(.liked, for: ids)
        #expect(firstWrite.existingCount == 2)
        #expect(firstWrite.changedCount == 2)
        let repeatedWrite = try await store.setMediaChoice(.liked, for: ids)
        #expect(repeatedWrite.accepted)
        #expect(repeatedWrite.changedCount == 0)
        #expect(try await store.windowReads.mediaAssets(for: ids).values.allSatisfy { $0.mediaChoice == .liked })

        let reloadedStore = makeTestStore(location: .databaseFile(databaseURL))
        try await reloadedStore.start(scansSavedLibraries: false)
        let reloaded = try await reloadedStore.windowReads.mediaAssets(for: ids)
        #expect(reloaded.values.allSatisfy { $0.mediaChoice == .liked })
    }

    @Test func importSettlementCarriesChoiceFromCatalogedSource() async throws {
        let temp = try makeTestDirectory()
        let sourceRoot = temp.appending(path: "Source", directoryHint: .isDirectory)
        let destinationRoot = temp.appending(path: "Destination", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        try writeCatalogStoreFile(sourceRoot.appending(path: "source.jpg"), contents: "jpeg")

        let store = makeTestStore(location: .databaseFile(temp.appending(path: "db/catalog.sqlite")))
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
            sourceKind: .library,
            sourceDeviceIdentity: nil,
            sourceRootPath: sourcePath,
            sourceRelativePath: sourceID.relativePath,
            destinationRootPath: destinationPath,
            destinationRelativePath: MediaRelativePath(rawValue: "imported.jpg"),
            stagingURL: nil,
            companionStagingURLs: [],
            contentHash: nil,
            importBatch: ImportBatchID(unixMilliseconds: 1),
            sourceByteSize: 4,
            sourceModifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            destinationModifiedAt: Date(timeIntervalSince1970: 1_700_000_001),
            phase: .publishedPendingSettlement,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
        try await store.beginImportOperation(operation)
        _ = try await store.backgroundReads.settleImportedAsset(
            operation: operation,
            byteSize: 4,
            contentModifiedAt: operation.destinationModifiedAt ?? operation.sourceModifiedAt,
            companions: []
        )

        let destinationID = MediaAssetID(
            libraryRootPath: destinationPath,
            relativePath: MediaRelativePath(rawValue: "imported.jpg")
        )
        #expect(try await store.windowReads.mediaAssets(for: [destinationID])[destinationID]?.mediaChoice == .liked)
    }

    // Validates: ARC-056
    /// ARC-056: an import onto a case-sensitive root keys the copy by that volume's name
    /// equality, so `2024/IMG_1.jpg` landing beside `2024/img_1.jpg` is a photo of its own,
    /// and the existing photo keeps its path and its overlay. The settlement is driven on the
    /// catalog itself: no scan of this case-insensitive test volume follows it.
    @Test func anImportOntoACaseSensitiveRootNeverTakesACaseTwinsOverlay() async throws {
        let temp = try makeTestDirectory()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let dbQueue = try makeTestDatabaseQueue(path: databaseURL.path(percentEncoded: false))
        try CatalogStore.migrator.migrate(dbQueue)
        let sourcePath = LibraryRootPath(rawValue: "/Volumes/Card")
        let destinationPath = LibraryRootPath(rawValue: "/Volumes/Photos")
        let existing = MediaRelativePath(rawValue: "2024/img_1.jpg")
        let imported = MediaRelativePath(rawValue: "2024/IMG_1.jpg")
        let operation = ActiveFileOperation(
            operationKey: .make(),
            sourceKind: .library,
            sourceDeviceIdentity: nil,
            sourceRootPath: sourcePath,
            sourceRelativePath: MediaRelativePath(rawValue: "DCIM/IMG_1.jpg"),
            destinationRootPath: destinationPath,
            destinationRelativePath: imported,
            stagingURL: nil,
            companionStagingURLs: [],
            contentHash: nil,
            importBatch: ImportBatchID(unixMilliseconds: 1),
            sourceByteSize: 4,
            sourceModifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            destinationModifiedAt: Date(timeIntervalSince1970: 1_700_000_001),
            phase: .publishedPendingSettlement,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
        let rows = try await dbQueue.write { db in
            let source = try CatalogStore.insertLibraryRoot(path: sourcePath, capabilities: .caseInsensitive, db: db)
            let destination = try CatalogStore.insertLibraryRoot(path: destinationPath, capabilities: .caseSensitive, db: db)
            _ = try CatalogStore.upsertScannedFile(
                ScannedMediaFile(
                    relativePath: existing,
                    name: existing.fileName,
                    contentTypeIdentifier: "public.jpeg",
                    byteSize: 8,
                    createdAt: Date(timeIntervalSince1970: 1_600_000_000),
                    contentModifiedAt: Date(timeIntervalSince1970: 1_600_000_000)
                ),
                libraryRootPath: destinationPath,
                libraryRootID: destination.id,
                capabilities: .caseSensitive,
                db: db
            )
            try db.execute(
                sql: "UPDATE media_asset SET media_choice = 'liked' WHERE library_root_id = ? AND relative_path = ?",
                arguments: [destination.id, existing.rawValue]
            )
            try CatalogStore.settleImportedAsset(
                LandedImport(
                    operation: operation,
                    destinationRootID: destination.id,
                    sourceRootID: source.id,
                    byteSize: 4,
                    contentModifiedAt: Date(timeIntervalSince1970: 1_700_000_001),
                    companions: [],
                    metadata: nil,
                    rendering: nil
                ),
                db: db
            )
            return try Row.fetchAll(
                db,
                sql: "SELECT relative_path, media_choice FROM media_asset WHERE library_root_id = ? ORDER BY relative_path",
                arguments: [destination.id]
            ).map { row -> String in
                let path: String = row[0]
                let choice: String = row[1]
                return "\(path)=\(choice)"
            }
        }
        #expect(rows == ["2024/IMG_1.jpg=notRated", "2024/img_1.jpg=liked"])
    }

    // Validates: ARC-017, ARC-032
    @Test func scanSkipsPackageDescendantsAndRecordsDiagnostics() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let package = root.appending(path: "Photos Library.photoslibrary", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try writeCatalogStoreFile(root.appending(path: "visible.jpg"), contents: "jpeg")
        try writeCatalogStoreFile(package.appending(path: "hidden-inside-package.jpg"), contents: "jpeg")

        let store = makeTestStore(
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
        let temp = try makeTestDirectory()
        let parent = temp.appending(path: "Parent", directoryHint: .isDirectory)
        let child = parent.appending(path: "Child", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)

        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10))
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

    // Validates: ARC-033, APP-007
    @Test func removeLibraryDeletesCatalogRowsAndLeavesOriginalsUntouched() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appending(path: "a.jpg")
        try writeCatalogStoreFile(original, contents: "jpeg")

        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        let store = makeTestStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
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
        #expect(try await store.removeLibrary(path: rootPath) == .removed)

        let snapshot = try await catalogStoreTestState(store)
        #expect(snapshot.libraries.isEmpty)
        #expect(snapshot.testAssets.isEmpty)
        #expect(FileManager.default.fileExists(atPath: original.path(percentEncoded: false)))

        let reloadedStore = makeTestStore(location: .databaseFile(databaseURL))
        try await reloadedStore.start(scansSavedLibraries: false)
        let reloaded = try await catalogStoreTestState(reloadedStore)
        #expect(reloaded.libraries.isEmpty)
        #expect(reloaded.testAssets.isEmpty)
    }

    // Validates: ARC-009, ARC-033
    @Test func completedLaunchScanDeletesRowsForMissingFiles() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = root.appending(path: "a.jpg")
        try writeCatalogStoreFile(first, contents: "jpeg")

        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        let firstStore = makeTestStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
        try await firstStore.start(scansSavedLibraries: false)
        try await firstStore.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(firstStore) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.map(\.relativePath.rawValue) == ["a.jpg"]
        }

        try FileManager.default.removeItem(at: first)
        try writeCatalogStoreFile(root.appending(path: "b.jpg"), contents: "jpeg")

        let secondStore = makeTestStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
        try await secondStore.start()
        let reconciled = try await waitForCatalogStoreState(secondStore) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.map(\.relativePath.rawValue) == ["b.jpg"]
        }
        #expect(reconciled.testAssets.map(\.relativePath.rawValue) == ["b.jpg"])
    }

    // Validates: ARC-033
    /// ADR 0008 move witness: a file renamed into another folder outside Otos keeps its row
    /// and its like across the launch scan, while a copy whose original is then deleted is
    /// a new file with a new identifier and keeps nothing.
    @Test func aFileMovedOutsideOtosKeepsItsOverlayAcrossTheLaunchScan() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeCatalogStoreFile(root.appending(path: "moved.jpg"), contents: "moved-bytes")
        try writeCatalogStoreFile(root.appending(path: "copied.jpg"), contents: "copied-bytes")

        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        let firstStore = makeTestStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
        try await firstStore.start(scansSavedLibraries: false)
        try await firstStore.addLibrary(url: root)
        let scanned = try await waitForCatalogStoreState(firstStore) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.count == 2
        }
        _ = try await firstStore.setMediaChoice(.liked, for: scanned.testAssets.map(\.id))
        await firstStore.shutdown()

        try FileManager.default.createDirectory(
            at: root.appending(path: "Sub", directoryHint: .isDirectory), withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: root.appending(path: "moved.jpg"), to: root.appending(path: "Sub/renamed.jpg"))
        try FileManager.default.copyItem(at: root.appending(path: "copied.jpg"), to: root.appending(path: "copy.jpg"))
        try FileManager.default.removeItem(at: root.appending(path: "copied.jpg"))

        let secondStore = makeTestStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
        try await secondStore.start()
        let reconciled = try await waitForCatalogStoreState(secondStore) { snapshot in
            !snapshot.isScanning && Set(snapshot.testAssets.map(\.relativePath.rawValue)) == ["Sub/renamed.jpg", "copy.jpg"]
        }
        let choices = Dictionary(uniqueKeysWithValues: reconciled.testAssets.map { ($0.relativePath.rawValue, $0.mediaChoice) })
        #expect(choices == ["Sub/renamed.jpg": .liked, "copy.jpg": .notRated])
        await secondStore.shutdown()
    }

    // Validates: ARC-009
    @Test func failedLaunchScanDoesNotDeletePreviouslyCatalogedRows() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = root.appending(path: "a.jpg")
        try writeCatalogStoreFile(first, contents: "jpeg")

        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        let firstStore = makeTestStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
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

        let secondStore = makeTestStore(
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

    // Validates: ARC-009
    @Test func cancelledLaunchScanDoesNotDeletePreviouslyCatalogedRows() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeCatalogStoreFile(root.appending(path: "a.jpg"), contents: "jpeg")

        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        let firstStore = makeTestStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
        try await firstStore.start(scansSavedLibraries: false)
        try await firstStore.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(firstStore) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.map(\.relativePath.rawValue) == ["a.jpg"]
        }

        let hangingScanner = CatalogScanner { _, _, _ in
            await suspendUntilCancelled()
            throw CancellationError()
        }
        let secondStore = makeTestStore(
            location: .databaseFile(databaseURL),
            scanner: hangingScanner,
            scanCadence: .milliseconds(10)
        )
        try await secondStore.start()
        _ = try await waitForCatalogStoreState(secondStore) { snapshot in
            snapshot.isScanning
        }
        await secondStore.shutdown()

        let reloadedStore = makeTestStore(location: .databaseFile(databaseURL))
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
