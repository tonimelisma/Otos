import Foundation
@testable import OtosKit
import Testing

/// `naming_settled` is derived from the enrichment staleness predicate, which
/// compares `content_modified_at_unix` against `metadata_source_mtime`. An asset
/// with neither can never satisfy it, so it reads "stale" forever — even after
/// enrichment has supplied the capture wall that names it. Planning asks a
/// different question and must not inherit that permanent answer.
@Suite(.testScope)
struct ImportPlanningNamingFactsTests {
    @Test func aKnownCaptureWallIsTerminalEvenWhenEnrichmentCanNeverSettle() async throws {
        let temp = try makeTestDirectory()
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

        let store = makeTestStore(location: .inMemory, scanner: scanner, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destinationURL)
        try await store.attachRemovableVolume(
            mountURL: cardURL,
            identity: .volume(uuid: "naming-facts"),
            displayName: "Card",
            isEjectable: true,
            capabilities: .unknown
        )

        let policy = ImportPolicy.from(.default)
        func snapshotFacts() async throws -> PlanningFileFacts? {
            try await store.windowReads.importPlanningSnapshot(
                source: cardPath,
                destination: destinationPath,
                policy: policy,
                generation: 1
            )?.sourceMedia.first
        }

        let beforeEnrichment = try await waitForValue(every: .milliseconds(25)) { try await snapshotFacts() }
        #expect(beforeEnrichment.namingFactState == .pending)
        #expect(!beforeEnrichment.hasAnyDate)

        // Enrichment finds an embedded capture date and, like the filesystem,
        // reports no mtime. `naming_settled` stays 0 for the life of this row.
        let captureDate = Date(timeIntervalSince1970: 1_767_279_600)
        let applied = await store.applyEnrichmentBatch([
            EnrichmentResult(
                id: MediaAssetID(libraryRootPath: cardPath, relativePath: relative),
                // `metadata.timestamps` is the one stored timestamp truth; both
                // `capture_wall_compact` (via `CaptureWallClock`) and the
                // `capture_instant_unix` ordering column (via `CaptureInstant`) are
                // derived from it where they are written.
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
                thumbnailPath: nil,
                sourceSize: 10,
                sourceMTimeSeconds: nil,
                contentHash: nil
            ),
        ])
        #expect(applied == .applied(count: 1))

        let afterEnrichment = try #require(try await snapshotFacts())
        // The record's floating wall clock, 2026-01-01 12:00:00, verbatim.
        #expect(afterEnrichment.captureWallCompact == 20_260_101_120_000)
        #expect(afterEnrichment.hasAnyDate)
        // Terminal, not settled: enrichment is still nominally outstanding, but
        // nothing it can add improves this name, so planning must not wait.
        #expect(afterEnrichment.namingFactState == .terminal)
    }

    /// ARC-057: a durable mtime is not a naming fact *before* enrichment has read the
    /// file. "No capture wall" on an unread row means "we have not looked", not "there
    /// is none" — and naming from mtime there fabricates
    /// a fact. For video the fabrication is provably wrong by the clip's duration
    /// (mtime is when recording *stopped*), and since the destination name is also the
    /// dedupe key, the next plan looks at a different path, finds nothing, and copies
    /// again. Field evidence: 23 videos imported twice, five minutes apart.
    ///
    /// A durable mtime becomes an honest fallback the moment enrichment has looked and
    /// found no embedded wall — proven absence, not assumed. That is the next test.
    @Test func aDurableMtimeIsPendingUntilEnrichmentHasLooked() async throws {
        let temp = try makeTestDirectory()
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

        let store = makeTestStore(location: .inMemory, scanner: scanner, scanCadence: .milliseconds(10))
        try await store.start(scansSavedLibraries: false)
        try await store.addLibrary(url: destinationURL)
        try await store.attachRemovableVolume(
            mountURL: cardURL,
            identity: .volume(uuid: "naming-facts-mtime"),
            displayName: "Card",
            isEjectable: true,
            capabilities: .unknown
        )

        let policy = ImportPolicy.from(.default)
        let facts = try await waitForValue(every: .milliseconds(25)) {
            try await store.windowReads.importPlanningSnapshot(
                source: cardPath,
                destination: destinationPath,
                policy: policy,
                generation: 1
            )?.sourceMedia.first
        }
        #expect(facts.namingFactState == .pending)
        #expect(facts.captureWallCompact == nil)
        // The mtime is right there and unchanged — what is missing is not a date but
        // the proof that no *better* date exists.
        #expect(facts.hasAnyDate)

        // Enrichment reads the file and finds no embedded capture wall. Absence is now
        // proven, so the filesystem mtime becomes an honest fallback and planning
        // proceeds — without this the gate would never open for a file that genuinely
        // carries no metadata (the permanent-wait failure ADR 0026 exists to prevent).
        let applied = await store.applyEnrichmentBatch([
            EnrichmentResult(
                id: MediaAssetID(libraryRootPath: cardPath, relativePath: relative),
                metadata: AssetMetadata(),
                thumbnailPath: nil,
                sourceSize: 10,
                sourceMTimeSeconds: 1000,
                contentHash: nil
            ),
        ])
        #expect(applied == .applied(count: 1))

        let afterEnrichment = try #require(
            try await store.windowReads.importPlanningSnapshot(
                source: cardPath,
                destination: destinationPath,
                policy: policy,
                generation: 2
            )?.sourceMedia.first
        )
        #expect(afterEnrichment.captureWallCompact == nil)
        #expect(afterEnrichment.namingFactState != .pending)
    }
}
