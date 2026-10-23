import Foundation
import OSLog

/// Window-state assembly for `CatalogProjection`.
///
/// Kept outside the actor file so publication ownership stays within the repo's
/// file-length budget for `CatalogProjection.swift`. Every Store read here is `try`:
/// a read that fails fails the build, and `CatalogProjection.pass` publishes nothing
/// for a failed build. No `catch` here substitutes `[]`, `0` or `.empty` for a value
/// the window would show as fact (MED-002).
extension CatalogProjection {
    func buildWindowState(
        store: CatalogStore,
        libraries unsortedLibraries: [CatalogLibraryState],
        request: CatalogQueryRequest,
        reuse: CatalogProjectionOrderReuse
    ) async throws -> (CatalogWindowState, CatalogProjectionBuildMetrics) {
        let allRoots = CatalogWindowPolicy.sortLibraries(unsortedLibraries)
        let importBatches = try await store.importBatches()
        let resolvedDescriptor = Self.resolvedDescriptor(
            for: request,
            allRoots: allRoots,
            importBatches: importBatches
        )
        let availableLibraryPaths = CatalogWindowPolicy.availablePaths(from: allRoots)
        let orderedAssetIDs: [MediaAssetID]
        let dayBuckets: [Date?]
        let orderQueryMs: Int
        if let reuseIDs = reuse.orderedAssetIDs, resolvedDescriptor == reuse.descriptor {
            orderedAssetIDs = reuseIDs
            dayBuckets = reuse.dayBuckets ?? []
            orderQueryMs = 0
        } else {
            orderQueryCount &+= 1
            let orderStart = Date()
            (orderedAssetIDs, dayBuckets) = try await store.orderedAssetIDs(
                for: resolvedDescriptor,
                availableLibraryPaths: availableLibraryPaths
            )
            orderQueryMs = DiagnosticsTiming.milliseconds(since: orderStart)
        }
        // Tests inject controlled derivation while keeping the real publication loop.
        if let stateBuilder {
            let state = try await stateBuilder(allRoots, orderedAssetIDs, request)
            return (state, CatalogProjectionBuildMetrics(orderQueryMs: 0))
        }

        let facts = makeBuildFacts(
            allRoots: allRoots,
            request: request,
            resolvedDescriptor: resolvedDescriptor,
            importBatches: importBatches,
            ordered: (orderedAssetIDs, dayBuckets),
            orderQueryMs: orderQueryMs
        )
        // The two supplementary reads are independent; an error in either fails the build.
        async let unfilteredVisibleAssetCount = unfilteredVisibleAssetCount(facts, store: store)
        async let allAssetCount = catalogedAssetCount(facts, store: store)
        async let filterOptions = store.filterOptions(
            for: facts.resolvedDescriptor.scope,
            availableLibraryPaths: facts.availableLibraryPaths
        )
        return try await windowState(
            from: facts,
            allAssetCount: allAssetCount,
            unfilteredVisibleAssetCount: unfilteredVisibleAssetCount,
            filterOptions: filterOptions
        )
    }

    static func resolvedDescriptor(
        for request: CatalogQueryRequest,
        allRoots: [CatalogLibraryState],
        importBatches: [ImportBatchSummary]
    ) -> CatalogQueryDescriptor {
        let sources = CatalogWindowPolicy.sourceRows(from: allRoots)
        return CatalogWindowPolicy.resolvedDescriptor(
            request.descriptor,
            libraries: sources.libraries,
            removableSources: sources.removableSources,
            importBatches: importBatches
        )
    }

    func makeBuildFacts(
        allRoots: [CatalogLibraryState],
        request: CatalogQueryRequest,
        resolvedDescriptor: CatalogQueryDescriptor,
        importBatches: [ImportBatchSummary],
        ordered: (ids: [MediaAssetID], dayBuckets: [Date?]),
        orderQueryMs: Int
    ) -> CatalogProjectionBuildFacts {
        let availableLibraryPaths = CatalogWindowPolicy.availablePaths(from: allRoots)
        let scoped = CatalogWindowPolicy.assetIDs(
            for: resolvedDescriptor.scope,
            orderedAssetIDs: ordered.ids,
            dayBuckets: ordered.dayBuckets,
            availableLibraryPaths: availableLibraryPaths,
            rootsByPath: CatalogWindowPolicy.rootsByPath(from: allRoots)
        )
        return CatalogProjectionBuildFacts(
            allRoots: allRoots,
            request: request,
            resolvedDescriptor: resolvedDescriptor,
            importBatches: importBatches,
            orderedAssetIDs: ordered.ids,
            availableLibraryPaths: availableLibraryPaths,
            scopedAssetIDs: scoped.ids,
            scopedDayBuckets: scoped.dayBuckets,
            orderQueryMs: orderQueryMs
        )
    }

    /// The pure half of the build: facts in, window state out. Synchronous, so it reads
    /// `detailRefreshGeneration` at the moment it assembles.
    func windowState(
        from facts: CatalogProjectionBuildFacts,
        allAssetCount: Int,
        unfilteredVisibleAssetCount: Int,
        filterOptions: CatalogFilterOptions
    ) -> (CatalogWindowState, CatalogProjectionBuildMetrics) {
        let signpost = OtosSignpost.performance.beginInterval("CatalogWindowStateBuild")
        defer {
            OtosSignpost.performance.endInterval("CatalogWindowStateBuild", signpost)
        }
        let sources = CatalogWindowPolicy.sourceRows(from: facts.allRoots)
        let mediaEmptyState = CatalogWindowPolicy.mediaEmptyState(
            for: facts.resolvedDescriptor,
            libraries: facts.allRoots,
            allAssetCount: allAssetCount,
            unfilteredVisibleAssetCount: unfilteredVisibleAssetCount,
            selectedAssetCount: facts.scopedAssetIDs.count
        )
        let state = CatalogWindowPolicy.catalogWindowState(
            CatalogProjectionWindowStateParts(
                title: CatalogWindowPolicy.title(for: facts.resolvedDescriptor.scope, libraries: facts.allRoots),
                libraries: sources.libraries,
                removableSources: sources.removableSources,
                importBatches: facts.importBatches,
                resolvedDescriptor: facts.resolvedDescriptor,
                queryGeneration: facts.request.generation,
                scopedAssetIDs: facts.scopedAssetIDs,
                scopedDayBuckets: facts.scopedDayBuckets,
                filterOptions: filterOptions,
                mediaEmptyState: mediaEmptyState
            ),
            detailRefreshGeneration: detailRefreshGeneration
        )
        return (state, CatalogProjectionBuildMetrics(orderQueryMs: facts.orderQueryMs))
    }

    /// Cataloged assets in scope ignoring the filter; only asked when the filtered scope
    /// is empty and a filter is active, so the empty state can say "no matches".
    private func unfilteredVisibleAssetCount(
        _ facts: CatalogProjectionBuildFacts,
        store: CatalogStore
    ) async throws -> Int {
        guard facts.resolvedDescriptor.filter.isActive, facts.scopedAssetIDs.isEmpty else {
            return facts.scopedAssetIDs.count
        }
        return try await store.visibleAssetCount(
            for: facts.resolvedDescriptor.scope,
            availableLibraryPaths: facts.availableLibraryPaths
        )
    }

    private func catalogedAssetCount(
        _ facts: CatalogProjectionBuildFacts,
        store: CatalogStore
    ) async throws -> Int {
        guard facts.scopedAssetIDs.isEmpty else {
            return facts.orderedAssetIDs.count
        }
        return try await store.catalogedAssetCount(for: facts.resolvedDescriptor.scope)
    }
}
