import Foundation
import OSLog

/// Catalog Projection guide
/// This actor is the read-model boundary between catalog truth and the main window:
/// fixed/removable source splitting, ordering, reachability filtering, sidebar scope,
/// title selection, camera guidance banner state, and empty-state meaning. Pure policy
/// lives in `CatalogWindowPolicy`; diagnostics values live in `CatalogProjectionDiagnostics`.
///
/// Publication is one loop. Every intent and every store change calls `requestPublication`, which
/// only ever adds to `requested`; a pass records the `requested` it started from and
/// advances `covered` to it when its build succeeds. Whether work is owed is
/// `requested != covered` — nothing a finishing pass does can erase a request made while
/// it ran, because a pass can only cover what it started from. One consumer task
/// (`loopTask`) runs every pass off a `bufferingNewest(1)` doorbell, so builds never
/// overlap. Intents and a store change that arrives before the first catalog load ring
/// the doorbell directly; other store changes wait for `cadenceTask`, which rings it
/// every `cadence` while the projection is behind.
///
/// The duplicate groups and People have their own owners, `DuplicatesProjection` and
/// `PeopleAssignment`, each with its own loop. A pass publishes the window with what they
/// last built and, when it took up a catalog change (`derivedRequested`), asks both owners
/// for a build, or People for its unchecked tally alone when rows were only added
/// (`tallyRequested`); it never waits for one. Builds come back on `duplicatesTask` and
/// `peopleTask` and go out by republishing the last state with them. So detection and
/// grouping never hold back the sidebar or the grid, and a change of scope, filter or sort
/// never rebuilds them, since neither depends on it.
///
/// Nothing cancels a build that newer work supersedes: GRDB reads throw
/// `CancellationError` in a cancelled task, so a cancelled build would hold errors, and the
/// older build's result is simply covered by the next pass. Cancellation is teardown only
/// (`removeContinuation`), and a pass that is cancelled or whose read fails publishes
/// nothing: it leaves `covered` where it was, so the request stays outstanding and the
/// next intent or cadence tick retries it.
actor CatalogProjection {
    typealias WindowStateBuilder = @Sendable ([CatalogLibraryState], [MediaAssetID], CatalogQueryRequest) async throws
        -> CatalogWindowState

    /// Whether the next pass must rebuild the full ordered-asset query. An expansion (a
    /// stack expanded or collapsed, ADR 0052) changes only how the order is collapsed, so it
    /// re-collapses the last published uncollapsed order, its map coordinates included. A
    /// detail-only change (enrichment that touched no ordering/scope column) reuses the last
    /// published order too — the grid's own same-identity `.refreshVisible` path already
    /// updates visible details cheaply (ADR 0011) — except where a re-read can move what the
    /// order carries. Declaration order is severity order: a pending structural change always
    /// wins over a detail-only one, and a detail-only one over an expansion.
    private enum DirtyKind: Comparable {
        case none
        case expansion
        case detailOnly
        case structural
    }

    /// How often background Store changes may publish: at most once a second. A rate
    /// limit standing on a measurement: each publication that reorders the grid costs
    /// the MainActor an apply of ~25 ms for an enrichment trickle and ~200 ms for a
    /// reloadData-class apply at 23k items
    /// (`docs/research/grid-reorder-cadence-and-appkit-diffable-apply.md`). User intents
    /// ring the doorbell directly and never wait for it.
    private let cadence: Duration
    let stateBuilder: WindowStateBuilder?
    /// Tests replace the duplicates build to hold it at its suspension; production builds them.
    let duplicatesBuilder: DuplicatesProjection.Builder?
    /// Tests replace the People build to hold it at its suspension; production builds it.
    let peopleBuilder: PeopleAssignment.Builder?

    private var queryRequest: CatalogQueryRequest = .initial
    /// Distinguishes one projection's diagnostics from another's in a shared log.
    private let diagnosticID = String(UUID().uuidString.prefix(8))
    /// Bumped by every intent and store change. Nothing decrements or clears it.
    private var requested: UInt64 = 0
    /// The `requested` value the last *successful* pass started from.
    private var covered: UInt64 = 0
    /// Severity merged since the last pass started.
    private var pendingKind: DirtyKind = .none
    /// Passes between their first and last line. Not request state: a count rather than
    /// a flag so a cancelled pass finishing after a re-subscribe cannot mask a live one.
    private var runningPasses = 0
    private var doorbell: AsyncStream<Void>.Continuation?
    private var continuations: [UUID: AsyncStream<CatalogWindowState>.Continuation] = [:]
    private var changeTask: Task<Void, Never>?
    private var loopTask: Task<Void, Never>?
    private var cadenceTask: Task<Void, Never>?
    private var lastPublishedState: CatalogWindowState?
    /// The duplicate groups the last successful duplicates build produced; nil until one has.
    private var duplicates: CatalogDuplicatesState?
    private var duplicatesProjection: DuplicatesProjection?
    /// What the last successful People build produced; nil until one has.
    private var people: CatalogPeopleState?
    private var peopleAssignment: PeopleAssignment?
    private var peopleTask: Task<Void, Never>?
    /// Answers a descriptor's search (ADR 0048); nil where nothing indexes (tests that do
    /// not search), and a search then publishes nothing.
    private(set) var searchIndex: PhotoSearchIndex?
    private var searchTask: Task<Void, Never>?
    private var searchQueryTask: Task<Void, Never>?
    private var duplicatesTask: Task<Void, Never>?
    /// Bumped by every catalog change and by a new subscription: the duplicate groups and
    /// People may differ.
    private var derivedRequested: UInt64 = 0
    /// The `derivedRequested` value last passed on to `duplicatesProjection` and
    /// `peopleAssignment`.
    private var derivedForwarded: UInt64 = 0
    /// Bumped by rows only added: they carry nothing the groups or the assignment are built
    /// from, but each new still is one People's tally counts as not yet checked.
    private var tallyRequested: UInt64 = 0
    /// The `tallyRequested` value last passed on to `peopleAssignment`.
    private var tallyForwarded: UInt64 = 0
    /// The last publication was the pre-load `.loadingCatalog` state. The next store
    /// change is the load itself (or something after it), so it publishes immediately
    /// rather than leaving the window blank for a cadence tick (APP-044).
    private var publishedBeforeCatalogLoad = false
    /// Count of full ordered-asset queries executed by publications. A detail-only
    /// publication skips it; the count is the observable "full-catalog re-sort per
    /// enrichment batch" metric (ADR 0011) and drives the regression test.
    var orderQueryCount: UInt64 = 0
    /// Window states published so far. Read with `isQuiescent`, it says whether a change
    /// published anything, without depending on when a subscriber receives it.
    private(set) var publicationCount: UInt64 = 0
    var detailRefreshGeneration: UInt64 = 0

    /// True when every request has been covered by a successful pass and no pass is
    /// running. Lets a test wait for settlement instead of guessing a sleep duration.
    var isQuiescent: Bool {
        requested == covered && runningPasses == 0
    }

    /// Whether the duplicates owner has built every request it was given. With `isQuiescent`,
    /// lets a test wait for the groups to settle.
    var duplicatesAreQuiescent: Bool {
        get async {
            await duplicatesProjection?.isQuiescent ?? true
        }
    }

    /// Whether the People owner has built every request it was given.
    var peopleAreQuiescent: Bool {
        get async {
            await peopleAssignment?.isQuiescent ?? true
        }
    }

    /// Whether any consumer still holds a stream. Teardown happens when the last one ends.
    var hasSubscribers: Bool {
        !continuations.isEmpty
    }

    init(
        cadence: Duration = .seconds(1),
        stateBuilder: WindowStateBuilder? = nil,
        duplicatesBuilder: DuplicatesProjection.Builder? = nil,
        peopleBuilder: PeopleAssignment.Builder? = nil
    ) {
        self.cadence = cadence
        self.stateBuilder = stateBuilder
        self.duplicatesBuilder = duplicatesBuilder
        self.peopleBuilder = peopleBuilder
    }

    func states(
        store: CatalogStore,
        initialDescriptor: CatalogQueryDescriptor
    ) async -> AsyncStream<CatalogWindowState> {
        await states(
            store: store,
            initialRequest: CatalogQueryRequest(descriptor: initialDescriptor, generation: 0)
        )
    }

    func states(
        store: CatalogStore,
        initialRequest: CatalogQueryRequest
    ) async -> AsyncStream<CatalogWindowState> {
        queryRequest = initialRequest
        let changes = changeTask == nil ? await store.changeNotifications() : nil
        ensurePublicationLoop(store: store, changes: changes)

        let (stream, continuation) = AsyncStream<CatalogWindowState>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let id = UUID()
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        requestPublication(.structural, ringNow: true)
        return stream
    }

    /// Uses `index` for searches from now on. A change to what it holds asks for a
    /// publication while a search is shown, on the cadence; a query whose reading ended, read
    /// or failed, asks for one at once.
    func attachSearchIndex(_ index: PhotoSearchIndex) async {
        searchTask?.cancel()
        searchQueryTask?.cancel()
        searchIndex = index
        let changes = await index.changes()
        let readings = await index.queries.readings()
        searchTask = Task { [weak self] in
            for await _ in changes {
                guard let self else { return }
                await searchIndexDidChange()
            }
        }
        searchQueryTask = Task { [weak self] in
            for await _ in readings {
                guard let self else { return }
                await searchQueryDidRead()
            }
        }
    }

    func updateSidebarSelection(_ selection: SidebarSelection) {
        updateQueryDescriptor(CatalogQueryDescriptor(
            scope: selection,
            filter: queryRequest.descriptor.filter,
            sort: queryRequest.descriptor.sort,
            search: queryRequest.descriptor.search
        ))
    }

    func updateQueryDescriptor(_ descriptor: CatalogQueryDescriptor) {
        guard queryRequest.descriptor != descriptor else { return }
        queryRequest = CatalogQueryRequest(
            descriptor: descriptor,
            generation: queryRequest.generation &+ 1
        )
        requestPublication(.structural, ringNow: true)
    }

    func updateQueryRequest(_ request: CatalogQueryRequest) {
        OtosLog.catalog.noticeOperation("projection.intent", phase: "received", fields: [
            "projection": diagnosticID,
            "generation": "\(request.generation)",
            "scope": String(describing: request.descriptor.scope),
            "changed": "\(queryRequest != request)",
            "requested": "\(requested)",
            "covered": "\(covered)",
        ])
        guard queryRequest != request else { return }
        // The same query with other stacks expanded: only the collapse differs.
        let expansionOnly = queryRequest.descriptor == request.descriptor
            && queryRequest.generation == request.generation
        queryRequest = request
        requestPublication(expansionOnly ? .expansion : .structural, ringNow: true)
    }

    /// One-shot window-state build for tests. Production UI consumes the publication
    /// loop; this entry derives a state from supplied facts so projection math can be
    /// asserted without a store. It reads nothing, so it cannot fail.
    func windowState(
        libraries: [CatalogLibraryState],
        orderedAssetIDs: [MediaAssetID],
        sidebarSelection: SidebarSelection
    ) async -> CatalogWindowState {
        let request = CatalogQueryRequest(
            descriptor: CatalogQueryDescriptor(scope: sidebarSelection),
            generation: 0
        )
        let allRoots = CatalogWindowPolicy.sortLibraries(libraries)
        let facts = makeBuildFacts(
            allRoots: allRoots,
            request: request,
            resolvedDescriptor: Self.resolvedDescriptor(for: request, allRoots: allRoots, importBatches: [], placeNameLanguages: []),
            importBatches: [],
            ordered: (orderedAssetIDs, [], []),
            orderQueryMs: 0
        )
        return windowState(
            from: facts,
            allAssetCount: orderedAssetIDs.count,
            unfilteredVisibleAssetCount: facts.scopedAssetIDs.count,
            filterOptions: .empty
        ).0
    }
}

extension CatalogProjection {
    /// The people each face of `photos` could be, from the last People published
    /// (ADR 0047); none before People is first published.
    func faceCandidates(for photos: [MediaAssetID]) async -> [FaceID: [FaceCandidate]] {
        guard let peopleAssignment else {
            return [:]
        }
        return await peopleAssignment.candidates(for: photos)
    }
}

private extension CatalogProjection {
    func ensurePublicationLoop(store: CatalogStore, changes: AsyncStream<CatalogStoreChange>?) {
        guard loopTask == nil else {
            return
        }

        let cadence = cadence
        let (bell, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        doorbell = continuation
        // Every loop here waits indefinitely, so it holds its owner weakly — and must
        // *end* when that upgrade fails, not merely skip a beat. A `while
        // !Task.isCancelled` loop whose body is `await self?.…` keeps running after
        // the projection is gone: it does nothing on each pass, but it never exits,
        // and its closure holds `store` strongly, so the whole `CatalogStore` (its
        // database, watchers and scan tasks) is kept alive by a loop with no owner.
        // `removeContinuation` cancels these, but only when the last stream consumer
        // tears down — which is not guaranteed to happen before the owner deallocates.
        // Hundreds of such orphans accumulating in one process is what deadlocked the
        // test suite mid-run.
        changeTask = Task { [weak self, changes] in
            guard let changes else {
                return
            }
            for await change in changes {
                guard let self else {
                    return
                }
                await storeDidChange(change)
            }
        }

        loopTask = Task { [weak self] in
            for await _ in bell {
                guard let self else {
                    return
                }
                await pass(store: store)
            }
        }

        // A new subscription knows no groups or people yet, so its first loaded pass asks for
        // them.
        let duplicatesProjection = DuplicatesProjection(store: store, builder: duplicatesBuilder)
        self.duplicatesProjection = duplicatesProjection
        let peopleAssignment = PeopleAssignment(store: store, builder: peopleBuilder)
        self.peopleAssignment = peopleAssignment
        derivedRequested &+= 1
        duplicatesTask = Task { [weak self, duplicatesProjection] in
            await duplicatesProjection.start()
            for await built in duplicatesProjection.builds {
                guard let self else {
                    return
                }
                await publishDuplicates(built)
            }
        }
        peopleTask = Task { [weak self, peopleAssignment] in
            await peopleAssignment.start()
            for await built in peopleAssignment.builds {
                guard let self else {
                    return
                }
                await publishPeople(built)
            }
        }

        // The cadence task is the one that notices the owner is gone, so it also ends the
        // doorbell and the derived owners on every exit: `loopTask`, `duplicatesTask` and
        // `peopleTask` wait indefinitely, and a wait nothing can end keeps `store` alive
        // through its closure.
        cadenceTask = Task { [weak self, continuation, duplicatesProjection, peopleAssignment] in
            defer {
                continuation.finish()
                duplicatesProjection.stop()
                peopleAssignment.stop()
            }
            while !Task.isCancelled {
                do {
                    // time: cadence docs/research/grid-reorder-cadence-and-appkit-diffable-apply.md
                    try await Task.sleep(for: cadence)
                } catch {
                    return
                }
                guard let self else {
                    return
                }
                await ringIfBehind()
            }
        }
    }

    /// The only way work becomes owed. `ringNow` wakes the loop immediately; without it
    /// the cadence tick picks the request up.
    private func requestPublication(_ kind: DirtyKind, ringNow: Bool) {
        requested &+= 1
        pendingKind = max(pendingKind, kind)
        if ringNow {
            doorbell?.yield()
        }
    }

    func ringIfBehind() {
        if requested != covered {
            doorbell?.yield()
        }
    }

    func searchIndexDidChange() {
        guard queryRequest.descriptor.search != nil else { return }
        requestPublication(.structural, ringNow: false)
    }

    /// The answer to a user's query: published now, not on the cadence.
    func searchQueryDidRead() {
        guard queryRequest.descriptor.search != nil else { return }
        requestPublication(.structural, ringNow: true)
    }

    func storeDidChange(_ change: CatalogStoreChange) {
        // A remove and same-path add can coalesce into a final snapshot where the
        // path exists again. Store's typed removal signal preserves that transient
        // deletion fact without durable library-instance identity.
        if case let .libraryRemoved(path) = change {
            if queryRequest.descriptor.scope == .library(path) {
                queryRequest.descriptor.scope = .allMedia
            }
        }
        detailRefreshGeneration &+= 1
        // Rows that were only added carry nothing the groups or the assignment are built
        // from; they change People's unchecked tally alone.
        if change == .assetsAdded {
            tallyRequested &+= 1
        } else {
            derivedRequested &+= 1
        }
        if case .assetsDetailChanged = change {
            requestPublication(.detailOnly, ringNow: false)
        } else {
            requestPublication(.structural, ringNow: publishedBeforeCatalogLoad)
        }
    }

    /// One publication pass. It only runs on `loopTask`, so passes never overlap. It
    /// takes up everything requested so far (`startedFrom`) and covers exactly that:
    /// a request made while it awaits leaves `requested != covered` and runs next.
    func pass(store: CatalogStore) async {
        guard requested != covered else {
            return
        }
        runningPasses += 1
        defer { runningPasses -= 1 }
        let startedFrom = requested
        let derivedStartedFrom = derivedRequested
        let tallyStartedFrom = tallyRequested
        let kind = pendingKind
        pendingKind = .none
        let selectedRequest = queryRequest
        OtosLog.catalog.noticeOperation("projection.publish", phase: "start", fields: [
            "projection": diagnosticID,
            "generation": "\(selectedRequest.generation)",
            "scope": String(describing: selectedRequest.descriptor.scope),
        ])

        // Detail-only dirt reuses the order we last published — but only when the
        // freshly-resolved descriptor still matches the descriptor that order was
        // built for (libraries/import batches are unchanged), so a concurrent scope
        // resolution change still re-runs the query. The grid renders the same
        // identities (a cheap `.refreshVisible`) and the identity comparison
        // short-circuits on the shared array buffer. A structural change or a newer
        // user intent re-runs the full query.
        // A search narrows the order after it is read, so the published order is not the
        // order a search pass starts from: a detail-only pass under a search always reads it.
        // An expansion reuses the order under any search, scope or filter: it is the same
        // order, and the build searches and collapses it again.
        let reusesOrder = switch kind {
        case .expansion: true
        case .detailOnly: selectedRequest.descriptor.search == nil
        case .none, .structural: false
        }
        let reuse: CatalogProjectionOrderReuse = if reusesOrder, let previous = lastPublishedState {
            CatalogProjectionOrderReuse(
                orderedAssetIDs: previous.uncollapsedOrder.ids,
                dayBuckets: previous.uncollapsedOrder.dayBuckets,
                coordinates: kind == .expansion ? previous.uncollapsedOrder.coordinates : nil,
                stacks: previous.uncollapsedOrder.stacks,
                pendingIdentityRemaps: previous.pendingIdentityRemaps,
                descriptor: previous.queryDescriptor
            )
        } else {
            .none
        }

        let publicationStart = ContinuousClock.now
        let storeReadStart = ContinuousClock.now
        let completed: CatalogProjectionCompletedPublication
        do {
            // Before the catalog's first load there is nothing to query and nothing to
            // claim: publish the loading state instead of an empty catalog (APP-044).
            guard let libraries = await store.loadedLibraries() else {
                try Task.checkCancellation()
                publishLoadingState(for: selectedRequest)
                covered = startedFrom
                ringIfBehind()
                return
            }
            publishedBeforeCatalogLoad = false
            let storeReadMs = DiagnosticsTiming.milliseconds(since: storeReadStart)

            let projectionStart = ContinuousClock.now
            let signpost = OtosSignpost.performance.beginInterval("CatalogWindowPublication")
            defer {
                OtosSignpost.performance.endInterval("CatalogWindowPublication", signpost)
            }
            let build = try await buildWindowState(
                store: store,
                libraries: libraries,
                request: selectedRequest,
                reuse: reuse
            )
            // A cancelled pass is a teardown: whatever it read is not the catalog.
            try Task.checkCancellation()
            guard case let .built(state, buildMetrics) = build else {
                // Owed, not failed: the window keeps what it shows and says it is searching,
                // and the reader's report that the reading ended rings the loop.
                pendingKind = max(pendingKind, kind)
                OtosLog.catalog.noticeOperation("projection.publish", phase: "searchReading", fields: [
                    "projection": diagnosticID,
                    "generation": "\(selectedRequest.generation)",
                ])
                publishSearchReading()
                return
            }
            completed = CatalogProjectionCompletedPublication(
                state: state,
                buildMetrics: buildMetrics,
                selectedDescriptor: selectedRequest.descriptor,
                timing: CatalogProjectionPublicationTiming(
                    storeReadMs: storeReadMs,
                    projectionMs: DiagnosticsTiming.milliseconds(since: projectionStart),
                    totalMs: DiagnosticsTiming.milliseconds(since: publicationStart)
                )
            )
        } catch is CancellationError {
            // Teardown (`removeContinuation`) already reset the counters; this pass
            // belongs to a subscription that no longer exists.
            return
        } catch {
            // The work is still owed: `covered` stays put and the severity is
            // re-merged. No doorbell here — a persistent error must not retry in a
            // tight loop; the next intent or cadence tick retries it.
            pendingKind = max(pendingKind, kind)
            OtosLog.catalog.errorOperation("projection.publish", phase: "failed", fields: [
                "projection": diagnosticID,
                "generation": "\(selectedRequest.generation)",
                "error": String(describing: error),
            ])
            return
        }

        // The window goes out now, with the groups last built.
        var window = completed.state
        window.duplicates = duplicates
        window.people = people
        let diagnostics = publish(
            CatalogProjectionCompletedPublication(
                state: window,
                buildMetrics: completed.buildMetrics,
                selectedDescriptor: completed.selectedDescriptor,
                timing: completed.timing
            ),
            selectedRequest: selectedRequest
        )
        await diagnostics.emit()
        // A cancelled pass is a teardown: the counters and the derived owners it would touch
        // now belong to no subscription, or to the next one.
        guard !Task.isCancelled else {
            return
        }
        covered = startedFrom
        ringIfBehind()
        // An injected test builder derives nothing. Otherwise a pass that took up a catalog
        // change asks both owners for a build, and one that took up only added rows asks
        // People for its tally; it waits for neither.
        guard stateBuilder == nil, let duplicatesProjection, let peopleAssignment else {
            return
        }
        let asksBuild = derivedStartedFrom != derivedForwarded
        let asksTally = tallyStartedFrom != tallyForwarded
        derivedForwarded = derivedStartedFrom
        tallyForwarded = tallyStartedFrom
        if asksBuild {
            // A full People pass reads the tally too.
            await duplicatesProjection.request()
            await peopleAssignment.request()
        } else if asksTally {
            await peopleAssignment.requestTally()
        }
    }

    /// Republishes the last state, as it is, marked as searching: while a query is read the
    /// window keeps what it shows (ADR 0048). Nothing is covered, so the pass the reading's
    /// end rings builds the answer. Synchronous.
    func publishSearchReading() {
        guard var state = lastPublishedState, state.searchPhase != .reading else {
            return
        }
        state.searchPhase = .reading
        yield(state)
    }

    /// Takes in a fresh People build and republishes the last state with it when it differs
    /// from what it carries. Synchronous.
    func publishPeople(_ built: CatalogPeopleState) {
        people = built
        guard var state = lastPublishedState, state.people != built else {
            return
        }
        state.people = built
        yield(state)
    }

    /// Takes in freshly built groups and republishes the last state with them when they
    /// differ from what it carries. Synchronous.
    func publishDuplicates(_ built: CatalogDuplicatesState) {
        duplicates = built
        guard var state = lastPublishedState, state.duplicates != built else {
            return
        }
        state.duplicates = built
        yield(state)
    }

    /// Normalizes the selection the build resolved, compares against the last published
    /// state, and yields it if it changed. Synchronous.
    func publish(
        _ publication: CatalogProjectionCompletedPublication,
        selectedRequest: CatalogQueryRequest
    ) -> CatalogProjectionPublicationDiagnostics {
        // Normalize only the exact input this build used; a newer reentrant user
        // intent stays outstanding and wins on the next pass.
        let retainedResolvedSelection = retainResolvedSelection(
            publication.state.queryDescriptor,
            forInput: selectedRequest
        )
        let equalityStart = ContinuousClock.now
        let changeSummary = CatalogProjectionChangeSummary.compare(
            previous: lastPublishedState,
            current: publication.state
        )
        let stateChanged = changeSummary.stateChanged
        let equalityUs = DiagnosticsTiming.microseconds(since: equalityStart)
        if stateChanged {
            yield(publication.state)
        }
        return CatalogProjectionPublicationDiagnostics(
            state: publication.state,
            assetCount: publication.state.mediaGrid.orderedAssetIDs.count,
            metrics: publication.buildMetrics,
            changeSummary: changeSummary,
            selectedSidebarRow: publication.selectedDescriptor.scope,
            retainedResolvedSelection: retainedResolvedSelection,
            equalityUs: equalityUs,
            storeReadMs: publication.timing.storeReadMs,
            projectionMs: publication.timing.projectionMs,
            totalMs: publication.timing.totalMs,
            dirtyAfter: requested != covered,
            stateChanged: stateChanged,
            orderQueryCount: orderQueryCount
        )
    }

    private func retainResolvedSelection(
        _ resolvedDescriptor: CatalogQueryDescriptor,
        forInput inputRequest: CatalogQueryRequest
    ) -> Bool {
        guard queryRequest == inputRequest else {
            return false
        }
        queryRequest.descriptor = resolvedDescriptor
        return resolvedDescriptor != inputRequest.descriptor
    }

    func publishLoadingState(for request: CatalogQueryRequest) {
        publishedBeforeCatalogLoad = true
        var loading = CatalogWindowState.empty
        loading.mediaGrid = CatalogMediaGridState(descriptor: request.descriptor, orderedAssetIDs: [])
        loading.resolvedSidebarSelection = request.descriptor.scope
        loading.queryGeneration = request.generation
        OtosLog.catalog.notice("op=projection.publish phase=loadingCatalog")
        if loading != lastPublishedState {
            yield(loading)
        }
    }

    private func yield(_ state: CatalogWindowState) {
        lastPublishedState = state
        publicationCount += 1
        for continuation in continuations.values {
            continuation.yield(state)
        }
    }

    func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
        guard continuations.isEmpty else {
            return
        }
        duplicatesProjection?.stop()
        duplicatesProjection = nil
        duplicatesTask?.cancel()
        duplicatesTask = nil
        peopleAssignment?.stop()
        peopleAssignment = nil
        peopleTask?.cancel()
        peopleTask = nil
        derivedRequested = 0
        derivedForwarded = 0
        tallyRequested = 0
        tallyForwarded = 0
        changeTask?.cancel()
        changeTask = nil
        loopTask?.cancel()
        loopTask = nil
        cadenceTask?.cancel()
        cadenceTask = nil
        doorbell?.finish()
        doorbell = nil
        requested = 0
        covered = 0
        pendingKind = .none
        lastPublishedState = nil
        duplicates = nil
        people = nil
        orderQueryCount = 0
    }
}
