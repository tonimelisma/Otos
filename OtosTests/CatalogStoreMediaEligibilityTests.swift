import Foundation
import GRDB
@testable import Otos
import Testing

struct CatalogStoreMediaEligibilityTests {
    @Test func scanCatalogsImageAndVideoMediaAndSkipsNonMedia() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeCatalogStoreFile(root.appending(path: "photo.jpg"), contents: "jpeg")
        try writeCatalogStoreFile(root.appending(path: "clip.mp4"), contents: "mp4")
        try writeCatalogStoreFile(root.appending(path: "notes.txt"), contents: "text")
        try writeCatalogStoreFile(root.appending(path: "track.mp3"), contents: "mp3")

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
            !snapshot.isScanning && snapshot.testAssets.count == 2
        }
        #expect(
            Set(scanned.testAssets.map(\.relativePath.rawValue)) == ["clip.mp4", "photo.jpg"]
        )

        let diagnosticsData = try Data(contentsOf: diagnosticsURL)
        let diagnosticsText = try String.decodedUTF8(diagnosticsData)
        #expect(diagnosticsText.contains("\"operation\":\"catalog.scan.skippedNonMedia\""))
        #expect(diagnosticsText.contains("\"count\":\"2\""))
    }

    @Test func completedScanRemovesPreviouslyCatalogedNonMediaRows() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeCatalogStoreFile(root.appending(path: "photo.jpg"), contents: "jpeg")
        try writeCatalogStoreFile(root.appending(path: "notes.txt"), contents: "text")

        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        let firstStore = CatalogStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
        try await firstStore.start(scansSavedLibraries: false)
        try await firstStore.addLibrary(url: root)
        _ = try await waitForCatalogStoreSnapshot(firstStore) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.map(\.relativePath.rawValue) == ["photo.jpg"]
        }

        let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)
        try await insertLegacyNonMediaRow(
            databaseURL: databaseURL,
            rootPath: rootPath,
            relativePath: "notes.txt"
        )

        let secondStore = CatalogStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(10))
        try await secondStore.start()
        let reconciled = try await waitForCatalogStoreSnapshot(secondStore) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.map(\.relativePath.rawValue) == ["photo.jpg"]
        }
        #expect(reconciled.testAssets.map(\.relativePath.rawValue) == ["photo.jpg"])
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "notes.txt").path(percentEncoded: false)))
    }
}

private func insertLegacyNonMediaRow(
    databaseURL: URL,
    rootPath: LibraryRootPath,
    relativePath: String
) async throws {
    let dbQueue = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
    try await dbQueue.write { db in
        let rootID = try Int64.fetchOne(
            db,
            sql: "SELECT id FROM library_root WHERE path = ?",
            arguments: [rootPath.rawValue]
        )
        guard let rootID else {
            Issue.record("Missing library root row for reconciliation setup")
            return
        }
        try db.execute(
            sql: """
            INSERT OR REPLACE INTO media_asset (
                library_root_id,
                relative_path,
                name,
                content_type_identifier,
                byte_size,
                created_at_unix,
                content_modified_at_unix
            )
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                rootID,
                relativePath,
                relativePath,
                "public.plain-text",
                4,
                Date().timeIntervalSince1970,
                Date().timeIntervalSince1970,
            ]
        )
    }
}

private enum CatalogStoreMediaEligibilityTestError: Error {
    case invalidUTF8
}

private extension String {
    static func decodedUTF8(_ data: Data) throws -> String {
        guard let string = String(data: data, encoding: .utf8) else {
            throw CatalogStoreMediaEligibilityTestError.invalidUTF8
        }
        return string
    }
}
