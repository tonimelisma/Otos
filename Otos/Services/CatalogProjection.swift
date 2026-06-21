import Foundation
import OSLog

/// CatalogProjection turns raw catalog snapshots into the state SwiftUI renders.
/// It also owns the publication cadence so Store mutations, scan batches, and
/// sidebar changes are coalesced through one backpressure point.
actor CatalogProjection {
    typealias WindowStateBuilder = @Sendable (CatalogSnapshot, SidebarSelection) async -> CatalogWindowState

    private struct BuildMetrics {
        let orderCacheHit: Bool
        let orderSorted: Bool
        let orderInvariantRebuilt: Bool
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
    private var cachedAssetStructureRevision: UInt64?
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
                "assetStructureRevision": "\(snapshot.assetStructureRevision)",
                "assetOrderCacheHit": "\(buildMetrics.orderCacheHit)",
                "assetOrderSorted": "\(buildMetrics.orderSorted)",
                "assetOrderInvariantRebuilt": "\(buildMetrics.orderInvariantRebuilt)",
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
        cachedAssetStructureRevision = nil
        cachedOrderedAssetIDs.removeAll(keepingCapacity: false)
    }
}

private extension CatalogProjection {
    private func buildWindowState(
        snapshot: CatalogSnapshot,
        sidebarSelection: SidebarSelection
    ) async -> (CatalogWindowState, BuildMetrics) {
        if let stateBuilder {
            let state = await stateBuilder(snapshot, sidebarSelection)
            return (
                state,
                BuildMetrics(
                    orderCacheHit: false,
                    orderSorted: false,
                    orderInvariantRebuilt: false,
                    sortMs: 0
                )
            )
        }

        let signpost = OtosSignpost.performance.beginInterval("CatalogWindowStateBuild")
        defer {
            OtosSignpost.performance.endInterval("CatalogWindowStateBuild", signpost)
        }
        let libraries = Self.sortLibraries(snapshot.libraries)
        let availableLibraryPaths = Set(libraries.filter(\.isAvailable).map(\.path))
        let (sortedAssets, metrics) = orderedAssets(for: snapshot)
        let availableAssets = sortedAssets.filter { availableLibraryPaths.contains($0.libraryRootPath) }
        let resolvedSidebarSelection = Self.resolvedSidebarSelection(sidebarSelection, libraries: libraries)
        let title = Self.title(for: resolvedSidebarSelection, libraries: libraries)
        let scopedAssets = Self.assets(for: resolvedSidebarSelection, assets: availableAssets)
        let mediaEmptyState = Self.mediaEmptyState(
            for: resolvedSidebarSelection,
            libraries: libraries,
            allAssetCount: sortedAssets.count,
            selectedAssetCount: scopedAssets.count
        )
        let scopedAssetsByID = Dictionary(
            uniqueKeysWithValues: scopedAssets.map { ($0.id, $0) }
        )

        return (
            CatalogWindowState(
                title: title,
                libraries: libraries,
                mediaGrid: CatalogMediaGridState(
                    scope: resolvedSidebarSelection,
                    orderedAssetIDs: scopedAssets.map(\.id),
                    assetsByID: scopedAssetsByID
                ),
                resolvedSidebarSelection: resolvedSidebarSelection,
                mediaEmptyState: mediaEmptyState
            ),
            metrics
        )
    }

    private func orderedAssets(for snapshot: CatalogSnapshot) -> ([MediaAsset], BuildMetrics) {
        if cachedAssetStructureRevision == snapshot.assetStructureRevision {
            let assets = cachedOrderedAssetIDs.compactMap { snapshot.assetsByID[$0] }
            let cacheResolvedExactly = assets.count == snapshot.assetsByID.count
                && cachedOrderedAssetIDs.count == snapshot.assetsByID.count
            if cacheResolvedExactly {
                return (
                    assets,
                    BuildMetrics(
                        orderCacheHit: true,
                        orderSorted: false,
                        orderInvariantRebuilt: false,
                        sortMs: 0
                    )
                )
            }

            // A missed revision increment must not produce a partial or stale
            // browser. Rebuild immediately and leave an observable invariant
            // failure so tests and diagnostics expose the Store bug.
            let revision = snapshot.assetStructureRevision
            OtosLog.catalog.error("Catalog asset order cache invariant failed revision=\(revision, privacy: .public)")
            return rebuildOrderedAssets(snapshot: snapshot, invariantRebuilt: true)
        }

        return rebuildOrderedAssets(snapshot: snapshot, invariantRebuilt: false)
    }

    private func rebuildOrderedAssets(
        snapshot: CatalogSnapshot,
        invariantRebuilt: Bool
    ) -> ([MediaAsset], BuildMetrics) {
        let sortStart = Date()
        let assets = Self.sortAssets(Array(snapshot.assetsByID.values))
        let sortMs = DiagnosticsTiming.milliseconds(since: sortStart)
        cachedAssetStructureRevision = snapshot.assetStructureRevision
        cachedOrderedAssetIDs = assets.map(\.id)
        return (
            assets,
            BuildMetrics(
                orderCacheHit: false,
                orderSorted: true,
                orderInvariantRebuilt: invariantRebuilt,
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

    static func sortAssets(_ assets: [MediaAsset]) -> [MediaAsset] {
        assets.sorted { left, right in
            let libraryComparison = left.libraryDisplayName.localizedStandardCompare(right.libraryDisplayName)
            if libraryComparison != .orderedSame {
                return libraryComparison == .orderedAscending
            }

            let pathComparison = left.libraryRootPath.rawValue.localizedStandardCompare(right.libraryRootPath.rawValue)
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

    static func assets(for sidebarSelection: SidebarSelection, assets: [MediaAsset]) -> [MediaAsset] {
        switch sidebarSelection {
        case .allMedia:
            assets
        case let .library(path):
            assets.filter { $0.libraryRootPath == path }
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
            return allAssetCount == 0 ? .noMedia : .noAvailableMedia
        case let .library(path):
            let library = libraries.first { $0.path == path }
            return library?.availability == .unavailable ? .libraryUnavailable : .noMedia
        }
    }
}
