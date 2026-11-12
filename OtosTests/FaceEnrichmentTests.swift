import CoreGraphics
import CoreServices
import Foundation
import ImageIO
@testable import OtosKit
import Synchronization
import Testing

/// Faces as an enrichment product (ADR 0047): which claims owe them, how one read of a still
/// produces them, and how the catalog stores, replaces, moves and purges them.
@Suite(.testDirectory)
struct FaceEnrichmentTests {
    /// What the stand-in analyzer was handed.
    private final class AnalysisRecorder: Sendable {
        private let sizes = Mutex<[CGSize]>([])

        func record(_ image: CGImage) {
            sizes.withLock { $0.append(CGSize(width: image.width, height: image.height)) }
        }

        var imageSizes: [CGSize] {
            sizes.withLock { $0 }
        }
    }

    // MARK: - Which claims owe faces

    /// A fixed library's row owes faces; a card's second pass and a metadata claim never do,
    /// because a card's rows are read for faces once imported into a library.
    @Test func onlyALibraryClaimOwesFaces() {
        let owed = Self.asset(facesStamped: false)

        #expect(owed.needsEnrichment(.library))
        #expect(!owed.needsEnrichment(.cardProducts))
        #expect(!owed.needsEnrichment(.metadata))
        #expect(EnrichmentScope(claim: .library, asset: owed) == [.faces])
        #expect(EnrichmentScope(claim: .cardProducts, asset: owed).isEmpty)
        #expect(!EnrichmentScope(claim: .metadata, asset: owed).contains(.faces))

        let read = Self.asset(facesStamped: true)
        #expect(!read.needsEnrichment(.library))
    }

    // MARK: - One read of a still

    /// A still is read once for its faces, from the original turned upright at full
    /// resolution, and the analyzer's faces come back as the result's faces.
    @Test func aStillIsReadForItsFacesAtFullResolution() async throws {
        let url = SourceTree.mediaFixtures.appending(path: "jpeg-exif-offset-date.jpg")
        let recorder = AnalysisRecorder()
        let face = Self.face(seed: 1)
        let expectedSize = try Self.uprightSize(of: url)
        let enricher = try MediaEnricher.live(
            thumbnailDirectory: makeTestDirectory(),
            analyzeFaces: { image in
                recorder.record(image)
                return FaceAnalysis(faces: [face], rejectedForQuality: 0, rejectedAsNoPerson: 0, rejectedForAlignment: 0, rejectedForLandmarks: 0)
            }
        )

        let outcome = await enricher.enrich(Self.id("a.jpg"), .localFile(url), 100, 1000, [.rendering, .faces], nil)

        guard case let .complete(result) = outcome else {
            Issue.record("expected .complete, got \(outcome)")
            return
        }
        #expect(result.faces == EnrichedFaces(faces: [face], analysisRevision: FaceAnalyzer.revision))
        #expect(result.rendering?.generatedPreview != nil)
        #expect(recorder.imageSizes == [expectedSize])
    }

    /// A video has no faces Otos reads: it is stamped with none and never handed to the
    /// analyzer.
    @Test func aVideoHasNoFacesAndIsNotAnalysed() async throws {
        let url = SourceTree.mediaFixtures.appending(path: "mov-no-embedded-capture-date.mov")
        let recorder = AnalysisRecorder()
        let enricher = try MediaEnricher.live(
            thumbnailDirectory: makeTestDirectory(),
            analyzeFaces: { image in
                recorder.record(image)
                return FaceAnalysis(faces: [], rejectedForQuality: 0, rejectedAsNoPerson: 0, rejectedForAlignment: 0, rejectedForLandmarks: 0)
            }
        )

        let outcome = await enricher.enrich(Self.id("a.mov"), .localFile(url), 100, 1000, [.faces], nil)

        guard case let .complete(result) = outcome else {
            Issue.record("expected .complete, got \(outcome)")
            return
        }
        #expect(result.faces == .noneFound)
        #expect(recorder.imageSizes.isEmpty)
    }

    /// A failed analysis is not "no faces": nothing is stamped and the row is retried.
    @Test func aFailedAnalysisIsRetriedNotStampedEmpty() async throws {
        struct AnalysisFailed: Error {}
        let url = SourceTree.mediaFixtures.appending(path: "jpeg-exif-offset-date.jpg")
        let enricher = try MediaEnricher.live(
            thumbnailDirectory: makeTestDirectory(),
            analyzeFaces: { _ in throw AnalysisFailed() }
        )

        let outcome = await enricher.enrich(Self.id("a.jpg"), .localFile(url), 100, 1000, [.faces], nil)

        guard case .transient = outcome else {
            Issue.record("expected .transient, got \(outcome)")
            return
        }
    }

    // MARK: - The catalog

    /// A reading's faces are stored with its stamp and read back as they were found; a
    /// later reading replaces every one of them.
    @Test func aReadingStoresItsFacesAndTheNextReplacesThem() async throws {
        let library = try await ScannedLibrary.make(in: makeTestDirectory(), files: ["a.jpg"])
        let first = [Self.face(seed: 1), Self.face(seed: 2)]

        try await library.store.applyEnrichmentBatch([library.result(for: "a.jpg", faces: first)])

        #expect(try await library.store.faces(of: library.id("a.jpg")) == first)
        let enriched = try #require(try await catalogStoreTestState(library.store).testAssets.first)
        #expect(!enriched.needsEnrichment(.library))

        let second = [Self.face(seed: 3)]
        try await library.store.applyEnrichmentBatch([library.result(for: "a.jpg", faces: second)])
        #expect(try await library.store.faces(of: library.id("a.jpg")) == second)
        await library.store.shutdown()
    }

    /// A reading of bytes the file no longer has is rejected whole: no faces are stored and
    /// the row still owes them.
    @Test func aReadingOfOtherBytesStoresNoFaces() async throws {
        let library = try await ScannedLibrary.make(in: makeTestDirectory(), files: ["a.jpg"])

        try await library.store.applyEnrichmentBatch([
            library.result(for: "a.jpg", faces: [Self.face(seed: 1)], sizeOffset: 1),
        ])

        #expect(try await library.store.faces(of: library.id("a.jpg")).isEmpty)
        let asset = try #require(try await catalogStoreTestState(library.store).testAssets.first)
        #expect(asset.needsEnrichment(.library))
        await library.store.shutdown()
    }

    /// A rename seen as file events moves the row, and its faces go with it (ADR 0034).
    @Test func aRenamedPhotoKeepsItsFaces() async throws {
        let library = try await ScannedLibrary.make(in: makeTestDirectory(), files: ["before.jpg"])
        let faces = [Self.face(seed: 1)]
        try await library.store.applyEnrichmentBatch([library.result(for: "before.jpg", faces: faces)])

        let original = library.root.appending(path: "before.jpg")
        let renamed = library.root.appending(path: "after.jpg")
        try FileManager.default.moveItem(at: original, to: renamed)
        let flags = UInt32(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsFile)
        library.emit(FilesystemEvent(path: original.path, flags: flags))
        library.emit(FilesystemEvent(path: renamed.path, flags: flags))
        _ = try await waitForCatalogStoreState(library.store) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.map(\.relativePath.rawValue) == ["after.jpg"]
        }

        #expect(try await library.store.faces(of: library.id("after.jpg")) == faces)
        #expect(try await library.store.faces(of: library.id("before.jpg")).isEmpty)
        await library.store.shutdown()
    }

    /// A photo proven deleted takes its faces with it.
    @Test func aRemovedPhotoTakesItsFacesWithIt() async throws {
        let library = try await ScannedLibrary.make(in: makeTestDirectory(), files: ["a.jpg", "b.jpg"])
        try await library.store.applyEnrichmentBatch([library.result(for: "a.jpg", faces: [Self.face(seed: 1)])])

        let file = library.root.appending(path: "a.jpg")
        try FileManager.default.removeItem(at: file)
        library.emit(FilesystemEvent(
            path: file.path,
            flags: UInt32(kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsFile)
        ))
        _ = try await waitForCatalogStoreState(library.store) { snapshot in
            !snapshot.isScanning && snapshot.testAssets.map(\.relativePath.rawValue) == ["b.jpg"]
        }

        #expect(try await library.store.faces(of: library.id("a.jpg")).isEmpty)
        await library.store.shutdown()
    }

    // MARK: - Fixtures

    /// A library on disk, scanned, whose catalog hears file events from the test.
    struct ScannedLibrary {
        let store: CatalogStore
        let root: URL
        let rootPath: LibraryRootPath
        let emit: @Sendable (FilesystemEvent) -> Void

        static func make(in directory: URL, files: [String]) async throws -> ScannedLibrary {
            let root = directory.appending(path: "Pictures", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for name in files {
                try writeCatalogStoreFile(root.appending(path: name), contents: "jpeg \(name)")
            }
            let (watcher, emit) = CatalogFilesystemWatcher.testing()
            let store = CatalogStore(location: .inMemory, filesystemWatcher: watcher, scanCadence: .milliseconds(10))
            try await store.start(scansSavedLibraries: false)
            try await store.addLibrary(url: root)
            _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == files.count }
            return try ScannedLibrary(
                store: store, root: root, rootPath: CatalogPath.normalizedDirectoryPath(for: root), emit: emit
            )
        }

        func id(_ name: String) -> MediaAssetID {
            MediaAssetID(libraryRootPath: rootPath, relativePath: MediaRelativePath(rawValue: name))
        }

        /// Every product current for the file as scanned, with `faces`; `sizeOffset` makes
        /// the result name other bytes.
        func result(for name: String, faces: [DetectedFace], sizeOffset: Int64 = 0) async throws -> EnrichmentResult {
            let asset = try #require(try await store.mediaAssets(for: [id(name)])[id(name)])
            let size = try #require(asset.byteSize)
            return EnrichmentResult(
                id: id(name),
                metadata: AssetMetadata(),
                thumbnailPath: nil,
                sourceSize: size + sizeOffset,
                sourceMTimeSeconds: MediaAsset.mtimeSeconds(asset.contentModifiedAt),
                contentHash: .empty,
                faces: EnrichedFaces(faces: faces, analysisRevision: FaceAnalyzer.revision)
            )
        }
    }

    static func id(_ name: String) -> MediaAssetID {
        MediaAssetID(libraryRootPath: LibraryRootPath(rawValue: "/Lib"), relativePath: MediaRelativePath(rawValue: name))
    }

    /// A row of 100 bytes whose metadata, rendering and digest are current.
    static func asset(facesStamped: Bool) -> MediaAsset {
        MediaAsset(
            libraryRootPath: LibraryRootPath(rawValue: "/Lib"),
            relativePath: MediaRelativePath(rawValue: "a.jpg"),
            name: "a.jpg",
            contentTypeIdentifier: "public.jpeg",
            byteSize: 100,
            createdAt: nil,
            contentModifiedAt: Date(timeIntervalSince1970: 1000),
            metadataSourceSize: 100,
            metadataSourceMTimeSeconds: 1000,
            renderedSourceSize: 100,
            renderedSourceMTimeSeconds: 1000,
            contentHash: .empty,
            contentHashSourceSize: 100,
            contentHashSourceMTimeSeconds: 1000,
            facesSourceSize: facesStamped ? 100 : nil,
            facesSourceMTimeSeconds: facesStamped ? 1000 : nil
        )
    }

    /// A face whose values survive Float32 storage exactly.
    static func face(seed: Int) -> DetectedFace {
        let quarter = Double(seed) / 16
        return DetectedFace(
            box: CGRect(x: quarter, y: 0.25, width: 0.125, height: 0.25),
            landmarks: FaceAlignment.Landmarks(
                leftEye: CGPoint(x: quarter, y: 0.375), rightEye: CGPoint(x: quarter + 1 / 64, y: 0.375),
                nose: CGPoint(x: quarter + 2 / 64, y: 0.375), leftMouth: CGPoint(x: quarter + 3 / 64, y: 0.375),
                rightMouth: CGPoint(x: quarter + 4 / 64, y: 0.375)
            ),
            quality: 0.5,
            embedding: (0 ..< FaceEmbeddingModel.dimensions).map { Float(($0 + seed) % 7) / 8 }
        )
    }

    /// The fixture's size once turned upright by its orientation.
    static func uprightSize(of url: URL) throws -> CGSize {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try #require(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try #require(properties[kCGImagePropertyPixelHeight] as? Int)
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }
}
