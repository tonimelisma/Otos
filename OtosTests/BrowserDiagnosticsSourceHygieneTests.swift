import Foundation
import Testing

struct BrowserDiagnosticsSourceHygieneTests {
    @Test func browserDiagnosticsAvoidHighCardinalityLogSpam() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let tile = try String(
            contentsOf: repoRoot.appending(path: "Otos/Views/MediaAssetTileView.swift"),
            encoding: .utf8
        )
        let grid = try String(
            contentsOf: repoRoot.appending(path: "Otos/Views/MediaAssetCollectionView.swift"),
            encoding: .utf8
        )
        let store = try String(
            contentsOf: repoRoot.appending(path: "Otos/Stores/CatalogStore.swift"),
            encoding: .utf8
        )
        let scanner = try String(
            contentsOf: repoRoot.appending(path: "Otos/Services/CatalogScanner.swift"),
            encoding: .utf8
        )

        #expect(tile.contains("OtosSignpost.ui.emitEvent(\"MediaTileLoadStarted\")"))
        #expect(tile.contains("OtosSignpost.ui.emitEvent(\"MediaTilePrepareForReuse\")"))
        #expect(!tile.contains("Media tile load started"))
        #expect(!tile.contains("Media tile load applied"))
        #expect(!tile.contains("Media tile content unchanged"))
        #expect(!tile.contains("Media tile prepared for reuse"))

        #expect(grid.contains("catch is CancellationError"))
        #expect(grid.contains("Media tile detail query failed error="))

        #expect(store.contains("slowQueryDiagnosticThresholdMs"))
        #expect(store.contains("\"thresholdMs\": \"\\(Self.slowQueryDiagnosticThresholdMs)\""))
        #expect(store.contains("Catalog slow tile details query"))
        #expect(store.contains("Catalog slow enrichment candidates query"))
        #expect(!store.contains("Catalog tile details queried requested="))
        #expect(!store.contains("Catalog enrichment candidates queried priority="))

        #expect(scanner.contains("issueExampleLimitPerKey"))
        #expect(scanner.contains("filesystemIssueBuckets"))
        #expect(!scanner.contains("operation: \"catalog.scan.issue\""))
    }
}
