import CoreGraphics
import Foundation
@testable import OtosKit
import Synchronization
import Testing

/// Faces read from stored previews (ADR 0047): which rows owe them in a library and an Immich
/// account, how a new version or a new edit is read, how a face read through an edit lands on
/// the upright photo, and the reader end to end.
@Suite(.testScope)
struct PreviewFaceReaderTests {
    /// How many previews the stand-in analyser was handed.
    private final class Calls: Sendable {
        private let count = Mutex(0)

        func record() {
            count.withLock { $0 += 1 }
        }

        var value: Int {
            count.withLock { $0 }
        }
    }

    private static let server = URL(string: "https://photos.example.com")!

    /// An Immich still with a stored preview owes faces once; a new version of the asset,
    /// with its new preview, owes them again. A video never does.
    @Test func anImmichStillOwesFacesFromEachPreview() async throws {
        let account = try await ImmichAccount.make(in: makeTestDirectory())
        try await account.list([("IMG_1.JPG", "public.jpeg", 42), ("CLIP.MOV", "com.apple.quicktime-movie", 42)])
        await account.applySourceImages(for: "IMG_1.JPG", size: 42)
        await account.applySourceImages(for: "CLIP.MOV", size: 42)

        let first = try await account.store.backgroundReads.previewFaceCandidates(limit: 10).candidates
        #expect(first.map(\.id) == [account.id("IMG_1.JPG")])
        #expect(try await account.store.applyPreviewFaces(first.map {
            PreviewFaceResult(candidate: $0, faces: EnrichedFaces(faces: [FaceEnrichmentTests.face(seed: 1)], analysisRevision: 1))
        }) == 1)
        #expect(try await account.store.backgroundReads.previewFaceCandidates(limit: 10).candidates.isEmpty)
        #expect(try await account.store.windowReads.faces(of: account.id("IMG_1.JPG")) == [FaceEnrichmentTests.face(seed: 1)])

        try await account.list([("IMG_1.JPG", "public.jpeg", 43)])
        await account.applySourceImages(for: "IMG_1.JPG", size: 43)
        #expect(try await account.store.backgroundReads.previewFaceCandidates(limit: 10).candidates.map(\.id) == [account.id("IMG_1.JPG")])
        await account.store.shutdown()
    }

    /// A reading of a preview the row no longer has is not written.
    @Test func aReadingOfAnOlderPreviewIsNotWritten() async throws {
        let account = try await ImmichAccount.make(in: makeTestDirectory())
        try await account.list([("IMG_1.JPG", "public.jpeg", 42)])
        await account.applySourceImages(for: "IMG_1.JPG", size: 42)
        let stale = try await account.store.backgroundReads.previewFaceCandidates(limit: 10).candidates

        try await account.list([("IMG_1.JPG", "public.jpeg", 43)])
        await account.applySourceImages(for: "IMG_1.JPG", size: 43)

        #expect(try await account.store.applyPreviewFaces(stale.map { PreviewFaceResult(candidate: $0, faces: .noneFound) }) == 0)
        await account.store.shutdown()
    }

    /// The reader reads the stored preview, hands it upright to the analyser, and stores the
    /// faces.
    @Test func theReaderStoresThePreviewsFaces() async throws {
        let account = try await ImmichAccount.make(in: makeTestDirectory())
        try await account.list([("IMG_1.JPG", "public.jpeg", 42)])
        let directory = try #require(account.store.thumbnailDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeSubjectJPEG(to: directory.appending(path: "preview.jpg"), center: CGPoint(x: 0.5, y: 0.5))
        await account.applySourceImages(for: "IMG_1.JPG", size: 42)
        let face = FaceEnrichmentTests.face(seed: 2)
        let analysed = Calls()
        let reader = PreviewFaceReader(
            store: account.store,
            thumbnailDirectory: directory,
            analyzeFaces: { _ in
                analysed.record()
                return FaceAnalysis(faces: [face], rejectedForQuality: 0, rejectedAsNoPerson: 0, rejectedForAlignment: 0, rejectedForLandmarks: 0)
            }
        )

        await reader.start()
        try await waitUntil { try await account.store.windowReads.faces(of: account.id("IMG_1.JPG")) == [face] }
        await reader.shutdown()

        #expect(try await account.store.backgroundReads.previewFaceCandidates(limit: 10).candidates.isEmpty)
        #expect(analysed.value == 1)
        await account.store.shutdown()
    }

    /// A library still owes faces once it has a stored preview, and once read, not again: an
    /// edit and its new rendering are not a new source. A video never owes them, and a still
    /// still waiting for its rendering counts as unchecked.
    @Test func aLibraryStillOwesFacesFromItsPreviewOnce() async throws {
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(in: makeTestDirectory(), files: ["a.jpg", "clip.mov"])
        let still = library.id("a.jpg")
        #expect(try await library.store.backgroundReads.previewFaceCandidates(limit: 10).candidates.isEmpty)
        // The video is not the preview reader's; enrichment owes its faces (ENR-031).
        #expect(try await library.store.windowReads.peopleGallery(availableLibraryPaths: [library.rootPath])?.unchecked == MediaCount(photos: 1, videos: 1))

        try await Self.render(still, in: library, editRevision: 0)
        let first = try await library.store.backgroundReads.previewFaceCandidates(limit: 10).candidates
        #expect(first.map(\.id) == [still])
        #expect(first.first?.recipe == .neutral)
        #expect(try await library.store.applyPreviewFaces(first.map { PreviewFaceResult(candidate: $0, faces: .noneFound) }) == 1)
        #expect(try await library.store.backgroundReads.previewFaceCandidates(limit: 10).candidates.isEmpty)
        #expect(try await library.store.windowReads.peopleGallery(availableLibraryPaths: [library.rootPath])?.unchecked == MediaCount(videos: 1))

        let saved = try #require(try await library.store.setEditRecipe(Self.leftHalf, for: still).saved)
        try await Self.render(still, in: library, editRevision: saved.revision)
        #expect(try await library.store.backgroundReads.previewFaceCandidates(limit: 10).candidates.isEmpty)
        await library.store.shutdown()
    }

    /// A preview is read through the edit it shows: the unedited photo until the rendering of
    /// a new edit lands, then that edit; a reading of a preview whose edit has since changed
    /// is not written.
    @Test func anEditedPreviewIsReadThroughItsEdit() async throws {
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(in: makeTestDirectory(), files: ["a.jpg"])
        let still = library.id("a.jpg")
        try await Self.render(still, in: library, editRevision: 0)
        let saved = try #require(try await library.store.setEditRecipe(Self.leftHalf, for: still).saved)
        #expect(try await library.store.backgroundReads.previewFaceCandidates(limit: 10).candidates.map(\.recipe) == [.neutral])

        try await Self.render(still, in: library, editRevision: saved.revision)
        let edited = try await library.store.backgroundReads.previewFaceCandidates(limit: 10).candidates
        #expect(edited.map(\.recipe) == [Self.leftHalf])
        #expect(edited.map(\.renderedRevision) == [saved.revision])

        let newer = try #require(try await library.store.setEditRecipe(EditRecipe(quarterTurns: 1), for: still).saved)
        try await Self.render(still, in: library, editRevision: newer.revision)
        #expect(try await library.store.applyPreviewFaces(edited.map { PreviewFaceResult(candidate: $0, faces: .noneFound) }) == 0)
        #expect(try await library.store.backgroundReads.previewFaceCandidates(limit: 10).candidates.map(\.recipe) == [EditRecipe(quarterTurns: 1)])
        await library.store.shutdown()
    }

    /// A face tile is cut from the stored preview through the edit that preview shows: the
    /// unedited photo until the rendering of a new edit lands, then that edit, and no preview
    /// at all while a rendering of a newer edit is owed.
    @Test func aFaceTileCarriesTheEditItsPreviewShows() async throws {
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(in: makeTestDirectory(), files: ["a.jpg"])
        let still = library.id("a.jpg")
        let face = FaceID(asset: still, index: 0)
        #expect(try await library.readFaces([library.result(for: "a.jpg", faces: [PeopleStoreTests.face(x: 0.6)])]) == 1)
        let unedited = FacePreview(name: "preview-a.jpg.heic", recipe: .neutral)
        func tile() async throws -> FaceTile? {
            try await library.store.windowReads.photoFaces(of: [still], landedThrough: 0).face(face)?.tile
        }
        #expect(try await tile()?.preview == unedited)

        let saved = try #require(try await library.store.setEditRecipe(Self.leftHalf, for: still).saved)
        #expect(try await tile()?.preview == unedited)
        try await Self.render(still, in: library, editRevision: saved.revision, preview: unedited.name)
        #expect(try await tile()?.preview == FacePreview(name: unedited.name, recipe: Self.leftHalf))

        _ = try await library.store.setEditRecipe(EditRecipe(quarterTurns: 1), for: still)
        let owed = try #require(try await tile())
        #expect(owed.preview == nil)
        await library.store.shutdown()
    }

    /// A face read from a cropped preview lies on the upright photo where the crop shows it;
    /// one read from a preview turned a quarter clockwise lies where the turn took it from.
    @Test func aFaceReadThroughAnEditLandsOnTheUprightPhoto() {
        let face = DetectedFace(
            box: CGRect(x: 0.5, y: 0.25, width: 0.25, height: 0.25),
            landmarks: FaceAlignment.Landmarks(
                leftEye: CGPoint(x: 0.5, y: 0.25), rightEye: CGPoint(x: 0.75, y: 0.25), nose: CGPoint(x: 0.625, y: 0.375),
                leftMouth: CGPoint(x: 0.5, y: 0.5), rightMouth: CGPoint(x: 0.75, y: 0.5)
            ),
            quality: 0.5,
            embedding: FaceEnrichmentTests.face(seed: 1).embedding
        )
        let cropped = PreviewFaceReader.upright(face, readFrom: CGSize(width: 500, height: 1000), recipe: Self.leftHalf)
        Self.expect(cropped.box, CGRect(x: 0.25, y: 0.25, width: 0.125, height: 0.25))
        Self.expect(cropped.landmarks.nose, CGPoint(x: 0.3125, y: 0.375))
        #expect(cropped.embedding == face.embedding && cropped.quality == face.quality)

        // A quarter clockwise shows the upright photo's (x, y) at (1 - y, x), so a point read
        // at (u, v) came from (v, 1 - u).
        let turned = PreviewFaceReader.upright(face, readFrom: CGSize(width: 600, height: 800), recipe: EditRecipe(quarterTurns: 1))
        Self.expect(turned.box, CGRect(x: 0.25, y: 0.25, width: 0.25, height: 0.25))
        Self.expect(turned.landmarks.leftMouth, CGPoint(x: 0.5, y: 0.5))
        Self.expect(turned.landmarks.rightEye, CGPoint(x: 0.25, y: 0.25))

        #expect(PreviewFaceReader.upright(face, readFrom: CGSize(width: 600, height: 800), recipe: EditRecipe(exposure: 1)) == face)
    }

    /// A still whose analysis fails is passed over, not waited on: the stills after it are
    /// read in the same drain. It is not read again at the next ring, only once its pacing
    /// passes: a still that keeps failing is not analysed on every catalog change.
    @Test func aStillThatFailsDoesNotHoldBackTheRestAndIsPaced() async throws {
        let directory = try makeTestDirectory()
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(in: directory, files: ["a.jpg", "b.jpg", "c.jpg"])
        let previews = directory.appending(path: "Previews", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
        for name in ["a.jpg", "b.jpg", "c.jpg"] {
            try writeSubjectJPEG(to: previews.appending(path: "preview-\(name)"), center: CGPoint(x: 0.5, y: 0.5))
        }
        for name in ["a.jpg", "b.jpg"] {
            try await Self.render(library.id(name), in: library, editRevision: 0, preview: "preview-\(name)")
        }
        let face = FaceEnrichmentTests.face(seed: 3)
        let analysed = Calls()
        struct AnalysisFailed: Error {}
        let reader = PreviewFaceReader(
            store: library.store,
            thumbnailDirectory: previews,
            analyzeFaces: { _ in
                analysed.record()
                guard analysed.value > 1 else { throw AnalysisFailed() }
                return FaceAnalysis(faces: [face], rejectedForQuality: 0, rejectedAsNoPerson: 0, rejectedForAlignment: 0, rejectedForLandmarks: 0)
            },
            pageSize: 1
        )

        await reader.start()
        try await waitUntil { try await library.store.windowReads.faces(of: library.id("b.jpg")) == [face] }
        // A new rendering rings the reader: c is read, a is not tried again.
        try await Self.render(library.id("c.jpg"), in: library, editRevision: 0, preview: "preview-c.jpg")
        try await waitUntil { try await library.store.windowReads.faces(of: library.id("c.jpg")) == [face] }
        await reader.shutdown()
        #expect(analysed.value == 3)
        #expect(try await library.store.backgroundReads.previewFaceCandidates(limit: 10).candidates.map(\.id) == [library.id("a.jpg")])
        await library.store.shutdown()
    }

    /// A preview whose file cannot be read, and one whose bytes are not an image, leave their
    /// stills owed: nothing is known of their faces, so neither is stamped with none (ENR-026).
    /// Neither reaches the analyser.
    @Test func aMissingOrUndecodablePreviewStaysOwed() async throws {
        let directory = try makeTestDirectory()
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(in: directory, files: ["a.jpg", "b.jpg"])
        let previews = directory.appending(path: "Previews", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
        try Data("not an image".utf8).write(to: previews.appending(path: "preview-b.jpg"))
        for name in ["a.jpg", "b.jpg"] {
            try await Self.render(library.id(name), in: library, editRevision: 0, preview: "preview-\(name)")
        }
        let analysed = Calls()
        let reader = PreviewFaceReader(
            store: library.store,
            thumbnailDirectory: previews,
            analyzeFaces: { _ in
                analysed.record()
                return FaceAnalysis(faces: [], rejectedForQuality: 0, rejectedAsNoPerson: 0, rejectedForAlignment: 0, rejectedForLandmarks: 0)
            }
        )

        await reader.start()
        try await waitUntil { await reader.drains >= 1 }
        await reader.shutdown()
        #expect(try await library.store.backgroundReads.previewFaceCandidates(limit: 10).candidates.map(\.id) == [library.id("a.jpg"), library.id("b.jpg")])
        #expect(analysed.value == 0)
        await library.store.shutdown()
    }

    /// A model that cannot be loaded stops the drain at the first still, which stays owed with
    /// every other, and a catalog change does not start reading again: only the pacing does.
    @Test func aMissingModelStopsTheReadUntilItsPacingPasses() async throws {
        let directory = try makeTestDirectory()
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(in: directory, files: ["a.jpg", "b.jpg", "c.jpg"])
        let previews = directory.appending(path: "Previews", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
        for name in ["a.jpg", "b.jpg", "c.jpg"] {
            try writeSubjectJPEG(to: previews.appending(path: "preview-\(name)"), center: CGPoint(x: 0.5, y: 0.5))
        }
        for name in ["a.jpg", "b.jpg"] {
            try await Self.render(library.id(name), in: library, editRevision: 0, preview: "preview-\(name)")
        }
        let analysed = Calls()
        let reader = PreviewFaceReader(
            store: library.store,
            thumbnailDirectory: previews,
            analyzeFaces: { _ in
                analysed.record()
                throw FaceAnalysisError.modelUnavailable(description: "missing")
            },
            pageSize: 1
        )

        await reader.start()
        try await waitUntil { await reader.drains >= 1 }
        let before = await reader.drains
        try await Self.render(library.id("c.jpg"), in: library, editRevision: 0, preview: "preview-c.jpg")
        try await waitUntil { await reader.drains > before }
        await reader.shutdown()
        #expect(analysed.value == 1)
        #expect(try await library.store.backgroundReads.previewFaceCandidates(limit: 10).candidates.count == 3)
        await library.store.shutdown()
    }

    /// Starting the reader twice starts one loop: a still is analysed once.
    @Test func startingTwiceStartsOneLoop() async throws {
        let directory = try makeTestDirectory()
        let library = try await FaceEnrichmentTests.ScannedLibrary.make(in: directory, files: ["a.jpg"])
        let previews = directory.appending(path: "Previews", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
        try writeSubjectJPEG(to: previews.appending(path: "preview-a.jpg"), center: CGPoint(x: 0.5, y: 0.5))
        try await Self.render(library.id("a.jpg"), in: library, editRevision: 0, preview: "preview-a.jpg")
        let face = FaceEnrichmentTests.face(seed: 4)
        let analysed = Calls()
        let reader = PreviewFaceReader(
            store: library.store,
            thumbnailDirectory: previews,
            analyzeFaces: { _ in
                analysed.record()
                return FaceAnalysis(faces: [face], rejectedForQuality: 0, rejectedAsNoPerson: 0, rejectedForAlignment: 0, rejectedForLandmarks: 0)
            }
        )

        async let first: Void = reader.start()
        async let second: Void = reader.start()
        _ = await (first, second)
        try await waitUntil { try await library.store.windowReads.faces(of: library.id("a.jpg")) == [face] }
        try await waitUntil { await reader.drains >= 1 }
        await reader.shutdown()
        #expect(analysed.value == 1)
        await library.store.shutdown()
    }

    /// The retry ledger, driven by the instants it covers: a failed still waits out its pacing
    /// unless its preview changes, a missing model holds every still, and a read clears both.
    @Test func aFailedStillWaitsOutItsPacingUnlessItsPreviewChanges() {
        let start = ContinuousClock.now
        var retries = PreviewFaceRetries(pacing: .seconds(900))
        let id = MediaAssetID(libraryRootPath: LibraryRootPath(rawValue: "/L"), relativePath: MediaRelativePath(rawValue: "a.jpg"))
        let candidate = PreviewFaceCandidate(
            id: id, previewPath: "p.heic", sourceSize: 1, sourceMTimeSeconds: 1, renderedRevision: 0, recipe: .neutral
        )
        let newPreview = PreviewFaceCandidate(
            id: id, previewPath: "p.heic", sourceSize: 2, sourceMTimeSeconds: 2, renderedRevision: 0, recipe: .neutral
        )
        retries.failed(candidate, at: start)
        #expect(!retries.admits(candidate, at: start.advanced(by: .seconds(899))))
        #expect(retries.admits(candidate, at: start.advanced(by: .seconds(900))))
        #expect(retries.admits(newPreview, at: start))
        #expect(retries.nextWake(after: start) == start.advanced(by: .seconds(900)))

        retries.modelFailed(at: start)
        #expect(!retries.admitsModel(at: start.advanced(by: .seconds(1))))
        #expect(retries.admitsModel(at: start.advanced(by: .seconds(900))))
        retries.read(candidate)
        #expect(retries.admitsModel(at: start) && retries.admits(candidate, at: start))
        #expect(retries.nextWake(after: start) == nil)

        retries.failed(candidate, at: start)
        retries.keep(only: [])
        #expect(retries.stills.isEmpty)
    }

    private static let leftHalf = EditRecipe(crop: EditCrop(left: 0, top: 0, width: 0.5, height: 1))

    private static func expect(_ rect: CGRect, _ expected: CGRect, sourceLocation: SourceLocation = #_sourceLocation) {
        for (a, b) in [(rect.minX, expected.minX), (rect.minY, expected.minY), (rect.width, expected.width), (rect.height, expected.height)] {
            #expect(abs(a - b) < 1e-9, "\(rect) is not \(expected)", sourceLocation: sourceLocation)
        }
    }

    private static func expect(_ point: CGPoint, _ expected: CGPoint, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(abs(point.x - expected.x) < 1e-9 && abs(point.y - expected.y) < 1e-9, "\(point) is not \(expected)", sourceLocation: sourceLocation)
    }

    /// Otos's rendering of `id` at `editRevision`, made from the file as scanned.
    private static func render(
        _ id: MediaAssetID,
        in library: FaceEnrichmentTests.ScannedLibrary,
        editRevision: Int64,
        preview: String = "preview.heic"
    ) async throws {
        let asset = try #require(try await library.store.windowReads.mediaAssets(for: [id])[id])
        _ = await library.store.applyEnrichmentBatch([EnrichmentResult(
            id: id,
            metadata: AssetMetadata(),
            thumbnailPath: "thumb.jpg",
            sourceSize: asset.byteSize,
            sourceMTimeSeconds: MediaAsset.mtimeSeconds(asset.contentModifiedAt),
            contentHash: .empty,
            previewPath: preview,
            editRevision: editRevision
        )])
    }

    /// An Immich account in a file-backed catalog, whose listing the test drives by hand.
    struct ImmichAccount {
        let store: CatalogStore
        let rootPath: LibraryRootPath

        static func make(in directory: URL) async throws -> ImmichAccount {
            let store = makeTestStore(
                location: .databaseFile(directory.appending(path: "db/catalog.sqlite")), scanCadence: .milliseconds(10),
                stagingContainers: StagingContainers(base: directory)
            )
            try await store.start(scansSavedLibraries: false)
            let rootPath = try await store.addImmichAccount(
                server: PreviewFaceReaderTests.server, userID: "user-1", displayName: "Family"
            )
            return ImmichAccount(store: store, rootPath: rootPath)
        }

        func id(_ name: String) -> MediaAssetID {
            MediaAssetID(libraryRootPath: rootPath, relativePath: MediaRelativePath(rawValue: "asset-\(name)/\(name)"))
        }

        /// Lists `files` as the server would, each under its own asset folder.
        func list(_ files: [(name: String, type: String, size: Int64)]) async throws {
            let scan = try await store.beginSourceListing(rootPath: rootPath)
            let scanned = files.map { file in
                ScannedMediaFile(
                    relativePath: id(file.name).relativePath,
                    name: file.name,
                    contentTypeIdentifier: file.type,
                    byteSize: file.size,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    contentModifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
                )
            }
            try await store.recordSourceListingBatch(scanned, scan: scan)
            try await store.completeSourceListing(scan: scan, observedPaths: Set(scanned.map(\.relativePath)))
        }

        /// Immich's thumbnail and preview for `name`, as sync stores them.
        func applySourceImages(for name: String, size: Int64) async {
            _ = await store.applyEnrichmentBatch([EnrichmentResult(
                id: id(name),
                metadata: nil,
                rendering: EnrichedRendering(thumbnailPath: "thumb.jpg", previewPath: "preview.jpg", origin: .source),
                sourceSize: size,
                sourceMTimeSeconds: 1_700_000_000,
                contentHash: nil
            )])
        }
    }
}
