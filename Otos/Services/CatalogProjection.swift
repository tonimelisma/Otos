import Foundation
import OSLog

/// Catalog Projection guide
///
/// This actor is the complete read-model boundary between catalog truth and the
/// main window. Store snapshots have keyed but unordered assets; Projection owns
/// library ordering, global asset ordering, reachability filtering, sidebar
/// scope, title selection, and empty-state meaning. None of that work belongs on
/// MainActor or inside a SwiftUI body.
///
/// One 10 Hz loop coalesces Store notifications and sidebar intents. `dirty` is
/// cleared before an awaited snapshot/build so input arriving during that await
/// survives for the next tick. Actor isolation permits only one build at a time,
/// and equal-state suppression prevents detail views from receiving values that
/// did not change. Asset order is produced by sorting precomputed sort keys on
/// every publication; the projection no longer caches order. A missing selected
/// library is normalized here, where selection input is owned;
/// the fallback is retained only if no newer intent arrived during the build.
actor CatalogProjection {
    typealias WindowStateBuilder = @Sendable (CatalogSnapshot, SidebarSelection) async -> CatalogWindowState

    private struct BuildMetrics {
        let sortMs: Int
    }

    private struct PublicationDiagnostics {
        let state: CatalogWindowState
        let assetCount: Int
        let metrics: BuildMetrics
        let selectedSidebarRow: SidebarSelection
        let retainedResolvedSelection: Bool
        let equalityUs: Int
        let snapshotMs: Int
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
                    "selectedScopeAssetCount": "\(state.mediaGrid.orderedAssetIDs.count)",
                    "assetSortMs": "\(metrics.sortMs)",
                    "equalityUs": "\(equalityUs)",
                    "sidebarSelection": selectedSidebarRow.diagnosticDescription,
                    "resolvedSidebarSelection": state.resolvedSidebarSelection.diagnosticDescription,
                    "retainedResolvedSelection": "\(retainedResolvedSelection)",
                    "emptyState": state.mediaEmptyState.diagnosticDescription,
                    "snapshotMs": "\(snapshotMs)",
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
    ) -> AsyncStream<CatalogWindowState> {
        sidebarSelection = initialSidebarSelection
        ensurePublicationLoop(store: store)
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
        markDirty()
    }

    func windowState(
        snapshot: CatalogSnapshot,
        sidebarSelection: SidebarSelection
    ) async -> CatalogWindowState {
        let (state, _) = await buildWindowState(
            snapshot: snapshot,
            sidebarSelection: sidebarSelection
        )
        return state
    }
}

private extension CatalogProjection {
    func ensurePublicationLoop(store: CatalogStore) {
        guard publicationTask == nil else {
            return
        }

        let cadence = cadence
        changeTask = Task { [weak self] in
            let changes = await store.changeNotifications()
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
        // final snapshot then contains the path again, so snapshot validation
        // alone cannot prove that the selected root was removed. Store's typed
        // removal signal preserves that transient fact without exposing row IDs
        // or creating durable library-instance identity.
        if case let .libraryRemoved(path) = change {
            if sidebarSelection == .library(path) {
                sidebarSelection = .allMedia
            }
        }
        markDirty()
    }

    func publishIfDirty(store: CatalogStore) async {
        guard dirty else {
            return
        }

        // Clear before awaiting so changes that arrive during snapshot/projection
        // work remain queued for the next tick instead of being lost.
        dirty = false
        let selectedSidebarRow = sidebarSelection

        let publicationStart = Date()
        let snapshotStart = Date()
        let snapshot = await store.currentSnapshot()
        let snapshotMs = DiagnosticsTiming.milliseconds(since: snapshotStart)

        let projectionStart = Date()
        let signpost = OtosSignpost.performance.beginInterval("CatalogWindowPublication")
        let (state, buildMetrics) = await buildWindowState(
            snapshot: snapshot,
            sidebarSelection: selectedSidebarRow
        )
        OtosSignpost.performance.endInterval("CatalogWindowPublication", signpost)

        // The emitted state and Projection's retained input must agree after a
        // selected root disappears. Actor reentrancy may have delivered a newer
        // user intent during the awaited snapshot/build, so only normalize the
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

        await PublicationDiagnostics(
            state: state,
            assetCount: snapshot.assetsByID.count,
            metrics: buildMetrics,
            selectedSidebarRow: selectedSidebarRow,
            retainedResolvedSelection: retainedResolvedSelection,
            equalityUs: equalityUs,
            snapshotMs: snapshotMs,
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
        snapshot: CatalogSnapshot,
        sidebarSelection: SidebarSelection
    ) async -> (CatalogWindowState, BuildMetrics) {
        if let injectedState = await injectedWindowState(snapshot, sidebarSelection: sidebarSelection) {
            return injectedState
        }

        let signpost = OtosSignpost.performance.beginInterval("CatalogWindowStateBuild")
        defer {
            OtosSignpost.performance.endInterval("CatalogWindowStateBuild", signpost)
        }
        let libraries = Self.sortLibraries(snapshot.libraries)
        let availableLibraryPaths = Set(libraries.filter(\.isAvailable).map(\.path))
        let (orderedAssetIDs, metrics) = orderedAssetIDs(for: snapshot)
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
            allAssetCount: orderedAssetIDs.count,
            selectedAssetCount: scopedAssetIDs.count
        )

        // Pass the snapshot's full value map by copy-on-write. The precomputed sort
        // key made re-sorting every publication negligible, so the projection no
        // longer caches order or materializes a scoped copy; the grid looks up only
        // the visible ids from this shared map.
        return (
            CatalogWindowState(
                title: title,
                libraries: libraries,
                mediaGrid: CatalogMediaGridState(
                    scope: resolvedSidebarSelection,
                    orderedAssetIDs: scopedAssetIDs,
                    assetsByID: snapshot.assetsByID
                ),
                resolvedSidebarSelection: resolvedSidebarSelection,
                mediaEmptyState: mediaEmptyState
            ),
            metrics
        )
    }

    /// Tests can inject deliberately slow or controlled derivation without
    /// replacing the publication loop whose dirty/in-flight behavior they need
    /// to exercise. Injected output reports a zero sort duration.
    private func injectedWindowState(
        _ snapshot: CatalogSnapshot,
        sidebarSelection: SidebarSelection
    ) async -> (CatalogWindowState, BuildMetrics)? {
        guard let stateBuilder else {
            return nil
        }
        let state = await stateBuilder(snapshot, sidebarSelection)
        return (state, BuildMetrics(sortMs: 0))
    }

    private func orderedAssetIDs(for snapshot: CatalogSnapshot) -> ([MediaAssetID], BuildMetrics) {
        // With the precomputed sort key, re-sorting every publication is cheap, so
        // the projection no longer caches order or validates membership; it sorts
        // the current ids directly.
        let sortStart = Date()
        let orderedIDs = Self.sortAssetIDs(snapshot.assetsByID)
        return (orderedIDs, BuildMetrics(sortMs: DiagnosticsTiming.milliseconds(since: sortStart)))
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

    static func sortAssetIDs(_ assetsByID: [MediaAssetID: MediaAsset]) -> [MediaAssetID] {
        // Sort by each asset's precomputed `sortKey` with a plain string compare
        // rather than localized collation per comparison. Ties, which only arise
        // for malformed test or diagnostic snapshots, fall back to the raw path so
        // the result stays deterministic.
        assetsByID.values
            .sorted { left, right in
                if left.sortKey != right.sortKey {
                    return left.sortKey < right.sortKey
                }
                if left.libraryRootPath.rawValue != right.libraryRootPath.rawValue {
                    return left.libraryRootPath.rawValue < right.libraryRootPath.rawValue
                }
                return left.relativePath.rawValue < right.relativePath.rawValue
            }
            .map(\.id)
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
        guard selectedAssetCount == 0 else {
            return .noMedia
        }

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
