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
        let coordinates: [PlaceCoordinate]
        let pendingIdentityRemaps: [CatalogIdentityRemapBatch]
        let orderQueryMs: Int
        // The map's coordinates are read with the order and can move without it (a
        // re-enriched location), so a detail-only pass under the Places scope re-runs
        // the query rather than reusing the last order.
        if let reuseIDs = reuse.orderedAssetIDs,
           resolvedDescriptor == reuse.descriptor,
           resolvedDescriptor.scope != .places
        {
            orderedAssetIDs = reuseIDs
            dayBuckets = reuse.dayBuckets ?? []
            coordinates = []
            pendingIdentityRemaps = reuse.pendingIdentityRemaps ?? []
            orderQueryMs = 0
        } else {
            orderQueryCount &+= 1
            let orderStart = ContinuousClock.now
            let ordered = try await store.orderedAssetIDs(
                for: resolvedDescriptor,
                availableLibraryPaths: availableLibraryPaths
            )
            orderedAssetIDs = ordered.ids
            dayBuckets = ordered.dayBuckets
            coordinates = ordered.coordinates
            pendingIdentityRemaps = ordered.pendingIdentityRemaps
            orderQueryMs = DiagnosticsTiming.milliseconds(since: orderStart)
        }
        // Tests inject controlled derivation while keeping the real publication loop.
        if let stateBuilder {
            var state = try await stateBuilder(allRoots, orderedAssetIDs, request)
            state.pendingIdentityRemaps = pendingIdentityRemaps
            return (state, CatalogProjectionBuildMetrics(orderQueryMs: 0))
        }

        var unsearched = makeBuildFacts(
            allRoots: allRoots,
            request: request,
            resolvedDescriptor: resolvedDescriptor,
            importBatches: importBatches,
            ordered: (orderedAssetIDs, dayBuckets, coordinates),
            orderQueryMs: orderQueryMs
        )
        if let search = resolvedDescriptor.effectiveSearch {
            try await applySearch(search, to: &unsearched, store: store)
        }
        let facts = unsearched
        // The supplementary reads are independent; an error in any fails the build.
        async let unfilteredVisibleAssetCount = unfilteredVisibleAssetCount(facts, store: store)
        async let allAssetCount = catalogedAssetCount(facts, store: store)
        async let filterOptions = store.filterOptions(
            for: facts.resolvedDescriptor.scope,
            availableLibraryPaths: facts.availableLibraryPaths
        )
        async let filteredFixedAssetCount = filteredFixedAssetCount(facts, store: store)
        var (state, metrics) = try await windowState(
            from: facts,
            allAssetCount: allAssetCount,
            unfilteredVisibleAssetCount: unfilteredVisibleAssetCount,
            filterOptions: filterOptions,
            filteredFixedAssetCount: filteredFixedAssetCount
        )
        state.pendingIdentityRemaps = pendingIdentityRemaps
        return (state, metrics)
    }

    /// Narrows the scope to what `search` matches (ADR 0048). With no index there is no
    /// answer, so the build fails and publishes nothing rather than an empty grid.
    private func applySearch(_ search: CatalogSearch, to facts: inout CatalogProjectionBuildFacts, store: CatalogStore) async throws {
        guard let searchIndex else {
            throw CatalogProjectionSearchUnavailable()
        }
        let matches = try await searchIndex.matches(for: search.text)
        let unsearched = facts.scopedAssetIDs.count
        let searched = CatalogWindowPolicy.searched(
            ids: facts.scopedAssetIDs,
            dayBuckets: facts.scopedDayBuckets,
            coordinates: facts.scopedCoordinates,
            scores: matches.scores,
            order: search.order
        )
        facts.scopedAssetIDs = searched.ids
        facts.scopedDayBuckets = searched.dayBuckets
        facts.scopedCoordinates = searched.coordinates
        facts.search = try await CatalogSearchOutcome(
            unsearchedScopeCount: unsearched,
            stillReadingCount: searched.ids.isEmpty ? store.searchEmbeddingPendingCount() : 0
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
        ordered: (ids: [MediaAssetID], dayBuckets: [Date?], coordinates: [PlaceCoordinate]),
        orderQueryMs: Int
    ) -> CatalogProjectionBuildFacts {
        let availableLibraryPaths = CatalogWindowPolicy.availablePaths(from: allRoots)
        let scoped = CatalogWindowPolicy.assetIDs(
            for: resolvedDescriptor.scope,
            orderedAssetIDs: ordered.ids,
            dayBuckets: ordered.dayBuckets,
            coordinates: ordered.coordinates,
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
            scopedCoordinates: scoped.coordinates,
            orderQueryMs: orderQueryMs
        )
    }

    /// The pure half of the build: facts in, window state out. Synchronous, so it reads
    /// `detailRefreshGeneration` at the moment it assembles.
    func windowState(
        from facts: CatalogProjectionBuildFacts,
        allAssetCount: Int,
        unfilteredVisibleAssetCount: Int,
        filterOptions: CatalogFilterOptions,
        filteredFixedAssetCount: Int
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
            selectedAssetCount: facts.scopedAssetIDs.count,
            search: facts.search
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
                mediaEmptyState: mediaEmptyState,
                map: CatalogWindowPolicy.mapState(
                    for: facts.resolvedDescriptor,
                    scopedAssetIDs: facts.scopedAssetIDs,
                    scopedCoordinates: facts.scopedCoordinates,
                    filteredFixedAssetCount: filteredFixedAssetCount
                ),
                onThisDay: CatalogWindowPolicy.onThisDayState(
                    for: facts.resolvedDescriptor,
                    scopedAssetIDs: facts.scopedAssetIDs,
                    scopedDayBuckets: facts.scopedDayBuckets
                )
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

    /// Items the fixed libraries hold under the current filter, located or not — what
    /// the Places map measures its own count against to say how many it leaves off
    /// (ADR 0040). Only the Places scope asks.
    private func filteredFixedAssetCount(
        _ facts: CatalogProjectionBuildFacts,
        store: CatalogStore
    ) async throws -> Int {
        guard facts.resolvedDescriptor.scope == .places else {
            return 0
        }
        return try await store.visibleAssetCount(
            for: .allMedia,
            filter: facts.resolvedDescriptor.filter,
            availableLibraryPaths: facts.availableLibraryPaths
        )
    }
}

/// A search was asked of a projection that has no index to answer it.
nonisolated struct CatalogProjectionSearchUnavailable: Error {}
