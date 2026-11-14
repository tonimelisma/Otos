import AVFoundation
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
            AVURLAsset(url: SourceTree.mediaFixtures.appending(path: "mov-no-embedded-capture-date.mov")),
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
            AVURLAsset(url: SourceTree.mediaFixtures.appending(path: "mov-no-embedded-capture-date.mov")),
            analyzeFaces: { _ in
                FaceAnalysis(faces: [], rejectedForQuality: 0, rejectedAsNoPerson: 0, rejectedForAlignment: 0, rejectedForLandmarks: 0)
            },
            framesRelativeName: "clip.faces.heic",
            in: directory
        )
        #expect(read == .noneFound)
    }

    // MARK: - An Immich account's videos

    /// An account's video is read in byte ranges from its server, never downloaded whole:
    /// its six frames are each read through the ranges the server answers.
    @Test func anAccountVideosFramesAreReadInRanges() async throws {
        let directory = try makeTestDirectory()
        let file = try Data(contentsOf: Self.fixture)
        let remote = RemoteVideoAsset(reader: Self.reader(serving: file), filename: "abc/clip.mov")
        let calls = Mutex(0)
        let read = try await VideoFaceReader.read(
            remote.asset,
            analyzeFaces: { _ in
                calls.withLock { $0 += 1 }
                return Self.analysis([Self.face(person: 1, quality: 0.5)])
            },
            framesRelativeName: "clip.faces.heic",
            in: directory
        )
        #expect(!remote.failed)
        #expect(calls.withLock { $0 } == VideoFaceReader.samples.count)
        #expect(read.faces.count == 1)
        #expect(remote.cost.bytes > 0)
    }

    /// A server that stops answering mid-read leaves the video owed: the read is unanswered,
    /// never a video with no faces. One that answers gives the faces, and reads nothing it
    /// was not asked for.
    @Test func anAccountVideoTheServerStopsSendingIsUnansweredNotFaceless() async throws {
        let directory = try makeTestDirectory()
        let file = try Data(contentsOf: Self.fixture)
        let enricher = MediaEnricher.live(
            thumbnailDirectory: directory,
            analyzeFaces: { _ in Self.analysis([Self.face(person: 1, quality: 0.5)]) }
        )
        let id = MediaAssetID(libraryRootPath: LibraryRootPath(rawValue: "/Account"), relativePath: MediaRelativePath(rawValue: "abc/clip.mov"))
        let size = Int64(file.count)

        let stopped = await enricher.enrich(
            id, .remoteRanges(Self.reader(serving: file, answering: 1), relativePath: id.relativePath), size, 1000, [.videoFaces], nil
        )
        guard case .unanswered = stopped else {
            Issue.record("expected .unanswered, got \(stopped)")
            return
        }

        let answered = await enricher.enrich(
            id, .remoteRanges(Self.reader(serving: file), relativePath: id.relativePath), size, 1000, [.videoFaces], nil
        )
        guard case let .complete(result) = answered else {
            Issue.record("expected .complete, got \(answered)")
            return
        }
        #expect(result.videoFaces?.faces.count == 1)
        #expect(result.metadata == nil)
    }

    /// An Immich account's video owes its faces under the account claim, beside its metadata;
    /// a camera's videos are never read for faces.
    @Test func anAccountVideoOwesItsFacesUnderTheAccountClaim() {
        #expect(LibraryRootKind.immichAccount.firstClaim == .account)
        #expect(LibraryRootKind.deviceMTP.firstClaim == .metadata)
        #expect(LibraryRootKind.removableVolume.firstClaim == .metadata)
        let video = Self.asset(name: "abc/clip.mov", kind: .video, facesStamped: false)
        #expect(video.needsEnrichment(.account))
        #expect(EnrichmentScope(claim: .account, asset: video) == .videoFaces)
        #expect(EnrichmentScope(claim: .account, asset: video).isReadableInRanges)
        #expect(!Self.asset(name: "abc/clip.mov", kind: .video, facesStamped: true).needsEnrichment(.account))
        #expect(!Self.asset(name: "abc/a.jpg", kind: .image, facesStamped: false).needsEnrichment(.account))
    }

    static let fixture = SourceTree.mediaFixtures.appending(path: "mov-no-embedded-capture-date.mov")

    static func analysis(_ faces: [DetectedFace]) -> FaceAnalysis {
        FaceAnalysis(faces: faces, rejectedForQuality: 0, rejectedAsNoPerson: 0, rejectedForAlignment: 0, rejectedForLandmarks: 0)
    }

    /// A server holding `file` that answers its first `answering` reads, every read when nil,
    /// and fails the rest as a lost connection.
    static func reader(serving file: Data, answering: Int? = nil) -> RemoteRangeReader {
        let calls = Mutex(0)
        return RemoteRangeReader(size: UInt64(file.count)) { offset, length, completion in
            let call = calls.withLock { count in
                count += 1
                return count
            }
            if let answering, call > answering {
                completion(.failure(URLError(.networkConnectionLost)))
                return .settled
            }
            let start = Int(offset)
            completion(.success(file.subdata(in: start ..< min(file.count, start + length))))
            return .settled
        }
    }

    // MARK: - The claim

    /// A library's video owes its faces until its frames are read; a still never does, since
    /// A remote video whose server stops answering partway is an error whose asset says the
    /// server failed, so enrichment paces the row (`.unanswered`) instead of stamping the
    /// frames it got, or calling the video unreadable.
    @Test func aRemoteVideoTheServerStopsSendingIsAFailedReadNotAFacelessOne() async throws {
        let data = try Data(contentsOf: SourceTree.mediaFixtures.appending(path: "mov-no-embedded-capture-date.mov"))
        struct Unanswered: Error {}
        let reader = RemoteRangeReader(size: UInt64(data.count)) { offset, length, completion in
            guard offset < UInt64(data.count / 3) else {
                completion(.failure(Unanswered()))
                return .settled
            }
            let start = Int(offset)
            completion(.success(data.subdata(in: start ..< min(data.count, start + length))))
            return .settled
        }
        let remote = RemoteVideoAsset(reader: reader, filename: "clip.mov")
        await #expect(throws: (any Error).self) {
            try await VideoFaceReader.read(
                remote.asset,
                analyzeFaces: { _ in
                    FaceAnalysis(faces: [], rejectedForQuality: 0, rejectedAsNoPerson: 0, rejectedForAlignment: 0, rejectedForLandmarks: 0)
                },
                framesRelativeName: "frames.heic", in: makeTestDirectory()
            )
        }
        #expect(remote.failed)
    }

    /// A video whose frames cannot be read is an error, not a video without faces: nothing is
    /// stamped and it is read again, and the analyser never sees a frame.
    @Test func aVideoThatDoesNotDecodeIsNotStampedAsFaceless() async throws {
        let directory = try makeTestDirectory()
        let video = directory.appending(path: "broken.mov")
        try Data("not a movie".utf8).write(to: video)
        await #expect(throws: (any Error).self) {
            try await VideoFaceReader.read(
                AVURLAsset(url: video),
                analyzeFaces: { _ in
                    Issue.record("a frame reached the analyser")
                    return FaceAnalysis(faces: [], rejectedForQuality: 0, rejectedAsNoPerson: 0, rejectedForAlignment: 0, rejectedForLandmarks: 0)
                },
                framesRelativeName: "frames.heic", in: directory
            )
        }
    }

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
