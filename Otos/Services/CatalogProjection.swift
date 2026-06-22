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
/// did not change. Ordered IDs are cached, but membership is validated directly
/// against each immutable snapshot so Store does not maintain cache metadata.
actor CatalogProjection {
    typealias WindowStateBuilder = @Sendable (CatalogSnapshot, SidebarSelection) async -> CatalogWindowState

    private struct BuildMetrics {
        let orderCacheHit: Bool
        let orderSorted: Bool
        let assetMembershipChanged: Bool
        let sortMs: Int
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
            for await _ in changes {
                await self?.markDirty()
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
        let projectionMs = DiagnosticsTiming.milliseconds(since: projectionStart)
        let totalMs = DiagnosticsTiming.milliseconds(since: publicationStart)
        let stateChanged = lastPublishedState != state

        await diagnostics?.record(
            operation: "catalog.projection.window",
            phase: "finish",
            fields: [
                "libraries": "\(state.libraries.count)",
                "assetCount": "\(snapshot.assetsByID.count)",
                "selectedScopeAssetCount": "\(state.mediaGrid.orderedAssetIDs.count)",
                "assetOrderCacheHit": "\(buildMetrics.orderCacheHit)",
                "assetOrderSorted": "\(buildMetrics.orderSorted)",
                "assetMembershipChanged": "\(buildMetrics.assetMembershipChanged)",
                "assetSortMs": "\(buildMetrics.sortMs)",
                "sidebarSelection": selectedSidebarRow.diagnosticDescription,
                "resolvedSidebarSelection": state.resolvedSidebarSelection.diagnosticDescription,
                "emptyState": state.mediaEmptyState.diagnosticDescription,
                "snapshotMs": "\(snapshotMs)",
                "projectionMs": "\(projectionMs)",
                "totalMs": "\(totalMs)",
                "dirtyAfterPublication": "\(dirty)",
                "stateChanged": "\(stateChanged)",
            ]
        )

        guard stateChanged else {
            return
        }
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
        cachedOrderedAssetIDs.removeAll(keepingCapacity: false)
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
        let displayNamesByRootPath = Dictionary(
            uniqueKeysWithValues: libraries.map { ($0.path, $0.displayName) }
        )
        let availableLibraryPaths = Set(libraries.filter(\.isAvailable).map(\.path))
        let (orderedAssetIDs, metrics) = orderedAssetIDs(
            for: snapshot,
            displayNamesByRootPath: displayNamesByRootPath
        )
        let resolvedSidebarSelection = Self.resolvedSidebarSelection(sidebarSelection, libraries: libraries)
        let title = Self.title(for: resolvedSidebarSelection, libraries: libraries)
        let scopedAssetIDs = Self.assetIDs(
            for: resolvedSidebarSelection,
            orderedAssetIDs: orderedAssetIDs,
            availableLibraryPaths: availableLibraryPaths
        )

        // Preserve a scoped value map rather than passing the complete snapshot
        // through UI state. A detail update in an unselected library then remains
        // equal and does not trigger unrelated SwiftUI or AppKit work.
        let scopedAssetsByID = Dictionary(
            uniqueKeysWithValues: scopedAssetIDs.compactMap { id in
                snapshot.assetsByID[id].map { (id, $0) }
            }
        )
        let mediaEmptyState = Self.mediaEmptyState(
            for: resolvedSidebarSelection,
            libraries: libraries,
            allAssetCount: orderedAssetIDs.count,
            selectedAssetCount: scopedAssetIDs.count
        )

        return (
            CatalogWindowState(
                title: title,
                libraries: libraries,
                mediaGrid: CatalogMediaGridState(
                    scope: resolvedSidebarSelection,
                    orderedAssetIDs: scopedAssetIDs,
                    assetsByID: scopedAssetsByID
                ),
                resolvedSidebarSelection: resolvedSidebarSelection,
                mediaEmptyState: mediaEmptyState
            ),
            metrics
        )
    }

    /// Tests can inject deliberately slow or controlled derivation without
    /// replacing the publication loop whose dirty/in-flight behavior they need
    /// to exercise. Injected output does not participate in the production order
    /// cache, so its metrics remain neutral.
    private func injectedWindowState(
        _ snapshot: CatalogSnapshot,
        sidebarSelection: SidebarSelection
    ) async -> (CatalogWindowState, BuildMetrics)? {
        guard let stateBuilder else {
            return nil
        }
        let state = await stateBuilder(snapshot, sidebarSelection)
        return (
            state,
            BuildMetrics(
                orderCacheHit: false,
                orderSorted: false,
                assetMembershipChanged: false,
                sortMs: 0
            )
        )
    }

    private func orderedAssetIDs(
        for snapshot: CatalogSnapshot,
        displayNamesByRootPath: [LibraryRootPath: String]
    ) -> ([MediaAssetID], BuildMetrics) {
        // Equal count plus successful lookup of every cached ID proves set
        // equality because asset IDs are unique dictionary keys. This direct
        // validation costs the same O(n) traversal detail rematerialization
        // already required and cannot be forgotten by a Store mutation path.
        let membershipUnchanged = cachedOrderedAssetIDs.count == snapshot.assetsByID.count
            && cachedOrderedAssetIDs.allSatisfy { snapshot.assetsByID[$0] != nil }
        if membershipUnchanged {
            return (
                cachedOrderedAssetIDs,
                BuildMetrics(
                    orderCacheHit: true,
                    orderSorted: false,
                    assetMembershipChanged: false,
                    sortMs: 0
                )
            )
        }

        let sortStart = Date()
        let orderedIDs = Self.sortAssetIDs(
            Array(snapshot.assetsByID.keys),
            displayNamesByRootPath: displayNamesByRootPath
        )
        let sortMs = DiagnosticsTiming.milliseconds(since: sortStart)
        cachedOrderedAssetIDs = orderedIDs
        return (
            orderedIDs,
            BuildMetrics(
                orderCacheHit: false,
                orderSorted: true,
                assetMembershipChanged: true,
                sortMs: sortMs
            )
        )
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

    static func sortAssetIDs(
        _ assetIDs: [MediaAssetID],
        displayNamesByRootPath: [LibraryRootPath: String]
    ) -> [MediaAssetID] {
        assetIDs.sorted { left, right in
            // A snapshot produced by Store always has a matching library. The
            // path-derived fallback keeps malformed test or diagnostic snapshots
            // deterministic without inventing unrelated display text.
            let leftLibraryName = displayNamesByRootPath[left.libraryRootPath]
                ?? left.libraryRootPath.displayName
            let rightLibraryName = displayNamesByRootPath[right.libraryRootPath]
                ?? right.libraryRootPath.displayName
            let libraryComparison = leftLibraryName.localizedStandardCompare(rightLibraryName)
            if libraryComparison != .orderedSame {
                return libraryComparison == .orderedAscending
            }

            let pathComparison = left.libraryRootPath.rawValue.localizedStandardCompare(
                right.libraryRootPath.rawValue
            )
            if pathComparison != .orderedSame {
                return pathComparison == .orderedAscending
            }

            return left.relativePath.rawValue.localizedStandardCompare(right.relativePath.rawValue) == .orderedAscending
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
