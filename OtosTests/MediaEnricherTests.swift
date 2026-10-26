import CoreGraphics
import Foundation
@testable import OtosKit
import Synchronization
import Testing

@Suite(.testDirectory)
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
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/Media", directoryHint: .isDirectory)
    }

    /// APP-015, at the seam where two owners write the same column.
    ///
    /// A camera row's provisional thumbnail is written at enumeration by one type; its
    /// enrichment result is written by another. `EnrichmentResult` resolves
    /// `generatedThumbnail?.finalRelativePath ?? thumbnailPath`, so a device pass that
    /// produced no preview and reported nil for both *cleared* the column — pointing the
    /// tile at nothing while its image sat on disk under the deterministic name.
    ///
    /// Found on a live 991-item card: 684 rows lost their thumbnail with all 8,606 files
    /// still present. Neither owner's tests could see it alone.
    @Test func aDeviceRowKeepsItsProvisionalThumbnailWhenNoPreviewIsProduced() throws {
        let directory = try makeTestDirectory()
        let id = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/DeviceStaging/Cam"),
            relativePath: MediaRelativePath(rawValue: "DSC00001.ARW")
        )
        let name = ThumbnailStore.relativeName(for: id)
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: directory.appending(path: name))

        let result = EnrichmentResult(
            id: id,
            metadata: AssetMetadata(),
            enrichedKind: nil,
            enrichedFormat: nil,
            thumbnailPath: MediaEnricher.testExistingThumbnailName(for: id, in: directory),
            sourceSize: 1,
            sourceMTimeSeconds: 1,
            contentHash: nil,
            generatedThumbnail: nil
        )

        #expect(
            result.thumbnailPath == name,
            "a pass with no new thumbnail must keep the one already on disk, not blank the tile"
        )
    }

    /// The other half: a row with nothing on disk still reports nothing, rather than a path
    /// that resolves to a missing file.
    @Test func aRowWithNoThumbnailOnDiskReportsNone() throws {
        let directory = try makeTestDirectory()
        let id = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/DeviceStaging/Cam"),
            relativePath: MediaRelativePath(rawValue: "absent.arw")
        )
        #expect(MediaEnricher.testExistingThumbnailName(for: id, in: directory) == nil)
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

        let outcome = await enricher.enrich(id, .localFile(url), 100, 1000, true, nil)
        guard case let .complete(result) = outcome else {
            Issue.record("expected .complete, got \(outcome)")
            return
        }
        #expect(BestCaptureInstants.from(result.metadata.timestamps).original != nil)
        #expect(!result.metadata.timestamps.isEmpty)
        #expect(result.metadata.family != nil)
        #expect(result.sourceSize == 100)
        #expect(result.sourceMTimeSeconds == 1000)

        let thumbnailPath = try #require(result.thumbnailPath)
        let generatedThumbnail = try #require(result.generatedThumbnail)
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
            id, .localFile(fixtureDirectory.appending(path: "ios-heic-offset-date.heic")), 100, 1000, true, nil
        )
        guard case let .complete(result) = outcome else {
            Issue.record("expected .complete, got \(outcome)")
            return
        }
        let preview = try #require(result.generatedPreview)
        #expect(result.previewPath == ThumbnailStore.previewRelativeName(for: id))
        let previewImage = try #require(ThumbnailStore.load(preview.stagedRelativePath, in: directory))
        #expect(max(previewImage.width, previewImage.height) <= ThumbnailStore.previewMaxPixelSize)
        let thumbnail = try #require(result.generatedThumbnail)
        let thumbnailImage = try #require(ThumbnailStore.load(thumbnail.stagedRelativePath, in: directory))
        #expect(max(thumbnailImage.width, thumbnailImage.height) <= ThumbnailStore.maxPixelSize)
        #expect(!FileManager.default.fileExists(atPath: ThumbnailStore.url(for: preview.finalRelativePath, in: directory)
                .path(percentEncoded: false)))
    }

    /// A HEIF that records its rotation only in its `irot` property (as Sony cameras write
    /// it) is cataloged with that orientation, so its upright size is right.
    @Test func aHeifTurnedByItsIrotPropertyIsReadWithItsOrientation() async throws {
        let temp = try makeTestDirectory()
        let file = temp.appending(path: "turned.heic")
        try writeIrotOnlyHEIC(to: file)
        let enricher = MediaEnricher.live(thumbnailDirectory: temp.appending(path: "Thumbnails", directoryHint: .isDirectory))
        let id = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/Lib"),
            relativePath: MediaRelativePath(rawValue: "turned.heic")
        )
        let outcome = await enricher.enrich(id, .localFile(file), 100, 1000, true, nil)
        guard case let .complete(result) = outcome else {
            Issue.record("expected .complete, got \(outcome)")
            return
        }
        #expect(result.metadata.orientation == 6)
        #expect(result.metadata.pixelWidth == 96)
        #expect(result.metadata.pixelHeight == 64)
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
            id, .localFile(fixtureDirectory.appending(path: "mov-no-embedded-capture-date.mov")), 100, 1000, true, nil
        )
        guard case let .complete(result) = outcome else {
            Issue.record("expected .complete, got \(outcome)")
            return
        }
        #expect(result.generatedPreview == nil)
        #expect(result.previewPath == nil)
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

        let outcome = await enricher.enrich(id, .localFile(stubURL), 0, 1000, true, nil)
        guard case let .complete(result) = outcome else {
            Issue.record("expected .complete for zero-byte stub, got \(outcome)")
            return
        }
        #expect(result.thumbnailPath == nil)
        #expect(result.generatedThumbnail == nil)
        #expect(result.sourceSize == 0)
        #expect(result.sourceMTimeSeconds == 1000)
    }

    @Test func unsupportedFileIsDefinitiveComplete() async throws {
        let temp = try makeTestDirectory()
        let thumbnailDirectory = temp.appending(path: "Thumbnails", directoryHint: .isDirectory)
        let textURL = temp.appending(path: "note.txt")
        try Data("not media".utf8).write(to: textURL)
        let enricher = MediaEnricher.live(thumbnailDirectory: thumbnailDirectory)
        let id = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/Lib"),
            relativePath: MediaRelativePath(rawValue: "note.txt")
        )

        // Unsupported is definitive (stamped, never retried), even with empty metadata.
        let outcome = await enricher.enrich(id, .localFile(textURL), 9, 1000, true, nil)
        guard case .complete = outcome else {
            Issue.record("expected .complete for unsupported, got \(outcome)")
            return
        }
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

        let outcome = await enricher.enrich(id, .localFile(missing), 100, 1000, true, nil)
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
            true, nil
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
            true, nil
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
            true, nil
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

        let outcome = await enricher.enrich(id, .localFile(url), 100, 1000, false, nil)
        guard case let .complete(result) = outcome else {
            Issue.record("expected .complete for removable source, got \(outcome)")
            return
        }
        #expect(result.contentHash == nil)
        #expect(hasherCalls.withLock { $0 } == 0)
    }
}
