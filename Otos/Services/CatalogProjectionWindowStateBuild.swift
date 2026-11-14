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
        let placeNameLanguages = try await store.placeNameLanguages()
        let resolvedDescriptor = Self.resolvedDescriptor(
            for: request,
            allRoots: allRoots,
            importBatches: importBatches,
            placeNameLanguages: placeNameLanguages
        )
        // The query is read by the index's own owner; a pass only takes what it has read, so
        // it never waits on Translation or Maps. A query still being read publishes nothing
        // yet: its reading rings the loop when it lands.
        let searchStatus = try await searchStatus(for: resolvedDescriptor.effectiveSearch, store: store)
        if searchStatus == .reading {
            throw CatalogProjectionSearchStillReading()
        }
        let availableLibraryPaths = CatalogWindowPolicy.availablePaths(from: allRoots)
        let orderedAssetIDs: [MediaAssetID]
        let dayBuckets: [Date?]
        let coordinates: [PlaceCoordinate]
        let pendingIdentityRemaps: [CatalogIdentityRemapBatch]
        let stacks: CatalogStacks
        let orderQueryMs: Int
        // The map's coordinates are read with the order and can move without it (a
        // re-enriched location), so a detail-only pass under the Places scope, which reuses
        // no coordinates, re-runs the query rather than reusing the last order.
        if let reuseIDs = reuse.orderedAssetIDs,
           resolvedDescriptor == reuse.descriptor,
           resolvedDescriptor.scope != .places || reuse.coordinates != nil
        {
            orderedAssetIDs = reuseIDs
            dayBuckets = reuse.dayBuckets ?? []
            coordinates = reuse.coordinates ?? []
            pendingIdentityRemaps = reuse.pendingIdentityRemaps ?? []
            stacks = reuse.stacks
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
            stacks = ordered.stacks
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
        if let search = resolvedDescriptor.effectiveSearch, let searchStatus {
            try await applySearch(search, status: searchStatus, to: &unsearched, store: store)
        }
        Self.collapseStacks(stacks, expanded: request.expandedStacks, in: &unsearched)
        Self.capAnniversaries(in: &unsearched)
        let facts = unsearched
        // The supplementary reads are independent; an error in any fails the build.
        async let unfilteredVisibleAssetCount = unfilteredVisibleAssetCount(facts, store: store)
        async let allAssetCount = catalogedAssetCount(facts, store: store)
        async let filterOptions = store.filterOptions(
            for: facts.resolvedDescriptor.scope,
            availableLibraryPaths: facts.availableLibraryPaths,
            placeNameLanguages: placeNameLanguages
        )
        var (state, metrics) = try await windowState(
            from: facts,
            allAssetCount: allAssetCount,
            unfilteredVisibleAssetCount: unfilteredVisibleAssetCount,
            filterOptions: filterOptions
        )
        state.pendingIdentityRemaps = pendingIdentityRemaps
        state.uncollapsedOrder = CatalogUncollapsedOrder(
            ids: orderedAssetIDs, dayBuckets: dayBuckets, coordinates: coordinates, stacks: stacks
        )
        return (state, metrics)
    }

    /// Collapses each stack in the scoped order to its shown member (ADR 0052), after the
    /// search so a stack matches when any member does. The duplicates list shows every
    /// copy as itself and never collapses.
    static func collapseStacks(
        _ stacks: CatalogStacks,
        expanded: Set<PhotoStackID>,
        in facts: inout CatalogProjectionBuildFacts
    ) {
        facts.stacks = stacks
        switch facts.resolvedDescriptor.scope {
        case .duplicates, .duplicateGroup:
            return
        case .allMedia, .library, .places, .mapArea, .mapStack, .onThisDay, .importBatch, .allImports, .people, .person:
            break
        }
        let start = ContinuousClock.now
        let collapsed = PhotoStackCollapse.collapse(
            ids: facts.scopedAssetIDs,
            dayBuckets: facts.scopedDayBuckets,
            coordinates: facts.scopedCoordinates,
            stacks: stacks,
            expanded: expanded
        )
        // The pass's cost on the user's own order, which no benchmark fixture has the shape of.
        OtosLog.catalog.noticeOperation("projection.stacks", phase: "collapsed", fields: [
            "ids": "\(facts.scopedAssetIDs.count)",
            "shown": "\(collapsed.ids.count)",
            "stacks": "\(stacks.stacks.count)",
            "expanded": "\(expanded.count)",
            "ms": "\(DiagnosticsTiming.milliseconds(since: start))",
        ])
        facts.scopedAssetIDs = collapsed.ids
        facts.scopedDayBuckets = collapsed.dayBuckets
        facts.scopedCoordinates = collapsed.coordinates
        facts.gridStacks = collapsed.grid
    }

    /// On This Day shows at most `OnThisDayPicks.anniversaryCap` photos an anniversary,
    /// counted after stacks collapse, so the cards, the counts and the story agree.
    static func capAnniversaries(in facts: inout CatalogProjectionBuildFacts) {
        guard case .onThisDay = facts.resolvedDescriptor.scope,
              facts.scopedDayBuckets.count == facts.scopedAssetIDs.count,
              let kept = OnThisDayPicks.keptPositions(dayBuckets: facts.scopedDayBuckets)
        else {
            return
        }
        let ids = facts.scopedAssetIDs, buckets = facts.scopedDayBuckets, coordinates = facts.scopedCoordinates
        facts.scopedAssetIDs = kept.map { ids[$0] }
        facts.scopedDayBuckets = kept.map { buckets[$0] }
        if coordinates.count == ids.count {
            facts.scopedCoordinates = kept.map { coordinates[$0] }
        }
    }

    /// What the index's query reader holds for `search` (ADR 0048); nil with no search, when
    /// the reader lets its last answer go. With no index there is no answer, so the build fails
    /// and publishes nothing rather than an empty grid.
    private func searchStatus(for search: CatalogSearch?, store: CatalogStore) async throws -> SearchQueryStatus? {
        guard let search else {
            await searchIndex?.queries.forget()
            return nil
        }
        guard let searchIndex else {
            throw CatalogProjectionSearchUnavailable()
        }
        let request = try await SearchQueryRequest(
            text: search.text, languages: search.languages, people: store.namedPeople(), label: search.label
        )
        return await searchIndex.queries.status(for: request)
    }

    /// Narrows the scope to what `search` matches (ADR 0048), among the scope's own assets.
    /// A query the reader could not answer (a failed reading waiting for its retry, or one past
    /// its deadline) leaves the scope unsearched, never narrowed by another query's results.
    private func applySearch(
        _ search: CatalogSearch,
        status: SearchQueryStatus,
        to facts: inout CatalogProjectionBuildFacts,
        store: CatalogStore
    ) async throws {
        guard case let .read(encoding) = status else {
            OtosLog.catalog.noticeOperation("projection.search", phase: "unanswered", fields: [
                "scope": "\(facts.scopedAssetIDs.count)",
            ])
            return
        }
        guard let searchIndex else {
            throw CatalogProjectionSearchUnavailable()
        }
        let matches = try await searchIndex.matches(encoding, among: facts.scopedAssetIDs)
        let unsearched = facts.scopedAssetIDs.count
        let searched = CatalogWindowPolicy.searched(
            ids: facts.scopedAssetIDs,
            dayBuckets: facts.scopedDayBuckets,
            coordinates: facts.scopedCoordinates,
            scores: matches.scores,
            allowed: matches.allowed,
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
        importBatches: [ImportBatchSummary],
        placeNameLanguages: Set<PlaceNameLanguage>
    ) -> CatalogQueryDescriptor {
        let sources = CatalogWindowPolicy.sourceRows(from: allRoots)
        return CatalogWindowPolicy.resolvedDescriptor(
            request.descriptor,
            libraries: sources.libraries,
            removableSources: sources.removableSources,
            importBatches: importBatches,
            placeNameLanguages: placeNameLanguages
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
                    scopedCoordinates: facts.scopedCoordinates
                ),
                onThisDay: CatalogWindowPolicy.onThisDayState(
                    for: facts.resolvedDescriptor,
                    scopedAssetIDs: facts.scopedAssetIDs,
                    scopedDayBuckets: facts.scopedDayBuckets
                ),
                gridStacks: facts.gridStacks
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

/// A search was asked of a projection that has no index to answer it.
nonisolated struct CatalogProjectionSearchUnavailable: Error {}

/// The search's query is still being read (`SearchQueryReader`): the pass publishes nothing
/// yet, and the reading rings the loop when it lands.
nonisolated struct CatalogProjectionSearchStillReading: Error {}
