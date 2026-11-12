import Foundation
import GRDB
import MediaMetadata
@testable import OtosKit
import Testing

/// ADR 0041: a still and a movie that share a folder and Apple's content identifier, and are
/// the only still and movie there that do, are one Live Photo — one item whose movie is a
/// member of the still's.
@Suite(.testDirectory)
@MainActor
struct LivePhotoTests {
    private let identifier = "66E9019A-9CAF-4603-A6C3-2F22030B7C65"

    @Test func aStillAndItsMotionAreOneItem() async throws {
        try await withLibrary(["a/IMG_1.HEIC", "a/IMG_1.MOV", "a/IMG_2.JPG"]) { library in
            try await library.enrich("a/IMG_1.HEIC", kind: .image, contentIdentifier: identifier)
            try await library.enrich("a/IMG_1.MOV", kind: .video, contentIdentifier: identifier)
            try await library.enrich("a/IMG_2.JPG", kind: .image, contentIdentifier: nil)

            #expect(try await library.visible() == ["a/IMG_1.HEIC", "a/IMG_2.JPG"])
            #expect(try await library.visibleCount() == 2)
            #expect(try await library.visible(kinds: [.video]).isEmpty)
            #expect(try await library.store.livePhotoMotion(of: library.id("a/IMG_1.HEIC")) == library.id("a/IMG_1.MOV"))
            #expect(try await library.store.livePhotoMotion(of: library.id("a/IMG_2.JPG")) == nil)
        }
    }

    /// The pair needs its evidence: the same identifier, the same folder, exactly one still
    /// and one movie. A name proves nothing (the Takeout folder's `IMG_0002.JPG`).
    @Test func anythingLessThanOneStillAndOneMovieInOneFolderPairsNothing() async throws {
        let files = [
            "same-name/IMG_2.HEIC", "same-name/IMG_2.MP4", "same-name/IMG_2.JPG",
            "two-movies/IMG_3.HEIC", "two-movies/IMG_3.MOV", "two-movies/IMG_3b.MOV",
            "split/still/IMG_4.HEIC", "split/movie/IMG_4.MOV",
            "alone/IMG_5.MOV",
        ]
        try await withLibrary(files) { library in
            try await library.enrich("same-name/IMG_2.HEIC", kind: .image, contentIdentifier: "A")
            try await library.enrich("same-name/IMG_2.MP4", kind: .video, contentIdentifier: "A")
            try await library.enrich("same-name/IMG_2.JPG", kind: .image, contentIdentifier: nil)
            for name in ["two-movies/IMG_3.HEIC", "two-movies/IMG_3.MOV", "two-movies/IMG_3b.MOV"] {
                try await library.enrich(name, kind: name.hasSuffix("HEIC") ? .image : .video, contentIdentifier: "B")
            }
            try await library.enrich("split/still/IMG_4.HEIC", kind: .image, contentIdentifier: "C")
            try await library.enrich("split/movie/IMG_4.MOV", kind: .video, contentIdentifier: "C")
            try await library.enrich("alone/IMG_5.MOV", kind: .video, contentIdentifier: "D")

            let visible = try await library.visible()
            #expect(visible == Set(files).subtracting(["same-name/IMG_2.MP4"]))
        }
    }

    /// A movie read before its still shows on its own; reading the still makes them one
    /// item, and the write reports a structural change so the grid re-queries.
    @Test func theMotionLeavesTheGridWhenItsStillIsRead() async throws {
        try await withLibrary(["IMG_6.HEIC", "IMG_6.MOV"]) { library in
            try await library.enrich("IMG_6.MOV", kind: .video, contentIdentifier: identifier)
            #expect(try await library.visible() == ["IMG_6.HEIC", "IMG_6.MOV"])
            let changes = AsyncValueRecorder<CatalogStoreChange>()
            let changeStream = await library.store.changeNotifications()
            let changeTask = Task {
                for await change in changeStream {
                    await changes.append(change)
                }
            }
            defer { changeTask.cancel() }

            // The still's kind and date are what the scan already had: only the identifier
            // changes, and it changes which rows the grid shows.
            try await library.enrich("IMG_6.HEIC", kind: .image, contentIdentifier: identifier)

            _ = await changes.waitForValues { $0.last == .catalogChanged }
            #expect(try await library.visible() == ["IMG_6.HEIC"])
        }
    }

    @Test func moveToTrashTakesTheMotionWithItsStill() async throws {
        try await withLibrary(["IMG_7.HEIC", "IMG_7.MOV"]) { library in
            try await library.enrich("IMG_7.HEIC", kind: .image, contentIdentifier: identifier)
            try await library.enrich("IMG_7.MOV", kind: .video, contentIdentifier: identifier)

            let items = try await library.store.mediaTrashItems(for: [library.id("IMG_7.HEIC")])

            let members = try #require(items.first).members
            #expect(members.map(\.relativePath.rawValue).sorted() == ["IMG_7.HEIC", "IMG_7.MOV"])
            #expect(members.first { $0.relativePath.rawValue == "IMG_7.MOV" }?.role == .livePhotoMotion)
            #expect(members.last?.role == .primary)
        }
    }

    /// Import and reorganization name the movie with its still, whatever its own stem, so
    /// a date-time policy can never put the two in different folders.
    @Test func theMotionNamesInItsStillsBundle() async throws {
        try await withLibrary(["IMG_8.HEIC", "MOTION_8.MOV"]) { library in
            try await library.enrich("IMG_8.HEIC", kind: .image, contentIdentifier: identifier)
            try await library.enrich("MOTION_8.MOV", kind: .video, contentIdentifier: identifier)

            let facts = try #require(await library.store.planningMedia(for: library.rootPath))
            let motion = try #require(facts.first { $0.relativePath.rawValue == "MOTION_8.MOV" })
            #expect(motion.livePhotoStillPath?.rawValue == "IMG_8.HEIC")

            let policy = ImportPolicy(
                destinationFolderPolicy: .yearMonth,
                destinationNamePolicy: .captureDateTime,
                importSidecarFiles: false,
                deleteSourceAfterImport: false,
                autoEjectAfterImport: false
            )
            let bundles = ImportNaming.bundles(from: facts, policy: policy, capabilities: .caseInsensitive)
            #expect(bundles.count == 1)
            #expect(Set(bundles.first?.members.map(\.relativePath.rawValue) ?? []) == ["IMG_8.HEIC", "MOTION_8.MOV"])
        }
    }

    /// The loupe offers the motion of the Live Photo it shows (DES-106), and only of one.
    @Test func theLoupeOffersToPlayALivePhotosMotion() async throws {
        try await withLibrary(["IMG_9.HEIC", "IMG_9.MOV", "IMG_10.JPG"]) { library in
            try await library.enrich("IMG_9.HEIC", kind: .image, contentIdentifier: identifier)
            try await library.enrich("IMG_9.MOV", kind: .video, contentIdentifier: identifier)
            try await library.enrich("IMG_10.JPG", kind: .image, contentIdentifier: nil)
            let still = library.id("IMG_9.HEIC")
            let other = library.id("IMG_10.JPG")
            let model = makeEditModel(store: library.store, ids: [still, other])
            defer { model.editCommandTask?.cancel() }
            defer { model.editRenderTask?.cancel() }

            model.openLoupe(id: still)
            try await waitUntil { model.focusedLivePhotoMotion == library.id("IMG_9.MOV") }
            #expect(model.canPlayLivePhoto)
            #expect(!model.canTrimVideo)

            model.setFocus(other)
            #expect(model.focusedLivePhotoMotion == nil)
            try await waitUntil { model.focusedAssetKind == .image }
            #expect(!model.canPlayLivePhoto)
        }
    }

    // MARK: - Support

    private struct Library {
        let store: CatalogStore
        let rootPath: LibraryRootPath

        func id(_ path: String) -> MediaAssetID {
            MediaAssetID(libraryRootPath: rootPath, relativePath: MediaRelativePath(rawValue: path))
        }

        func enrich(_ path: String, kind: MediaKind, contentIdentifier: String?) async throws {
            let asset = try #require(try await catalogStoreTestState(store).testAssets.first { $0.id == id(path) })
            let outcome = await store.applyEnrichmentBatch([
                EnrichmentResult(
                    id: asset.id,
                    metadata: AssetMetadata(contentIdentifier: contentIdentifier),
                    enrichedKind: kind,
                    thumbnailPath: nil,
                    sourceSize: asset.byteSize,
                    sourceMTimeSeconds: MediaAsset.mtimeSeconds(asset.contentModifiedAt),
                    contentHash: .empty
                ),
            ])
            try #require(outcome == .applied(count: 1))
        }

        func visible(kinds: Set<MediaKind> = []) async throws -> Set<String> {
            let descriptor = CatalogQueryDescriptor(
                scope: .library(rootPath),
                filter: MediaFilter(kinds: kinds)
            )
            return try await Set(
                store.orderedAssetIDs(for: descriptor, availableLibraryPaths: [rootPath]).ids.map(\.relativePath.rawValue)
            )
        }

        func visibleCount() async throws -> Int {
            try await store.visibleAssetCount(for: .library(rootPath), availableLibraryPaths: [rootPath])
        }
    }

    private func withLibrary(
        _ files: [String],
        _ body: (Library) async throws -> Void
    ) async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Photos", directoryHint: .isDirectory)
        for file in files {
            let url = root.appending(path: file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(file.utf8).write(to: url)
        }
        let databaseURL = temp.appending(path: "Catalog/catalog.sqlite")
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let store = CatalogStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(5))
        do {
            try await store.addLibrary(url: root)
            let scanned = try await waitForCatalogStoreState(store) { !$0.isScanning }
            try #require(scanned.testAssets.count == files.count)
            let rootPath = try CatalogPath.normalizedExistingDirectoryPath(for: root)
            try await body(Library(store: store, rootPath: rootPath))
        } catch {
            await store.shutdown()
            throw error
        }
        await store.shutdown()
    }
}
