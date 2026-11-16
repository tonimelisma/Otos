import CoreGraphics
import Foundation
@testable import OtosKit
import Testing

/// The overlay's one lifecycle for derived files (ADR 0008): after renders, a re-render, a
/// file moved outside Otos and rendered again under its new path, a deleted file, a
/// camera's thumbnail, and the files a crash or an older build left behind, the derived
/// folder holds exactly the files the catalog's rows name.
@Suite(.testScope)
struct DerivedFileLifecycleTests {
    @Test func theDerivedFolderHoldsExactlyWhatTheRowsName() async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Generated", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, contents) in [("a.jpg", "jpeg a"), ("b.jpg", "jpeg bb"), ("c.jpg", "jpeg ccc")] {
            try writeCatalogStoreFile(root.appending(path: name), contents: contents)
        }
        let (watcher, emit) = CatalogFilesystemWatcher.testing()
        let databaseURL = temp.appending(path: "db/catalog.sqlite")
        let store = makeTestStore(location: .databaseFile(databaseURL), filesystemWatcher: watcher)
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: root)
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 3 }
        let directory = try #require(store.thumbnailDirectory)
        let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)
        let id: @Sendable (String) -> MediaAssetID = { name in
            MediaAssetID(libraryRootPath: rootPath, relativePath: MediaRelativePath(rawValue: name))
        }

        // Renders, then a re-render of one: the same deterministic names, overwritten.
        try await render(["a.jpg", "b.jpg", "c.jpg"].map(id), store: store, directory: directory)
        try await render([id("a.jpg")], store: store, directory: directory)
        try await expectFolderMatchesRows(directory, store)

        // A file moved outside Otos keeps its row and its images; rendered again under its
        // new path, its images take the new names and the old ones go.
        try FileManager.default.moveItem(at: root.appending(path: "b.jpg"), to: root.appending(path: "b-moved.jpg"))
        emit(FilesystemEvent(path: root.path(percentEncoded: false), flags: 0))
        _ = try await waitForCatalogStoreState(store) { state in
            !state.isScanning && state.testAssets.contains { $0.id == id("b-moved.jpg") }
        }
        try await render([id("b-moved.jpg")], store: store, directory: directory)
        try await expectFolderMatchesRows(directory, store)

        // A deleted file's row is purged with its images.
        try FileManager.default.removeItem(at: root.appending(path: "c.jpg"))
        emit(FilesystemEvent(path: root.appending(path: "c.jpg").path(percentEncoded: false), flags: 0))
        _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 2 }
        try await expectFolderMatchesRows(directory, store)

        // A camera's thumbnail is taken only by a row with none, in the write that names it.
        let staged = try ThumbnailStore.stageProvisionalJPEG(
            Data("camera".utf8), finalRelativeName: ThumbnailStore.relativeName(for: id("a.jpg")), in: directory
        )
        try await store.applyProvisionalThumbnails([id("a.jpg"): staged])
        #expect(try Data(contentsOf: ThumbnailStore.url(for: ThumbnailStore.relativeName(for: id("a.jpg")), in: directory))
            != Data("camera".utf8), "a rendered thumbnail is never replaced by the camera's")
        try await expectFolderMatchesRows(directory, store)

        // What a crash between a promotion and its row, or an older build, left: removed by
        // the launch's reconciliation, which then reports the folder by kind.
        // The purged file's own names are left over too: no present row derives them.
        let purged = [
            ThumbnailStore.relativeName(for: id("c.jpg")), ThumbnailStore.previewRelativeName(for: id("c.jpg")),
        ]
        for leftover in ["0123abcd.jpg", "0123abcd.heic", "thumb.jpg.tmp-1"] + purged {
            try Data("left".utf8).write(to: directory.appending(path: leftover))
        }
        // A file of a present row's own identity that its column does not name (yet): a write
        // that promoted it and has not named it, or a row about to write that name again. The
        // row writes exactly this name when it renders, so it is never removed.
        let unnamedOwn = ThumbnailStore.faceFramesRelativeName(for: id("a.jpg"))
        try Data("frames".utf8).write(to: directory.appending(path: unnamedOwn))

        let census = try #require(try await store.reconcileDerivedFiles())
        let rows = try await named(store)
        #expect(try listed(directory) == rows.union([unnamedOwn]))
        #expect(census.files[.thumbnail] == 2)
        #expect(census.files[.preview] == 2)
        #expect(census.files[.faceFrames] == 1)
        #expect(census.files[.other, default: 0] == 0)
        await store.shutdown()
    }

    /// Renders `ids`: a staged thumbnail and preview each, applied as enrichment applies them.
    private func render(_ ids: [MediaAssetID], store: CatalogStore, directory: URL) async throws {
        let assets = try await store.mediaAssets(for: ids)
        let image = try tinyImage()
        var results: [EnrichmentResult] = []
        for id in ids {
            let asset = try #require(assets[id])
            try results.append(EnrichmentResult(
                id: id,
                metadata: AssetMetadata(),
                thumbnailPath: nil,
                sourceSize: asset.byteSize,
                sourceMTimeSeconds: MediaAsset.mtimeSeconds(asset.contentModifiedAt),
                contentHash: .empty,
                generatedThumbnail: ThumbnailStore.stage(
                    image, finalRelativeName: ThumbnailStore.relativeName(for: id), in: directory
                ),
                generatedPreview: ThumbnailStore.stagePreview(
                    image, finalRelativeName: ThumbnailStore.previewRelativeName(for: id), in: directory
                )
            ))
        }
        #expect(await store.applyEnrichmentBatch(results) == .applied(count: ids.count))
    }

    private func expectFolderMatchesRows(_ directory: URL, _ store: CatalogStore) async throws {
        let rows = try await named(store)
        #expect(try listed(directory) == rows)
    }

    /// The derived folder's top-level files (staging is a running write's).
    private func listed(_ directory: URL) throws -> Set<String> {
        try Set(DerivedFileReconciliation.list(directory).map(\.name))
    }

    /// Every derived name the rows hold.
    private func named(_ store: CatalogStore) async throws -> Set<String> {
        let ids = try await catalogStoreTestState(store).testAssets.map(\.id)
        let details = try await store.mediaTileDetails(for: ids)
        return Set(details.values.flatMap { [$0.thumbnailPath, $0.previewPath].compactMap(\.self) })
    }

    private func tinyImage() throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        return try #require(context.makeImage())
    }
}
