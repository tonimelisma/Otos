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
/// One 10 Hz loop coalesces Store notifications and sidebar intents. Store's
/// notification stream is registered before the loop starts so detail-only writes
/// that arrive right after startup cannot be missed. `dirty` is cleared before
/// awaited Store reads/build work so input arriving during that await survives for
/// the next tick. The order-requery flag is also cleared before its awaited Store
/// read, so a newer structural or sidebar event can set it again and force the next
/// tick to read fresh IDs. Actor isolation permits only one build at a time.
/// Store invalidations bump a scalar grid detail generation, so detail-only
/// thumbnail/date/name changes still reach the visible cell detail reader without
/// reintroducing whole-asset UI state. Asset order is produced by Store-owned SQL
/// ordering for structural/scope changes; detail-only changes reuse the last ordered
/// IDs because enrichment cannot affect membership or sort order. Missing selected
/// libraries are normalized here, and empty-state policy asks Store for a separate
/// cataloged count only when no assets are visible, so unavailable persisted rows
/// still produce "no available media" instead of "no media." Selection fallback is
/// retained only if no newer intent arrived.
actor CatalogProjection {
    // swiftlint:disable:next line_length
    typealias WindowStateBuilder = @Sendable ([CatalogLibraryState], [MediaAssetID], SidebarSelection) async -> CatalogWindowState

    private struct BuildMetrics {
        let orderQueryMs: Int
    }

    private struct PublicationChangeSummary {
        let previousSelectedScopeAssetCount: Int
        let mediaIdentityChanged: Bool
        let librariesChanged: Bool
        let emptyStateChanged: Bool
        let resolvedSelectionChanged: Bool
        let detailRefreshChanged: Bool
        let mediaIdentityEqualityUs: Int

        static func compare(
            previous: CatalogWindowState?,
            current: CatalogWindowState
        ) -> PublicationChangeSummary {
            guard let previous else {
                return PublicationChangeSummary(
                    previousSelectedScopeAssetCount: -1,
                    mediaIdentityChanged: true,
                    librariesChanged: true,
                    emptyStateChanged: true,
                    resolvedSelectionChanged: true,
                    detailRefreshChanged: true,
                    mediaIdentityEqualityUs: 0
                )
            }

            let identityStart = Date()
            let mediaIdentityChanged = previous.mediaGrid.scope != current.mediaGrid.scope
                || previous.mediaGrid.orderedAssetIDs != current.mediaGrid.orderedAssetIDs
            let identityUs = DiagnosticsTiming.microseconds(since: identityStart)

            return PublicationChangeSummary(
                previousSelectedScopeAssetCount: previous.mediaGrid.orderedAssetIDs.count,
                mediaIdentityChanged: mediaIdentityChanged,
                librariesChanged: previous.libraries != current.libraries,
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
                    "mediaIdentityChanged": "\(changeSummary.mediaIdentityChanged)",
                    "librariesChanged": "\(changeSummary.librariesChanged)",
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

    private var sidebarSelection: SidebarSelection = .allMedia
    private var dirty = false
    private var continuations: [UUID: AsyncStream<CatalogWindowState>.Continuation] = [:]
    private var changeTask: Task<Void, Never>?
    private var publicationTask: Task<Void, Never>?
    private var lastPublishedState: CatalogWindowState?
    private var detailRefreshGeneration: UInt64 = 0
    private var needsOrderRequery = true
    private var cachedOrderedAssetIDs: [MediaAssetID] = []

    init(
        cadence: Duration = .milliseconds(100),
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
        sidebarSelection = initialSidebarSelection
        let changes = changeTask == nil ? await store.changeNotifications() : nil
        ensurePublicationLoop(store: store, changes: changes)
        markDirty()

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
        return stream
    }

    func updateSidebarSelection(_ selection: SidebarSelection) {
        guard sidebarSelection != selection else {
            return
        }
        sidebarSelection = selection
        needsOrderRequery = true
        markDirty()
    }

    func windowState(
        libraries: [CatalogLibraryState],
        orderedAssetIDs: [MediaAssetID],
        sidebarSelection: SidebarSelection
    ) async -> CatalogWindowState {
        let (state, _) = await buildWindowState(
            libraries: libraries,
            orderedAssetIDs: orderedAssetIDs,
            sidebarSelection: sidebarSelection
        )
        return state
    }
}

private extension CatalogProjection {
    func ensurePublicationLoop(store: CatalogStore, changes: AsyncStream<CatalogStoreChange>?) {
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

    func markDirty() {
        dirty = true
    }

    func storeDidChange(_ change: CatalogStoreChange) {
        // A remove and same-path add can occur inside one 10 Hz interval. The
        // final queried state then contains the path again, so state validation
        // alone cannot prove that the selected root was removed. Store's typed
        // removal signal preserves that transient fact without exposing row IDs
        // or creating durable library-instance identity.
        if case let .libraryRemoved(path) = change {
            if sidebarSelection == .library(path) {
                sidebarSelection = .allMedia
            }
        }
        switch change {
        case .catalogChanged, .libraryRemoved:
            needsOrderRequery = true
        case .assetsDetailChanged:
            break
        }
        detailRefreshGeneration &+= 1
        markDirty()
    }

    func publishIfDirty(store: CatalogStore) async {
        guard dirty else {
            return
        }

        // Clear before awaiting so changes that arrive during Store reads/projection
        // work remain queued for the next tick instead of being lost.
        dirty = false
        let selectedSidebarRow = sidebarSelection

        let publicationStart = Date()
        let storeReadStart = Date()
        let libraries = await store.currentLibraries()
        let storeReadMs = DiagnosticsTiming.milliseconds(since: storeReadStart)

        let projectionStart = Date()
        let signpost = OtosSignpost.performance.beginInterval("CatalogWindowPublication")
        let (state, buildMetrics) = await buildWindowState(
            store: store,
            libraries: libraries,
            sidebarSelection: selectedSidebarRow
        )
        OtosSignpost.performance.endInterval("CatalogWindowPublication", signpost)

        // The emitted state and Projection's retained input must agree after a
        // selected root disappears. Actor reentrancy may have delivered a newer
        // user intent during the awaited reads/build, so only normalize the
        // exact input used by this completed build; newer input stays dirty and
        // wins on the next tick.
        let retainedResolvedSelection = retainResolvedSelection(
            state.resolvedSidebarSelection,
            forInput: selectedSidebarRow
        )
        let projectionMs = DiagnosticsTiming.milliseconds(since: projectionStart)
        let totalMs = DiagnosticsTiming.milliseconds(since: publicationStart)
        let equalityStart = Date()
        let stateChanged = lastPublishedState != state
        let equalityUs = DiagnosticsTiming.microseconds(since: equalityStart)
        let changeSummary = PublicationChangeSummary.compare(
            previous: lastPublishedState,
            current: state
        )

        await PublicationDiagnostics(
            state: state,
            assetCount: state.mediaGrid.orderedAssetIDs.count,
            metrics: buildMetrics,
            changeSummary: changeSummary,
            selectedSidebarRow: selectedSidebarRow,
            retainedResolvedSelection: retainedResolvedSelection,
            equalityUs: equalityUs,
            storeReadMs: storeReadMs,
            projectionMs: projectionMs,
            totalMs: totalMs,
            dirtyAfter: dirty,
            stateChanged: stateChanged
        ).emit(to: diagnostics)

        if stateChanged {
            yield(state)
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
        dirty = false
        lastPublishedState = nil
        needsOrderRequery = true
        cachedOrderedAssetIDs = []
    }

    private func retainResolvedSelection(
        _ resolvedSelection: SidebarSelection,
        forInput inputSelection: SidebarSelection
    ) -> Bool {
        guard sidebarSelection == inputSelection else {
            return false
        }
        sidebarSelection = resolvedSelection
        return true
    }
}

private extension CatalogProjection {
    private func buildWindowState(
        store: CatalogStore,
        libraries unsortedLibraries: [CatalogLibraryState],
        sidebarSelection: SidebarSelection
    ) async -> (CatalogWindowState, BuildMetrics) {
        let libraries = Self.sortLibraries(unsortedLibraries)
        let availableLibraryPaths = Set(libraries.filter(\.isAvailable).map(\.path))
        let orderedAssetIDs: [MediaAssetID]
        let orderQueryMs: Int
        if needsOrderRequery {
            let orderStart = Date()
            needsOrderRequery = false
            do {
                orderedAssetIDs = try await store.orderedAssetIDs(
                    for: sidebarSelection,
                    availableLibraryPaths: availableLibraryPaths
                )
                cachedOrderedAssetIDs = orderedAssetIDs
                orderQueryMs = DiagnosticsTiming.milliseconds(since: orderStart)
            } catch {
                OtosLog.catalog.error("Catalog ordered asset query failed")
                needsOrderRequery = true
                orderedAssetIDs = cachedOrderedAssetIDs
                orderQueryMs = DiagnosticsTiming.milliseconds(since: orderStart)
            }
        } else {
            orderedAssetIDs = cachedOrderedAssetIDs
            orderQueryMs = 0
        }
        let scopedAssetIDs = Self.assetIDs(
            for: sidebarSelection,
            orderedAssetIDs: orderedAssetIDs,
            availableLibraryPaths: availableLibraryPaths
        )
        let allAssetCount: Int
        if scopedAssetIDs.isEmpty {
            do {
                allAssetCount = try await store.catalogedAssetCount(for: sidebarSelection)
            } catch {
                OtosLog.catalog.error("Catalog asset count query failed")
                allAssetCount = orderedAssetIDs.count
            }
        } else {
            allAssetCount = orderedAssetIDs.count
        }
        return await buildWindowState(
            libraries: libraries,
            orderedAssetIDs: orderedAssetIDs,
            sidebarSelection: sidebarSelection,
            allAssetCount: allAssetCount,
            orderQueryMs: orderQueryMs
        )
    }

    private func buildWindowState(
        libraries unsortedLibraries: [CatalogLibraryState],
        orderedAssetIDs: [MediaAssetID],
        sidebarSelection: SidebarSelection,
        allAssetCount: Int? = nil,
        orderQueryMs: Int = 0
    ) async -> (CatalogWindowState, BuildMetrics) {
        if let injectedState = await injectedWindowState(
            unsortedLibraries,
            orderedAssetIDs: orderedAssetIDs,
            sidebarSelection: sidebarSelection
        ) {
            return injectedState
        }

        let signpost = OtosSignpost.performance.beginInterval("CatalogWindowStateBuild")
        defer {
            OtosSignpost.performance.endInterval("CatalogWindowStateBuild", signpost)
        }
        let libraries = Self.sortLibraries(unsortedLibraries)
        let availableLibraryPaths = Set(libraries.filter(\.isAvailable).map(\.path))
        let resolvedSidebarSelection = Self.resolvedSidebarSelection(sidebarSelection, libraries: libraries)
        let title = Self.title(for: resolvedSidebarSelection, libraries: libraries)
        let scopedAssetIDs = Self.assetIDs(
            for: resolvedSidebarSelection,
            orderedAssetIDs: orderedAssetIDs,
            availableLibraryPaths: availableLibraryPaths
        )

        let mediaEmptyState = Self.mediaEmptyState(
            for: resolvedSidebarSelection,
            libraries: libraries,
            allAssetCount: allAssetCount ?? orderedAssetIDs.count,
            selectedAssetCount: scopedAssetIDs.count
        )

        return (
            CatalogWindowState(
                title: title,
                libraries: libraries,
                mediaGrid: CatalogMediaGridState(
                    scope: resolvedSidebarSelection,
                    orderedAssetIDs: scopedAssetIDs,
                    detailRefreshGeneration: detailRefreshGeneration
                ),
                resolvedSidebarSelection: resolvedSidebarSelection,
                mediaEmptyState: mediaEmptyState
            ),
            BuildMetrics(orderQueryMs: orderQueryMs)
        )
    }

    /// Tests can inject deliberately slow or controlled derivation without
    /// replacing the publication loop whose dirty/in-flight behavior they need
    /// to exercise. Injected output reports a zero sort duration.
    private func injectedWindowState(
        _ libraries: [CatalogLibraryState],
        orderedAssetIDs: [MediaAssetID],
        sidebarSelection: SidebarSelection
    ) async -> (CatalogWindowState, BuildMetrics)? {
        guard let stateBuilder else {
            return nil
        }
        let state = await stateBuilder(libraries, orderedAssetIDs, sidebarSelection)
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
        for sidebarSelection: SidebarSelection,
        libraries: [CatalogLibraryState],
        allAssetCount: Int,
        selectedAssetCount: Int
    ) -> CatalogMediaEmptyState {
        guard selectedAssetCount == 0 else { return .noMedia }
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
