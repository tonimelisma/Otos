import Foundation
import GRDB
@testable import Otos
import Testing

struct CatalogStoreTests {
    @Test func changeNotificationsAreCheapDirtySignals() async throws {
        let store = CatalogStore(location: .inMemory, diagnostics: nil)
        let recorder = ChangeRecorder()
        let stream = await store.changeNotifications()
        let recordingTask = Task {
            for await _ in stream {
                await recorder.increment()
            }
        }
        defer {
            recordingTask.cancel()
        }

        try await store.start(scansSavedLibraries: false)
        try await recorder.waitForCount(1)

        let snapshot = await store.currentSnapshot()
        #expect(snapshot.libraries.isEmpty)
        #expect(snapshot.testAssets.isEmpty)
    }

    @Test func migratesV1DatabaseAndReloadsNewNullableFields() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)
        let dbQueue = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
        try Self.migrateV1Schema(dbQueue)
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
        try await store.start(scansSavedLibraries: false)
        let snapshot = await store.currentSnapshot()

        #expect(snapshot.libraries.map(\.path) == [rootPath])
        #expect(snapshot.testAssets.count == 1)
        #expect(snapshot.testAssets[0].relativePath.rawValue == "legacy.jpg")
        #expect(snapshot.testAssets[0].name == nil)
        #expect(snapshot.testAssets[0].createdAt == nil)
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

        let scanned = try await waitForCatalogStoreSnapshot(store) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.count == 2
        }
        #expect(try scanned.libraries.map(\.path) == [CatalogPath.normalizedDirectoryPath(for: root)])
        #expect(scanned.libraries.allSatisfy { !$0.isScanning })
        #expect(scanned.testAssets.map(\.relativePath.rawValue).sorted() == ["Nested/b.txt", "a.jpg"])
        #expect(scanned.testAssets.map(\.name).sorted { ($0 ?? "") < ($1 ?? "") } == ["a.jpg", "b.txt"])
        #expect(scanned.testAssets.allSatisfy { $0.byteSize != nil })
        #expect(scanned.testAssets.allSatisfy { $0.createdAt != nil })

        let reloadedStore = CatalogStore(location: .databaseFile(databaseURL))
        try await reloadedStore.start(scansSavedLibraries: false)
        let reloaded = await reloadedStore.currentSnapshot()
        #expect(reloaded.libraries.count == 1)
        #expect(reloaded.testAssets.map(\.relativePath.rawValue).sorted() == ["Nested/b.txt", "a.jpg"])
        #expect(reloaded.testAssets.map(\.name).sorted { ($0 ?? "") < ($1 ?? "") } == ["a.jpg", "b.txt"])
    }

    @Test func scanSkipsPackageDescendantsAndRecordsDiagnostics() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let package = root.appending(path: "Photos Library.photoslibrary", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try writeCatalogStoreFile(root.appending(path: "visible.jpg"), contents: "jpeg")
        try writeCatalogStoreFile(package.appending(path: "hidden-inside-package.jpg"), contents: "jpeg")

        let diagnosticsURL = temp.appending(path: "diagnostics/catalog-diagnostics.jsonl")
        let diagnostics = CatalogDiagnostics(outputURL: diagnosticsURL, isEnabled: true)
        let store = CatalogStore(
            location: .databaseFile(temp.appending(path: "db/catalog.sqlite")),
            scanCadence: .milliseconds(10),
            diagnostics: diagnostics
        )
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)

        let scanned = try await waitForCatalogStoreSnapshot(store) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.map(\.relativePath.rawValue) == ["visible.jpg"]
        }
        #expect(scanned.testAssets.map(\.relativePath.rawValue) == ["visible.jpg"])

        let diagnosticsData = try Data(contentsOf: diagnosticsURL)
        let diagnosticsText = try String.decodedUTF8(diagnosticsData)
        #expect(diagnosticsText.contains("\"operation\":\"catalog.scan.skippedPackage\""))
        #expect(diagnosticsText.contains("Photos Library.photoslibrary"))
        #expect(diagnosticsText.contains("com.apple.photos.library"))
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

        let snapshot = await store.currentSnapshot()
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
        _ = try await waitForCatalogStoreSnapshot(store) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.count == 1
        }

        let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)
        try await store.removeLibrary(path: rootPath)

        let snapshot = await store.currentSnapshot()
        #expect(snapshot.libraries.isEmpty)
        #expect(snapshot.testAssets.isEmpty)
        #expect(FileManager.default.fileExists(atPath: original.path(percentEncoded: false)))

        let reloadedStore = CatalogStore(location: .databaseFile(databaseURL))
        try await reloadedStore.start(scansSavedLibraries: false)
        let reloaded = await reloadedStore.currentSnapshot()
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
        _ = try await waitForCatalogStoreSnapshot(firstStore) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.map(\.relativePath.rawValue) == ["a.jpg"]
        }

        try FileManager.default.removeItem(at: first)
        try writeCatalogStoreFile(root.appending(path: "b.jpg"), contents: "jpeg")

        let secondStore = CatalogStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
        try await secondStore.start()
        let reconciled = try await waitForCatalogStoreSnapshot(secondStore) { snapshot in
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
        _ = try await waitForCatalogStoreSnapshot(firstStore) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.map(\.relativePath.rawValue) == ["a.jpg"]
        }

        try FileManager.default.removeItem(at: first)
        let failingScanner = CatalogScanner { _, _, _, batchHandler in
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
            throw CatalogScanError.filesystemErrorsEncountered(1)
        }

        let secondStore = CatalogStore(
            location: .databaseFile(databaseURL),
            scanner: failingScanner,
            scanCadence: .milliseconds(10)
        )
        try await secondStore.start()
        let failed = try await waitForCatalogStoreSnapshot(secondStore) { snapshot in
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
        _ = try await waitForCatalogStoreSnapshot(firstStore) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.map(\.relativePath.rawValue) == ["a.jpg"]
        }

        let hangingScanner = CatalogScanner { _, _, _, _ in
            while true {
                try Task.checkCancellation()
                try await Task.sleep(for: .seconds(1))
            }
        }
        let secondStore = CatalogStore(
            location: .databaseFile(databaseURL),
            scanner: hangingScanner,
            scanCadence: .milliseconds(10)
        )
        try await secondStore.start()
        _ = try await waitForCatalogStoreSnapshot(secondStore) { snapshot in
            snapshot.isScanning
        }
        await secondStore.shutdown()

        let reloadedStore = CatalogStore(location: .databaseFile(databaseURL))
        try await reloadedStore.start(scansSavedLibraries: false)
        let reloaded = await reloadedStore.currentSnapshot()
        #expect(reloaded.testAssets.map(\.relativePath.rawValue) == ["a.jpg"])
    }

    @Test func noManualScanControlsAreExposedInSwiftUISurfaces() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let files = [
            "Otos/ContentView.swift",
            "Otos/OtosApp.swift",
            "Otos/Views/MediaGridView.swift",
            "Otos/Views/MediaAssetCollectionView.swift",
            "Otos/Views/SettingsView.swift",
            "Otos/Views/SidebarView.swift",
        ]
        let disallowedLabels = [
            "Scan Library",
            "Scan Libraries",
            "Rescan",
            "Refresh Library",
            "Refresh Libraries",
        ]

        for file in files {
            let content = try String(contentsOf: repoRoot.appending(path: file), encoding: .utf8)
            for label in disallowedLabels {
                #expect(!content.contains(label), "\(label) should not appear in \(file)")
            }
        }
    }
}

private extension CatalogStoreTests {
    static func migrateV1Schema(_ dbQueue: DatabaseQueue) throws {
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
    case timedOut
    case expectedOverlap
    case invalidUTF8
}

private actor ChangeRecorder {
    private var count = 0

    func increment() {
        count += 1
    }

    func waitForCount(_ expectedCount: Int) async throws {
        for _ in 0 ..< 100 {
            if count >= expectedCount {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CatalogStoreTestError.timedOut
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

func waitForCatalogStoreSnapshot(
    _ store: CatalogStore,
    timeoutAttempts: Int = 100,
    predicate: (CatalogSnapshot) -> Bool
) async throws -> CatalogSnapshot {
    for _ in 0 ..< timeoutAttempts {
        let snapshot = await store.currentSnapshot()
        if predicate(snapshot) {
            return snapshot
        }
        try await Task.sleep(for: .milliseconds(50))
    }
    throw CatalogStoreTestError.timedOut
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
