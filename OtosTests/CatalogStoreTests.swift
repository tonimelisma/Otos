import Foundation
import GRDB
@testable import Otos
import Testing

struct CatalogStoreTests {
    @Test func migratesV1DatabaseAndReloadsNewNullableFields() async throws {
        let temp = try makeTemporaryDirectory()
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

        #expect(snapshot.roots.map(\.path) == [rootPath])
        #expect(snapshot.assets.count == 1)
        #expect(snapshot.assets[0].relativePath.rawValue == "legacy.jpg")
        #expect(snapshot.assets[0].name == nil)
        #expect(snapshot.assets[0].createdAt == nil)
    }

    @Test func addLibraryScansRegularFilesAndReloadsFromDisk() async throws {
        let temp = try makeTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        let nested = root.appending(path: "Nested", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try writeFile(root.appending(path: "a.jpg"), contents: "jpeg")
        try writeFile(nested.appending(path: "b.txt"), contents: "text")
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "linked.jpg"),
            withDestinationURL: root.appending(path: "a.jpg")
        )

        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        let store = CatalogStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)

        let scanned = try await waitForSnapshot(store) { snapshot in
            !snapshot.isScanning && snapshot.assets.count == 2
        }
        #expect(try scanned.roots.map(\.path) == [CatalogPath.normalizedDirectoryPath(for: root)])
        #expect(scanned.assets.map(\.relativePath.rawValue).sorted() == ["Nested/b.txt", "a.jpg"])
        #expect(scanned.assets.map(\.name).sorted { ($0 ?? "") < ($1 ?? "") } == ["a.jpg", "b.txt"])
        #expect(scanned.assets.allSatisfy { $0.byteSize != nil })
        #expect(scanned.assets.allSatisfy { $0.createdAt != nil })

        let reloadedStore = CatalogStore(location: .databaseFile(databaseURL))
        try await reloadedStore.start(scansSavedLibraries: false)
        let reloaded = await reloadedStore.currentSnapshot()
        #expect(reloaded.roots.count == 1)
        #expect(reloaded.assets.map(\.relativePath.rawValue).sorted() == ["Nested/b.txt", "a.jpg"])
        #expect(reloaded.assets.map(\.name).sorted { ($0 ?? "") < ($1 ?? "") } == ["a.jpg", "b.txt"])
    }

    @Test func addLibraryRejectsDuplicateAncestorAndDescendantRoots() async throws {
        let temp = try makeTemporaryDirectory()
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
        #expect(snapshot.roots.count == 1)
    }

    @Test func removeLibraryDeletesCatalogRowsAndLeavesOriginalsUntouched() async throws {
        let temp = try makeTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appending(path: "a.jpg")
        try writeFile(original, contents: "jpeg")

        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        let store = CatalogStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForSnapshot(store) { snapshot in
            !snapshot.isScanning && snapshot.assets.count == 1
        }

        let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)
        try await store.removeLibrary(path: rootPath)

        let snapshot = await store.currentSnapshot()
        #expect(snapshot.roots.isEmpty)
        #expect(snapshot.assets.isEmpty)
        #expect(FileManager.default.fileExists(atPath: original.path(percentEncoded: false)))

        let reloadedStore = CatalogStore(location: .databaseFile(databaseURL))
        try await reloadedStore.start(scansSavedLibraries: false)
        let reloaded = await reloadedStore.currentSnapshot()
        #expect(reloaded.roots.isEmpty)
        #expect(reloaded.assets.isEmpty)
    }

    @Test func completedLaunchScanDeletesRowsForMissingFiles() async throws {
        let temp = try makeTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = root.appending(path: "a.jpg")
        try writeFile(first, contents: "jpeg")

        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        let firstStore = CatalogStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
        try await firstStore.start(scansSavedLibraries: false)
        try await firstStore.addLibrary(url: root)
        _ = try await waitForSnapshot(firstStore) { snapshot in
            !snapshot.isScanning && snapshot.assets.map(\.relativePath.rawValue) == ["a.jpg"]
        }

        try FileManager.default.removeItem(at: first)
        try writeFile(root.appending(path: "b.jpg"), contents: "jpeg")

        let secondStore = CatalogStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
        try await secondStore.start()
        let reconciled = try await waitForSnapshot(secondStore) { snapshot in
            !snapshot.isScanning && snapshot.assets.map(\.relativePath.rawValue) == ["b.jpg"]
        }
        #expect(reconciled.assets.map(\.relativePath.rawValue) == ["b.jpg"])
    }

    @Test func failedLaunchScanDoesNotDeletePreviouslyCatalogedRows() async throws {
        let temp = try makeTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = root.appending(path: "a.jpg")
        try writeFile(first, contents: "jpeg")

        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        let firstStore = CatalogStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
        try await firstStore.start(scansSavedLibraries: false)
        try await firstStore.addLibrary(url: root)
        _ = try await waitForSnapshot(firstStore) { snapshot in
            !snapshot.isScanning && snapshot.assets.map(\.relativePath.rawValue) == ["a.jpg"]
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
        let failed = try await waitForSnapshot(secondStore) { snapshot in
            !snapshot.isScanning && snapshot.assets.contains { $0.relativePath.rawValue == "a.jpg" }
        }
        #expect(failed.assets.contains { $0.relativePath.rawValue == "a.jpg" })
    }

    @Test func cancelledLaunchScanDoesNotDeletePreviouslyCatalogedRows() async throws {
        let temp = try makeTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeFile(root.appending(path: "a.jpg"), contents: "jpeg")

        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        let firstStore = CatalogStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
        try await firstStore.start(scansSavedLibraries: false)
        try await firstStore.addLibrary(url: root)
        _ = try await waitForSnapshot(firstStore) { snapshot in
            !snapshot.isScanning && snapshot.assets.map(\.relativePath.rawValue) == ["a.jpg"]
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
        _ = try await waitForSnapshot(secondStore) { snapshot in
            snapshot.isScanning
        }
        await secondStore.shutdown()

        let reloadedStore = CatalogStore(location: .databaseFile(databaseURL))
        try await reloadedStore.start(scansSavedLibraries: false)
        let reloaded = await reloadedStore.currentSnapshot()
        #expect(reloaded.assets.map(\.relativePath.rawValue) == ["a.jpg"])
    }

    @Test func noManualScanControlsAreExposedInSwiftUISurfaces() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let files = [
            "Otos/ContentView.swift",
            "Otos/OtosApp.swift",
            "Otos/Views/MediaTableView.swift",
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

private func waitForSnapshot(
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

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "OtosTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeFile(_ url: URL, contents: String) throws {
    try Data(contents.utf8).write(to: url)
}
