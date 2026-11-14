import Foundation
import OSLog

/// Projection diagnostics guide
///
/// `CatalogProjection` owns publication ordering and actor state; this file owns
/// the value-shaped diagnostics it emits after each completed publication. Keeping
/// the comparison and OSLog field construction here (`op=`/`key=value` for the
/// agent; interval signposts for Instruments) lets the actor read as publication
/// machinery while preserving the same bounded scalar diagnostics.
nonisolated struct CatalogProjectionBuildMetrics {
    let orderQueryMs: Int
}

nonisolated struct CatalogProjectionPublicationTiming {
    let storeReadMs: Int
    let projectionMs: Int
    let totalMs: Int
}

nonisolated struct CatalogProjectionCompletedPublication {
    let state: CatalogWindowState
    let buildMetrics: CatalogProjectionBuildMetrics
    let selectedDescriptor: CatalogQueryDescriptor
    let timing: CatalogProjectionPublicationTiming
}

nonisolated struct CatalogProjectionChangeSummary {
    let previousSelectedScopeAssetCount: Int
    let titleChanged: Bool
    let mediaIdentityChanged: Bool
    let librariesChanged: Bool
    let filterOptionsChanged: Bool
    let emptyStateChanged: Bool
    let resolvedSelectionChanged: Bool
    let detailRefreshChanged: Bool
    /// The map's located items or its left-off count moved without the identities
    /// moving — a re-enriched coordinate, or an item that gained one.
    let mapChanged: Bool
    /// Where the shown search stands moved: searching, read, or failed (ADR 0048).
    let searchPhaseChanged: Bool
    let mediaIdentityEqualityUs: Int

    var stateChanged: Bool {
        titleChanged
            || mediaIdentityChanged
            || librariesChanged
            || filterOptionsChanged
            || emptyStateChanged
            || resolvedSelectionChanged
            || detailRefreshChanged
            || mapChanged
            || searchPhaseChanged
    }

    static func compare(
        previous: CatalogWindowState?,
        current: CatalogWindowState
    ) -> CatalogProjectionChangeSummary {
        guard let previous else {
            return CatalogProjectionChangeSummary(
                previousSelectedScopeAssetCount: -1,
                titleChanged: true,
                mediaIdentityChanged: true,
                librariesChanged: true,
                filterOptionsChanged: true,
                emptyStateChanged: true,
                resolvedSelectionChanged: true,
                detailRefreshChanged: true,
                mapChanged: current.map != nil,
                searchPhaseChanged: current.searchPhase != nil,
                mediaIdentityEqualityUs: 0
            )
        }

        let identityStart = ContinuousClock.now
        let mediaIdentityChanged = previous.mediaGrid.descriptor != current.mediaGrid.descriptor
            || previous.mediaGrid.orderedAssetIDs != current.mediaGrid.orderedAssetIDs
        let identityUs = DiagnosticsTiming.microseconds(since: identityStart)

        return CatalogProjectionChangeSummary(
            previousSelectedScopeAssetCount: previous.mediaGrid.orderedAssetIDs.count,
            titleChanged: previous.title != current.title,
            mediaIdentityChanged: mediaIdentityChanged,
            librariesChanged: previous.libraries != current.libraries
                || previous.removableSources != current.removableSources
                || previous.importBatches != current.importBatches,
            filterOptionsChanged: previous.filterOptions != current.filterOptions,
            emptyStateChanged: previous.mediaEmptyState != current.mediaEmptyState,
            resolvedSelectionChanged: previous.resolvedSidebarSelection != current.resolvedSidebarSelection,
            detailRefreshChanged: previous.mediaGrid.detailRefreshGeneration
                != current.mediaGrid.detailRefreshGeneration,
            mapChanged: previous.map != current.map,
            searchPhaseChanged: previous.searchPhase != current.searchPhase,
            mediaIdentityEqualityUs: identityUs
        )
    }
}

nonisolated struct CatalogProjectionPublicationDiagnostics {
    let state: CatalogWindowState
    let assetCount: Int
    let metrics: CatalogProjectionBuildMetrics
    let changeSummary: CatalogProjectionChangeSummary
    let selectedSidebarRow: SidebarSelection
    let retainedResolvedSelection: Bool
    let equalityUs: Int
    let storeReadMs: Int
    let projectionMs: Int
    let totalMs: Int
    let dirtyAfter: Bool
    let stateChanged: Bool
    /// Cumulative full ordered-asset queries this session — the regression metric
    /// for ADR 0011's detail-only publication path. It makes "how many full
    /// re-sorts did N enrichment batches cause?" answerable from a log capture,
    /// not only from a test.
    let orderQueryCount: UInt64

    func emit() async {
        OtosLog.ui.noticeOperation(
            "catalog.projection.window",
            phase: "finish",
            fields: [
                "libraries": "\(state.libraries.count)",
                "assetCount": "\(assetCount)",
                "previousSelectedScopeAssetCount": "\(changeSummary.previousSelectedScopeAssetCount)",
                "selectedScopeAssetCount": "\(state.mediaGrid.orderedAssetIDs.count)",
                "assetOrderQueryMs": "\(metrics.orderQueryMs)",
                "titleChanged": "\(changeSummary.titleChanged)",
                "mediaIdentityChanged": "\(changeSummary.mediaIdentityChanged)",
                "librariesChanged": "\(changeSummary.librariesChanged)",
                "filterOptionsChanged": "\(changeSummary.filterOptionsChanged)",
                "emptyStateChanged": "\(changeSummary.emptyStateChanged)",
                "resolvedSelectionChanged": "\(changeSummary.resolvedSelectionChanged)",
                "detailRefreshChanged": "\(changeSummary.detailRefreshChanged)",
                "detailRefreshGeneration": "\(state.mediaGrid.detailRefreshGeneration)",
                "mediaIdentityEqualityUs": "\(changeSummary.mediaIdentityEqualityUs)",
                "equalityUs": "\(equalityUs)",
                "sidebarSelection": selectedSidebarRow.diagnosticDescription,
                "resolvedSidebarSelection": state.resolvedSidebarSelection.diagnosticDescription,
                "retainedResolvedSelection": "\(retainedResolvedSelection)",
                "emptyState": state.mediaEmptyState.diagnosticDescription,
                "searchPhase": state.searchPhase.map { "\($0)" } ?? "none",
                "storeReadMs": "\(storeReadMs)",
                "projectionMs": "\(projectionMs)",
                "totalMs": "\(totalMs)",
                "dirtyAfterPublication": "\(dirtyAfter)",
                "stateChanged": "\(stateChanged)",
                "orderQueryCount": "\(orderQueryCount)",
            ]
        )
    }
}
