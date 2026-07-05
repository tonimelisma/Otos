import Foundation
import Testing

struct BrowserDiagnosticsSourceHygieneTests {
    @Test func browserDiagnosticsAvoidHighCardinalityLogSpam() throws {
        let sources = try BrowserDiagnosticsSources()

        #expect(sources.tile.contains("OtosSignpost.ui.emitEvent(\"MediaTileLoadStarted\")"))
        #expect(sources.tile.contains("OtosSignpost.ui.emitEvent(\"MediaTilePrepareForReuse\")"))
        #expect(!sources.tile.contains("Media tile load started"))
        #expect(!sources.tile.contains("Media tile load applied"))
        #expect(!sources.tile.contains("Media tile content unchanged"))
        #expect(!sources.tile.contains("Media tile prepared for reuse"))

        #expect(sources.grid.contains("catch is CancellationError"))
        #expect(sources.grid.contains("Media tile detail query failed error="))

        #expect(sources.store.contains("slowQueryDiagnosticThresholdMs"))
        #expect(sources.store.contains("\"thresholdMs\": \"\\(Self.slowQueryDiagnosticThresholdMs)\""))
        #expect(sources.store.contains("Catalog slow tile details query"))
        #expect(sources.store.contains("Catalog slow enrichment candidates query"))
        #expect(!sources.store.contains("Catalog tile details queried requested="))
        #expect(!sources.store.contains("Catalog enrichment candidates queried priority="))

        #expect(sources.scanner.contains("issueExampleLimitPerKey"))
        #expect(sources.scanner.contains("issueSummaryLimit"))
        #expect(sources.scanner.contains("filesystemIssueBuckets"))
        #expect(sources.scanner.contains("stableIssueDescription"))
        let scannerUsesStringDescribingError = sources.scanner.contains("String(describing: error)")
        #expect(scannerUsesStringDescribingError == false)
        #expect(!sources.scanner.contains("operation: \"catalog.scan.issue\""))

        let initializer = try #require(sources.diagnostics.range(of: "init(\n"))
        let deinitializer = try #require(sources.diagnostics.range(of: "deinit {"))
        let record = try #require(sources.diagnostics.range(of: "func record("))
        let removeForTesting = try #require(sources.diagnostics.range(of: "func removeExistingDiagnosticsForTesting()"))
        let initializerBody = sources.diagnostics[initializer.lowerBound ..< deinitializer.lowerBound]
        let recordBody = sources.diagnostics[record.lowerBound ..< removeForTesting.lowerBound]
        #expect(!initializerBody.contains("prepareDefaultDirectory"))
        #expect(sources.diagnostics.contains("func prepareForLifecycle()"))
        #expect(sources.diagnostics.contains("prepareDefaultDirectoryIfNeeded()"))
        #expect(!recordBody.contains("prepareDefaultDirectory"))
    }
}

private struct BrowserDiagnosticsSources {
    let tile: String
    let grid: String
    let store: String
    let scanner: String
    let diagnostics: String

    init() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        tile = try Self.read("Otos/Views/MediaAssetTileView.swift", repoRoot: repoRoot)
        grid = try Self.read("Otos/Views/MediaAssetCollectionView.swift", repoRoot: repoRoot)
            + Self.read("Otos/Views/MediaAssetCollectionSupport.swift", repoRoot: repoRoot)
            + Self.read("Otos/Views/MediaAssetCollectionPrefetch.swift", repoRoot: repoRoot)
        store = try Self.read("Otos/Stores/CatalogStore.swift", repoRoot: repoRoot)
        scanner = try Self.read("Otos/Services/CatalogScanner.swift", repoRoot: repoRoot)
        diagnostics = try Self.read("Otos/Support/Diagnostics.swift", repoRoot: repoRoot)
    }

    private static func read(_ path: String, repoRoot: URL) throws -> String {
        try String(contentsOf: repoRoot.appending(path: path), encoding: .utf8)
    }
}
