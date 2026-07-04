import Foundation
import Testing

@Suite(.serialized)
struct CatalogBrowserSourceHygieneTests {
    @Test func appKitGridDoesNotPruneTileDetailsDuringStructuralApply() throws {
        let content = try appSource("Otos/Views/MediaAssetCollectionView.swift")
        let applyStart = try #require(content.range(of: "func applyStructure("))
        let visibleDetailStart = try #require(content.range(of: "func requestVisibleDetails("))
        let applyBody = content[applyStart.lowerBound ..< visibleDetailStart.lowerBound]

        #expect(!applyBody.contains("tileDetailsByID = tileDetailsByID.filter"))
        #expect(!applyBody.contains("grid.orderedAssetIDs.contains($0.key)"))
    }

    @Test func filterSurfacesShareAvailableKindMenuContent() throws {
        let toolbar = try appSource("Otos/Views/CatalogToolbarControls.swift")
        let app = try appSource("Otos/OtosApp.swift")

        #expect(toolbar.contains("struct CatalogFilterMenuContent"))
        #expect(toolbar.contains("options.availableKinds"))
        #expect(toolbar.contains("kindSymbol(kind, formats: formats)"))
        #expect(!toolbar.contains("MediaKind.displayOrder.filter { !options.formats"))
        #expect(app.contains("CatalogFilterMenuContent("))
        #expect(!app.contains("catalogViewModel.queryDescriptor.filter.kinds.contains(kind)"))
        #expect(!app.contains("if !formats.isEmpty"))
    }

    @Test func appKitGridUsesNativeTelemetryWithOnlyStructuralJSONLAggregates() throws {
        let bridge = try appSource("Otos/Views/MediaAssetCollectionView.swift")
        let structuralApply = try appSource("Otos/Views/MediaAssetCollectionStructuralApply.swift")
        let content = bridge + structuralApply

        #expect(content.contains("operation: \"ui.mediaGrid.structuralApply\""))
        #expect(!content.contains("operation: \"ui.mediaGrid.visible"))
        #expect(!content.contains("operation: \"ui.mediaGrid.cell"))
        #expect(content.contains("Task { [weak self, detailReader, visibleIDs]"))
        #expect(content.contains("OtosLog.ui"))
        #expect(content.contains("OtosSignpost.ui"))
    }

    @Test func appKitGridDoesNotReloadItemsForDetailRefresh() throws {
        let content = try appSource("Otos/Views/MediaAssetCollectionView.swift")

        #expect(content.contains("case let .refreshVisible(_, resetScroll, resetSelection):"))
        #expect(content.contains("requestVisibleDetails(reason: \"detailRefresh\")"))
        #expect(content.contains("reconfigureVisibleItems(reason: \"detailQuery\")"))
        #expect(content.contains("collectionView.item(at: indexPath)"))
        #expect(!content.contains("reloadItems(at:"))
    }

    @Test func enrichmentPriorityClaimsAreBatchedAndClaimDiagnosticsAreSlowOnly() throws {
        let content = try appSource("Otos/Stores/CatalogStore.swift")
        let priorityStart = try #require(content.range(of: "private func priorityEnrichmentCandidates("))
        let claimedStart = try #require(content.range(of: "private func claimedEnrichmentCandidates("))
        let startMethod = try #require(content.range(of: "func start(scansSavedLibraries:"))
        let priorityBody = content[priorityStart.lowerBound ..< claimedStart.lowerBound]
        let claimedBody = content[claimedStart.lowerBound ..< startMethod.lowerBound]

        #expect(priorityBody.contains("let timedClaim = try await dbWriter.write"))
        #expect(priorityBody.components(separatedBy: "try await dbWriter.write").count - 1 == 1)
        #expect(priorityBody.contains("let claimInputs = eligibleClaims"))
        #expect(priorityBody.contains("for (asset, rootID) in claimInputs"))
        #expect(priorityBody.contains("if result.queryMs > Self.slowQueryDiagnosticThresholdMs"))
        #expect(claimedBody.contains("if result.queryMs > Self.slowQueryDiagnosticThresholdMs"))
    }

    @Test func walDiagnosticsSampleSizeWithoutForcingCheckpoints() throws {
        let content = try appSource("Otos/Stores/CatalogStore.swift")

        #expect(content.contains("operation: \"catalog.database.wal\""))
        #expect(content.contains("phase: \"sample\""))
        #expect(content.contains("\"walBytes\""))
        #expect(!content.contains("wal_checkpoint"))
        #expect(!content.contains("passiveWALCheckpoint"))
    }
}

private func appSource(_ relativePath: String) throws -> String {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try String(contentsOf: repoRoot.appending(path: relativePath), encoding: .utf8)
}
