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

        let facts = makeBuildFacts(
            allRoots: allRoots,
            request: request,
            resolvedDescriptor: resolvedDescriptor,
            importBatches: importBatches,
            ordered: (orderedAssetIDs, dayBuckets, coordinates),
            orderQueryMs: orderQueryMs
        )
        // The supplementary reads are independent; an error in any fails the build.
        async let unfilteredVisibleAssetCount = unfilteredVisibleAssetCount(facts, store: store)
        async let allAssetCount = catalogedAssetCount(facts, store: store)
        async let filterOptions = store.filterOptions(
            for: facts.resolvedDescriptor.scope,
            availableLibraryPaths: facts.availableLibraryPaths
        )
        async let filteredFixedAssetCount = filteredFixedAssetCount(facts, store: store)
        async let duplicateCopies = store.duplicateCopies(availableLibraryPaths: facts.availableLibraryPaths)
        var (state, metrics) = try await windowState(
            from: facts,
            allAssetCount: allAssetCount,
            unfilteredVisibleAssetCount: unfilteredVisibleAssetCount,
            filterOptions: filterOptions,
            filteredFixedAssetCount: filteredFixedAssetCount
        )
        let duplicates = try await duplicateCopies
        let identical = DuplicateGroupPolicy.groups(copies: duplicates.copies, keptPairs: duplicates.keptPairs)
        let samePhoto = try await samePhotoGroups(
            store: store,
            availableLibraryPaths: facts.availableLibraryPaths,
            excluding: Set(identical.flatMap(\.copies).map(\.id)),
            keptPairs: duplicates.keptPairs
        )
        state.duplicates = Self.duplicatesState(groups: identical + samePhoto)
        state.pendingIdentityRemaps = pendingIdentityRemaps
        return (state, metrics)
    }

    /// Versions of the same photo (ADR 0042): candidates from stored signatures and capture
    /// facts, then only the candidates' grayscale renders read to confirm them. A group the
    /// user kept whole is set aside like an identical one.
    func samePhotoGroups(
        store: CatalogStore,
        availableLibraryPaths: Set<LibraryRootPath>,
        excluding excluded: Set<MediaAssetID>,
        keptPairs: Set<DuplicateKeptPair>
    ) async throws -> [DuplicateGroup] {
        let signpost = OtosSignpost.performance.beginInterval("SamePhotoGroups")
        defer { OtosSignpost.performance.endInterval("SamePhotoGroups", signpost) }
        let candidates = try await store.samePhotoCandidates(availableLibraryPaths: availableLibraryPaths)
        let pairs = SamePhotoPolicy.candidatePairs(candidates, excluding: excluded)
        guard !pairs.isEmpty else {
            return []
        }
        let involved = Array(Set(pairs.flatMap { [$0.0.copy.id, $0.1.copy.id] }))
        let signatures = try await store.renderSignatures(for: involved)
        return SamePhotoPolicy.groups(candidates: candidates, signatures: signatures, excluding: excluded).map { group in
            let ids = group.copies.map(\.id)
            var everyPairKept = true
            for (index, left) in ids.enumerated() {
                for right in ids[(index + 1)...] where !keptPairs.contains(DuplicateKeptPair(left, right)) {
                    everyPairKept = false
                }
            }
            guard everyPairKept else {
                return group
            }
            return DuplicateGroup(
                id: group.id,
                copies: group.copies,
                defaultKeep: Set(ids),
                wait: nil,
                isKept: true,
                libraryPair: group.libraryPair
            )
        }
    }

    /// The published duplicates, off the MainActor (ADR 0042).
    static func duplicatesState(groups: [DuplicateGroup]) -> CatalogDuplicatesState {
        let state = CatalogDuplicatesState(groups: groups)
        OtosLog.catalog.debugOperation("duplicates.groups", phase: "built", fields: [
            "copies": "\(groups.reduce(0) { $0 + $1.copies.count })",
            "groups": "\(groups.count)",
            "kept": "\(state.keptGroups.count)",
            "preselected": "\(groups.count { !$0.isKept && $0.defaultKeep != nil })",
            "waitSpansLibraries": "\(groups.count { $0.wait == .spansLibraries })",
            "waitAuthoredWork": "\(groups.count { $0.wait == .differingAuthoredWork })",
            "samePhoto": "\(groups.count { $0.wait == .samePhoto })",
        ])
        return state
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
                mediaEmptyState: mediaEmptyState,
                map: CatalogWindowPolicy.mapState(
                    for: facts.resolvedDescriptor,
                    scopedAssetIDs: facts.scopedAssetIDs,
                    scopedCoordinates: facts.scopedCoordinates,
                    filteredFixedAssetCount: filteredFixedAssetCount
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
