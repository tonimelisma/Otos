import Foundation
import GRDB
@testable import OtosKit
import Testing

/// ADR 0052 through the Store: a RAW and its JPEG are read as one stack with the order,
/// whatever the filter, and the user's key choice is kept on the member it names.
@Suite(.testDirectory)
@MainActor
struct PhotoStackStoreTests {
    @Test func theOrderIsReadWithItsPairs() async throws {
        try await withLibrary(["a/DSC1.ARW", "a/DSC1.JPG", "a/DSC2.JPG", "b/DSC1.JPG"]) { library in
            let ordered = try await library.ordered()
            #expect(ordered.ids.count == 4)
            let pair = try #require(ordered.stacks.stack(containing: library.id("a/DSC1.ARW")))
            #expect(Set(pair.members) == [library.id("a/DSC1.ARW"), library.id("a/DSC1.JPG")])
            #expect(pair.key == library.id("a/DSC1.JPG"))
            #expect(ordered.stacks.stack(containing: library.id("b/DSC1.JPG")) == nil)
            #expect(ordered.stacks.stack(containing: library.id("a/DSC2.JPG")) == nil)
        }
    }

    /// A filter that shows only RAWs still reads the pair, so the RAW is known to be one.
    @Test func aFilterNeverUnpairs() async throws {
        try await withLibrary(["DSC1.ARW", "DSC1.JPG"]) { library in
            let ordered = try await library.ordered(kinds: [.raw])
            #expect(ordered.ids == [library.id("DSC1.ARW")])
            #expect(ordered.stacks.stack(containing: library.id("DSC1.ARW")) != nil)
        }
    }

    @Test func makeKeyPhotoIsKeptOnTheChosenMemberAndUndoes() async throws {
        try await withLibrary(["DSC1.ARW", "DSC1.JPG"]) { library in
            let raw = library.id("DSC1.ARW"), jpeg = library.id("DSC1.JPG")
            let previous = try await library.store.setStackKeyChoices([raw: 1000, jpeg: nil], kind: .pair)
            #expect(previous == [raw: Int64?.none, jpeg: Int64?.none])
            #expect(try await library.ordered().stacks.stack(containing: jpeg)?.key == raw)

            _ = try await library.store.setStackKeyChoices(previous, kind: .pair)
            #expect(try await library.ordered().stacks.stack(containing: jpeg)?.key == jpeg)
        }
    }

    /// Stills whose metadata carries one burst identifier are read as one burst with the
    /// order, and a burst's key choice is kept apart from a pair's (ADR 0052).
    @Test func stillsSharingABurstIdentifierAreReadAsOneBurst() async throws {
        try await withLibrary(["IMG_1.HEIC", "IMG_2.HEIC", "IMG_3.HEIC"]) { library in
            let assets = try await library.store.mediaAssets(for: ["IMG_1.HEIC", "IMG_2.HEIC", "IMG_3.HEIC"].map(library.id))
            let results = assets.values.map { asset in
                EnrichmentResult(
                    id: asset.id,
                    metadata: AssetMetadata(
                        timestamps: [],
                        burstIdentifier: asset.id.relativePath.rawValue == "IMG_3.HEIC" ? nil : "B1"
                    ),
                    enrichedKind: .image,
                    thumbnailPath: nil,
                    sourceSize: asset.byteSize,
                    sourceMTimeSeconds: MediaAsset.mtimeSeconds(asset.contentModifiedAt),
                    contentHash: nil
                )
            }
            _ = await library.store.applyEnrichmentBatch(results)
            let first = library.id("IMG_1.HEIC"), second = library.id("IMG_2.HEIC")
            let burst = try #require(try await library.ordered().stacks.stack(containing: first))
            #expect(burst.id.kind == .burst)
            #expect(Set(burst.members) == [first, second])
            #expect(try await library.ordered().stacks.stack(containing: library.id("IMG_3.HEIC")) == nil)

            _ = try await library.store.setStackKeyChoices([second: 1000, first: nil], kind: .burst)
            #expect(try await library.ordered().stacks.stack(containing: first)?.key == second)
        }
    }

    /// A camera's continuous frames never stack, though their metadata carries the frame
    /// number the camera recorded: the number says where a frame stands in its sequence, not
    /// which sequence (ADR 0052). Burst A culled to its frame 2 and burst B, another day in
    /// another folder, culled to its frames 3 and 5 rise in capture order like one burst, and
    /// an intact burst numbered 1, 2 reads the same as A's frame 1 beside B's frame 2.
    @Test func aCamerasContinuousFramesNeverStack() async throws {
        let frames = [
            "2024/05/DSC0002.ARW": 2, "2024/05/DSC0002.JPG": 2,
            "2024/06/DSC0103.JPG": 3, "2024/06/DSC0105.JPG": 5,
            "2024/07/DSC0201.JPG": 1, "2024/07/DSC0202.JPG": 2,
        ]
        try await withLibrary(Array(frames.keys)) { library in
            let assets = try await library.store.mediaAssets(for: frames.keys.map(library.id))
            let results = assets.values.map { asset in
                EnrichmentResult(
                    id: asset.id,
                    metadata: AssetMetadata(
                        timestamps: [],
                        cameraMake: "SONY",
                        cameraModel: "ILCE-6700",
                        continuousShootingFrame: frames[asset.id.relativePath.rawValue]
                    ),
                    enrichedKind: asset.id.relativePath.fileExtension == "ARW" ? .raw : .image,
                    thumbnailPath: nil,
                    sourceSize: asset.byteSize,
                    sourceMTimeSeconds: MediaAsset.mtimeSeconds(asset.contentModifiedAt),
                    contentHash: nil
                )
            }
            _ = await library.store.applyEnrichmentBatch(results)
            let stacks = try await library.ordered().stacks
            #expect(stacks.burstOfMember.isEmpty)
            // The RAW+JPEG pair is still one photo.
            let pair = try #require(stacks.stack(containing: library.id("2024/05/DSC0002.ARW")))
            #expect(pair.id.kind == .pair)
            #expect(stacks.stack(containing: library.id("2024/06/DSC0103.JPG")) == nil)
            #expect(stacks.stack(containing: library.id("2024/07/DSC0201.JPG")) == nil)
        }
    }

    /// An import batch reads the stacks of its own folders and bursts, not every candidate of
    /// its libraries, and they are the stacks the whole library has for its rows: a pair
    /// whose RAW is not in the batch, and a burst whose other frame is in another folder,
    /// stay whole; a pair and a burst that hold no batch row are not read.
    @Test func anImportBatchReadsTheStacksOfItsOwnFoldersWhole() async throws {
        let files = [
            "a/DSC1.ARW", "a/DSC1.JPG", "a/DSC2.JPG",
            "b/DSC5.ARW", "b/DSC5.JPG",
            "c/IMG_1.HEIC", "d/IMG_2.HEIC",
            "e/IMG_7.HEIC", "e/IMG_8.HEIC",
        ]
        let bursts = ["c/IMG_1.HEIC": "B1", "d/IMG_2.HEIC": "B1", "e/IMG_7.HEIC": "B2", "e/IMG_8.HEIC": "B2"]
        try await withLibrary(files) { library in
            let assets = try await library.store.mediaAssets(for: bursts.keys.map(library.id))
            _ = await library.store.applyEnrichmentBatch(assets.values.map { asset in
                EnrichmentResult(
                    id: asset.id,
                    metadata: AssetMetadata(timestamps: [], burstIdentifier: bursts[asset.id.relativePath.rawValue]),
                    enrichedKind: .image,
                    thumbnailPath: nil,
                    sourceSize: asset.byteSize,
                    sourceMTimeSeconds: MediaAsset.mtimeSeconds(asset.contentModifiedAt),
                    contentHash: nil
                )
            })
            let batch = ImportBatchID(unixMilliseconds: 1_800_000_000_000)
            let stamp = try DatabaseQueue(path: library.databaseURL.path(percentEncoded: false))
            try await stamp.write { db in
                try db.execute(
                    sql: "UPDATE media_asset SET import_batch_unix_ms = ? WHERE relative_path IN ('a/DSC1.JPG', 'a/DSC2.JPG', 'c/IMG_1.HEIC')",
                    arguments: [batch.unixMilliseconds]
                )
            }
            try stamp.close()

            let whole = try await library.ordered()
            let ordered = try await library.store.orderedAssetIDs(
                for: CatalogQueryDescriptor(scope: .importBatch(batch)),
                availableLibraryPaths: [library.rootPath]
            )
            let built = try #require(ordered.builtStacks)
            #expect(Set(ordered.ids.map(\.relativePath.rawValue)) == ["a/DSC1.JPG", "a/DSC2.JPG", "c/IMG_1.HEIC"])
            #expect(built.span != .roots)
            // The folders a and c, and the burst's other frame in d.
            #expect(built.candidateCount == 5)
            let pair = try #require(whole.stacks.stack(containing: library.id("a/DSC1.JPG")))
            let burst = try #require(whole.stacks.stack(containing: library.id("c/IMG_1.HEIC")))
            #expect(Set(burst.members) == [library.id("c/IMG_1.HEIC"), library.id("d/IMG_2.HEIC")])
            #expect(ordered.stacks == CatalogStacks([pair, burst]))
        }
    }

    private struct Library {
        let store: CatalogStore
        let rootPath: LibraryRootPath
        let databaseURL: URL

        func id(_ path: String) -> MediaAssetID {
            MediaAssetID(libraryRootPath: rootPath, relativePath: MediaRelativePath(rawValue: path))
        }

        func ordered(kinds: Set<MediaKind> = []) async throws -> CatalogOrderedAssets {
            try await store.orderedAssetIDs(
                for: CatalogQueryDescriptor(scope: .library(rootPath), filter: MediaFilter(kinds: kinds)),
                availableLibraryPaths: [rootPath]
            )
        }
    }

    private func withLibrary(_ files: [String], _ body: (Library) async throws -> Void) async throws {
        let temp = try makeTestDirectory()
        let root = temp.appending(path: "Photos", directoryHint: .isDirectory)
        for file in files {
            let url = root.appending(path: file)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(file.utf8).write(to: url)
        }
        let databaseURL = temp.appending(path: "Catalog/catalog.sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let store = CatalogStore(location: .databaseFile(databaseURL), scanCadence: .milliseconds(5))
        do {
            try await store.addLibrary(url: root)
            let scanned = try await waitForCatalogStoreState(store) { !$0.isScanning }
            try #require(scanned.testAssets.count == files.count)
            let rootPath = try CatalogPath.normalizedExistingDirectoryPath(for: root)
            try await body(Library(store: store, rootPath: rootPath, databaseURL: databaseURL))
        } catch {
            await store.shutdown()
            throw error
        }
        await store.shutdown()
    }
}
