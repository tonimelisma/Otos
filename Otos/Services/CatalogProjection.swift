import Foundation
import OSLog

/// CatalogProjection turns raw catalog snapshots into the state SwiftUI renders.
/// It also owns the publication cadence so Store mutations, scan batches, and
/// sidebar changes are coalesced through one backpressure point.
actor CatalogProjection {
    typealias WindowStateBuilder = @Sendable (CatalogSnapshot, SidebarSelection) async -> CatalogWindowState

    private let cadence: Duration
    private let diagnostics: CatalogDiagnostics?
    private let stateBuilder: WindowStateBuilder

    private var sidebarSelection: SidebarSelection = .allMedia
    private var dirty = false
    private var continuations: [UUID: AsyncStream<CatalogWindowState>.Continuation] = [:]
    private var changeTask: Task<Void, Never>?
    private var publicationTask: Task<Void, Never>?

    init(
        cadence: Duration = .milliseconds(100),
        diagnostics: CatalogDiagnostics? = .shared,
        stateBuilder: WindowStateBuilder? = nil
    ) {
        self.cadence = cadence
        self.diagnostics = diagnostics
        self.stateBuilder = stateBuilder ?? { snapshot, selection in
            Self.windowState(snapshot: snapshot, sidebarSelection: selection)
        }
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
        await stateBuilder(snapshot, sidebarSelection)
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

        let snapshot = await store.currentSnapshot()
        let signpost = OtosSignpost.performance.beginInterval("CatalogWindowPublication")
        let state = await stateBuilder(snapshot, selectedSidebarRow)
        OtosSignpost.performance.endInterval("CatalogWindowPublication", signpost)

        await diagnostics?.record(
            operation: "catalog.projection.window",
            phase: "finish",
            fields: [
                "libraries": "\(state.libraries.count)",
                "assetCount": "\(snapshot.assets.count)",
                "selectedScopeAssetCount": "\(state.assetsInSelectedScope.count)",
                "sidebarSelection": selectedSidebarRow.diagnosticDescription,
                "resolvedSidebarSelection": state.resolvedSidebarSelection.diagnosticDescription,
                "emptyState": state.mediaEmptyState.diagnosticDescription,
            ]
        )

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
    }
}

private extension CatalogProjection {
    static func windowState(
        snapshot: CatalogSnapshot,
        sidebarSelection: SidebarSelection
    ) -> CatalogWindowState {
        let libraries = sortLibraries(snapshot.libraries)
        let availableLibraryPaths = Set(libraries.filter(\.isAvailable).map(\.path))
        let sortedAssets = sortAssets(snapshot.assets)
        let availableAssets = sortedAssets.filter { availableLibraryPaths.contains($0.libraryRootPath) }
        let resolvedSidebarSelection = resolvedSidebarSelection(sidebarSelection, libraries: libraries)
        let title = title(for: resolvedSidebarSelection, libraries: libraries)
        let assetsInSelectedScope = assets(for: resolvedSidebarSelection, assets: availableAssets)
        let mediaEmptyState = mediaEmptyState(
            for: resolvedSidebarSelection,
            libraries: libraries,
            allAssets: sortedAssets,
            assetsInSelectedScope: assetsInSelectedScope
        )

        return CatalogWindowState(
            title: title,
            libraries: libraries,
            assetsInSelectedScope: assetsInSelectedScope,
            resolvedSidebarSelection: resolvedSidebarSelection,
            mediaEmptyState: mediaEmptyState
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
        allAssets: [MediaAsset],
        assetsInSelectedScope: [MediaAsset]
    ) -> CatalogMediaEmptyState {
        guard assetsInSelectedScope.isEmpty else {
            return .noMedia
        }

        switch sidebarSelection {
        case .allMedia:
            return allAssets.isEmpty ? .noMedia : .noAvailableMedia
        case let .library(path):
            let library = libraries.first { $0.path == path }
            return library?.availability == .unavailable ? .libraryUnavailable : .noMedia
        }
    }
}

private extension SidebarSelection {
    var diagnosticDescription: String {
        switch self {
        case .allMedia:
            "allMedia"
        case let .library(path):
            "library:\(path.rawValue)"
        }
    }
}

private extension CatalogMediaEmptyState {
    var diagnosticDescription: String {
        switch self {
        case .noMedia:
            "noMedia"
        case .noAvailableMedia:
            "noAvailableMedia"
        case .libraryUnavailable:
            "libraryUnavailable"
        }
    }
}
