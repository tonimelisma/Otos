import CoreServices
import Foundation
@testable import Otos
import Testing

struct MediaCompanionPairingTests {
    @Test func pairsSinglePrimaryByStemIgnoringExtensionCase() {
        let primary = scanned("IMG_1.JPG", kind: .image)
        let companion = ScannedCompanionFile(
            relativePath: MediaRelativePath(rawValue: "IMG_1.xmp"),
            kind: .xmp,
            byteSize: 10,
            contentModifiedAt: nil
        )
        let paired = MediaCompanionPairing.pair(companions: [companion], primaries: [primary])
        #expect(paired.count == 1)
        #expect(paired[0].primaryRelativePath?.rawValue == "IMG_1.JPG")
        #expect(paired[0].kind == .xmp)
    }

    @Test func rawPlusJPEGPrefersRawPrimary() {
        let jpeg = scanned("IMG_1.JPG", kind: .image)
        let raw = scanned("IMG_1.CR2", kind: .raw)
        let companion = ScannedCompanionFile(
            relativePath: MediaRelativePath(rawValue: "IMG_1.xmp"),
            kind: .xmp,
            byteSize: nil,
            contentModifiedAt: nil
        )
        let paired = MediaCompanionPairing.pair(companions: [companion], primaries: [jpeg, raw])
        #expect(paired[0].primaryRelativePath?.rawValue == "IMG_1.CR2")
    }

    @Test func unpairedCompanionRetainsNilPrimary() {
        let companion = ScannedCompanionFile(
            relativePath: MediaRelativePath(rawValue: "orphan.srt"),
            kind: .srt,
            byteSize: 1,
            contentModifiedAt: nil
        )
        let paired = MediaCompanionPairing.pair(companions: [companion], primaries: [])
        #expect(paired[0].primaryRelativePath == nil)
    }

    @Test func doesNotRecognizeLRC() {
        #expect(MediaCompanionKind.recognize(fileExtension: "lrc") == nil)
        #expect(MediaCompanionKind.recognize(fileExtension: "XMP") == .xmp)
        #expect(MediaCompanionKind.recognize(fileExtension: "srt") == .srt)
    }

    private func scanned(_ name: String, kind: MediaKind) -> ScannedMediaFile {
        ScannedMediaFile(
            relativePath: MediaRelativePath(rawValue: name),
            name: name,
            contentTypeIdentifier: kind == .raw ? "com.canon.cr2-raw-image" : "public.jpeg",
            byteSize: 100,
            createdAt: nil,
            contentModifiedAt: nil,
            kind: kind
        )
    }
}

struct ImportPreferencesStoreTests {
    @Test func roundTripsThroughUserDefaults() {
        let temp = TemporaryDefaults()
        defer { temp.cleanUp() }

        var prefs = ImportPreferences.default
        prefs.importSidecarFiles = false
        prefs.deleteSourceAfterImport = true
        prefs.autoEjectAfterImport = true
        prefs.destinationFolderPolicy = .none
        prefs.destinationNamePolicy = .original
        ImportPreferencesStore.save(prefs, defaults: temp.defaults)

        let loaded = ImportPreferencesStore.load(defaults: temp.defaults)
        #expect(loaded == prefs)
    }
}

struct MediaCompanionInventoryTests {
    @Test func scanInventoriesCompanionsWithoutEnteringMediaQueries() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeCatalogStoreFile(root.appending(path: "IMG_1.JPG"), contents: "jpeg")
        try writeCatalogStoreFile(root.appending(path: "IMG_1.xmp"), contents: "<xmp/>")
        try writeCatalogStoreFile(root.appending(path: "notes.txt"), contents: "skip")

        let store = CatalogStore(location: .inMemory, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)
        let scanned = try await waitForCatalogStoreState(store) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.map(\.relativePath.rawValue) == ["IMG_1.JPG"]
        }

        let companions = try await store.companions(in: rootPath)
        #expect(companions.map(\.relativePath.rawValue) == ["IMG_1.xmp"])
        #expect(companions[0].primaryRelativePath?.rawValue == "IMG_1.JPG")
        #expect(companions[0].kind == .xmp)
        #expect(scanned.testAssets.map(\.relativePath.rawValue) == ["IMG_1.JPG"])
    }

    @Test func rawJPEGPairingPrefersRawWhenClassified() {
        let jpeg = ScannedMediaFile(
            relativePath: MediaRelativePath(rawValue: "IMG_1.JPG"),
            name: "IMG_1.JPG",
            contentTypeIdentifier: "public.jpeg",
            byteSize: 100,
            createdAt: nil,
            contentModifiedAt: nil,
            kind: .image
        )
        let raw = ScannedMediaFile(
            relativePath: MediaRelativePath(rawValue: "IMG_1.CR2"),
            name: "IMG_1.CR2",
            contentTypeIdentifier: "com.canon.cr2-raw-image",
            byteSize: 100,
            createdAt: nil,
            contentModifiedAt: nil,
            kind: .raw
        )
        let companion = ScannedCompanionFile(
            relativePath: MediaRelativePath(rawValue: "IMG_1.xmp"),
            kind: .xmp,
            byteSize: nil,
            contentModifiedAt: nil
        )
        let paired = MediaCompanionPairing.pair(companions: [companion], primaries: [jpeg, raw])
        #expect(paired[0].primaryRelativePath?.rawValue == "IMG_1.CR2")
    }

    @Test func targetedDeleteRepairsCompanionPairing() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let media = root.appending(path: "shot.JPG")
        try writeCatalogStoreFile(media, contents: "jpeg")
        try writeCatalogStoreFile(root.appending(path: "shot.xmp"), contents: "<xmp/>")

        let recorder = FilesystemEventScanInvocationRecorder()
        let (watcher, emit) = CatalogFilesystemWatcher.testing()
        let store = CatalogStore(
            location: .inMemory,
            scanner: recordingLiveScanner(recorder),
            filesystemWatcher: watcher,
            scanCadence: .milliseconds(10),
            filesystemEventDebounce: .milliseconds(30)
        )
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 1 }

        var companions = try await store.companions(in: rootPath)
        #expect(companions[0].primaryRelativePath?.rawValue == "shot.JPG")

        try FileManager.default.removeItem(at: media)
        emit(
            FilesystemEvent(
                path: media.path(percentEncoded: false),
                flags: UInt32(kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsFile)
            )
        )

        _ = try await waitForCatalogStoreState(store) { $0.testAssets.isEmpty }
        companions = try await store.companions(in: rootPath)
        #expect(companions.count == 1)
        #expect(companions[0].primaryRelativePath == nil)
    }
}
