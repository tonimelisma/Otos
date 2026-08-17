import Foundation
@testable import OtosKit
import Synchronization
import Testing

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

    @Test func enrichesJpegFixtureWithMetadataThumbnailAndTimestampFacts() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let thumbnailDirectory = temp.appending(path: "Thumbnails", directoryHint: .isDirectory)
        let enricher = MediaEnricher.live(thumbnailDirectory: thumbnailDirectory)
        let url = fixtureDirectory.appending(path: "jpeg-exif-offset-date.jpg")
        let id = MediaAssetID(
            libraryRootPath: LibraryRootPath(rawValue: "/Lib"),
            relativePath: MediaRelativePath(rawValue: "a.jpg")
        )

        let outcome = await enricher.enrich(id, url, 100, 1000, true)
        guard case let .complete(result) = outcome else {
            Issue.record("expected .complete, got \(outcome)")
            return
        }
        #expect(result.timestampFacts.original != nil)
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

    @Test func zeroByteStubIsDefinitiveCompleteWithoutThumbnail() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
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

        let outcome = await enricher.enrich(id, stubURL, 0, 1000, true)
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
        let outcome = await enricher.enrich(id, textURL, 9, 1000, true)
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

        let outcome = await enricher.enrich(id, missing, 100, 1000, true)
        guard case .notMaterialized = outcome else {
            Issue.record("expected .notMaterialized for a missing file, got \(outcome)")
            return
        }
    }

    @Test func evictionAfterHashGateSkipsMetadata() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
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
            url,
            100,
            1000,
            true
        )
        guard case .notMaterialized = outcome else {
            Issue.record("expected notMaterialized, got \(outcome)")
            return
        }
        #expect(checker.callCount == 2)
    }

    @Test func evictionAfterMetadataGateSkipsThumbnail() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
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
            url,
            100,
            1000,
            true
        )
        guard case .notMaterialized = outcome else {
            Issue.record("expected notMaterialized, got \(outcome)")
            return
        }
        #expect(checker.callCount == 3)
        #expect(!FileManager.default.fileExists(atPath: thumbnailDirectory.path))
    }

    @Test func materializedEnrichmentUsesOneGatePerBytePhase() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
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
            fixtureDirectory.appending(path: "jpeg-exif-offset-date.jpg"),
            100,
            1000,
            true
        )
        guard case .complete = outcome else {
            Issue.record("expected complete enrichment, got \(outcome)")
            return
        }
        #expect(checker.callCount == 3)
    }

    /// Plan 0062: a `.removableVolume` source (ADR 0018) is never hashed in place, so
    /// its enrichment performs no full-file read. Assert against a spy hasher rather
    /// than elapsed time — a regression that hashes-and-discards would still return a
    /// nil contentHash, so only observing the hash call itself catches it.
    @Test func removableSourceEnrichmentNeverCallsContentHasher() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
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

        let outcome = await enricher.enrich(id, url, 100, 1000, false)
        guard case let .complete(result) = outcome else {
            Issue.record("expected .complete for removable source, got \(outcome)")
            return
        }
        #expect(result.contentHash == nil)
        #expect(hasherCalls.withLock { $0 } == 0)
    }
}
