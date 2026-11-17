import AVFoundation
import CoreGraphics
import Foundation
import GRDB
import ImageIO
@testable import OtosKit
import Synchronization
import Testing

/// A library video's faces (ADR 0047): read by enrichment from six frames, one face per
/// person, stored with the frame each was read in, and shown and counted as a video's.
@Suite(.testScope)
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

    /// Plan 0116, peak footprint: one full-resolution frame is held at a time. Each frame is
    /// analysed before the next is decoded, and none is decoded twice; a frame in which faces
    /// were found is kept only at the preview's size, which is what is staged.
    @Test func oneFullResolutionFrameIsHeldAtATime() async throws {
        let directory = try makeTestDirectory()
        let events = Mutex<[String]>([])
        let alive = Mutex(0)
        let mostAlive = Mutex(0)
        let read = try await VideoFaceReader.read(
            frame: { index in
                events.withLock { $0.append("decode \(index)") }
                let count = alive.withLock { $0 += 1
                    return $0
                }
                mostAlive.withLock { $0 = max($0, count) }
                return Self.image(width: 3840, height: 2160)
            },
            analyzeFaces: { _ in
                let index = events.withLock { events in
                    events.append("analyse")
                    return events.count(where: { $0.hasPrefix("decode") }) - 1
                }
                alive.withLock { $0 -= 1 }
                // A face in the second frame only.
                return FaceAnalysis(
                    faces: index == 1 ? [Self.face(person: 1, quality: 0.9)] : [],
                    rejectedForQuality: 0, rejectedAsNoPerson: 0, rejectedForAlignment: 0, rejectedForLandmarks: 0
                )
            },
            framesRelativeName: "clip.faces.heic",
            in: directory
        )
        #expect(events.withLock { $0 } == VideoFaceReader.samples.indices.flatMap { ["decode \($0)", "analyse"] })
        #expect(mostAlive.withLock { $0 } == 1)
        let staged = try #require(read.frames)
        let source = try #require(CGImageSourceCreateWithURL(
            ThumbnailStore.url(for: staged.stagedRelativePath, in: directory) as CFURL, nil
        ))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == ThumbnailStore.previewMaxPixelSize)
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

    /// A video whose frames cannot be read is an error to the reader, not a video without
    /// faces, and the analyser never sees a frame: whether the error is a verdict on the
    /// video is the enricher's question (`VideoFaceReader.isUndecodable`).
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
        #expect(try await fixture.store.windowReads.peopleGallery(availableLibraryPaths: [fixture.rootPath])?.unchecked == MediaCount(videos: 1))

        let frames = try ThumbnailStore.stageFaceFrames(
            [Self.image(), Self.image()], finalRelativeName: ThumbnailStore.faceFramesRelativeName(for: fixture.id), in: fixture.thumbnailDirectory
        )
        let outcome = try await fixture.apply(EnrichedVideoFaces(
            faces: [.init(face: Self.face(person: 1, quality: 0.5), frameIndex: 0), .init(face: Self.face(person: 2, quality: 0.5), frameIndex: 1)],
            analysisRevision: FaceAnalyzer.revision,
            frames: frames
        ))
        #expect(outcome == .applied(count: 1))

        #expect(try await fixture.store.windowReads.peopleGallery(availableLibraryPaths: [fixture.rootPath])?.unchecked == MediaCount())
        let faces = try await fixture.store.windowReads.photoFaces(of: [fixture.id], landedThrough: 0)
        let second = try #require(faces.face(FaceID(asset: fixture.id, index: 1))?.tile)
        #expect(second.isInVideo)
        #expect(second.preview == FacePreview(name: frames.finalRelativePath, recipe: .neutral, image: 1))
        let file = ThumbnailStore.url(for: frames.finalRelativePath, in: fixture.thumbnailDirectory)
        #expect(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
        let asset = try #require(try await fixture.store.windowReads.mediaAssets(for: [fixture.id])[fixture.id])
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

        #expect(try await fixture.store.backgroundReads.peopleSnapshot().faces.isEmpty)
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

    static func image(width: Int = 64, height: Int = 36) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
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
            let store = makeTestStore(location: .databaseFile(databaseURL), filesystemWatcher: watcher)
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
            let asset = try #require(try await store.windowReads.mediaAssets(for: [id])[id])
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

extension VideoFaceTests {
    /// A library video whose faces cannot be read keeps every other product: its metadata,
    /// digest and thumbnail are made and returned, and only the faces stay owed, as their own
    /// outcome, which names whether this video or the model failed. Never `.transient`.
    @Test func aVideoWhoseFacesFailKeepsEveryOtherProduct() async throws {
        let directory = try makeTestDirectory()
        let video = directory.appending(path: "clip.mov")
        try FileManager.default.copyItem(at: Self.fixture, to: video)
        let size = try #require(try FileManager.default.attributesOfItem(atPath: video.path)[.size] as? Int64)
        let id = MediaAssetID(libraryRootPath: LibraryRootPath(rawValue: directory.path), relativePath: MediaRelativePath(rawValue: "clip.mov"))
        struct FrameFailed: Error {}
        let failures: [(any Error & Sendable, VideoFacesUnread)] = [
            (FrameFailed(), .video), (FaceAnalysisError.modelUnavailable(description: "missing"), .model),
        ]
        for (failure, expected) in failures {
            let enricher = MediaEnricher.live(
                thumbnailDirectory: directory.appending(path: "Thumbnails", directoryHint: .isDirectory),
                readinessChecker: TestEnrichmentReadinessChecker(result: .materialized),
                analyzeFaces: { _ in throw failure }
            )
            let outcome = await enricher.enrich(id, .localFile(video), size, 1000, [.metadata, .rendering, .hash, .videoFaces], nil)
            guard case let .facesUnread(result, unread) = outcome else {
                Issue.record("expected .facesUnread, got \(outcome)")
                continue
            }
            #expect(unread == expected)
            #expect(result.metadata != nil)
            #expect(result.contentHash != nil)
            #expect(result.rendering != nil)
            #expect(result.videoFaces == nil)
        }
    }

    /// A video's re-read carries what the user said by likeness, not by box: its boxes belong
    /// to the frames they were read in, so the box a named face had can hold someone else in
    /// the frame a re-read keeps.
    @Test func aVideosNamedFaceMovesToTheSamePersonNotTheSameBox() async throws {
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(in: makeTestDirectory(), files: ["clip.mov"])
        let here = CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.3)
        let there = CGRect(x: 0.6, y: 0.2, width: 0.2, height: 0.3)
        func face(person: Int, box: CGRect) -> DetectedFace {
            let face = Self.face(person: person, quality: 0.5)
            return DetectedFace(box: box, landmarks: face.landmarks, quality: face.quality, embedding: face.embedding)
        }
        try await library.readVideoFaces("clip.mov", faces: [face(person: 1, box: here), face(person: 2, box: there)])
        let sam = try #require(try await library.store.perform(
            .moveToNewPerson([FaceID(asset: library.id("clip.mov"), index: 0)], name: "Sam")
        ).person)

        // The re-read keeps person 2 from a frame where they stand where Sam stood.
        try await library.readVideoFaces("clip.mov", faces: [face(person: 2, box: here), face(person: 1, box: there)])

        let faces = try await library.store.backgroundReads.peopleSnapshot().faces
        #expect(faces.map(\.assignment) == [.open, .user(sam)])
        await library.store.shutdown()
    }
}

extension VideoFaceTests {
    /// ADR 0047: while the face model cannot be loaded, a library video that owes only its
    /// faces is never claimed. Counted by the claim writes the catalog sees: a held wake writes
    /// no claim and no release for it; an admitted wake claims it once, for its faces alone.
    @Test func aVideoOwedOnlyItsFacesIsNotClaimedWhileTheModelIsMissing() async throws {
        let directory = try makeTestDirectory()
        let library = try await VideoLibrary.make(in: directory)
        let counter = try makeTestDatabaseQueue(path: directory.appending(path: "db/catalog.sqlite").path(percentEncoded: false))
        try await counter.write { db in
            // Every product but the faces is current.
            try db.execute(sql: """
            UPDATE media_asset SET
                metadata_source_size = COALESCE(byte_size, -1),
                metadata_source_mtime = CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER),
                rendered_source_size = COALESCE(byte_size, -1),
                rendered_source_mtime = CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER),
                content_sha1 = zeroblob(20),
                content_hash_source_size = COALESCE(byte_size, -1),
                content_hash_source_mtime = CAST(COALESCE(content_modified_at_unix, -1) AS INTEGER)
            """)
            try db.execute(sql: "CREATE TABLE claim_write (claimed INTEGER NOT NULL)")
            try db.execute(sql: """
            CREATE TRIGGER count_claim_write AFTER UPDATE OF enrichment_claimed ON media_asset
            WHEN NEW.enrichment_claimed IS NOT OLD.enrichment_claimed
            BEGIN INSERT INTO claim_write VALUES (NEW.enrichment_claimed IS NOT NULL); END
            """)
        }
        func writes() async throws -> (claims: Int, releases: Int) {
            try await counter.read { db in
                try (
                    Int.fetchOne(db, sql: "SELECT COUNT(*) FROM claim_write WHERE claimed = 1") ?? 0,
                    Int.fetchOne(db, sql: "SELECT COUNT(*) FROM claim_write WHERE claimed = 0") ?? 0
                )
            }
        }
        func coordinator(_ schedule: EnrichmentSchedule) -> EnrichmentCoordinator {
            EnrichmentCoordinator(
                store: library.store,
                enricher: MediaEnricher { _, _, _, _, _, _ in .transient },
                materialize: { _ in .testMaterialized },
                originalStatus: { _ in .materialized },
                schedule: schedule
            )
        }

        var held = EnrichmentSchedule(retrySchedule: .production)
        held.holdVideoFaces(now: .now)
        let heldCoordinator = coordinator(held)
        let heldWork = await heldCoordinator.dequeueEnrichmentWork()
        let heldWrites = try await writes()
        await heldCoordinator.shutdown()
        #expect(heldWork.isEmpty)
        #expect(heldWrites.claims == 0)
        #expect(heldWrites.releases == 0)

        let admittedCoordinator = coordinator(EnrichmentSchedule(retrySchedule: .production))
        let admittedWork = await admittedCoordinator.dequeueEnrichmentWork()
        let admittedWrites = try await writes()
        await admittedCoordinator.shutdown()
        #expect(admittedWork.map(\.id) == [library.id])
        #expect(admittedWork.map(\.scope) == [.videoFaces])
        #expect(admittedWrites.claims == 1)
        #expect(admittedWrites.releases == 0)
        await library.store.shutdown()
    }
}

// MARK: - A video AVFoundation cannot decode

extension VideoFaceTests {
    /// A library video whose bytes AVFoundation says it cannot parse is read, as holding no
    /// face, by the decoder that said so: the read is complete, its faces are stamped, and it
    /// neither owes faces nor counts as unchecked, so it is not read again on every wake. The
    /// analyser never sees a frame.
    @Test func aVideoAVFoundationCannotDecodeIsStampedWithNoFacesByThatDecoder() async throws {
        let fixture = try await VideoLibrary.make(in: makeTestDirectory())
        let asset = try #require(try await fixture.store.windowReads.mediaAssets(for: [fixture.id])[fixture.id])
        let enricher = MediaEnricher.live(
            thumbnailDirectory: fixture.thumbnailDirectory,
            readinessChecker: TestEnrichmentReadinessChecker(result: .materialized),
            analyzeFaces: { _ in
                Issue.record("a frame reached the analyser")
                return FaceAnalysis(faces: [], rejectedForQuality: 0, rejectedAsNoPerson: 0, rejectedForAlignment: 0, rejectedForLandmarks: 0)
            }
        )
        let video = URL(fileURLWithPath: fixture.rootPath.rawValue, isDirectory: true).appending(path: "clip.mov")

        let outcome = await enricher.enrich(
            fixture.id, .localFile(video), asset.byteSize, MediaAsset.mtimeSeconds(asset.contentModifiedAt), [.videoFaces], nil
        )

        guard case let .complete(result) = outcome else {
            Issue.record("expected .complete, got \(outcome)")
            await fixture.store.shutdown()
            return
        }
        #expect(result.videoFaces == .noneFound)
        #expect(result.decodeVerdict == .undecodable(decoder: VideoFaceReader.decoderIdentity))
        #expect(await fixture.store.applyEnrichmentBatch([result]) == .applied(count: 1))
        #expect(asset.videoFacesStale)
        let stamped = try #require(try await fixture.store.windowReads.mediaAssets(for: [fixture.id])[fixture.id])
        #expect(!stamped.videoFacesStale)
        #expect(try await fixture.store.windowReads.peopleGallery(availableLibraryPaths: [fixture.rootPath])?.unchecked == MediaCount())
        await fixture.store.shutdown()
    }

    /// A video the reader decodes is decoded, so a verdict an earlier read left is cleared.
    @Test func aVideoTheReaderDecodesIsDecoded() async throws {
        let directory = try makeTestDirectory()
        let video = directory.appending(path: "clip.mov")
        try FileManager.default.copyItem(at: Self.fixture, to: video)
        let enricher = MediaEnricher.live(
            thumbnailDirectory: directory.appending(path: "Thumbnails", directoryHint: .isDirectory),
            readinessChecker: TestEnrichmentReadinessChecker(result: .materialized),
            analyzeFaces: { _ in Self.analysis([]) }
        )
        let id = MediaAssetID(libraryRootPath: LibraryRootPath(rawValue: directory.path), relativePath: MediaRelativePath(rawValue: "clip.mov"))

        let outcome = await enricher.enrich(id, .localFile(video), 100, 1000, [.videoFaces], nil)

        guard case let .complete(result) = outcome else {
            Issue.record("expected .complete, got \(outcome)")
            return
        }
        #expect(result.videoFaces == .noneFound)
        #expect(result.decodeVerdict == .decoded)
    }

    /// Only AVFoundation's word that it cannot decode the bytes is a verdict, by domain and
    /// code, and for a truncated AVI's `unknown` by its underlying status. Another unknown error, a failed decode (which the same video has answered once and
    /// then read cleanly), a network error and a failed analysis are failed reads.
    @Test func onlyAVFoundationsWordThatItCannotDecodeIsAVerdict() {
        struct AnalysisFailed: Error {}
        let verdicts: [AVError.Code] = [.fileFormatNotRecognized, .fileFailedToParse, .failedToParse, .decoderNotFound, .noImageAtTime]
        for code in verdicts {
            #expect(VideoFaceReader.isUndecodable(AVError(code)), "\(code)")
            #expect(VideoFaceReader.isUndecodable(NSError(domain: AVFoundationErrorDomain, code: code.rawValue)), "\(code) as NSError")
        }
        func unknown(over status: Int) -> NSError {
            NSError(domain: AVFoundationErrorDomain, code: AVError.Code.unknown.rawValue, userInfo: [
                NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: status),
            ])
        }
        // A truncated AVI's answer: `unknown` over -12344, on every read.
        #expect(VideoFaceReader.isUndecodable(unknown(over: -12344)))
        let failures: [any Error] = [
            AVError(.unknown), AVError(.decodeFailed), URLError(.timedOut), AnalysisFailed(),
            FaceAnalysisError.modelUnavailable(description: "missing"),
            unknown(over: -17761),
            NSError(domain: AVFoundationErrorDomain, code: AVError.Code.unknown.rawValue, userInfo: [
                NSUnderlyingErrorKey: NSError(domain: NSCocoaErrorDomain, code: -12344),
            ]),
        ]
        for failure in failures {
            #expect(!VideoFaceReader.isUndecodable(failure), "\(failure)")
        }
    }
}
