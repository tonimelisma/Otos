import Foundation
import OSLog

/// Window-state assembly helpers for `CatalogProjection`.
///
/// Kept outside the actor file so publication ownership stays within the repo's
/// file-length budget for `CatalogProjection.swift`.
extension CatalogProjection {
    func emptyStateForBuild(
        _ input: CatalogProjectionEmptyStateBuildInput
    ) async -> CatalogMediaEmptyState {
        let unfilteredVisibleAssetCount = await unfilteredVisibleAssetCountForEmptyState(
            descriptor: input.descriptor,
            scopedAssetIDs: input.scopedAssetIDs,
            store: input.store,
            availableLibraryPaths: input.availableLibraryPaths
        )
        let allAssetCount = await catalogedAssetCountForEmptyState(
            resolvedSidebarSelection: input.descriptor.scope,
            scopedAssetIDs: input.scopedAssetIDs,
            orderedAssetIDs: input.orderedAssetIDs,
            store: input.store
        )
        return CatalogWindowPolicy.mediaEmptyState(
            for: input.descriptor,
            libraries: input.libraries,
            allAssetCount: allAssetCount,
            unfilteredVisibleAssetCount: unfilteredVisibleAssetCount,
            selectedAssetCount: input.scopedAssetIDs.count
        )
    }

    func catalogWindowState(_ parts: CatalogProjectionWindowStateParts) -> CatalogWindowState {
        CatalogWindowPolicy.catalogWindowState(
            parts,
            detailRefreshGeneration: detailRefreshGeneration
        )
    }

    func catalogedAssetCountForEmptyState(
        resolvedSidebarSelection: SidebarSelection,
        scopedAssetIDs: [MediaAssetID],
        orderedAssetIDs: [MediaAssetID],
        store: CatalogStore?
    ) async -> Int {
        guard scopedAssetIDs.isEmpty, let store else {
            return orderedAssetIDs.count
        }
        do {
            return try await store.catalogedAssetCount(for: resolvedSidebarSelection)
        } catch {
            OtosLog.catalog.error(
                "Catalog asset count query failed error=\(String(describing: error), privacy: .public)"
            )
            return orderedAssetIDs.count
        }
    }

    func unfilteredVisibleAssetCountForEmptyState(
        descriptor: CatalogQueryDescriptor,
        scopedAssetIDs: [MediaAssetID],
        store: CatalogStore?,
        availableLibraryPaths: Set<LibraryRootPath>
    ) async -> Int {
        guard descriptor.filter.isActive, scopedAssetIDs.isEmpty, let store else {
            return scopedAssetIDs.count
        }
        do {
            return try await store.visibleAssetCount(
                for: descriptor.scope,
                availableLibraryPaths: availableLibraryPaths
            )
        } catch {
            OtosLog.catalog.error(
                """
                Catalog unfiltered visible count query failed \
                error=\(String(describing: error), privacy: .public)
                """
            )
            return 0
        }
    }

    func filterOptions(
        for selection: SidebarSelection,
        store: CatalogStore?,
        availableLibraryPaths: Set<LibraryRootPath>
    ) async -> CatalogFilterOptions {
        guard let store else {
            return .empty
        }
        do {
            return try await store.filterOptions(
                for: selection,
                availableLibraryPaths: availableLibraryPaths
            )
        } catch {
            OtosLog.catalog.error(
                "Catalog filter option query failed error=\(String(describing: error), privacy: .public)"
            )
            return .empty
        }
    }

    /// Tests inject controlled derivation while keeping the real publication loop.
    func injectedWindowState(
        _ libraries: [CatalogLibraryState],
        orderedAssetIDs: [MediaAssetID],
        request: CatalogQueryRequest
    ) async -> (CatalogWindowState, CatalogProjectionBuildMetrics)? {
        guard let stateBuilder else {
            return nil
        }
        let state = await stateBuilder(libraries, orderedAssetIDs, request)
        return (state, CatalogProjectionBuildMetrics(orderQueryMs: 0))
    }
}
