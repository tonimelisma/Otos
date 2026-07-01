import Foundation
@testable import Otos
import Testing

struct MediaEnricherTests {
    private var fixtureDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/Media", directoryHint: .isDirectory)
    }

    @Test func enrichesJpegFixtureWithMetadataThumbnailAndCaptureDate() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let thumbnailDirectory = temp.appending(path: "Thumbnails", directoryHint: .isDirectory)
        let enricher = MediaEnricher.live(thumbnailDirectory: thumbnailDirectory)
        let url = fixtureDirectory.appending(path: "jpeg-exif-offset-date.jpg")
        let id = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/Lib"),
            relativePath: MediaRelativePath(rawValue: "a.jpg")
        )

        let outcome = await enricher.enrich(id, url, 100, 1000)
        guard case let .complete(result) = outcome else {
            Issue.record("expected .complete, got \(outcome)")
            return
        }
        #expect(result.captureDate != nil)
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

    @Test func unsupportedFileIsDefinitiveComplete() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let thumbnailDirectory = temp.appending(path: "Thumbnails", directoryHint: .isDirectory)
        let textURL = temp.appending(path: "note.txt")
        try Data("not media".utf8).write(to: textURL)
        let enricher = MediaEnricher.live(thumbnailDirectory: thumbnailDirectory)
        let id = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/Lib"),
            relativePath: MediaRelativePath(rawValue: "note.txt")
        )

        // Unsupported is definitive (stamped, never retried), even with empty metadata.
        let outcome = await enricher.enrich(id, textURL, 9, 1000)
        guard case .complete = outcome else {
            Issue.record("expected .complete for unsupported, got \(outcome)")
            return
        }
    }

    @Test func datalessRegressionRoutesBackToDownload() async throws {
        // A missing/unreadable path reports unknown status, so the gate refuses to read.
        let temp = try makeCatalogStoreTemporaryDirectory()
        let thumbnailDirectory = temp.appending(path: "Thumbnails", directoryHint: .isDirectory)
        let enricher = MediaEnricher.live(thumbnailDirectory: thumbnailDirectory)
        let missing = temp.appending(path: "gone.jpg")
        let id = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/Lib"),
            relativePath: MediaRelativePath(rawValue: "gone.jpg")
        )

        let outcome = await enricher.enrich(id, missing, 100, 1000)
        guard case .notMaterialized = outcome else {
            Issue.record("expected .notMaterialized for a missing file, got \(outcome)")
            return
        }
    }
}
