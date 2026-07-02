import Foundation
import OSLog

// swiftlint:disable file_length

/// Catalog Projection guide
///
/// This actor is the complete read-model boundary between catalog truth and the
/// main window. Store exposes root rows and ordered asset IDs; Projection owns library
/// ordering, reachability filtering, sidebar scope, title selection, and empty-state
/// meaning. None of that work belongs on MainActor or inside a SwiftUI body.
///
/// Why a separate actor from the Store: sorting and filtering tens of thousands of
/// assets is real CPU work that must not run on the main thread (main-thread work
/// is what makes a UI hang). Being its own actor moves that work off the main
/// thread automatically. Keeping it separate from the Store means "what media
/// exists" and "how this window shows it" stay independent — sorting can change
/// without touching persistence, and the Store stays testable without UI concerns.
///
/// Background Store notifications coalesce on the cadence, while direct user query
/// intents schedule an immediate publication attempt. Store's notification stream
/// is registered before publication starts so detail-only writes that arrive right
/// after startup cannot be missed. `dirty` is cleared before awaited Store
/// reads/build work so input arriving during that await survives for the next pass.
/// Actor isolation permits only one build at a time.
///
/// Store invalidations bump a scalar grid detail generation, so thumbnail/date/name
/// changes still reach the visible cell detail reader without reintroducing
/// whole-asset UI state. Every publication asks Store for ordered IDs for the
/// current descriptor: enrichment can now change best date, kind, or format, so
/// order and membership are query truth rather than a cached assumption. Missing
/// selected libraries are normalized here while preserving filter/sort, and
/// empty-state policy asks Store for separate counts only when no assets are
/// visible. Selection fallback is retained only if no newer intent arrived.
actor CatalogProjection {
    // swiftlint:disable:next line_length
    typealias WindowStateBuilder = @Sendable ([CatalogLibraryState], [MediaAssetID], CatalogQueryDescriptor) async -> CatalogWindowState

    private struct BuildMetrics {
        let orderQueryMs: Int
    }

    private struct PublicationTiming {
        let storeReadMs: Int
        let projectionMs: Int
        let totalMs: Int
    }

    private struct CompletedPublication {
        let state: CatalogWindowState
        let buildMetrics: BuildMetrics
        let selectedDescriptor: CatalogQueryDescriptor
        let retainedResolvedSelection: Bool
        let timing: PublicationTiming
    }

    private struct WindowStateParts {
        let title: String
        let libraries: [CatalogLibraryState]
        let resolvedDescriptor: CatalogQueryDescriptor
        let scopedAssetIDs: [MediaAssetID]
        let filterOptions: CatalogFilterOptions
        let mediaEmptyState: CatalogMediaEmptyState
    }

    private struct EmptyStateBuildInput {
        let descriptor: CatalogQueryDescriptor
        let libraries: [CatalogLibraryState]
        let orderedAssetIDs: [MediaAssetID]
        let scopedAssetIDs: [MediaAssetID]
        let store: CatalogStore?
        let availableLibraryPaths: Set<LibraryRootPath>
    }

    struct PublicationChangeSummary {
        let previousSelectedScopeAssetCount: Int
        let titleChanged: Bool
        let mediaIdentityChanged: Bool
        let librariesChanged: Bool
        let filterOptionsChanged: Bool
        let emptyStateChanged: Bool
        let resolvedSelectionChanged: Bool
        let detailRefreshChanged: Bool
        let mediaIdentityEqualityUs: Int

        var stateChanged: Bool {
            titleChanged
                || mediaIdentityChanged
                || librariesChanged
                || filterOptionsChanged
                || emptyStateChanged
                || resolvedSelectionChanged
                || detailRefreshChanged
        }

        static func compare(
            previous: CatalogWindowState?,
            current: CatalogWindowState
        ) -> PublicationChangeSummary {
            guard let previous else {
                return PublicationChangeSummary(
                    previousSelectedScopeAssetCount: -1,
                    titleChanged: true,
                    mediaIdentityChanged: true,
                    librariesChanged: true,
                    filterOptionsChanged: true,
                    emptyStateChanged: true,
                    resolvedSelectionChanged: true,
                    detailRefreshChanged: true,
                    mediaIdentityEqualityUs: 0
                )
            }

            let identityStart = Date()
            let mediaIdentityChanged = previous.mediaGrid.descriptor != current.mediaGrid.descriptor
                || previous.mediaGrid.orderedAssetIDs != current.mediaGrid.orderedAssetIDs
            let identityUs = DiagnosticsTiming.microseconds(since: identityStart)

            return PublicationChangeSummary(
                previousSelectedScopeAssetCount: previous.mediaGrid.orderedAssetIDs.count,
                titleChanged: previous.title != current.title,
                mediaIdentityChanged: mediaIdentityChanged,
                librariesChanged: previous.libraries != current.libraries,
                filterOptionsChanged: previous.filterOptions != current.filterOptions,
                emptyStateChanged: previous.mediaEmptyState != current.mediaEmptyState,
                resolvedSelectionChanged: previous.resolvedSidebarSelection != current.resolvedSidebarSelection,
                detailRefreshChanged: previous.mediaGrid.detailRefreshGeneration
                    != current.mediaGrid.detailRefreshGeneration,
                mediaIdentityEqualityUs: identityUs
            )
        }
    }

    private struct PublicationDiagnostics {
        let state: CatalogWindowState
        let assetCount: Int
        let metrics: BuildMetrics
        let changeSummary: PublicationChangeSummary
        let selectedSidebarRow: SidebarSelection
        let retainedResolvedSelection: Bool
        let equalityUs: Int
        let storeReadMs: Int
        let projectionMs: Int
        let totalMs: Int
        let dirtyAfter: Bool
        let stateChanged: Bool

        func emit(to diagnostics: CatalogDiagnostics?) async {
            await diagnostics?.record(
                operation: "catalog.projection.window",
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
                    "storeReadMs": "\(storeReadMs)",
                    "projectionMs": "\(projectionMs)",
                    "totalMs": "\(totalMs)",
                    "dirtyAfterPublication": "\(dirtyAfter)",
                    "stateChanged": "\(stateChanged)",
                ]
            )
        }
    }

    private let cadence: Duration
    private let diagnostics: CatalogDiagnostics?
    private let stateBuilder: WindowStateBuilder?

    private var queryDescriptor: CatalogQueryDescriptor = .default
    private var dirty = false
    private var publishing = false
    private var continuations: [UUID: AsyncStream<CatalogWindowState>.Continuation] = [:]
    private var changeTask: Task<Void, Never>?
    private var publicationTask: Task<Void, Never>?
    private var immediatePublicationTask: Task<Void, Never>?
    private var publicationStore: CatalogStore?
    private var lastPublishedState: CatalogWindowState?
    private var detailRefreshGeneration: UInt64 = 0

    init(
        cadence: Duration = .seconds(1),
        diagnostics: CatalogDiagnostics? = .shared,
        stateBuilder: WindowStateBuilder? = nil
    ) {
        self.cadence = cadence
        self.diagnostics = diagnostics
        self.stateBuilder = stateBuilder
    }

    func states(
        store: CatalogStore,
        initialSidebarSelection: SidebarSelection
    ) async -> AsyncStream<CatalogWindowState> {
        await states(store: store, initialDescriptor: CatalogQueryDescriptor(scope: initialSidebarSelection))
    }

    func states(
        store: CatalogStore,
        initialDescriptor: CatalogQueryDescriptor
    ) async -> AsyncStream<CatalogWindowState> {
        queryDescriptor = initialDescriptor
        let changes = changeTask == nil ? await store.changeNotifications() : nil
        ensurePublicationLoop(store: store, changes: changes)

        let (stream, continuation) = AsyncStream<CatalogWindowState>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let id = UUID()
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeContinuation(id)
            }
        }
        markDirty(wakeImmediately: true, store: store)
        return stream
    }

    func updateSidebarSelection(_ selection: SidebarSelection) {
        updateQueryDescriptor(CatalogQueryDescriptor(
            scope: selection,
            filter: queryDescriptor.filter,
            sort: queryDescriptor.sort
        ))
    }

    func updateQueryDescriptor(_ descriptor: CatalogQueryDescriptor) {
        guard queryDescriptor != descriptor else { return }
        queryDescriptor = descriptor
        scheduleImmediatePublicationAfterIntent()
    }

    func windowState(
        libraries: [CatalogLibraryState],
        orderedAssetIDs: [MediaAssetID],
        sidebarSelection: SidebarSelection
    ) async -> CatalogWindowState {
        let (state, _) = await buildWindowState(
            libraries: libraries,
            orderedAssetIDs: orderedAssetIDs,
            descriptor: CatalogQueryDescriptor(scope: sidebarSelection)
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
        // A remove and same-path add can occur inside one coalescing interval. The
        // final queried state then contains the path again, so state validation
        // alone cannot prove that the selected root was removed. Store's typed
        // removal signal preserves that transient fact without exposing row IDs
        // or creating durable library-instance identity.
        if case let .libraryRemoved(path) = change {
            if queryDescriptor.scope == .library(path) {
                queryDescriptor.scope = .allMedia
            }
        }
        detailRefreshGeneration &+= 1
        markDirty()
    }

    func publishIfDirty(store: CatalogStore) async {
        guard dirty else {
            return
        }
        guard !publishing else {
            return
        }

        // Clear before awaiting so changes that arrive during Store reads/projection
        // work remain queued for the next tick instead of being lost.
        dirty = false
        publishing = true
        let selectedDescriptor = queryDescriptor

        let publicationStart = Date()
        let storeReadStart = Date()
        let libraries = await store.currentLibraries()
        let storeReadMs = DiagnosticsTiming.milliseconds(since: storeReadStart)

        let projectionStart = Date()
        let signpost = OtosSignpost.performance.beginInterval("CatalogWindowPublication")
        let (state, buildMetrics) = await buildWindowState(
            store: store,
            libraries: libraries,
            descriptor: selectedDescriptor
        )
        OtosSignpost.performance.endInterval("CatalogWindowPublication", signpost)

        // The emitted state and Projection's retained input must agree after a
        // selected root disappears. Actor reentrancy may have delivered a newer
        // user intent during the awaited reads/build, so only normalize the
        // exact input used by this completed build; newer input stays dirty and
        // wins on the next tick.
        let retainedResolvedSelection = retainResolvedSelection(
            state.queryDescriptor,
            forInput: selectedDescriptor
        )
        await finishPublication(CompletedPublication(
            state: state,
            buildMetrics: buildMetrics,
            selectedDescriptor: selectedDescriptor,
            retainedResolvedSelection: retainedResolvedSelection,
            timing: PublicationTiming(
                storeReadMs: storeReadMs,
                projectionMs: DiagnosticsTiming.milliseconds(since: projectionStart),
                totalMs: DiagnosticsTiming.milliseconds(since: publicationStart)
            )
        ), store: store)
    }

    private func finishPublication(
        _ publication: CompletedPublication,
        store: CatalogStore
    ) async {
        let equalityStart = Date()
        let changeSummary = PublicationChangeSummary.compare(
            previous: lastPublishedState,
            current: publication.state
        )
        let stateChanged = changeSummary.stateChanged
        let equalityUs = DiagnosticsTiming.microseconds(since: equalityStart)

        await PublicationDiagnostics(
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
            stateChanged: stateChanged
        ).emit(to: diagnostics)

        if stateChanged {
            yield(publication.state)
        }
        publishing = false
        if dirty {
            markDirty(wakeImmediately: true, store: store)
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
        publishing = false
        lastPublishedState = nil
    }

    private func retainResolvedSelection(
        _ resolvedDescriptor: CatalogQueryDescriptor,
        forInput inputDescriptor: CatalogQueryDescriptor
    ) -> Bool {
        guard queryDescriptor == inputDescriptor else {
            return false
        }
        queryDescriptor = resolvedDescriptor
        return resolvedDescriptor != inputDescriptor
    }
}

private extension CatalogProjection {
    private func buildWindowState(
        store: CatalogStore,
        libraries unsortedLibraries: [CatalogLibraryState],
        descriptor: CatalogQueryDescriptor
    ) async -> (CatalogWindowState, BuildMetrics) {
        let libraries = Self.sortLibraries(unsortedLibraries)
        let availableLibraryPaths = Set(libraries.filter(\.isAvailable).map(\.path))
        let resolvedDescriptor = Self.resolvedDescriptor(descriptor, libraries: libraries)
        let orderedAssetIDs: [MediaAssetID]
        let orderQueryMs: Int
        let orderStart = Date()
        do {
            orderedAssetIDs = try await store.orderedAssetIDs(
                for: resolvedDescriptor,
                availableLibraryPaths: availableLibraryPaths
            )
            orderQueryMs = DiagnosticsTiming.milliseconds(since: orderStart)
        } catch {
            OtosLog.catalog.error("Catalog ordered asset query failed")
            orderedAssetIDs = []
            orderQueryMs = DiagnosticsTiming.milliseconds(since: orderStart)
        }
        return await buildWindowState(
            libraries: libraries,
            orderedAssetIDs: orderedAssetIDs,
            descriptor: descriptor,
            resolvedDescriptor: resolvedDescriptor,
            store: store,
            availableLibraryPaths: availableLibraryPaths,
            orderQueryMs: orderQueryMs
        )
    }

    private func buildWindowState(
        libraries unsortedLibraries: [CatalogLibraryState],
        orderedAssetIDs: [MediaAssetID],
        descriptor: CatalogQueryDescriptor,
        resolvedDescriptor providedResolvedDescriptor: CatalogQueryDescriptor? = nil,
        store: CatalogStore? = nil,
        availableLibraryPaths providedAvailableLibraryPaths: Set<LibraryRootPath>? = nil,
        orderQueryMs: Int = 0
    ) async -> (CatalogWindowState, BuildMetrics) {
        if let injectedState = await injectedWindowState(
            unsortedLibraries,
            orderedAssetIDs: orderedAssetIDs,
            descriptor: descriptor
        ) {
            return injectedState
        }

        let signpost = OtosSignpost.performance.beginInterval("CatalogWindowStateBuild")
        defer {
            OtosSignpost.performance.endInterval("CatalogWindowStateBuild", signpost)
        }
        let libraries = Self.sortLibraries(unsortedLibraries)
        let availableLibraryPaths = providedAvailableLibraryPaths ?? Set(
            libraries.filter(\.isAvailable).map(\.path)
        )
        let resolvedDescriptor = providedResolvedDescriptor ?? Self.resolvedDescriptor(descriptor, libraries: libraries)
        let resolvedSidebarSelection = resolvedDescriptor.scope
        let title = Self.title(for: resolvedSidebarSelection, libraries: libraries)
        let scopedAssetIDs = Self.assetIDs(
            for: resolvedSidebarSelection,
            orderedAssetIDs: orderedAssetIDs,
            availableLibraryPaths: availableLibraryPaths
        )
        let mediaEmptyState = await emptyStateForBuild(EmptyStateBuildInput(
            descriptor: resolvedDescriptor,
            libraries: libraries,
            orderedAssetIDs: orderedAssetIDs,
            scopedAssetIDs: scopedAssetIDs,
            store: store,
            availableLibraryPaths: availableLibraryPaths
        ))
        let filterOptions = await filterOptions(
            for: resolvedDescriptor.scope,
            store: store,
            availableLibraryPaths: availableLibraryPaths
        )

        return (catalogWindowState(WindowStateParts(
            title: title,
            libraries: libraries,
            resolvedDescriptor: resolvedDescriptor,
            scopedAssetIDs: scopedAssetIDs,
            filterOptions: filterOptions,
            mediaEmptyState: mediaEmptyState
        )), BuildMetrics(orderQueryMs: orderQueryMs))
    }

    private func emptyStateForBuild(_ input: EmptyStateBuildInput) async -> CatalogMediaEmptyState {
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
        return Self.mediaEmptyState(
            for: input.descriptor,
            libraries: input.libraries,
            allAssetCount: allAssetCount,
            unfilteredVisibleAssetCount: unfilteredVisibleAssetCount,
            selectedAssetCount: input.scopedAssetIDs.count
        )
    }

    private func catalogWindowState(_ parts: WindowStateParts) -> CatalogWindowState {
        CatalogWindowState(
            title: parts.title,
            libraries: parts.libraries,
            mediaGrid: CatalogMediaGridState(
                descriptor: parts.resolvedDescriptor,
                orderedAssetIDs: parts.scopedAssetIDs,
                detailRefreshGeneration: detailRefreshGeneration
            ),
            filterOptions: parts.filterOptions,
            resolvedSidebarSelection: parts.resolvedDescriptor.scope,
            mediaEmptyState: parts.mediaEmptyState
        )
    }

    private func catalogedAssetCountForEmptyState(
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
            OtosLog.catalog.error("Catalog asset count query failed")
            return orderedAssetIDs.count
        }
    }

    private func unfilteredVisibleAssetCountForEmptyState(
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
            OtosLog.catalog.error("Catalog unfiltered visible count query failed")
            return 0
        }
    }

    private func filterOptions(
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
            OtosLog.catalog.error("Catalog filter option query failed")
            return .empty
        }
    }

    /// Tests can inject deliberately slow or controlled derivation without
    /// replacing the publication loop whose dirty/in-flight behavior they need
    /// to exercise. Injected output reports a zero sort duration.
    private func injectedWindowState(
        _ libraries: [CatalogLibraryState],
        orderedAssetIDs: [MediaAssetID],
        descriptor: CatalogQueryDescriptor
    ) async -> (CatalogWindowState, BuildMetrics)? {
        guard let stateBuilder else {
            return nil
        }
        let state = await stateBuilder(libraries, orderedAssetIDs, descriptor)
        return (state, BuildMetrics(orderQueryMs: 0))
    }

    static func sortLibraries(_ libraries: [CatalogLibraryState]) -> [CatalogLibraryState] {
        libraries.sorted { left, right in
            let displayComparison = left.displayName.localizedStandardCompare(right.displayName)
            if displayComparison == .orderedSame {
                return left.path.rawValue.localizedStandardCompare(right.path.rawValue) == .orderedAscending
            }
            return displayComparison == .orderedAscending
        }
    }

    static func resolvedSidebarSelection(
        _ sidebarSelection: SidebarSelection,
        libraries: [CatalogLibraryState]
    ) -> SidebarSelection {
        switch sidebarSelection {
        case .allMedia:
            .allMedia
        case let .library(path):
            libraries.contains { $0.path == path } ? sidebarSelection : .allMedia
        }
    }

    static func resolvedDescriptor(
        _ descriptor: CatalogQueryDescriptor,
        libraries: [CatalogLibraryState]
    ) -> CatalogQueryDescriptor {
        CatalogQueryDescriptor(
            scope: resolvedSidebarSelection(descriptor.scope, libraries: libraries),
            filter: descriptor.filter,
            sort: descriptor.sort
        )
    }

    static func assetIDs(
        for sidebarSelection: SidebarSelection,
        orderedAssetIDs: [MediaAssetID],
        availableLibraryPaths: Set<LibraryRootPath>
    ) -> [MediaAssetID] {
        orderedAssetIDs.filter { id in
            guard availableLibraryPaths.contains(id.libraryRootPath) else {
                return false
            }
            switch sidebarSelection {
            case .allMedia:
                return true
            case let .library(path):
                return id.libraryRootPath == path
            }
        }
    }

    static func title(for sidebarSelection: SidebarSelection, libraries: [CatalogLibraryState]) -> String {
        switch sidebarSelection {
        case .allMedia:
            "All Media"
        case let .library(path):
            libraries.first { $0.path == path }?.displayName ?? "Library"
        }
    }

    static func mediaEmptyState(
        for descriptor: CatalogQueryDescriptor,
        libraries: [CatalogLibraryState],
        allAssetCount: Int,
        unfilteredVisibleAssetCount: Int,
        selectedAssetCount: Int
    ) -> CatalogMediaEmptyState {
        guard selectedAssetCount == 0 else { return .noMedia }
        if descriptor.filter.isActive, unfilteredVisibleAssetCount > 0 {
            return .noFilterMatches
        }
        let sidebarSelection = descriptor.scope
        switch sidebarSelection {
        case .allMedia:
            if libraries.contains(where: { $0.availability == .unknown }) {
                return .checkingLibraries
            }
            return allAssetCount == 0 ? .noMedia : .noAvailableMedia
        case let .library(path):
            let library = libraries.first { $0.path == path }
            switch library?.availability {
            case .unknown:
                return .libraryChecking
            case .unavailable:
                return .libraryUnavailable
            case .available, .none:
                return .noMedia
            }
        }
    }
}
