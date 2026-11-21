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
    /// while it still holds (`CatalogProjectionReads`). `changes` is the change log the pass
    /// started from: its `revisions` are what a read made now records, and its entries name
    /// the rows a keyed re-read reads again. The two come from one value so that a revision
    /// that moved is always a change that names its rows (`CatalogChangeLog`). Returns the reads the state was
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
        changes: CatalogChangeLog = CatalogChangeLog(),
        answerFromHeld: Bool = false
    ) async throws -> CatalogProjectionBuild {
        let revisions = changes.revisions
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
            importBatches = try await store.windowReads.importBatches(counting: counting)
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
            placeNameLanguages = try await store.windowReads.placeNameLanguages()
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
        } else if let patched = try await keyedOrder(
            previous.heldOrder(for: resolvedDescriptor, availableLibraryPaths: availableLibraryPaths),
            descriptor: resolvedDescriptor,
            availableLibraryPaths: availableLibraryPaths,
            changes: changes,
            store: store
        ) {
            keyedOrderQueryCount &+= 1
            ordered = patched.answer
            orderQueryMs = patched.ms
            reuse.keyed = true
            reads.orders[CatalogProjectionReads.Slot(resolvedDescriptor.scope)] = CatalogProjectionReads.Order(
                descriptor: resolvedDescriptor,
                availableLibraryPaths: availableLibraryPaths,
                revisions: revisions,
                sequence: changes.sequence,
                answer: patched.answer
            )
        } else {
            orderQueryCount &+= 1
            let orderStart = ContinuousClock.now
            let heldStacks = previous.stacks(at: revisions)
            // An order read again that came back as held keeps the held arrays, which the
            // reused collapse and the published window share (`holdingArrays(of:)`).
            let read = try await store.windowReads.orderedAssetIDs(
                for: resolvedDescriptor,
                availableLibraryPaths: availableLibraryPaths,
                heldStacks: heldStacks
            )
            ordered = await Self.holding(
                read, of: previous.heldOrder(for: resolvedDescriptor, availableLibraryPaths: availableLibraryPaths)?.answer
            )
            orderQueryMs = DiagnosticsTiming.milliseconds(since: orderStart)
            reads.orders[CatalogProjectionReads.Slot(resolvedDescriptor.scope)] = CatalogProjectionReads.Order(
                descriptor: resolvedDescriptor,
                availableLibraryPaths: availableLibraryPaths,
                revisions: revisions,
                sequence: changes.sequence,
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

        var unsearched = await Self.scopedFacts(
            allRoots: allRoots,
            request: request,
            resolvedDescriptor: resolvedDescriptor,
            importBatches: importBatches,
            ordered: ordered,
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
                let searchedScope = unsearched.scopedAssetIDs
                let unsearchedCount = Self.narrow(&unsearched, to: matches.made.matches, order: search.order)
                // Only an empty answer says how many of the scope's photos search has not read
                // yet, which the index knows of the scope it just searched.
                unsearched.search = try await .read(
                    unsearchedScopeCount: unsearchedCount,
                    stillReadingCount: unsearched.scopedAssetIDs.isEmpty ? unreadCount(among: searchedScope) : 0
                )
            case let .refining(encoding):
                // A first reading shows its matches while the full one is read, still marked as
                // searching; one that matches nothing shows nothing new, so the grid never
                // empties between the two readings, and reads nothing more: it is no answer.
                let matches = try await searchMatches(
                    encoding, among: unsearched.scopedAssetIDs, previous: previous, revisions: revisions
                )
                reads.search = matches.made
                reuse.search = matches.reused
                let unsearchedCount = Self.narrow(&unsearched, to: matches.made.matches, order: search.order)
                guard !unsearched.scopedAssetIDs.isEmpty else {
                    return .queryBeingRead
                }
                unsearched.search = .refining(unsearchedScopeCount: unsearchedCount)
            case .failed:
                Self.failSearch(in: &unsearched)
            case .reading:
                return .queryBeingRead
            }
        }
        let collapseStart = ContinuousClock.now
        let collapseSlot = CatalogProjectionReads.CollapseKey(resolvedDescriptor)
        let collapsed = await Self.collapsed(
            unsearched, stacks: ordered.stacks, expanded: request.expandedStacks, last: previous.collapses[collapseSlot]
        )
        reads.collapses[collapseSlot] = collapsed.collapse
        reuse.collapse = collapsed.reused
        let collapseMs = DiagnosticsTiming.milliseconds(since: collapseStart)
        let facts = collapsed.facts
        // The supplementary reads are independent; an error in any fails the build.
        async let unfilteredVisibleAssetCount = unfilteredVisibleAssetCount(facts, store: store)
        async let allAssetCount = catalogedAssetCount(facts, store: store)
        let counts = try await (all: allAssetCount, unfiltered: unfilteredVisibleAssetCount)
        var state = await Self.assembled(
            from: facts,
            allAssetCount: counts.all,
            unfilteredVisibleAssetCount: counts.unfiltered,
            filterOptions: shownOptions,
            detailRefreshGeneration: detailRefreshGeneration
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

    /// The held order for `descriptor` with only the rows the Store's changes since its read
    /// named read again and merged in (`CatalogOrderPatch`), when every such change moved only
    /// capture dates (`CatalogChangeLog.keyedRows`) and nothing the held stacks are built from;
    /// nil when a full read is owed. On the owner's catalog, while a sync brought metadata for
    /// 152 rows, the order was read whole 125 times
    /// (`docs/research/2026-11-16-window-reads-owner-catalog.md`).
    private func keyedOrder(
        _ held: CatalogProjectionReads.Order?,
        descriptor: CatalogQueryDescriptor,
        availableLibraryPaths: Set<LibraryRootPath>,
        changes: CatalogChangeLog,
        store: CatalogStore
    ) async throws -> (answer: CatalogOrderedAssets, ms: Int)? {
        guard let held, held.answer.keys != nil,
              let rows = changes.keyedRows(since: held.sequence, for: descriptor)
        else {
            return nil
        }
        let start = ContinuousClock.now
        guard let reread = try await store.windowReads.orderedAssetIDs(
            ofRows: rows, for: descriptor, availableLibraryPaths: availableLibraryPaths
        ), let patched = await Self.patching(
            held.answer, changed: rows, reread: reread, descending: descriptor.effectiveSort.direction == .descending
        ) else {
            return nil
        }
        return (patched, DiagnosticsTiming.milliseconds(since: start))
    }

    // The pure steps of a build each walk the scope, so each leaves the actor (ADR 0032, rule
    // 6): an act that reaches the projection while a build makes them is applied at once
    // (ADR 0005, "An act is never queued behind a build").

    /// `read`, holding `held`'s arrays where they are equal (`holdingArrays(of:)`).
    @concurrent
    private static func holding(_ read: CatalogOrderedAssets, of held: CatalogOrderedAssets?) async -> CatalogOrderedAssets {
        read.holdingArrays(of: held)
    }

    /// The held order with the re-read rows merged in (`CatalogOrderPatch`), holding its
    /// arrays where they are equal.
    @concurrent
    private static func patching(
        _ held: CatalogOrderedAssets,
        changed rows: Set<MediaAssetID>,
        reread: CatalogOrderedAssets,
        descending: Bool
    ) async -> CatalogOrderedAssets? {
        CatalogOrderPatch.patching(held, changed: rows, reread: reread, descending: descending)?.holdingArrays(of: held)
    }

    /// How an options read reads (`plan(forOptions:)`): the row's whole scope, or only the rows
    /// the changes since the held tally was read name, with the names in the tally's language
    /// of the cells those rows give and of `renamed` (the tally's cells, when the cells' names
    /// moved), to patch that tally in place.
    enum FilterOptionsPlan: Equatable, Sendable {
        case whole
        case keyed(rows: Set<MediaAssetID>, names: PlaceNameLanguage?, renamed: Set<PlaceCell>, patching: UInt64)
    }

    /// What an options read gave and the Store change it started after.
    struct FilterOptionsRead: Sendable {
        enum Outcome: Sendable {
            /// A test's reader's options, which no keyed read patches.
            case answered(CatalogFilterOptions)
            /// The row's whole tally.
            case whole(CatalogFilterOptionTally)
            /// The named rows and names, for the held tally read after change `patching`.
            case keyed(CatalogFilterOptionRows, patching: UInt64)
        }

        let outcome: Outcome
        let sequence: UInt64
        let ms: Int

        var isKeyed: Bool {
            if case .keyed = outcome {
                true
            } else {
                false
            }
        }

        /// The options a read gave whole; nil for a keyed read, which only the tally it patches
        /// answers.
        var options: CatalogFilterOptions? {
            switch outcome {
            case let .answered(options): options
            case let .whole(tally): tally.options
            case .keyed: nil
            }
        }
    }

    /// Reads the options `owed` names as `plan` says: the read a pass asks for
    /// (`askFilterOptions`) after the window it owes them to is published. A keyed plan whose
    /// row's scope a key cannot test reads the whole scope instead. `sequence` is the Store
    /// change the read starts after.
    func readFilterOptions(
        _ owed: OwedFilterOptions,
        plan: FilterOptionsPlan = .whole,
        sequence: UInt64 = 0,
        store: CatalogStore
    ) async throws -> FilterOptionsRead {
        let start = ContinuousClock.now
        if let filterOptionsReader {
            filterOptionsQueryCount &+= 1
            let options = try await filterOptionsReader(owed)
            return FilterOptionsRead(outcome: .answered(options), sequence: sequence, ms: DiagnosticsTiming.milliseconds(since: start))
        }
        if case let .keyed(rows, names, renamed, patching) = plan {
            // Nothing a change named moved what the options count: the held tally stands.
            guard !rows.isEmpty || !renamed.isEmpty else {
                return FilterOptionsRead(
                    outcome: .keyed(CatalogFilterOptionRows(rows: [], namedCells: [], names: [:]), patching: patching),
                    sequence: sequence, ms: 0
                )
            }
            if let read = try await store.windowReads.filterOptionsOfRows(
                rows, namesIn: names, renamed: renamed, for: owed.row, availableLibraryPaths: owed.availableLibraryPaths
            ) {
                keyedFilterOptionsQueryCount &+= 1
                return FilterOptionsRead(
                    outcome: .keyed(read, patching: patching), sequence: sequence, ms: DiagnosticsTiming.milliseconds(since: start)
                )
            }
        }
        filterOptionsQueryCount &+= 1
        let tally = try await store.windowReads.filterOptionTally(
            for: owed.row,
            availableLibraryPaths: owed.availableLibraryPaths,
            placeNameLanguages: owed.placeNameLanguages
        )
        return FilterOptionsRead(outcome: .whole(tally), sequence: sequence, ms: DiagnosticsTiming.milliseconds(since: start))
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
            text: search.text, languages: search.languages, people: store.windowReads.namedPeople(), label: search.label
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

    /// How many of `scope`'s assets search has not read yet: the index's answer
    /// (`PhotoSearchIndex.unreadCount`), for the scope its matches were just computed among.
    private func unreadCount(among scope: [MediaAssetID]) async throws -> Int {
        guard let searchIndex else {
            throw CatalogProjectionSearchUnavailable()
        }
        return try await searchIndex.unreadCount(among: scope)
    }

    /// `facts` with its stacks collapsed and On This Day capped (`collapseStacks`,
    /// `capAnniversaries`), off the actor, with the collapse for the next pass.
    @concurrent
    private static func collapsed(
        _ facts: CatalogProjectionBuildFacts,
        stacks: CatalogStacks,
        expanded: Set<PhotoStackID>,
        last: CatalogProjectionReads.Collapse?
    ) async -> (facts: CatalogProjectionBuildFacts, collapse: CatalogProjectionReads.Collapse?, reused: Bool) {
        var facts = facts
        let collapse = collapseStacks(stacks, expanded: expanded, in: &facts, last: last)
        capAnniversaries(in: &facts)
        return (facts, collapse.made, collapse.reused)
    }

    /// The scope's facts of `ordered` (`makeBuildFacts`), off the actor.
    @concurrent
    private static func scopedFacts(
        allRoots: [CatalogLibraryState],
        request: CatalogQueryRequest,
        resolvedDescriptor: CatalogQueryDescriptor,
        importBatches: [ImportBatchSummary],
        ordered: CatalogOrderedAssets,
        orderQueryMs: Int
    ) async -> CatalogProjectionBuildFacts {
        buildFacts(
            allRoots: allRoots,
            request: request,
            resolvedDescriptor: resolvedDescriptor,
            importBatches: importBatches,
            ordered: (ordered.ids, ordered.dayBuckets, ordered.coordinates),
            orderQueryMs: orderQueryMs
        )
    }

    /// The window state of `facts` (`windowState(from:)`), off the actor: its map and On This
    /// Day walk the scope.
    @concurrent
    private static func assembled(
        from facts: CatalogProjectionBuildFacts,
        allAssetCount: Int,
        unfilteredVisibleAssetCount: Int,
        filterOptions: CatalogFilterOptions,
        detailRefreshGeneration: UInt64
    ) async -> CatalogWindowState {
        windowState(
            from: facts,
            allAssetCount: allAssetCount,
            unfilteredVisibleAssetCount: unfilteredVisibleAssetCount,
            filterOptions: filterOptions,
            detailRefreshGeneration: detailRefreshGeneration
        )
    }

    /// Narrows the scope to `matches` (ADR 0048), among the scope's own assets, and returns how
    /// many the scope held before.
    private static func narrow(
        _ facts: inout CatalogProjectionBuildFacts,
        to matches: SearchMatches,
        order: CatalogSearch.Order
    ) -> Int {
        let unsearched = facts.scopedAssetIDs.count
        let searched = CatalogWindowPolicy.searched(
            ids: facts.scopedAssetIDs,
            dayBuckets: facts.scopedDayBuckets,
            coordinates: facts.scopedCoordinates,
            scores: matches.scores,
            allowed: matches.allowed,
            order: order
        )
        facts.scopedAssetIDs = searched.ids
        facts.scopedDayBuckets = searched.dayBuckets
        facts.scopedCoordinates = searched.coordinates
        return unsearched
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
        Self.buildFacts(
            allRoots: allRoots,
            request: request,
            resolvedDescriptor: resolvedDescriptor,
            importBatches: importBatches,
            ordered: ordered,
            orderQueryMs: orderQueryMs
        )
    }

    nonisolated static func buildFacts(
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
        (
            Self.windowState(
                from: facts,
                allAssetCount: allAssetCount,
                unfilteredVisibleAssetCount: unfilteredVisibleAssetCount,
                filterOptions: filterOptions,
                detailRefreshGeneration: detailRefreshGeneration
            ),
            CatalogProjectionBuildMetrics(orderQueryMs: facts.orderQueryMs)
        )
    }

    /// `windowState(from:…)` with the detail refresh it carries given.
    nonisolated static func windowState(
        from facts: CatalogProjectionBuildFacts,
        allAssetCount: Int,
        unfilteredVisibleAssetCount: Int,
        filterOptions: CatalogFilterOptions,
        detailRefreshGeneration: UInt64
    ) -> CatalogWindowState {
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
        return CatalogWindowPolicy.catalogWindowState(
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
    }

    /// Cataloged assets in scope ignoring the filter; only asked when the filtered scope
    /// is empty and a filter is active, so the empty state can say "no matches". An empty
    /// search answer says why it is empty itself, so it asks for neither this nor the scope's
    /// cataloged count, each a count of the whole scope (`searchSaysWhyEmpty`); the counts
    /// it passes on are then read by nothing.
    private func unfilteredVisibleAssetCount(
        _ facts: CatalogProjectionBuildFacts,
        store: CatalogStore
    ) async throws -> Int {
        guard facts.resolvedDescriptor.filter.isActive, facts.scopedAssetIDs.isEmpty,
              !CatalogWindowPolicy.searchSaysWhyEmpty(facts.search)
        else {
            return facts.scopedAssetIDs.count
        }
        return try await store.windowReads.visibleAssetCount(
            for: facts.resolvedDescriptor.scope,
            availableLibraryPaths: facts.availableLibraryPaths
        )
    }

    private func catalogedAssetCount(
        _ facts: CatalogProjectionBuildFacts,
        store: CatalogStore
    ) async throws -> Int {
        guard facts.scopedAssetIDs.isEmpty, !CatalogWindowPolicy.searchSaysWhyEmpty(facts.search) else {
            return facts.orderedAssetIDs.count
        }
        return try await store.windowReads.catalogedAssetCount(for: facts.resolvedDescriptor.scope)
    }
}

/// A search was asked of a projection that has no index to answer it.
nonisolated struct CatalogProjectionSearchUnavailable: Error {}
