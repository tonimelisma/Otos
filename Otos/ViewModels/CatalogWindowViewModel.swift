import Foundation
import Observation
import OSLog

/// MainActor adapter for SwiftUI. It owns user intents and assigns already-made
/// window state; catalog mutation and projection work stay with their actors.
@MainActor
@Observable
final class CatalogWindowViewModel {
    var sidebarSelection: SidebarSelection = .allMedia {
        didSet {
            guard sidebarSelection != oldValue,
                  !isApplyingResolvedSidebarSelection
            else {
                return
            }
            syncSidebarSelectionToProjection()
        }
    }

    var state: CatalogWindowState = .empty

    @ObservationIgnored private let catalogStore: CatalogStore
    @ObservationIgnored private let catalogProjection: CatalogProjection
    @ObservationIgnored private let diagnostics: CatalogDiagnostics?
    @ObservationIgnored private let startsStallMonitor: Bool

    @ObservationIgnored private var stateTask: Task<Void, Never>?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var isApplyingResolvedSidebarSelection = false

    init(
        catalogStore: CatalogStore = CatalogStore(),
        catalogProjection: CatalogProjection = CatalogProjection(),
        diagnostics: CatalogDiagnostics? = .shared,
        startsStallMonitor: Bool = true
    ) {
        self.catalogStore = catalogStore
        self.catalogProjection = catalogProjection
        self.diagnostics = diagnostics
        self.startsStallMonitor = startsStallMonitor
    }

    deinit {
        stateTask?.cancel()
        startTask?.cancel()
    }

    func start() {
        guard !hasStarted else {
            return
        }
        hasStarted = true

        let signpost = OtosSignpost.ui.beginInterval("CatalogWindowViewModelStart")
        OtosSignpost.ui.endInterval("CatalogWindowViewModelStart", signpost)
        OtosLog.ui.info("Catalog window view model started")
        if startsStallMonitor {
            MainRunLoopStallMonitor.shared.start(diagnostics: diagnostics)
        }

        stateTask = Task {
            let signpost = OtosSignpost.ui.beginInterval("CatalogWindowStateStream")
            let states = await catalogProjection.states(
                store: catalogStore,
                initialSidebarSelection: sidebarSelection
            )
            OtosSignpost.ui.endInterval("CatalogWindowStateStream", signpost)
            for await nextState in states {
                applyState(nextState)
            }
        }

        startTask = Task {
            let signpost = OtosSignpost.catalog.beginInterval("CatalogStartIntent")
            do {
                try await catalogStore.start()
            } catch {
                OtosLog.persistence.error("Catalog start failed")
                await diagnostics?.record(
                    operation: "catalog.start",
                    phase: "error",
                    fields: ["error": String(describing: error)]
                )
            }
            OtosSignpost.catalog.endInterval("CatalogStartIntent", signpost)
        }
    }

    func addLibrary(url: URL) {
        Task {
            let signpost = OtosSignpost.ui.beginInterval("CatalogAddLibraryIntent")
            do {
                try await catalogStore.addLibrary(url: url)
            } catch {
                OtosLog.catalog.error("Catalog add library failed")
                await diagnostics?.record(
                    operation: "catalog.library.add",
                    phase: "error",
                    fields: [
                        "url": url.path(percentEncoded: false),
                        "error": String(describing: error),
                    ]
                )
            }
            OtosSignpost.ui.endInterval("CatalogAddLibraryIntent", signpost)
        }
    }

    func removeLibrary(_ library: LibraryRoot) {
        Task {
            let signpost = OtosSignpost.ui.beginInterval("CatalogRemoveLibraryIntent")
            do {
                try await catalogStore.removeLibrary(path: library.path)
            } catch {
                OtosLog.catalog.error("Catalog remove library failed")
                await diagnostics?.record(
                    operation: "catalog.library.remove",
                    phase: "error",
                    fields: [
                        "rootPath": library.path.rawValue,
                        "error": String(describing: error),
                    ]
                )
            }
            OtosSignpost.ui.endInterval("CatalogRemoveLibraryIntent", signpost)
        }
    }

    private func syncSidebarSelectionToProjection() {
        let selection = sidebarSelection
        let signpost = OtosSignpost.ui.beginInterval("CatalogSidebarSelectionSync")
        Task {
            await catalogProjection.updateSidebarSelection(selection)
            OtosSignpost.ui.endInterval("CatalogSidebarSelectionSync", signpost)
        }
    }

    private func applyState(_ nextState: CatalogWindowState) {
        let previousState = state
        let updateID = CatalogUIUpdateTracker.shared.reserveUpdateID()
        let applyStart = Date()
        let signpost = OtosSignpost.ui.beginInterval("CatalogWindowStateApply")

        if sidebarSelection != nextState.resolvedSidebarSelection {
            isApplyingResolvedSidebarSelection = true
            sidebarSelection = nextState.resolvedSidebarSelection
            isApplyingResolvedSidebarSelection = false
        }

        state = nextState
        OtosSignpost.ui.endInterval("CatalogWindowStateApply", signpost)

        let itemCount = nextState.mediaGrid.orderedAssetIDs.count
        let previousItemCount = previousState.mediaGrid.orderedAssetIDs.count
        let handoff = CatalogGridHandoff(
            updateID: updateID,
            itemCount: itemCount,
            previousItemCount: previousItemCount,
            itemDelta: itemCount - previousItemCount,
            selection: nextState.resolvedSidebarSelection.diagnosticDescription,
            emptyState: nextState.mediaEmptyState.diagnosticDescription,
            timestamp: Date()
        )
        CatalogUIUpdateTracker.shared.recordGridHandoff(handoff)

        let applyMs = DiagnosticsTiming.milliseconds(since: applyStart)
        let diagnostics = diagnostics
        Task {
            await diagnostics?.record(
                operation: "catalog.window.state.apply",
                phase: "finish",
                fields: [
                    "updateID": "\(updateID)",
                    "itemCount": "\(itemCount)",
                    "previousItemCount": "\(previousItemCount)",
                    "itemDelta": "\(itemCount - previousItemCount)",
                    "libraries": "\(nextState.libraries.count)",
                    "selection": nextState.resolvedSidebarSelection.diagnosticDescription,
                    "emptyState": nextState.mediaEmptyState.diagnosticDescription,
                    "applyMs": "\(applyMs)",
                ]
            )
        }
    }
}
