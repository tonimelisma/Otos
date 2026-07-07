import Foundation
import Testing

@Suite(.serialized)
struct CatalogBrowserSourceHygieneTests {
    @Test func appKitGridDoesNotPruneTileDetailsDuringStructuralApply() throws {
        // `applyStructure` lives in MediaAssetCollectionStructuralApply.swift (spec 0048).
        let content = try appSource("Otos/Views/MediaAssetCollectionStructuralApply.swift")
        let applyStart = try #require(content.range(of: "func applyStructure("))
        let nextFunctionStart = try #require(content.range(of: "private func logStartedStructuralApply("))
        let applyBody = content[applyStart.lowerBound ..< nextFunctionStart.lowerBound]

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

    @Test func appKitGridUsesNativeTelemetryWithOnlyCoarseJSONLAggregates() throws {
        let bridge = try appSource("Otos/Views/MediaAssetCollectionView.swift")
        let structuralApply = try appSource("Otos/Views/MediaAssetCollectionStructuralApply.swift")
        let viewModel = try appSource("Otos/ViewModels/CatalogWindowViewModel.swift")
        let gridTelemetry = try appSource("Otos/ViewModels/CatalogWindowViewModelGridTelemetry.swift")
        let app = try appSource("Otos/OtosApp.swift")
        let content = bridge + structuralApply + viewModel + gridTelemetry

        #expect(content.contains("operation: \"ui.mediaGrid.structuralApply\""))
        #expect(content.contains("operation: \"ui.grid.counters\""))
        #expect(app.contains("NSApplication.willTerminateNotification"))
        #expect(app.contains("recordGridTelemetryForTermination()"))
        #expect(gridTelemetry.contains("phase: \"willTerminate\""))
        #expect(gridTelemetry.contains("try await Task.sleep(for: sleepDuration)"))
        #expect(gridTelemetry.contains("sleepDuration = .seconds(60)"))
        #expect(!content.contains("operation: \"ui.mediaGrid.visible"))
        #expect(!content.contains("operation: \"ui.mediaGrid.cell"))
        #expect(content.contains("Task { [weak self, detailReader, visibleIDs]"))
        #expect(content.contains("OtosLog.ui"))
        #expect(content.contains("OtosSignpost.ui"))
    }

    @Test func appKitGridUsesMeasuredReloadDataFallbackForLargeOrReorderApplies() throws {
        let bridge = try appSource("Otos/Views/MediaAssetCollectionView.swift")
        let support = try appSource("Otos/Views/MediaAssetCollectionSupport.swift")
        let structuralApply = try appSource("Otos/Views/MediaAssetCollectionStructuralApply.swift")
        let bridgeAndSupport = bridge + support

        #expect(bridgeAndSupport.contains("MediaGridStructuralApplyPolicy"))
        #expect(bridgeAndSupport.contains("let reorderOnly ="))
        #expect(bridgeAndSupport.contains("let usesReloadDataFallback = reorderOnly || largeApply"))
        #expect(bridgeAndSupport.contains("animatingDifferences: !usesReloadDataFallback"))
        // `applyStructure`/`applySnapshot` moved into MediaAssetCollectionStructuralApply.swift
        // alongside `completeStructuralApply` (spec 0048) to keep the bridge file under the
        // repo's file-length lint budget; the apply call site lives there now.
        #expect(structuralApply.contains("dataSource.apply("))
        #expect(structuralApply.contains("animatingDifferences: summary.animatingDifferences"))
        #expect(!structuralApply.contains("NSAnimationContext.runAnimationGroup"))
        #expect(!bridge.contains("largeReorderAnimationItemLimit"))
        #expect(!bridge.contains("countsStructuralApplyReloads"))
        #expect(!bridge.contains("structuralApplyReloadsStarted"))
        #expect(!bridge.contains("visibleReloadsStarted"))
        #expect(structuralApply.contains("\"reorderOnly\": \"\\(reorderOnly)\""))
        #expect(structuralApply.contains("\"largeApply\": \"\\(largeApply)\""))
        #expect(structuralApply.contains("\"animatingDifferences\": \"\\(animatingDifferences)\""))
        #expect(structuralApply.contains("\"reloadDataFallback\": \"\\(usesReloadDataFallback)\""))
        #expect(structuralApply.contains("\"visibleDetailRequestCount\": \"\\(visibleDetailRequestCount)\""))
    }

    @Test func preheaterCoalescesBurstsIntoOneStoreRead() throws {
        let prefetch = try appSource("Otos/Views/MediaAssetCollectionPrefetch.swift")

        #expect(prefetch.contains("detailReader.details(for: ids)"))
        #expect(prefetch.contains("preheatTask = Task.detached"))
        #expect(prefetch.contains("canReuseCurrentPreheat(for: requestedIDs)"))
        #expect(prefetch.contains("requestedIDs.isSubset(of: preheatIDs)"))
        #expect(prefetch.contains("preheatIDs.subtract(cancelledIDs)"))
        #expect(prefetch.contains("let activeDetails = details.filter"))
        #expect(prefetch.contains("preheatGeneration += 1"))
        #expect(!prefetch.contains("detailReader.details(for: [id])"))
        #expect(!prefetch.contains("for id in ids where preheatTasks"))
        #expect(!prefetch.contains("preheatTasks:"))
    }

    @Test func tileOverlayRemovesFilenameDateLabelsAndKeepsVideoBadgeCornerMask() throws {
        let tile = try appSource("Otos/Views/MediaAssetTileView.swift")
        let presentation = try appSource("Otos/Views/MediaAssetTilePresentation.swift")

        #expect(tile.contains("videoBadge.layer?.maskedCorners = [.layerMinXMaxYCorner]"))
        #expect(!tile.contains("textScrim"))
        #expect(!tile.contains("titleField"))
        #expect(!tile.contains("dateField"))
        #expect(!presentation.contains("captureDateText"))
        #expect(!tile.contains("imageView.image = nil"))
    }

    @Test func materializationDiagnosticsRetainResultAndClaimFailures() throws {
        let materialization = try appSource("Otos/Services/FileMaterialization.swift")
        let coordinator = try appSource("Otos/Services/EnrichmentCoordinator.swift")
            + appSource("Otos/Services/EnrichmentCoordinatorCompletion.swift")
        let script = try appSource("script/catalog-diagnostics.sh")

        #expect(materialization.contains("struct MaterializationResult"))
        #expect(materialization.contains("requestRetryInterval: Duration = .seconds(1)"))
        #expect(coordinator.contains("MaterializationResult"))
        #expect(coordinator.contains("\"rerequestCount\": \"\\(result.rerequestCount)\""))
        #expect(coordinator.contains("\"requestToCompleteMs\": \"\\(result.elapsedMs)\""))
        #expect(coordinator.contains("phase: \"claimReleaseFailed\""))
        #expect(coordinator.contains("phase: \"claimRefreshFailed\""))
        #expect(coordinator.contains("static let diagnosticTimestampFormatter"))
        #expect(!coordinator.contains("try? await store.releaseEnrichmentClaims([id])"))
        #expect(!coordinator.contains("try? await store.refreshEnrichmentClaims([id])"))
        #expect(script.contains("ui.grid.counters record missing"))
        #expect(script.contains("ui.grid.counters interval-or-termination record missing"))
        #expect(script.contains("DIAGNOSTICS_FILE=\"$COPY_FILE\""))
        #expect(script.contains("slow single-row tile-detail records present"))
        #expect(script.contains("download completion records missing rerequestCount/requestToCompleteMs"))
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
