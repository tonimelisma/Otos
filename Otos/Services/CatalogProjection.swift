import Foundation
import OSLog

/// Catalog Projection guide
/// This actor is the read-model boundary between catalog truth and the main window:
/// fixed/removable source splitting, ordering, reachability filtering, sidebar scope,
/// title selection, camera guidance banner state, and empty-state meaning. Notifications
/// coalesce on the cadence; direct query intents wake publication immediately. `dirty`
/// is cleared before awaited reads/build work so input survives for the next pass. Pure
/// policy lives in `CatalogWindowPolicy`; diagnostics values live in
/// `CatalogProjectionDiagnostics`.
actor CatalogProjection {
    // swiftlint:disable:next line_length
    typealias WindowStateBuilder = @Sendable ([CatalogLibraryState], [MediaAssetID], CatalogQueryRequest) async -> CatalogWindowState

    /// Whether the next publication must rebuild the full ordered-asset query. A
    /// detail-only change (enrichment that touched no ordering/scope column) reuses
    /// the last published order — the grid's own same-identity `.refreshVisible` path
    /// already updates visible details cheaply (ADR 0011). `.none` means no
    /// change is pending (the publish gate is `dirty`).
    private enum DirtyKind {
        case none
        case structural
        case detailOnly
    }

    private let cadence: Duration
    let stateBuilder: WindowStateBuilder?

    private var queryRequest: CatalogQueryRequest = .initial
    private var dirty = false
    private var dirtyKind: DirtyKind = .none
    private var publishing = false
    private var continuations: [UUID: AsyncStream<CatalogWindowState>.Continuation] = [:]
    private var changeTask: Task<Void, Never>?
    private var publicationTask: Task<Void, Never>?
    private var immediatePublicationTask: Task<Void, Never>?
    private var publicationStore: CatalogStore?
    private var lastPublishedState: CatalogWindowState?
    /// Count of full ordered-asset queries executed by publications. A detail-only
    /// publication skips it; the count is the observable "full-catalog re-sort per
    /// enrichment batch" metric (ADR 0011) and drives the regression test.
    private(set) var orderQueryCount: UInt64 = 0
    var detailRefreshGeneration: UInt64 = 0

    /// True when no change is pending and no publication is in flight. Lets a test
    /// poll for settlement instead of guessing a sleep duration.
    var isQuiescent: Bool {
        !dirty && !publishing
    }

    init(
        cadence: Duration = .seconds(1),
        stateBuilder: WindowStateBuilder? = nil
    ) {
        self.cadence = cadence
        self.stateBuilder = stateBuilder
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
        markDirty(wakeImmediately: true, store: store)
        return stream
    }

    func updateSidebarSelection(_ selection: SidebarSelection) {
        updateQueryDescriptor(CatalogQueryDescriptor(
            scope: selection,
            filter: queryRequest.descriptor.filter,
            sort: queryRequest.descriptor.sort
        ))
    }

    func updateQueryDescriptor(_ descriptor: CatalogQueryDescriptor) {
        guard queryRequest.descriptor != descriptor else { return }
        queryRequest = CatalogQueryRequest(
            descriptor: descriptor,
            generation: queryRequest.generation &+ 1
        )
        scheduleImmediatePublicationAfterIntent()
    }

    func updateQueryRequest(_ request: CatalogQueryRequest) {
        guard queryRequest != request else { return }
        queryRequest = request
        scheduleImmediatePublicationAfterIntent()
    }

    /// One-shot window-state build for tests. Production UI consumes the coalesced
    /// publication loop; this entry exists so projection math can be asserted without
    /// standing up the dirty/publish cadence.
    func windowState(
        libraries: [CatalogLibraryState],
        orderedAssetIDs: [MediaAssetID],
        sidebarSelection: SidebarSelection
    ) async -> CatalogWindowState {
        let (state, _) = await buildWindowState(
            libraries: libraries,
            orderedAssetIDs: orderedAssetIDs,
            request: CatalogQueryRequest(
                descriptor: CatalogQueryDescriptor(scope: sidebarSelection),
                generation: 0
            )
        )
        return state
    }
}

private extension CatalogProjection {
    func ensurePublicationLoop(store: CatalogStore, changes: AsyncStream<CatalogStoreChange>?) {
        publicationStore = store
        guard publicationTask == nil else {
            return
        }

        let cadence = cadence
        changeTask = Task { [weak self, changes] in
            guard let changes else {
                return
            }
            for await change in changes {
                await self?.storeDidChange(change)
            }
        }

        publicationTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: cadence)
                } catch {
                    return
                }
                await self?.publishIfDirty(store: store)
            }
        }
    }

    func markDirty(wakeImmediately: Bool = false, store: CatalogStore? = nil) {
        dirty = true
        dirtyKind = .structural
        if wakeImmediately, let store {
            immediatePublicationTask?.cancel()
            immediatePublicationTask = Task { [weak self, store] in
                await self?.publishIfDirty(store: store)
            }
        }
    }

    /// Marks dirt that may skip the full order re-query. A pending structural change
    /// always wins over a detail-only one (max-severity semantics).
    func markDetailDirty(wakeImmediately: Bool = false, store: CatalogStore? = nil) {
        dirty = true
        if dirtyKind != .structural {
            dirtyKind = .detailOnly
        }
        if wakeImmediately, let store {
            immediatePublicationTask?.cancel()
            immediatePublicationTask = Task { [weak self, store] in
                await self?.publishIfDirty(store: store)
            }
        }
    }

    func scheduleImmediatePublicationAfterIntent() {
        guard let publicationStore else {
            dirty = true
            return
        }
        markDirty(wakeImmediately: true, store: publicationStore)
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
        if case .assetsDetailChanged = change {
            markDetailDirty()
        } else {
            markDirty()
        }
    }

    func publishIfDirty(store: CatalogStore) async {
        guard dirty else {
            return
        }
        guard !publishing else {
            return
        }

        // Clear before awaiting so changes during reads/build remain queued.
        dirty = false
        let pendingDirtyKind = dirtyKind
        dirtyKind = .none
        publishing = true
        let selectedRequest = queryRequest

        // Detail-only dirt reuses the order we last published — but only when the
        // freshly-resolved descriptor still matches the descriptor that order was
        // built for (libraries/import batches are unchanged), so a concurrent scope
        // resolution change still re-runs the query. The grid renders the same
        // identities (a cheap `.refreshVisible`) and the identity comparison
        // short-circuits on the shared array buffer. A structural change or a newer
        // user intent re-runs the full query.
        let reuseOrderedAssetIDs: [MediaAssetID]?
        let reuseDescriptor: CatalogQueryDescriptor?
        if pendingDirtyKind == .detailOnly, let previous = lastPublishedState {
            reuseOrderedAssetIDs = previous.mediaGrid.orderedAssetIDs
            reuseDescriptor = previous.queryDescriptor
        } else {
            reuseOrderedAssetIDs = nil
            reuseDescriptor = nil
        }

        let publicationStart = Date()
        let storeReadStart = Date()
        let libraries = await store.currentLibraries()
        let storeReadMs = DiagnosticsTiming.milliseconds(since: storeReadStart)

        let projectionStart = Date()
        let signpost = OtosSignpost.performance.beginInterval("CatalogWindowPublication")
        let (state, buildMetrics) = await buildWindowState(
            store: store,
            libraries: libraries,
            request: selectedRequest,
            reuseOrderedAssetIDs: reuseOrderedAssetIDs,
            reuseDescriptor: reuseDescriptor
        )
        OtosSignpost.performance.endInterval("CatalogWindowPublication", signpost)

        // Normalize only the exact input this build used; a newer reentrant user
        // intent stays dirty and wins on the next tick.
        let retainedResolvedSelection = retainResolvedSelection(
            state.queryDescriptor,
            forInput: selectedRequest
        )
        await finishPublication(CatalogProjectionCompletedPublication(
            state: state,
            buildMetrics: buildMetrics,
            selectedDescriptor: selectedRequest.descriptor,
            retainedResolvedSelection: retainedResolvedSelection,
            timing: CatalogProjectionPublicationTiming(
                storeReadMs: storeReadMs,
                projectionMs: DiagnosticsTiming.milliseconds(since: projectionStart),
                totalMs: DiagnosticsTiming.milliseconds(since: publicationStart)
            )
        ), store: store)
    }

    private func finishPublication(
        _ publication: CatalogProjectionCompletedPublication,
        store: CatalogStore
    ) async {
        let equalityStart = Date()
        let changeSummary = CatalogProjectionChangeSummary.compare(
            previous: lastPublishedState,
            current: publication.state
        )
        let stateChanged = changeSummary.stateChanged
        let equalityUs = DiagnosticsTiming.microseconds(since: equalityStart)

        await CatalogProjectionPublicationDiagnostics(
            state: publication.state,
            assetCount: publication.state.mediaGrid.orderedAssetIDs.count,
            metrics: publication.buildMetrics,
            changeSummary: changeSummary,
            selectedSidebarRow: publication.selectedDescriptor.scope,
            retainedResolvedSelection: publication.retainedResolvedSelection,
            equalityUs: equalityUs,
            storeReadMs: publication.timing.storeReadMs,
            projectionMs: publication.timing.projectionMs,
            totalMs: publication.timing.totalMs,
            dirtyAfter: dirty,
            stateChanged: stateChanged,
            orderQueryCount: orderQueryCount
        ).emit()

        if stateChanged {
            yield(publication.state)
        }
        publishing = false
        if dirty {
            // Re-wake with the pending change's kind preserved: a detail-only change
            // that arrived mid-publication must not be escalated to a structural
            // rebuild by the re-wake.
            if dirtyKind == .detailOnly {
                markDetailDirty(wakeImmediately: true, store: store)
            } else {
                markDirty(wakeImmediately: true, store: store)
            }
        }
    }

    private func yield(_ state: CatalogWindowState) {
        lastPublishedState = state
        for continuation in continuations.values {
            continuation.yield(state)
        }
    }

    func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
        guard continuations.isEmpty else {
            return
        }
        changeTask?.cancel()
        changeTask = nil
        publicationTask?.cancel()
        publicationTask = nil
        immediatePublicationTask?.cancel()
        immediatePublicationTask = nil
        publicationStore = nil
        dirty = false
        dirtyKind = .none
        publishing = false
        lastPublishedState = nil
        orderQueryCount = 0
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
}

private extension CatalogProjection {
    private func buildWindowState(
        store: CatalogStore,
        libraries unsortedLibraries: [CatalogLibraryState],
        request: CatalogQueryRequest,
        reuseOrderedAssetIDs: [MediaAssetID]? = nil,
        reuseDescriptor: CatalogQueryDescriptor? = nil
    ) async -> (CatalogWindowState, CatalogProjectionBuildMetrics) {
        let allRoots = CatalogWindowPolicy.sortLibraries(unsortedLibraries)
        let sources = CatalogWindowPolicy.sourceRows(from: allRoots)
        let availableLibraryPaths = CatalogWindowPolicy.availablePaths(from: allRoots)
        let importBatches: [ImportBatchSummary]
        do {
            importBatches = try await store.importBatches()
        } catch {
            OtosLog.catalog.error(
                "Catalog import batch query failed error=\(String(describing: error), privacy: .public)"
            )
            importBatches = []
        }
        let resolvedDescriptor = CatalogWindowPolicy.resolvedDescriptor(
            request.descriptor,
            libraries: sources.libraries,
            removableSources: sources.removableSources,
            importBatches: importBatches
        )
        let orderedAssetIDs: [MediaAssetID]
        let orderQueryMs: Int
        if let reuseOrderedAssetIDs, let reuseDescriptor, resolvedDescriptor == reuseDescriptor {
            orderedAssetIDs = reuseOrderedAssetIDs
            orderQueryMs = 0
        } else {
            orderQueryCount &+= 1
            let orderStart = Date()
            do {
                orderedAssetIDs = try await store.orderedAssetIDs(
                    for: resolvedDescriptor,
                    availableLibraryPaths: availableLibraryPaths
                )
                orderQueryMs = DiagnosticsTiming.milliseconds(since: orderStart)
            } catch {
                OtosLog.catalog.error(
                    "Catalog ordered asset query failed error=\(String(describing: error), privacy: .public)"
                )
                orderedAssetIDs = []
                orderQueryMs = DiagnosticsTiming.milliseconds(since: orderStart)
            }
        }
        return await buildWindowState(
            libraries: allRoots,
            orderedAssetIDs: orderedAssetIDs,
            request: request,
            resolvedDescriptor: resolvedDescriptor,
            store: store,
            availableLibraryPaths: availableLibraryPaths,
            importBatches: importBatches,
            orderQueryMs: orderQueryMs
        )
    }

    private func buildWindowState(
        libraries unsortedLibraries: [CatalogLibraryState],
        orderedAssetIDs: [MediaAssetID],
        request: CatalogQueryRequest,
        resolvedDescriptor providedResolvedDescriptor: CatalogQueryDescriptor? = nil,
        store: CatalogStore? = nil,
        availableLibraryPaths providedAvailableLibraryPaths: Set<LibraryRootPath>? = nil,
        importBatches providedImportBatches: [ImportBatchSummary]? = nil,
        orderQueryMs: Int = 0
    ) async -> (CatalogWindowState, CatalogProjectionBuildMetrics) {
        if let injectedState = await injectedWindowState(
            unsortedLibraries,
            orderedAssetIDs: orderedAssetIDs,
            request: request
        ) {
            return injectedState
        }

        let signpost = OtosSignpost.performance.beginInterval("CatalogWindowStateBuild")
        defer {
            OtosSignpost.performance.endInterval("CatalogWindowStateBuild", signpost)
        }
        let allRoots = CatalogWindowPolicy.sortLibraries(unsortedLibraries)
        let sources = CatalogWindowPolicy.sourceRows(from: allRoots)
        let rootsByPath = CatalogWindowPolicy.rootsByPath(from: allRoots)
        let availableLibraryPaths = providedAvailableLibraryPaths
            ?? CatalogWindowPolicy.availablePaths(from: allRoots)
        let importBatches: [ImportBatchSummary]
        if let providedImportBatches {
            importBatches = providedImportBatches
        } else if let store {
            do {
                importBatches = try await store.importBatches()
            } catch {
                importBatches = []
            }
        } else {
            importBatches = []
        }
        let resolvedDescriptor = providedResolvedDescriptor
            ?? CatalogWindowPolicy.resolvedDescriptor(
                request.descriptor,
                libraries: sources.libraries,
                removableSources: sources.removableSources,
                importBatches: importBatches
            )
        let resolvedSidebarSelection = resolvedDescriptor.scope
        let title = CatalogWindowPolicy.title(for: resolvedSidebarSelection, libraries: allRoots)
        let scopedAssetIDs = CatalogWindowPolicy.assetIDs(
            for: resolvedSidebarSelection,
            orderedAssetIDs: orderedAssetIDs,
            availableLibraryPaths: availableLibraryPaths,
            rootsByPath: rootsByPath
        )
        let (mediaEmptyState, filterOptions) = await supplementaryWindowStateFields(
            CatalogProjectionSupplementaryBuildInput(
                resolvedDescriptor: resolvedDescriptor,
                allRoots: allRoots,
                orderedAssetIDs: orderedAssetIDs,
                scopedAssetIDs: scopedAssetIDs,
                store: store,
                availableLibraryPaths: availableLibraryPaths
            )
        )

        return (catalogWindowState(CatalogProjectionWindowStateParts(
            title: title,
            libraries: sources.libraries,
            removableSources: sources.removableSources,
            importBatches: importBatches,
            resolvedDescriptor: resolvedDescriptor,
            queryGeneration: request.generation,
            scopedAssetIDs: scopedAssetIDs,
            filterOptions: filterOptions,
            mediaEmptyState: mediaEmptyState
        )), CatalogProjectionBuildMetrics(orderQueryMs: orderQueryMs))
    }

    private func supplementaryWindowStateFields(
        _ input: CatalogProjectionSupplementaryBuildInput
    ) async -> (CatalogMediaEmptyState, CatalogFilterOptions) {
        async let mediaEmptyState = emptyStateForBuild(CatalogProjectionEmptyStateBuildInput(
            descriptor: input.resolvedDescriptor,
            libraries: input.allRoots,
            rootsByPath: CatalogWindowPolicy.rootsByPath(from: input.allRoots),
            orderedAssetIDs: input.orderedAssetIDs,
            scopedAssetIDs: input.scopedAssetIDs,
            store: input.store,
            availableLibraryPaths: input.availableLibraryPaths
        ))
        async let filterOptions = filterOptions(
            for: input.resolvedDescriptor.scope,
            store: input.store,
            availableLibraryPaths: input.availableLibraryPaths
        )
        return await (mediaEmptyState, filterOptions)
    }
}
