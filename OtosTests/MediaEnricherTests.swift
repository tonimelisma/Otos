import CoreGraphics
import Foundation
import MediaMetadata
@testable import OtosKit
import Synchronization
import Testing

@Suite(.testScope)
struct MediaEnricherTests {
    private final class SequencedReadinessChecker: EnrichmentReadinessChecking, Sendable {
        private let statuses: Mutex<[FileMaterializationStatus]>
        private let calls = Mutex(0)

        init(_ statuses: [FileMaterializationStatus]) {
            self.statuses = Mutex(statuses)
        }

        func status(of _: URL) -> FileMaterializationStatus {
            calls.withLock { $0 += 1 }
            return statuses.withLock { values in
                values.isEmpty ? .materialized : values.removeFirst()
            }
        }

        var callCount: Int {
            calls.withLock { $0 }
        }
    }

    private var fixtureDirectory: URL {
        SourceTree.mediaFixtures
    }

    @Test func enrichesJpegFixtureWithMetadataThumbnailAndTimestampFacts() async throws {
        let temp = try makeTestDirectory()
        let thumbnailDirectory = temp.appending(path: "Thumbnails", directoryHint: .isDirectory)
        let enricher = MediaEnricher.live(thumbnailDirectory: thumbnailDirectory)
        let url = fixtureDirectory.appending(path: "jpeg-exif-offset-date.jpg")
        let id = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/Lib"),
            relativePath: MediaRelativePath(rawValue: "a.jpg")
        )

        let outcome = await enricher.enrich(id, .localFile(url), 100, 1000, [.metadata, .rendering, .hash], nil)
        guard case let .complete(result) = outcome else {
            Issue.record("expected .complete, got \(outcome)")
            return
        }
        #expect(try CaptureTimestamps(records: #require(result.metadata).metadata.timestamps).captureInstant != nil)
        #expect(result.metadata?.metadata.timestamps.isEmpty == false)
        #expect(result.metadata?.metadata.family != nil)
        #expect(result.sourceSize == 100)
        #expect(result.sourceMTimeSeconds == 1000)

        let thumbnailPath = try #require(result.rendering?.thumbnailPath)
        let generatedThumbnail = try #require(result.rendering?.generatedThumbnail)
        let finalURL = thumbnailDirectory.appending(path: thumbnailPath, directoryHint: .notDirectory)
        let stagedURL = thumbnailDirectory.appending(
            path: generatedThumbnail.stagedRelativePath,
            directoryHint: .notDirectory
        )
        #expect(!FileManager.default.fileExists(atPath: finalURL.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: stagedURL.path(percentEncoded: false)))
    }

    /// ADR 0035: a still is developed once into a staged 2560 px HEIC preview, and its grid
    /// thumbnail is drawn from that same rendering — both staged, neither published.
    @Test func aStillGetsARenderedPreviewAndAThumbnailDrawnFromIt() async throws {
        let temp = try makeTestDirectory()
        let directory = temp.appending(path: "Thumbnails", directoryHint: .isDirectory)
        let enricher = MediaEnricher.live(thumbnailDirectory: directory)
        let id = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/Lib"),
            relativePath: MediaRelativePath(rawValue: "a.heic")
        )
        let outcome = await enricher.enrich(
            id, .localFile(fixtureDirectory.appending(path: "ios-heic-offset-date.heic")), 100, 1000, [.metadata, .rendering, .hash], nil
        )
        guard case let .complete(result) = outcome else {
            Issue.record("expected .complete, got \(outcome)")
            return
        }
        let preview = try #require(result.rendering?.generatedPreview)
        #expect(result.rendering?.previewPath == ThumbnailStore.previewRelativeName(for: id))
        let previewImage = try #require(ThumbnailStore.load(preview.stagedRelativePath, in: directory))
        #expect(max(previewImage.width, previewImage.height) <= ThumbnailStore.previewMaxPixelSize)
        let thumbnail = try #require(result.rendering?.generatedThumbnail)
        let thumbnailImage = try #require(ThumbnailStore.load(thumbnail.stagedRelativePath, in: directory))
        #expect(max(thumbnailImage.width, thumbnailImage.height) <= ThumbnailStore.maxPixelSize)
        #expect(!FileManager.default.fileExists(atPath: ThumbnailStore.url(for: preview.finalRelativePath, in: directory)
                .path(percentEncoded: false)))
    }

    /// ADR 0009: a card's metadata pass reads metadata and makes a provisional QuickLook
    /// thumbnail, with no rendering and no digest — the import waits on that pass alone.
    @Test func aCardsMetadataPassMakesAProvisionalThumbnailAndNoRendering() async throws {
        let temp = try makeTestDirectory()
        let directory = temp.appending(path: "Thumbnails", directoryHint: .isDirectory)
        let enricher = MediaEnricher.live(thumbnailDirectory: directory)
        let id = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/Volumes/CARD"),
            relativePath: MediaRelativePath(rawValue: "a.heic")
        )
        let outcome = await enricher.enrich(
            id, .localFile(fixtureDirectory.appending(path: "ios-heic-offset-date.heic")), 100, 1000,
            [.metadata, .provisionalThumbnail], nil
        )
        guard case let .complete(result) = outcome else {
            Issue.record("expected .complete, got \(outcome)")
            return
        }
        #expect(result.metadata != nil)
        #expect(result.rendering == nil)
        #expect(result.provisionalThumbnail != nil)
        #expect(result.contentHash == nil)
    }

    /// An edited photo's thumbnail must show its edit, which only a rendering does, so its
    /// metadata pass makes no provisional thumbnail (ADR 0036).
    @Test func anEditedPhotosMetadataPassMakesNoProvisionalThumbnail() async throws {
        let temp = try makeTestDirectory()
        let enricher = MediaEnricher.live(thumbnailDirectory: temp.appending(path: "Thumbnails", directoryHint: .isDirectory))
        var edited = EditRecipe.neutral
        edited.exposure = 0.5
        let outcome = await enricher.enrich(
            MediaAssetID(libraryRootPath: LibraryRootPath(rawValue: "/Volumes/CARD"), relativePath: MediaRelativePath(rawValue: "a.jpg")),
            .localFile(fixtureDirectory.appending(path: "jpeg-exif-offset-date.jpg")), 100, 1000,
            [.metadata, .provisionalThumbnail], StoredEditRecipe(recipe: edited, revision: 1)
        )
        guard case let .complete(result) = outcome else {
            Issue.record("expected .complete, got \(outcome)")
            return
        }
        #expect(result.metadata != nil)
        #expect(result.provisionalThumbnail == nil)
        #expect(result.rendering == nil)
    }

    /// A rendering alone — a card's later pass, or an edit — develops the still without
    /// reading its metadata again (ADR 0009).
    @Test func aRenderingScopeDevelopsWithoutReadingMetadata() async throws {
        let temp = try makeTestDirectory()
        let enricher = MediaEnricher.live(thumbnailDirectory: temp.appending(path: "Thumbnails", directoryHint: .isDirectory))
        let outcome = await enricher.enrich(
            MediaAssetID(libraryRootPath: LibraryRootPath(rawValue: "/Lib"), relativePath: MediaRelativePath(rawValue: "a.heic")),
            .localFile(fixtureDirectory.appending(path: "ios-heic-offset-date.heic")), 100, 1000,
            [.rendering], nil
        )
        guard case let .complete(result) = outcome else {
            Issue.record("expected .complete, got \(outcome)")
            return
        }
        #expect(result.metadata == nil)
        #expect(result.rendering?.generatedPreview != nil)
        #expect(result.rendering?.generatedThumbnail != nil)
        #expect(result.provisionalThumbnail == nil)
    }

    /// A HEIF that records its rotation only in its `irot` property (as Sony cameras write
    /// it) is cataloged with that orientation, so the catalog turns its stored size upright.
    @Test func aHeifTurnedByItsIrotPropertyIsReadWithItsOrientation() async throws {
        let temp = try makeTestDirectory()
        let file = temp.appending(path: "turned.heic")
        try writeIrotOnlyHEIC(to: file)
        let enricher = MediaEnricher.live(thumbnailDirectory: temp.appending(path: "Thumbnails", directoryHint: .isDirectory))
        let id = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/Lib"),
            relativePath: MediaRelativePath(rawValue: "turned.heic")
        )
        let outcome = await enricher.enrich(id, .localFile(file), 100, 1000, [.metadata, .rendering, .hash], nil)
        guard case let .complete(result) = outcome else {
            Issue.record("expected .complete, got \(outcome)")
            return
        }
        #expect(result.metadata?.metadata.orientation == 6)
    }

    /// ADR 0039: Otos stores what the library reports, as it reports it — geometry from
    /// `result.geometry`, the codec by its stable identifier, and the extraction revision
    /// the record was read with.
    @Test func aRecordIsTheLibrarysResultAsReported() {
        let video = fixtureDirectory.appending(path: "mov-no-embedded-capture-date.mov")
        let result = MediaMetadataReader.read(url: video)
        let mapped = MediaEnricher.map(result)
        #expect(mapped.extractionRevision == MediaMetadataReader.extractionRevision(for: result.format.family))
        #expect(mapped.videoCodec == result.video?.codec?.identifier)
        #expect(mapped.orientation == result.geometry?.orientation?.rawValue)
        #expect(mapped.pixelWidth == result.geometry?.pixelWidth)
        #expect(mapped.pixelHeight == result.geometry?.pixelHeight)
        #expect(mapped.pixelWidth != nil)
    }

    /// A still's exposure is stored as the library reports it and put back unchanged.
    @Test func aStillsExposureIsStoredAsTheLibraryReportsIt() throws {
        let result = MediaMetadataReader.read(url: fixtureDirectory.appending(path: "ios-heic-offset-date.heic"))
        let exposure = try #require(result.exposure)
        let record = try #require(MediaEnricher.map(result).exposure)
        #expect(record.exposure == exposure)
        #expect(record.isoSensitivity == 25)
        #expect(record.exposureTimeNumerator == 1)
        #expect(record.exposureTimeDenominator == 345)
    }

    /// Kind is MediaMetadata's (ADR 0039): the type the bytes settled, camera RAW included;
    /// else the kind the bytes showed; else the type the extension names.
    @Test func kindIsTheLibrarysFromBytesThenExtension() {
        func kind(_ family: MediaFormat.Family, _ kind: MediaFormat.Kind?, _ ext: String, _ type: MediaFileType?) -> MediaKind? {
            MediaEnricher.normalizedKind(MediaFormat(
                family: family, kind: kind, fileExtension: ext, detectedByMagic: true, fileType: type
            ))
        }
        #expect(kind(.tiff, .image, "arw", .arw) == .raw)
        #expect(kind(.tiff, .image, "arw", .tiff) == .image)
        #expect(kind(.isoBMFF, .image, "cr3", .cr3) == .raw)
        #expect(kind(.isoBMFF, .video, "unknownext", nil) == .video)
        #expect(kind(.unknown, .unknown, "png", nil) == .image)
        #expect(kind(.unknown, .unknown, "raf", nil) == .raw)
        #expect(kind(.unknown, .unknown, "mp3", nil) == nil)
        #expect(kind(.unknown, .unknown, "unknownext", nil) == nil)
    }

    /// ADR 0035: a video keeps its Quick Look thumbnail and gets no preview.
    @Test func aVideoGetsNoPreview() async throws {
        let temp = try makeTestDirectory()
        let directory = temp.appending(path: "Thumbnails", directoryHint: .isDirectory)
        let enricher = MediaEnricher.live(thumbnailDirectory: directory)
        let id = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/Lib"),
            relativePath: MediaRelativePath(rawValue: "a.mov")
        )
        let outcome = await enricher.enrich(
            id, .localFile(fixtureDirectory.appending(path: "mov-no-embedded-capture-date.mov")), 100, 1000, [.metadata, .rendering, .hash], nil
        )
        guard case let .complete(result) = outcome else {
            Issue.record("expected .complete, got \(outcome)")
            return
        }
        #expect(result.rendering?.generatedPreview == nil)
        #expect(result.rendering?.previewPath == nil)
    }

    @Test func zeroByteStubIsDefinitiveCompleteWithoutThumbnail() async throws {
        let temp = try makeTestDirectory()
        let thumbnailDirectory = temp.appending(path: "Thumbnails", directoryHint: .isDirectory)
        // 0-byte stubs (toy-camera AVI/JPG shape) cannot yield real QuickLook imagery
        // once `.icon` is rejected from representationTypes.
        let stubURL = temp.appending(path: "broken.jpg")
        try Data().write(to: stubURL)
        let enricher = MediaEnricher.live(thumbnailDirectory: thumbnailDirectory)
        let id = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/Lib"),
            relativePath: MediaRelativePath(rawValue: "broken.jpg")
        )

        let outcome = await enricher.enrich(id, .localFile(stubURL), 0, 1000, [.metadata, .rendering, .hash], nil)
        guard case let .complete(result) = outcome else {
            Issue.record("expected .complete for zero-byte stub, got \(outcome)")
            return
        }
        #expect(result.rendering?.thumbnailPath == nil)
        #expect(result.rendering?.generatedThumbnail == nil)
        #expect(result.sourceSize == 0)
        #expect(result.sourceMTimeSeconds == 1000)
    }

    @Test func datalessRegressionRoutesBackToDownload() async throws {
        // A missing/unreadable path reports unknown status, so the gate refuses to read.
        let temp = try makeTestDirectory()
        let thumbnailDirectory = temp.appending(path: "Thumbnails", directoryHint: .isDirectory)
        let enricher = MediaEnricher.live(thumbnailDirectory: thumbnailDirectory)
        let missing = temp.appending(path: "gone.jpg")
        let id = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/Lib"),
            relativePath: MediaRelativePath(rawValue: "gone.jpg")
        )

        let outcome = await enricher.enrich(id, .localFile(missing), 100, 1000, [.metadata, .rendering, .hash], nil)
        guard case .notMaterialized = outcome else {
            Issue.record("expected .notMaterialized for a missing file, got \(outcome)")
            return
        }
    }

    @Test func evictionAfterHashGateSkipsMetadata() async throws {
        let temp = try makeTestDirectory()
        let url = fixtureDirectory.appending(path: "jpeg-exif-offset-date.jpg")
        let checker = SequencedReadinessChecker([.materialized, .dataless])
        let enricher = MediaEnricher.live(
            thumbnailDirectory: temp.appending(path: "Thumbnails"),
            readinessChecker: checker
        )
        let outcome = await enricher.enrich(
            MediaAssetID(
                libraryRootPath: LibraryRootPath(rawValue: "/Lib"),
                relativePath: MediaRelativePath(rawValue: "a.jpg")
            ),
            .localFile(url),
            100,
            1000,
            [.metadata, .rendering, .hash], nil
        )
        guard case .notMaterialized = outcome else {
            Issue.record("expected notMaterialized, got \(outcome)")
            return
        }
        #expect(checker.callCount == 2)
    }

    @Test func evictionAfterMetadataGateSkipsThumbnail() async throws {
        let temp = try makeTestDirectory()
        let thumbnailDirectory = temp.appending(path: "Thumbnails")
        let url = fixtureDirectory.appending(path: "jpeg-exif-offset-date.jpg")
        let checker = SequencedReadinessChecker([.materialized, .materialized, .dataless])
        let enricher = MediaEnricher.live(
            thumbnailDirectory: thumbnailDirectory,
            readinessChecker: checker
        )
        let outcome = await enricher.enrich(
            MediaAssetID(
                libraryRootPath: LibraryRootPath(rawValue: "/Lib"),
                relativePath: MediaRelativePath(rawValue: "a.jpg")
            ),
            .localFile(url),
            100,
            1000,
            [.metadata, .rendering, .hash], nil
        )
        guard case .notMaterialized = outcome else {
            Issue.record("expected notMaterialized, got \(outcome)")
            return
        }
        #expect(checker.callCount == 3)
        #expect(!FileManager.default.fileExists(atPath: thumbnailDirectory.path))
    }

    @Test func materializedEnrichmentUsesOneGatePerBytePhase() async throws {
        let temp = try makeTestDirectory()
        let checker = SequencedReadinessChecker([.materialized, .materialized, .materialized])
        let enricher = MediaEnricher.live(
            thumbnailDirectory: temp.appending(path: "Thumbnails"),
            readinessChecker: checker
        )
        let outcome = await enricher.enrich(
            MediaAssetID(
                libraryRootPath: LibraryRootPath(rawValue: "/Lib"),
                relativePath: MediaRelativePath(rawValue: "a.jpg")
            ),
            .localFile(fixtureDirectory.appending(path: "jpeg-exif-offset-date.jpg")),
            100,
            1000,
            [.metadata, .rendering, .hash], nil
        )
        guard case .complete = outcome else {
            Issue.record("expected complete enrichment, got \(outcome)")
            return
        }
        #expect(checker.callCount == 3)
    }

    /// ENR-013: a `.removableVolume` source (ADR 0018) is never hashed in place, so
    /// its enrichment performs no full-file read. Assert against a spy hasher rather
    /// than elapsed time — a regression that hashes-and-discards would still return a
    /// nil contentHash, so only observing the hash call itself catches it.
    @Test func removableSourceEnrichmentNeverCallsContentHasher() async throws {
        let temp = try makeTestDirectory()
        let thumbnailDirectory = temp.appending(path: "Thumbnails", directoryHint: .isDirectory)
        let url = fixtureDirectory.appending(path: "jpeg-exif-offset-date.jpg")
        let hasherCalls = Mutex(0)
        let enricher = MediaEnricher.live(
            thumbnailDirectory: thumbnailDirectory,
            contentHasher: { _ in
                hasherCalls.withLock { $0 += 1 }
                return .cancelled
            }
        )
        let id = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/Volumes/CARD"),
            relativePath: MediaRelativePath(rawValue: "a.jpg")
        )

        let outcome = await enricher.enrich(id, .localFile(url), 100, 1000, .metadata, nil)
        guard case let .complete(result) = outcome else {
            Issue.record("expected .complete for removable source, got \(outcome)")
            return
        }
        #expect(result.contentHash == nil)
        #expect(hasherCalls.withLock { $0 } == 0)
    }

    /// A digest-only claim (a card's second pass, ADR 0018) hashes the file and returns the
    /// digest alone: nothing is parsed and no thumbnail is rendered.
    @Test func aDigestOnlyClaimHashesWithoutRenderingAnything() async throws {
        let temp = try makeTestDirectory()
        let thumbnailDirectory = temp.appending(path: "Thumbnails", directoryHint: .isDirectory)
        let url = fixtureDirectory.appending(path: "jpeg-exif-offset-date.jpg")
        let digest = try #require(ContentDigest(data: Data(repeating: 3, count: ContentDigest.byteCount)))
        let enricher = MediaEnricher.live(
            thumbnailDirectory: thumbnailDirectory,
            readinessChecker: TestEnrichmentReadinessChecker(result: .materialized),
            contentHasher: { _ in .complete(digest) }
        )
        let id = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/Volumes/CARD"),
            relativePath: MediaRelativePath(rawValue: "a.jpg")
        )

        let outcome = await enricher.enrich(id, .localFile(url), 100, 1000, .hash, nil)

        guard case let .hashed(result) = outcome else {
            Issue.record("expected .hashed for a digest-only claim, got \(outcome)")
            return
        }
        #expect(result == ContentHashResult(id: id, contentHash: digest, sourceSize: 100, sourceMTimeSeconds: 1000))
        #expect(!FileManager.default.fileExists(atPath: thumbnailDirectory.path))
    }
}
