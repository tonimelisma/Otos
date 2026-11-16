import Foundation
import GRDB
@testable import OtosKit
import Testing

@Suite(.testScope)
struct CatalogStoreRootNormalizationTests {
    @Test func addLibraryResolvesSymlinkedRootBeforeScanning() async throws {
        let fixture = try makeSymlinkedOneDrivePicturesFixture()

        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: fixture.symlinkedPictures)

        let scanned = try await waitForCatalogStoreState(store) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.map(\.relativePath.rawValue) == ["one.jpg"]
        }
        #expect(try scanned.libraries.map(\.path) == [CatalogPath.normalizedDirectoryPath(for: fixture.pictures)])
        #expect(scanned.testAssets.map(\.relativePath.rawValue) == ["one.jpg"])
    }

    /// A library behind a link into `/private` (`/var`, `/tmp`): FSEvents reports a file in
    /// it by its real `/private` path, which, spelled as the catalog spells paths, belongs to
    /// the library and maps to the file's relative path.
    @Test func anEventUnderPrivateBelongsToItsLibrary() throws {
        let folder = try makeTestDirectory()
        let file = folder.appending(path: "one.jpg")
        try Data("jpeg".utf8).write(to: file)
        let reported = try #require(file.path.withCString { realpath($0, nil) }.map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        })
        // The test directory lives under `/var`, a link to `/private/var`.
        #expect(reported.hasPrefix("/private/var/"))

        let root = try CatalogPath.normalizedDirectoryPath(for: folder)
        let event = CatalogPath.catalogSpelling(ofEventPath: reported)
        #expect(CatalogPath.owningRoot(for: event, among: [root]) == root)
        #expect(CatalogPath.relativePath(rootPath: root, absolutePath: event)?.rawValue == "one.jpg")
        #expect(CatalogPath.catalogSpelling(ofEventPath: "/private/variable/x") == "/private/variable/x")
        #expect(CatalogPath.catalogSpelling(ofEventPath: "/Users/me/Pictures") == "/Users/me/Pictures")
    }

    @Test func startupResolvesSavedSymlinkedRootBeforeScanning() async throws {
        let fixture = try makeSymlinkedOneDrivePicturesFixture()
        let databaseURL = fixture.temp.appending(path: "db/catalog.sqlite")
        let savedSymlinkPath = LibraryRootPath(
            rawValue: fixture.symlinkedPictures.standardizedFileURL.path(percentEncoded: false)
        )
        let resolvedPath = try CatalogPath.normalizedDirectoryPath(for: fixture.pictures)
        try await writeSavedSymlinkCatalog(databaseURL: databaseURL, rootPath: savedSymlinkPath)

        let store = makeTestStore(
            location: .databaseFile(databaseURL),
            scanCadence: .milliseconds(10)
        )
        try await store.start()

        let scanned = try await waitForCatalogStoreState(store) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.map(\.relativePath.rawValue) == ["one.jpg"]
        }
        #expect(scanned.libraries.map(\.path) == [resolvedPath])
        #expect(scanned.testAssets.map(\.relativePath.rawValue) == ["one.jpg"])
        #expect(try await savedLibraryRootPaths(in: databaseURL) == [resolvedPath.rawValue])
    }

    @Test func startupMigratesThumbnailPathsWhenNormalizingSavedRoot() async throws {
        let fixture = try makeSymlinkedOneDrivePicturesFixture()
        let databaseURL = fixture.temp.appending(path: "db/catalog.sqlite")
        let savedSymlinkPath = LibraryRootPath(
            rawValue: fixture.symlinkedPictures.standardizedFileURL.path(percentEncoded: false)
        )
        let resolvedPath = try CatalogPath.normalizedDirectoryPath(for: fixture.pictures)
        let relativePath = MediaRelativePath(rawValue: "one.jpg")
        let oldThumbnail = ThumbnailStore.relativeName(for: MediaAssetID(
            libraryRootPath: savedSymlinkPath,
            relativePath: relativePath
        ))
        let newThumbnail = ThumbnailStore.relativeName(for: MediaAssetID(
            libraryRootPath: resolvedPath,
            relativePath: relativePath
        ))
        try await writeSavedSymlinkCatalog(
            databaseURL: databaseURL,
            rootPath: savedSymlinkPath,
            thumbnailPath: oldThumbnail
        )
        let thumbnailDirectory = databaseURL.deletingLastPathComponent()
            .appending(path: "Thumbnails", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: thumbnailDirectory, withIntermediateDirectories: true)
        try Data("thumbnail".utf8).write(to: thumbnailDirectory.appending(path: oldThumbnail))

        let store = makeTestStore(
            location: .databaseFile(databaseURL),
            scanCadence: .milliseconds(10)
        )
        try await store.start()

        _ = try await waitForCatalogStoreState(store) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.map(\.relativePath.rawValue) == ["one.jpg"]
        }
        #expect(try await savedAssetThumbnailPaths(in: databaseURL) == [newThumbnail])
        #expect(!FileManager.default.fileExists(
            atPath: thumbnailDirectory.appending(path: oldThumbnail).path(percentEncoded: false)
        ))
        #expect(FileManager.default.fileExists(
            atPath: thumbnailDirectory.appending(path: newThumbnail).path(percentEncoded: false)
        ))
    }
}

private struct SymlinkedOneDrivePicturesFixture {
    let temp: URL
    let pictures: URL
    let symlinkedPictures: URL
}

private func makeSymlinkedOneDrivePicturesFixture() throws -> SymlinkedOneDrivePicturesFixture {
    let temp = try makeTestDirectory()
    let cloudRoot = temp.appending(path: "Library/CloudStorage/OneDrive-Personal", directoryHint: .isDirectory)
    let pictures = cloudRoot.appending(path: "Pictures", directoryHint: .isDirectory)
    let desktop = temp.appending(path: "Desktop", directoryHint: .isDirectory)
    let oneDriveLink = desktop.appending(path: "OneDrive", directoryHint: .isDirectory)
    let symlinkedPictures = oneDriveLink.appending(path: "Pictures", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: oneDriveLink, withDestinationURL: cloudRoot)
    try writeCatalogStoreFile(pictures.appending(path: "one.jpg"), contents: "jpeg")
    return SymlinkedOneDrivePicturesFixture(
        temp: temp,
        pictures: pictures,
        symlinkedPictures: symlinkedPictures
    )
}

private func writeSavedSymlinkCatalog(
    databaseURL: URL,
    rootPath: LibraryRootPath,
    thumbnailPath: String? = nil
) async throws {
    try FileManager.default.createDirectory(
        at: databaseURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let dbQueue = try DatabaseQueue(path: databaseURL.path(percentEncoded: false))
    try CatalogStore.migrator.migrate(dbQueue)
    try await dbQueue.write { db in
        let storedRoot = try CatalogStore.insertLibraryRoot(path: rootPath, capabilities: .unknown, db: db)
        let relativePath = MediaRelativePath(rawValue: "one.jpg")
        try insertSavedAsset(
            rootID: storedRoot.id,
            rootPath: rootPath,
            relativePath: relativePath,
            thumbnailPath: thumbnailPath,
            db: db
        )
    }
}

private func insertSavedAsset(
    rootID: Int64,
    rootPath: LibraryRootPath,
    relativePath: MediaRelativePath,
    thumbnailPath: String?,
    db: Database
) throws {
    try db.execute(
        sql: """
        INSERT INTO media_asset (
            library_root_id,
            relative_path,
            sort_key,
            name_sort_key,
            name,
            content_type_identifier,
            thumbnail_path
        )
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
        arguments: [
            rootID,
            relativePath.rawValue,
            MediaSortKey.make(libraryRootPath: rootPath, relativePath: relativePath),
            MediaSortKey.naturalKey(relativePath.rawValue),
            relativePath.rawValue,
            "public.jpeg",
            thumbnailPath,
        ]
    )
}

private func savedLibraryRootPaths(in databaseURL: URL) async throws -> [String] {
    try await DatabaseQueue(path: databaseURL.path(percentEncoded: false)).read { db in
        try String.fetchAll(db, sql: "SELECT path FROM library_root")
    }
}

private func savedAssetThumbnailPaths(in databaseURL: URL) async throws -> [String] {
    try await DatabaseQueue(path: databaseURL.path(percentEncoded: false)).read { db in
        try String.fetchAll(db, sql: "SELECT thumbnail_path FROM media_asset")
    }
}
