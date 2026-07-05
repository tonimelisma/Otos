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

    @Test func appKitGridUsesTrueDiffingWithZeroDurationBackgroundSuppression() throws {
        let bridge = try appSource("Otos/Views/MediaAssetCollectionView.swift")
        let support = try appSource("Otos/Views/MediaAssetCollectionSupport.swift")
        let structuralApply = try appSource("Otos/Views/MediaAssetCollectionStructuralApply.swift")
        let bridgeAndSupport = bridge + support

        #expect(bridgeAndSupport.contains("MediaGridStructuralApplyPolicy"))
        #expect(bridgeAndSupport.contains("let reorderOnly ="))
        #expect(bridgeAndSupport.contains("let animatingDifferences = true"))
        #expect(bridgeAndSupport.contains("usesZeroDurationAnimation: reorderOnly || largeApply"))
        #expect(bridge.contains("NSAnimationContext.runAnimationGroup"))
        #expect(bridge.contains("dataSource.apply(snapshot, animatingDifferences: true"))
        #expect(!bridge.contains("largeReorderAnimationItemLimit"))
        #expect(!bridge.contains("animatingDifferences: !(reorderOnly"))
        #expect(!bridge.contains("countsStructuralApplyReloads"))
        #expect(!bridge.contains("structuralApplyReloadsStarted"))
        #expect(!bridge.contains("visibleReloadsStarted"))
        #expect(structuralApply.contains("\"reorderOnly\": \"\\(reorderOnly)\""))
        #expect(structuralApply.contains("\"largeApply\": \"\\(largeApply)\""))
        #expect(structuralApply.contains("\"animatingDifferences\": \"\\(animatingDifferences)\""))
        #expect(structuralApply.contains("\"zeroDuration\": \"\\(usesZeroDurationAnimation)\""))
        #expect(structuralApply.contains("\"visibleDetailRequestCount\": \"\\(visibleDetailRequestCount)\""))
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

        #expect(priorityBody.contains("let timedClaim = try await timedWrite(dbWriter)"))
        #expect(priorityBody.components(separatedBy: "try await timedWrite(dbWriter)").count - 1 == 1)
        #expect(priorityBody.contains("for (asset, rootID) in"))
        #expect(priorityBody.contains("candidates.count < limit"))
        #expect(priorityBody.contains("if result.totalMs > Self.slowQueryDiagnosticThresholdMs"))
        #expect(claimedBody.contains("if result.totalMs > Self.slowQueryDiagnosticThresholdMs"))
        #expect(!priorityBody.contains("let claimInputs = eligibleClaims"))
        #expect(!content.contains("NOT IN"))
    }

    @Test func visibleThumbnailLifecycleDiagnosticsStayCoordinatorBounded() throws {
        let content = try appSource("Otos/Services/EnrichmentCoordinator.swift")
            + appSource("Otos/Services/EnrichmentCoordinatorCompletion.swift")
            + appSource("Otos/Services/EnrichmentCoordinatorWorkSelection.swift")

        #expect(content.contains("diagnosedThumbnailLifecycleIDs"))
        #expect(content.contains("operation: \"catalog.thumbnails.visibleLifecycle\""))
        #expect(content.contains("viewport.contains(id)"))
        #expect(content.contains("batchAccepted"))
        #expect(!content.contains("operation: \"catalog.thumbnails.fileLifecycle\""))
    }

    @Test func filesystemEventsUseBatchJSONLInsteadOfReceiveAndDebounceSpam() throws {
        let content = try appSource("Otos/Stores/CatalogStore.swift")

        #expect(content.contains("filesystemEventBatchFields("))
        #expect(content.contains("\"flags\""))
        #expect(content.contains("\"actions\""))
        #expect(!content.contains("phase: \"receive\""))
        #expect(!content.contains("phase: \"debounce\""))
    }

    @Test func walDiagnosticsSampleSizeWithoutForcingCheckpoints() throws {
        let content = try appSource("Otos/Stores/CatalogStore.swift")

        #expect(content.contains("operation: \"catalog.database.wal\""))
        #expect(content.contains("phase: \"sample\""))
        #expect(content.contains("recordWALDiagnostics(reason: \"scanBatch\")"))
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
