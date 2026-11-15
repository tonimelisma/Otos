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
    /// Builds the window state for `request`, answering each catalog read from `previous`
    /// while it still holds (`CatalogProjectionReads`): `revisions` are the fact revisions
    /// the pass started from, which a read made now records. Returns the reads the state was
    /// built from, for the pass to keep once it publishes, and the filter's options when they
    /// are owed: the window never waits for them (`OwedFilterOptions`).
    ///
    /// The People gallery shows people, not items (ADR 0047): it reads no order, no stacks, no
    /// search and no options, and says only what its libraries' state is.
    ///
    /// With `answerFromHeld`, a read the projection holds an answer for is answered from it
    /// even when a fact it depends on moved since (`CatalogProjectionReuse.held` says one
    /// was): the first pass of a scope the user returns to shows what that scope last showed at
    /// once, and the pass after it reads again whatever moved. A read with no answer held is
    /// made either way.
    func buildWindowState(
        store: CatalogStore,
        libraries unsortedLibraries: [CatalogLibraryState],
        request: CatalogQueryRequest,
        reads previous: CatalogProjectionReads,
        revisions: CatalogFactRevisions,
        answerFromHeld: Bool = false
    ) async throws -> CatalogProjectionBuild {
        let allRoots = CatalogWindowPolicy.sortLibraries(unsortedLibraries)
        var reads = previous
        var reuse = CatalogProjectionReuse()
        let selection = request.descriptor.scope
        let counting = ImportBatchListing.counting(for: selection)
        let importBatches: [ImportBatchSummary]
        if let held = previous.importBatches(counting: counting, at: revisions, current: true) {
            importBatches = held
            reuse.importBatches = true
        } else if answerFromHeld, let held = previous.importBatches(counting: counting, at: revisions, current: false) {
            importBatches = held
            reuse.importBatches = true
            reuse.held = true
        } else {
            importBatches = try await store.importBatches(counting: counting)
            reads.importBatches = CatalogProjectionReads.ImportBatches(
                counting: counting, answer: importBatches, revisions: revisions
            )
        }
        let placeNameLanguages: Set<PlaceNameLanguage>
        if let held = previous.placeNameLanguages(at: revisions, current: true) {
            placeNameLanguages = held
            reuse.placeNameLanguages = true
        } else if answerFromHeld, let held = previous.placeNameLanguages(at: revisions, current: false) {
            placeNameLanguages = held
            reuse.placeNameLanguages = true
            reuse.held = true
        } else {
            placeNameLanguages = try await store.placeNameLanguages()
            reads.placeNameLanguages = CatalogProjectionReads.PlaceNameLanguages(
                answer: placeNameLanguages, revisions: revisions
            )
        }
        // A build an intent superseded may still be finishing its read; it must not reach the
        // search reader's state or count a read it never publishes.
        try Task.checkCancellation()
        let resolvedDescriptor = Self.resolvedDescriptor(
            for: request,
            allRoots: allRoots,
            importBatches: importBatches,
            placeNameLanguages: placeNameLanguages
        )
        if resolvedDescriptor.scope.isPeopleGallery {
            return peopleGalleryBuild(
                allRoots: allRoots,
                request: request,
                resolvedDescriptor: resolvedDescriptor,
                importBatches: importBatches,
                reads: reads,
                reuse: reuse
            )
        }
        // The query is read by the index's own owner; a pass only takes what it has read, so
        // it never waits on Translation or Maps. A query still being read builds nothing yet:
        // the pass keeps the last state and says it is searching, and the reader's report
        // that the reading ended rings the loop.
        let searchStatus = try await searchStatus(for: resolvedDescriptor.effectiveSearch, store: store)
        if searchStatus == .reading {
            return .queryBeingRead
        }
        let availableLibraryPaths = CatalogWindowPolicy.availablePaths(from: allRoots)

        // The filter's options are read after the window publishes, when they are owed; until
        // then the window carries the last ones read for its row, or none. An injected test
        // builder shows none and owes none.
        let optionsRow = resolvedDescriptor.scope.sidebarRow
        let heldOptions = stateBuilder != nil ? CatalogFilterOptions.empty : previous.filterOptions(
            for: optionsRow,
            availableLibraryPaths: availableLibraryPaths,
            placeNameLanguages: placeNameLanguages,
            at: revisions
        )
        reuse.filterOptions = heldOptions != nil && stateBuilder == nil
        let owedOptions: OwedFilterOptions? = heldOptions == nil ? OwedFilterOptions(
            row: optionsRow,
            availableLibraryPaths: availableLibraryPaths,
            placeNameLanguages: placeNameLanguages,
            revisions: revisions
        ) : nil
        let shownOptions = heldOptions ?? previous.lastFilterOptions(
            for: optionsRow,
            availableLibraryPaths: availableLibraryPaths,
            placeNameLanguages: placeNameLanguages
        ) ?? .empty

        let ordered: CatalogOrderedAssets
        let orderQueryMs: Int
        if let held = previous.order(for: resolvedDescriptor, availableLibraryPaths: availableLibraryPaths, at: revisions) {
            ordered = held
            orderQueryMs = 0
            reuse.order = true
        } else if answerFromHeld,
                  let held = previous.heldOrder(for: resolvedDescriptor, availableLibraryPaths: availableLibraryPaths)
        {
            ordered = held.answer
            orderQueryMs = 0
            reuse.order = true
            reuse.held = true
        } else {
            orderQueryCount &+= 1
            let orderStart = ContinuousClock.now
            let heldStacks = previous.stacks(at: revisions)
            ordered = try await store.orderedAssetIDs(
                for: resolvedDescriptor,
                availableLibraryPaths: availableLibraryPaths,
                heldStacks: heldStacks
            )
            orderQueryMs = DiagnosticsTiming.milliseconds(since: orderStart)
            reads.orders[CatalogProjectionReads.Slot(resolvedDescriptor.scope)] = CatalogProjectionReads.Order(
                descriptor: resolvedDescriptor,
                availableLibraryPaths: availableLibraryPaths,
                revisions: revisions,
                answer: ordered
            )
            if let built = ordered.builtStacks {
                // Stacks handed back unchanged keep the revisions they were read at.
                let heldStill = heldStacks.map { $0.rootPaths == built.rootPaths && $0.span == built.span } ?? false
                reuse.stacks = heldStill
                if !heldStill {
                    stackReadCount &+= 1
                    // Only a whole-roots build answers the next scope over the same roots; a
                    // narrow scope's own stacks answer that scope alone, and are read again,
                    // in milliseconds, rather than replace held whole-roots stacks.
                    if built.span == .roots {
                        reads.stacks = CatalogProjectionReads.Stacks(built: built, revisions: revisions)
                    }
                }
            }
        }
        // Tests inject controlled derivation while keeping the real publication loop.
        if let stateBuilder {
            var state = try await stateBuilder(allRoots, ordered.ids, request)
            state.pendingIdentityRemaps = ordered.pendingIdentityRemaps
            return .built(state, CatalogProjectionBuildMetrics(orderQueryMs: orderQueryMs, reuse: reuse), reads, nil)
        }

        var unsearched = makeBuildFacts(
            allRoots: allRoots,
            request: request,
            resolvedDescriptor: resolvedDescriptor,
            importBatches: importBatches,
            ordered: (ordered.ids, ordered.dayBuckets, ordered.coordinates),
            orderQueryMs: orderQueryMs
        )
        if let search = resolvedDescriptor.effectiveSearch, let searchStatus {
            switch searchStatus {
            case let .read(encoding):
                let matches = try await searchMatches(
                    encoding, among: unsearched.scopedAssetIDs, previous: previous, revisions: revisions
                )
                reads.search = matches.made
                reuse.search = matches.reused
                try await applySearch(search, matches: matches.made.matches, to: &unsearched, store: store)
            case .failed:
                Self.failSearch(in: &unsearched)
            case .reading:
                return .queryBeingRead
            }
        }
        let collapseStart = ContinuousClock.now
        let collapseSlot = CatalogProjectionReads.Slot(resolvedDescriptor.scope)
        let collapse = Self.collapseStacks(
            ordered.stacks,
            expanded: request.expandedStacks,
            in: &unsearched,
            last: previous.collapses[collapseSlot]
        )
        reads.collapses[collapseSlot] = collapse.made
        reuse.collapse = collapse.reused
        let collapseMs = DiagnosticsTiming.milliseconds(since: collapseStart)
        Self.capAnniversaries(in: &unsearched)
        let facts = unsearched
        // The supplementary reads are independent; an error in any fails the build.
        async let unfilteredVisibleAssetCount = unfilteredVisibleAssetCount(facts, store: store)
        async let allAssetCount = catalogedAssetCount(facts, store: store)
        var (state, _) = try await windowState(
            from: facts,
            allAssetCount: allAssetCount,
            unfilteredVisibleAssetCount: unfilteredVisibleAssetCount,
            filterOptions: shownOptions
        )
        state.pendingIdentityRemaps = ordered.pendingIdentityRemaps
        state.searchPhase = facts.search?.phase
        let metrics = CatalogProjectionBuildMetrics(
            orderQueryMs: orderQueryMs,
            collapseMs: collapseMs,
            reuse: reuse
        )
        return .built(state, metrics, reads, owedOptions)
    }

    /// The People gallery's window: its libraries, title and sidebar, and what its libraries'
    /// state says when it holds no one (`CatalogWindowPolicy.peopleGalleryLibrariesState`).
    /// People itself comes from `PeopleAssignment`. Reads nothing, and keeps every read the
    /// last pass made for the next scope that needs it.
    private func peopleGalleryBuild(
        allRoots: [CatalogLibraryState],
        request: CatalogQueryRequest,
        resolvedDescriptor: CatalogQueryDescriptor,
        importBatches: [ImportBatchSummary],
        reads: CatalogProjectionReads,
        reuse: CatalogProjectionReuse
    ) -> CatalogProjectionBuild {
        let facts = makeBuildFacts(
            allRoots: allRoots,
            request: request,
            resolvedDescriptor: resolvedDescriptor,
            importBatches: importBatches,
            ordered: ([], [], []),
            orderQueryMs: 0
        )
        var (state, _) = windowState(
            from: facts,
            allAssetCount: 0,
            unfilteredVisibleAssetCount: 0,
            filterOptions: .empty
        )
        state.mediaEmptyState = CatalogWindowPolicy.peopleGalleryLibrariesState(libraries: allRoots)
        return .built(state, CatalogProjectionBuildMetrics(orderQueryMs: 0, reuse: reuse), reads, nil)
    }

    /// Reads the options `owed` names. Run by the pass after the window it owes them to is
    /// published.
    func readFilterOptions(
        _ owed: OwedFilterOptions,
        store: CatalogStore
    ) async throws -> (options: CatalogFilterOptions, ms: Int) {
        filterOptionsQueryCount &+= 1
        let start = ContinuousClock.now
        let options = try await store.filterOptions(
            for: owed.row,
            availableLibraryPaths: owed.availableLibraryPaths,
            placeNameLanguages: owed.placeNameLanguages
        )
        return (options, DiagnosticsTiming.milliseconds(since: start))
    }

    /// Collapses each stack in the scoped order to its shown member (ADR 0052), after the
    /// search so a stack matches when any member does. The duplicates list shows every
    /// copy as itself and never collapses. The collapse is a pure step, so `last`, when it
    /// was made from the same order, stacks and expansions, is the answer. Returns the
    /// collapse for the next pass (nil where nothing collapses) and whether it was `last`.
    @discardableResult
    static func collapseStacks(
        _ stacks: CatalogStacks,
        expanded: Set<PhotoStackID>,
        in facts: inout CatalogProjectionBuildFacts,
        last: CatalogProjectionReads.Collapse? = nil
    ) -> (made: CatalogProjectionReads.Collapse?, reused: Bool) {
        facts.stacks = stacks
        switch facts.resolvedDescriptor.scope {
        case .duplicates, .duplicateGroup:
            return (nil, false)
        case .allMedia, .library, .places, .mapArea, .mapStack, .onThisDay, .importBatch, .allImports, .people, .person:
            break
        }
        let start = ContinuousClock.now
        let collapse: CatalogProjectionReads.Collapse
        let reused: Bool
        if let last, last.expanded == expanded, last.stacks == stacks, last.ids == facts.scopedAssetIDs,
           last.dayBuckets == facts.scopedDayBuckets, last.coordinates == facts.scopedCoordinates
        {
            collapse = last
            reused = true
        } else {
            collapse = CatalogProjectionReads.Collapse(
                ids: facts.scopedAssetIDs,
                dayBuckets: facts.scopedDayBuckets,
                coordinates: facts.scopedCoordinates,
                stacks: stacks,
                expanded: expanded,
                result: PhotoStackCollapse.collapse(
                    ids: facts.scopedAssetIDs,
                    dayBuckets: facts.scopedDayBuckets,
                    coordinates: facts.scopedCoordinates,
                    stacks: stacks,
                    expanded: expanded
                )
            )
            reused = false
        }
        let collapsed = collapse.result
        // The pass's cost on the user's own order, which no benchmark fixture has the shape of.
        OtosLog.catalog.noticeOperation("projection.stacks", phase: "collapsed", fields: [
            "ids": "\(facts.scopedAssetIDs.count)",
            "shown": "\(collapsed.ids.count)",
            "stacks": "\(stacks.stacks.count)",
            "expanded": "\(expanded.count)",
            "reused": "\(reused)",
            "ms": "\(DiagnosticsTiming.milliseconds(since: start))",
        ])
        facts.scopedAssetIDs = collapsed.ids
        facts.scopedDayBuckets = collapsed.dayBuckets
        facts.scopedCoordinates = collapsed.coordinates
        facts.gridStacks = collapsed.grid
        return (collapse, reused)
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

    /// A query whose reading failed shows none of the scope, so the empty state says the
    /// search could not be made (ADR 0048): the scope unsearched under the field's text would
    /// read as its answer.
    static func failSearch(in facts: inout CatalogProjectionBuildFacts) {
        OtosLog.catalog.noticeOperation("projection.search", phase: "failed", fields: [
            "scope": "\(facts.scopedAssetIDs.count)",
        ])
        facts.search = .failed(unsearchedScopeCount: facts.scopedAssetIDs.count)
        facts.scopedAssetIDs = []
        facts.scopedDayBuckets = []
        facts.scopedCoordinates = []
    }

    /// What the read query matches among `scope` (ADR 0048): the last answer while it holds
    /// (`CatalogProjectionReads.search`), and otherwise the index's answer now. The query's
    /// facts are resolved for this pass's now, so a date it names ("yesterday") moves with the
    /// day. Returns the answer, with what it is keyed by, for the next pass, and whether it
    /// was the last one.
    private func searchMatches(
        _ encoding: SearchQueryEncoding,
        among scope: [MediaAssetID],
        previous: CatalogProjectionReads,
        revisions: CatalogFactRevisions
    ) async throws -> (made: CatalogProjectionReads.Search, reused: Bool) {
        guard let searchIndex else {
            throw CatalogProjectionSearchUnavailable()
        }
        let facts = encoding.facts.filter(at: Date(), in: .current)
        if let held = await previous.search(
            encoding,
            facts: facts,
            among: scope,
            index: searchIndex,
            indexRevision: searchIndex.revision,
            at: revisions
        ) {
            return (held, true)
        }
        searchMatchCount &+= 1
        let matches = try await searchIndex.matches(encoding, facts: facts, among: scope)
        let made = CatalogProjectionReads.Search(
            index: searchIndex, facts: facts, scope: scope, revisions: revisions, matches: matches
        )
        return (made, false)
    }

    /// Narrows the scope to `matches` (ADR 0048), among the scope's own assets.
    private func applySearch(
        _ search: CatalogSearch,
        matches: SearchMatches,
        to facts: inout CatalogProjectionBuildFacts,
        store: CatalogStore
    ) async throws {
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
        facts.search = try await .read(
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
