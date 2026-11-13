import CoreGraphics
import Foundation
import ImageIO
@testable import OtosKit
import Synchronization
import Testing

/// A library video's faces (ADR 0047): read by enrichment from six frames, one face per
/// person, stored with the frame each was read in, and shown and counted as a video's.
@Suite(.testDirectory)
struct VideoFaceTests {
    // MARK: - One face per person

    /// Frames of one person are one face, kept by its sharpest reading; another person in
    /// the video stays a face of their own.
    @Test func eachPersonInAVideoIsOneFaceKeptByItsSharpestReading() {
        let frames = [
            [Self.face(person: 1, quality: 0.4), Self.face(person: 2, quality: 0.6)],
            [Self.face(person: 1, quality: 0.7)],
            [Self.face(person: 2, quality: 0.5), Self.face(person: 1, quality: 0.3)],
        ]
        let kept = VideoFaceReader.onePerPerson(frames)
        #expect(kept.map(\.frame) == [0, 1])
        #expect(kept.map(\.face) == [1, 0])
    }

    /// Two faces of one frame are two people, however alike: twins side by side stay two.
    @Test func twoFacesOfOneFrameAreNeverOnePerson() {
        let kept = VideoFaceReader.onePerPerson([[Self.face(person: 1, quality: 0.5), Self.face(person: 1, quality: 0.4)]])
        #expect(kept.count == 2)
    }

    /// A face the model cannot tell anyone by is never joined with another, as assignment
    /// never compares it with one.
    @Test func anUnrecognisableFaceIsNeverJoined() {
        let blurred = DetectedFace(
            box: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
            landmarks: Self.face(person: 1, quality: 0.5).landmarks,
            quality: 0.5,
            embedding: FaceRecognisability.direction
        )
        let kept = VideoFaceReader.onePerPerson([[blurred], [blurred], [Self.face(person: 1, quality: 0.5)]])
        #expect(kept.count == 3)
    }

    /// The video's frames are each read once; the kept faces' frame is staged as one image of
    /// the face frames, which the face names by its place.
    @Test func aVideosFramesAreReadAndTheKeptFramesStaged() async throws {
        let directory = try makeTestDirectory().appending(path: "Thumbnails", directoryHint: .isDirectory)
        let calls = Mutex(0)
        let read = try await VideoFaceReader.read(
            SourceTree.mediaFixtures.appending(path: "mov-no-embedded-capture-date.mov"),
            analyzeFaces: { _ in
                let call = calls.withLock { count in
                    count += 1
                    return count
                }
                // The same person in every frame, sharpest in the third.
                return FaceAnalysis(
                    faces: [Self.face(person: 1, quality: call == 3 ? 0.9 : 0.4)],
                    rejectedForQuality: 0, rejectedAsNoPerson: 0, rejectedForAlignment: 0, rejectedForLandmarks: 0
                )
            },
            framesRelativeName: "clip.faces.heic",
            in: directory
        )
        #expect(calls.withLock { $0 } == VideoFaceReader.samples.count)
        #expect(read.faces.map(\.frameIndex) == [0])
        #expect(read.faces.first?.face.quality == 0.9)
        let staged = try #require(read.frames)
        #expect(staged.finalRelativePath == "clip.faces.heic")
        let source = try #require(CGImageSourceCreateWithURL(
            ThumbnailStore.url(for: staged.stagedRelativePath, in: directory) as CFURL, nil
        ))
        #expect(CGImageSourceGetCount(source) == 1)
    }

    /// A video with no face stages nothing.
    @Test func aVideoWithNoFaceStagesNoFrames() async throws {
        let directory = try makeTestDirectory()
        let read = try await VideoFaceReader.read(
            SourceTree.mediaFixtures.appending(path: "mov-no-embedded-capture-date.mov"),
            analyzeFaces: { _ in
                FaceAnalysis(faces: [], rejectedForQuality: 0, rejectedAsNoPerson: 0, rejectedForAlignment: 0, rejectedForLandmarks: 0)
            },
            framesRelativeName: "clip.faces.heic",
            in: directory
        )
        #expect(read == .noneFound)
    }

    // MARK: - The claim

    /// A library's video owes its faces until its frames are read; a still never does, since
    /// its faces come from its preview, and no claim but a library's reads them.
    @Test func aLibraryVideoOwesItsFacesAndAStillNever() {
        let video = Self.asset(name: "clip.mov", kind: .video, facesStamped: false)
        #expect(video.needsEnrichment(.library))
        #expect(EnrichmentScope(claim: .library, asset: video) == .videoFaces)
        #expect(!video.needsEnrichment(.products))
        #expect(EnrichmentScope(claim: .products, asset: video).isEmpty)
        #expect(!Self.asset(name: "clip.mov", kind: .video, facesStamped: true).needsEnrichment(.library))
        let still = Self.asset(name: "a.jpg", kind: .image, facesStamped: false)
        #expect(!still.needsEnrichment(.library))
        #expect(EnrichmentScope(claim: .library, asset: still).isEmpty)
    }

    // MARK: - The catalog

    /// A video's reading stores each face with its frame, promotes the frames, and shows the
    /// face as a video's: its tile is cut from its frame. Before, the video counts as one not
    /// yet checked; removing the library deletes the frames.
    @Test func aVideosFacesAreStoredWithTheirFramesAndPurgedWithIt() async throws {
        let fixture = try await VideoLibrary.make(in: makeTestDirectory())
        #expect(try await fixture.store.peopleSnapshot(availableLibraryPaths: [fixture.rootPath]).unchecked == MediaCount(videos: 1))

        let frames = try ThumbnailStore.stageFaceFrames(
            [Self.image(), Self.image()], finalRelativeName: ThumbnailStore.faceFramesRelativeName(for: fixture.id), in: fixture.thumbnailDirectory
        )
        let outcome = try await fixture.apply(EnrichedVideoFaces(
            faces: [.init(face: Self.face(person: 1, quality: 0.5), frameIndex: 0), .init(face: Self.face(person: 2, quality: 0.5), frameIndex: 1)],
            analysisRevision: FaceAnalyzer.revision,
            frames: frames
        ))
        #expect(outcome == .applied(count: 1))

        let snapshot = try await fixture.store.peopleSnapshot(availableLibraryPaths: [fixture.rootPath])
        #expect(snapshot.unchecked == MediaCount())
        let second = try #require(snapshot.tiles[FaceID(asset: fixture.id, index: 1)])
        #expect(second.isInVideo)
        #expect(second.preview == FacePreview(name: frames.finalRelativePath, recipe: .neutral, image: 1))
        let file = ThumbnailStore.url(for: frames.finalRelativePath, in: fixture.thumbnailDirectory)
        #expect(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
        let asset = try #require(try await fixture.store.mediaAssets(for: [fixture.id])[fixture.id])
        #expect(!asset.needsEnrichment(.library))

        _ = try await fixture.store.removeLibrary(path: fixture.rootPath)
        #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
        await fixture.store.shutdown()
    }

    /// A new reading that finds no face takes the video's faces and its frames.
    @Test func aReadingWithNoFaceDeletesTheFrames() async throws {
        let fixture = try await VideoLibrary.make(in: makeTestDirectory())
        let frames = try ThumbnailStore.stageFaceFrames(
            [Self.image()], finalRelativeName: ThumbnailStore.faceFramesRelativeName(for: fixture.id), in: fixture.thumbnailDirectory
        )
        _ = try await fixture.apply(EnrichedVideoFaces(
            faces: [.init(face: Self.face(person: 1, quality: 0.5), frameIndex: 0)], analysisRevision: FaceAnalyzer.revision, frames: frames
        ))
        _ = try await fixture.apply(.noneFound)

        #expect(try await fixture.store.peopleSnapshot().faces.isEmpty)
        let file = ThumbnailStore.url(for: frames.finalRelativePath, in: fixture.thumbnailDirectory)
        #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
        await fixture.store.shutdown()
    }

    // MARK: - Words

    /// A count says what it holds: photos until one is a video, videos when all are.
    @Test func aCountNamesWhatItHolds() {
        #expect(MediaCount(photos: 1).text == "1 photo")
        #expect(MediaCount(photos: 3).text == "3 photos")
        #expect(MediaCount(videos: 1).text == "1 video")
        #expect(MediaCount(videos: 2).title == "2 Videos")
        #expect(MediaCount(photos: 13, videos: 1).text == "14 photos and videos")
        #expect(MediaCount(photos: 13, videos: 1).title == "14 Photos & Videos")
        #expect(MediaCount(photos: 1200).text == "1,200 photos")
        #expect(FaceActTitle.name(MediaCount(photos: 2, videos: 1)) == "Name 3 Photos & Videos")
    }

    // MARK: - Fixtures

    /// A face of `person`: a unit embedding along its own axis, recognisable and like no one
    /// else's.
    static func face(person: Int, quality: Float) -> DetectedFace {
        var embedding = [Float](repeating: 0, count: FaceEmbeddingModel.dimensions)
        embedding[person] = 1
        return DetectedFace(
            box: CGRect(x: 0.1 * Double(person), y: 0.2, width: 0.1, height: 0.2),
            landmarks: FaceEnrichmentTests.face(seed: person).landmarks,
            quality: quality,
            embedding: FaceEmbedding(normalizing: embedding)!
        )
    }

    static func asset(name: String, kind: MediaKind, facesStamped: Bool) -> MediaAsset {
        MediaAsset(
            libraryRootPath: LibraryRootPath(rawValue: "/Lib"),
            relativePath: MediaRelativePath(rawValue: name),
            name: name,
            contentTypeIdentifier: nil,
            byteSize: 100,
            createdAt: nil,
            contentModifiedAt: Date(timeIntervalSince1970: 1000),
            bestKind: kind,
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

    static func image() -> CGImage {
        let context = CGContext(
            data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 36))
        return context.makeImage()!
    }

    /// A library on disk holding one video, scanned, with a catalog that keeps its derived
    /// images.
    struct VideoLibrary {
        let store: CatalogStore
        let rootPath: LibraryRootPath
        let id: MediaAssetID
        let thumbnailDirectory: URL

        static func make(in directory: URL) async throws -> VideoLibrary {
            let root = directory.appending(path: "Videos", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try writeCatalogStoreFile(root.appending(path: "clip.mov"), contents: "movie")
            let databaseURL = directory.appending(path: "db/catalog.sqlite")
            let (watcher, _) = CatalogFilesystemWatcher.testing()
            let store = CatalogStore(location: .databaseFile(databaseURL), filesystemWatcher: watcher)
            try await store.start(scansSavedLibraries: false)
            try await store.addLibrary(url: root)
            _ = try await waitForCatalogStoreState(store) { !$0.isScanning && $0.testAssets.count == 1 }
            let rootPath = try CatalogPath.normalizedDirectoryPath(for: root)
            return VideoLibrary(
                store: store,
                rootPath: rootPath,
                id: MediaAssetID(libraryRootPath: rootPath, relativePath: MediaRelativePath(rawValue: "clip.mov")),
                thumbnailDirectory: databaseURL.deletingLastPathComponent().appending(path: "Thumbnails", directoryHint: .isDirectory)
            )
        }

        /// Writes `faces` as an enrichment of the video as scanned, with every other product.
        func apply(_ faces: EnrichedVideoFaces) async throws -> EnrichmentApplyOutcome {
            let asset = try #require(try await store.mediaAssets(for: [id])[id])
            return await store.applyEnrichmentBatch([EnrichmentResult(
                id: id,
                metadata: AssetMetadata(),
                thumbnailPath: nil,
                sourceSize: asset.byteSize,
                sourceMTimeSeconds: MediaAsset.mtimeSeconds(asset.contentModifiedAt),
                contentHash: .empty,
                videoFaces: faces
            )])
        }
    }
}
