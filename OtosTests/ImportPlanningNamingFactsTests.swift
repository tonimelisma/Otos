import Foundation
@testable import OtosKit
import Testing

/// `naming_settled` is derived from the enrichment staleness predicate, which
/// compares `content_modified_at_unix` against `enriched_source_mtime`. An asset
/// with neither can never satisfy it, so it reads "stale" forever — even after
/// enrichment has supplied the capture wall that names it. Planning asks a
/// different question and must not inherit that permanent answer.
struct ImportPlanningNamingFactsTests {
    @Test func aKnownCaptureWallIsTerminalEvenWhenEnrichmentCanNeverSettle() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let cardURL = temp.appending(path: "Card", directoryHint: .isDirectory)
        let destinationURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cardURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardURL)
        let destinationPath = try CatalogPath.normalizedDirectoryPath(for: destinationURL)
        let relative = MediaRelativePath(rawValue: "undated.jpg")

        // No `createdAt`, no `contentModifiedAt`: the filesystem reported no date
        // at all, which is what makes the staleness comparison unsatisfiable.
        let scanner = CatalogScanner { rootPath, _, batchHandler in
            guard rootPath == cardPath else { return .empty }
            try await batchHandler([
                ScannedMediaFile(
                    relativePath: relative,
                    name: relative.rawValue,
                    contentTypeIdentifier: "public.jpeg",
                    byteSize: 10,
                    createdAt: nil,
                    contentModifiedAt: nil
                ),
            ])
            return .mediaOnly([relative])
        }

        let store = CatalogStore(location: .inMemory, scanner: scanner, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destinationURL)
        try await store.attachRemovableVolume(
            mountURL: cardURL,
            identity: "volume:naming-facts",
            displayName: "Card",
            isEjectable: true
        )

        let policy = ImportPolicy.from(.default)
        func snapshotFacts() async throws -> PlanningFileFacts? {
            try await store.importPlanningSnapshot(
                source: cardPath,
                destination: destinationPath,
                policy: policy,
                generation: 1
            )?.sourceMedia.first
        }

        var scanned: PlanningFileFacts?
        let deadline = ContinuousClock().now + .seconds(5)
        while ContinuousClock().now < deadline {
            if let facts = try await snapshotFacts() {
                scanned = facts
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        let beforeEnrichment = try #require(scanned)
        #expect(beforeEnrichment.namingFactState == .pending)
        #expect(!beforeEnrichment.hasAnyDate)

        // Enrichment finds an embedded capture date and, like the filesystem,
        // reports no mtime. `naming_settled` stays 0 for the life of this row.
        let captureDate = Date(timeIntervalSince1970: 1_767_279_600)
        let applied = await store.applyEnrichmentBatch([
            EnrichmentResult(
                id: MediaAssetID(libraryRootPath: cardPath, relativePath: relative),
                // `capture_wall_compact` — the authoritative naming fact — is
                // derived by `CaptureWallClock.select(from:)` over
                // `metadata.timestamps`, not from `timestampFacts`, which only
                // populate the individual `ts_*_unix` columns.
                metadata: AssetMetadata(timestamps: [
                    CaptureTimestampRecord(
                        role: "original",
                        instant: captureDate,
                        utcOffsetSeconds: nil,
                        precision: "localFloating",
                        year: 2026,
                        month: 1,
                        day: 1,
                        hour: 12,
                        minute: 0,
                        second: 0
                    ),
                ]),
                timestampFacts: EnrichmentTimestampFacts(original: captureDate),
                thumbnailPath: nil,
                sourceSize: 10,
                sourceMTimeSeconds: nil,
                contentHash: nil
            ),
        ])
        #expect(applied == .applied(count: 1))

        let afterEnrichment = try #require(try await snapshotFacts())
        #expect(afterEnrichment.captureWallCompact != nil)
        #expect(afterEnrichment.hasAnyDate)
        // Terminal, not settled: enrichment is still nominally outstanding, but
        // nothing it can add improves this name, so planning must not wait.
        #expect(afterEnrichment.namingFactState == .terminal)
    }

    @Test func aDurableMtimeIsTerminalBeforeEnrichmentRuns() async throws {
        let temp = try makeCatalogStoreTemporaryDirectory()
        let cardURL = temp.appending(path: "Card", directoryHint: .isDirectory)
        let destinationURL = temp.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cardURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        let cardPath = try CatalogPath.normalizedDirectoryPath(for: cardURL)
        let destinationPath = try CatalogPath.normalizedDirectoryPath(for: destinationURL)
        let relative = MediaRelativePath(rawValue: "dated.jpg")

        let scanner = CatalogScanner { rootPath, _, batchHandler in
            guard rootPath == cardPath else { return .empty }
            try await batchHandler([
                ScannedMediaFile(
                    relativePath: relative,
                    name: relative.rawValue,
                    contentTypeIdentifier: "public.jpeg",
                    byteSize: 10,
                    createdAt: Date(timeIntervalSince1970: 1000),
                    contentModifiedAt: Date(timeIntervalSince1970: 1000)
                ),
            ])
            return .mediaOnly([relative])
        }

        let store = CatalogStore(location: .inMemory, scanner: scanner, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destinationURL)
        try await store.attachRemovableVolume(
            mountURL: cardURL,
            identity: "volume:naming-facts-mtime",
            displayName: "Card",
            isEjectable: true
        )

        let policy = ImportPolicy.from(.default)
        var scanned: PlanningFileFacts?
        let deadline = ContinuousClock().now + .seconds(5)
        while ContinuousClock().now < deadline {
            if let facts = try await store.importPlanningSnapshot(
                source: cardPath,
                destination: destinationPath,
                policy: policy,
                generation: 1
            )?.sourceMedia.first {
                scanned = facts
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        let facts = try #require(scanned)
        #expect(facts.namingFactState == .terminal)
        #expect(facts.captureWallCompact == nil)
    }
}
