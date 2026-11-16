import CoreServices
import Foundation
@testable import OtosKit
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
        let paired = MediaCompanionPairing.pair(companions: [companion], primaries: [primary], capabilities: .caseInsensitive)
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
        let paired = MediaCompanionPairing.pair(companions: [companion], primaries: [jpeg, raw], capabilities: .caseInsensitive)
        #expect(paired[0].primaryRelativePath?.rawValue == "IMG_1.CR2")
    }

    /// On a case-sensitive volume names that differ by case are different files, so they
    /// share no stem; on a case-insensitive one they do (ADR 0052, ARC-056).
    @Test func pairsByTheVolumesOwnStemEquality() {
        let primary = scanned("IMG_1.JPG", kind: .image)
        let companion = ScannedCompanionFile(
            relativePath: MediaRelativePath(rawValue: "img_1.xmp"),
            kind: .xmp,
            byteSize: nil,
            contentModifiedAt: nil
        )
        let insensitive = MediaCompanionPairing.pair(
            companions: [companion],
            primaries: [primary],
            capabilities: .caseInsensitive
        )
        let sensitive = MediaCompanionPairing.pair(
            companions: [companion],
            primaries: [primary],
            capabilities: .caseSensitive
        )
        #expect(insensitive[0].primaryRelativePath?.rawValue == "IMG_1.JPG")
        #expect(sensitive[0].primaryRelativePath == nil)
    }

    /// A precomposed and a decomposed spelling of one stem are one stem on every volume.
    @Test func pairsAcrossUnicodeNormalization() {
        let composed = "Caf\u{00E9}"
        let decomposed = "Cafe\u{0301}"
        let primary = scanned("\(composed).JPG", kind: .image)
        let companion = ScannedCompanionFile(
            relativePath: MediaRelativePath(rawValue: "\(decomposed).xmp"),
            kind: .xmp,
            byteSize: nil,
            contentModifiedAt: nil
        )
        for capabilities in [VolumeNamespaceCapabilities.caseSensitive, .caseInsensitive] {
            let paired = MediaCompanionPairing.pair(
                companions: [companion],
                primaries: [primary],
                capabilities: capabilities
            )
            #expect(paired[0].primaryRelativePath?.rawValue == "\(composed).JPG")
        }
    }

    @Test func theStemKeyKeepsTheFolderAndDropsOnlyTheLastExtension() {
        let raw = FilesystemNamespaceSemantics.stemKey(
            relativePath: MediaRelativePath(rawValue: "2026/DSC01234.ARW"),
            capabilities: .caseInsensitive
        )
        let jpeg = FilesystemNamespaceSemantics.stemKey(
            relativePath: MediaRelativePath(rawValue: "2026/dsc01234.jpg"),
            capabilities: .caseInsensitive
        )
        let otherFolder = FilesystemNamespaceSemantics.stemKey(
            relativePath: MediaRelativePath(rawValue: "2027/DSC01234.JPG"),
            capabilities: .caseInsensitive
        )
        let doubleExtension = FilesystemNamespaceSemantics.stemKey(
            relativePath: MediaRelativePath(rawValue: "2026/DSC01234.ARW.xmp"),
            capabilities: .caseInsensitive
        )
        #expect(raw == jpeg)
        #expect(raw != otherFolder)
        #expect(raw != doubleExtension)
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

@Suite(.testScope)
struct MediaCompanionInventoryTests {
    @Test func scanInventoriesCompanionsWithoutEnteringMediaQueries() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeCatalogStoreFile(root.appending(path: "IMG_1.JPG"), contents: "jpeg")
        try writeCatalogStoreFile(root.appending(path: "IMG_1.xmp"), contents: "<xmp/>")
        try writeCatalogStoreFile(root.appending(path: "notes.txt"), contents: "skip")

        let store = makeTestStore(location: .inMemory, scanCadence: .milliseconds(10))
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

    @Test func targetedDeleteRepairsCompanionPairing() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let media = root.appending(path: "shot.JPG")
        try writeCatalogStoreFile(media, contents: "jpeg")
        try writeCatalogStoreFile(root.appending(path: "shot.xmp"), contents: "<xmp/>")

        let recorder = FilesystemEventScanInvocationRecorder()
        let (watcher, emit) = CatalogFilesystemWatcher.testing()
        let store = makeTestStore(
            location: .inMemory,
            scanner: recordingLiveScanner(recorder),
            filesystemWatcher: watcher,
            scanCadence: .milliseconds(10)
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
