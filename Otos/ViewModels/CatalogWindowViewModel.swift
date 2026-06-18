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

    @ObservationIgnored private var stateTask: Task<Void, Never>?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var isApplyingResolvedSidebarSelection = false

    init(
        catalogStore: CatalogStore = CatalogStore(),
        catalogProjection: CatalogProjection = CatalogProjection()
    ) {
        self.catalogStore = catalogStore
        self.catalogProjection = catalogProjection
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

        stateTask = Task {
            let states = await catalogProjection.states(
                store: catalogStore,
                initialSidebarSelection: sidebarSelection
            )
            for await nextState in states {
                applyState(nextState)
            }
        }

        startTask = Task {
            do {
                try await catalogStore.start()
            } catch {
                OtosLog.persistence.error("Catalog start failed")
                await CatalogDiagnostics.shared.record(
                    operation: "catalog.start",
                    phase: "error",
                    fields: ["error": String(describing: error)]
                )
            }
        }
    }

    func addLibrary(url: URL) {
        Task {
            do {
                try await catalogStore.addLibrary(url: url)
            } catch {
                OtosLog.catalog.error("Catalog add library failed")
                await CatalogDiagnostics.shared.record(
                    operation: "catalog.library.add",
                    phase: "error",
                    fields: [
                        "url": url.path(percentEncoded: false),
                        "error": String(describing: error),
                    ]
                )
            }
        }
    }

    func removeLibrary(_ library: LibraryRoot) {
        Task {
            do {
                try await catalogStore.removeLibrary(path: library.path)
            } catch {
                OtosLog.catalog.error("Catalog remove library failed")
                await CatalogDiagnostics.shared.record(
                    operation: "catalog.library.remove",
                    phase: "error",
                    fields: [
                        "rootPath": library.path.rawValue,
                        "error": String(describing: error),
                    ]
                )
            }
        }
    }

    private func syncSidebarSelectionToProjection() {
        let selection = sidebarSelection
        Task {
            await catalogProjection.updateSidebarSelection(selection)
        }
    }

    private func applyState(_ nextState: CatalogWindowState) {
        if sidebarSelection != nextState.resolvedSidebarSelection {
            isApplyingResolvedSidebarSelection = true
            sidebarSelection = nextState.resolvedSidebarSelection
            isApplyingResolvedSidebarSelection = false
        }

        state = nextState
    }
}
