import Foundation
import Observation
import OSLog

/// Catalog window ViewModel guide
///
/// This is the single MainActor adapter between SwiftUI controls and the catalog
/// actors. It owns final UI state, immediate sidebar control state, user intents,
/// and the lifetimes of tasks that feed those actors. It does not inspect
/// snapshots, sort assets, touch SQLite, or traverse the filesystem.
///
/// Sidebar changes enter one buffering-newest stream rather than creating a Task
/// per click. The one forwarding task preserves intent order and lets rapid
/// changes coalesce before crossing to Projection. Projection may normalize a
/// removed library back to All Media; applying that result assigns the local
/// control value directly and therefore cannot create a feedback intent.
@MainActor
@Observable
final class CatalogWindowViewModel {
    private(set) var sidebarSelection: SidebarSelection = .allMedia
    var state: CatalogWindowState = .empty

    @ObservationIgnored private let catalogStore: CatalogStore
    @ObservationIgnored private let catalogProjection: CatalogProjection
    @ObservationIgnored private let diagnostics: CatalogDiagnostics?
    @ObservationIgnored private let stallMonitor: MainRunLoopStallMonitor
    @ObservationIgnored private let startsStallMonitor: Bool
    @ObservationIgnored private let selectionStream: AsyncStream<SidebarSelection>
    @ObservationIgnored private let selectionContinuation: AsyncStream<SidebarSelection>.Continuation

    @ObservationIgnored private var stateTask: Task<Void, Never>?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var selectionTask: Task<Void, Never>?
    @ObservationIgnored private var hasStarted = false

    init(
        catalogStore: CatalogStore = CatalogStore(),
        catalogProjection: CatalogProjection = CatalogProjection(),
        diagnostics: CatalogDiagnostics? = .shared,
        stallMonitor: MainRunLoopStallMonitor = MainRunLoopStallMonitor(),
        startsStallMonitor: Bool = true
    ) {
        let (selectionStream, selectionContinuation) = AsyncStream<SidebarSelection>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.catalogStore = catalogStore
        self.catalogProjection = catalogProjection
        self.diagnostics = diagnostics
        self.stallMonitor = stallMonitor
        self.startsStallMonitor = startsStallMonitor
        self.selectionStream = selectionStream
        self.selectionContinuation = selectionContinuation
    }

    isolated deinit {
        selectionContinuation.finish()
        stateTask?.cancel()
        startTask?.cancel()
        selectionTask?.cancel()
        stallMonitor.stop()
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
            stallMonitor.start(diagnostics: diagnostics)
        }

        // This is the sole sidebar-intent task. AsyncStream provides ordered
        // delivery and bufferingNewest prevents obsolete clicks from building a
        // queue while Projection is busy publishing a large state.
        selectionTask = Task { [catalogProjection, selectionStream] in
            for await selection in selectionStream {
                await catalogProjection.updateSidebarSelection(selection)
            }
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

    func selectSidebar(_ selection: SidebarSelection) {
        guard sidebarSelection != selection else {
            return
        }
        sidebarSelection = selection
        OtosLog.ui.info("Sidebar selection changed selection=\(selection.diagnosticDescription, privacy: .public)")
        OtosSignpost.ui.emitEvent("CatalogSidebarSelectionIntent")
        selectionContinuation.yield(selection)
    }

    private func applyState(_ nextState: CatalogWindowState) {
        let previousState = state
        let updateID = stallMonitor.reserveUpdateID()
        let applyStart = Date()
        let signpost = OtosSignpost.ui.beginInterval("CatalogWindowStateApply")

        // Projection is authoritative for whether the selected library still
        // exists. Direct assignment is not a new user intent and deliberately
        // bypasses the selection stream.
        sidebarSelection = nextState.resolvedSidebarSelection

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
        stallMonitor.recordGridHandoff(handoff)

        let applyMs = DiagnosticsTiming.milliseconds(since: applyStart)
        OtosLog.ui.debug(
            """
            Catalog window state applied updateID=\(updateID, privacy: .public) \
            items=\(itemCount, privacy: .public) delta=\(itemCount - previousItemCount, privacy: .public) \
            libraries=\(nextState.libraries.count, privacy: .public) applyMs=\(applyMs, privacy: .public)
            """
        )
    }
}
