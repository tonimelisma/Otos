import Foundation
import Observation
import OSLog

/// Catalog window ViewModel guide
///
/// This is the single MainActor adapter between SwiftUI controls and the catalog
/// actors. It owns final UI state, immediate sidebar control state, user intents,
/// and the lifetimes of tasks that connect those inputs and outputs. It does not
/// inspect snapshots, sort assets, touch SQLite, or traverse the filesystem.
///
/// Why MainActor: it assigns the `@Observable` state SwiftUI renders, and all UI
/// must run on the main thread. It is deliberately a thin bridge — if heavy work
/// ever lands here it belongs down in the Store or Projection instead.
///
/// The three asynchronous lanes deliberately have different delivery semantics:
/// Projection states are consumed losslessly, sidebar changes keep only the
/// newest pending value, and add/remove mutations are lossless and serial.
///
/// Why `weak self` in the state consumer: that task loops forever over the
/// Projection's state stream, and a task strongly retains whatever it captures. If
/// it held `self` strongly it would keep this ViewModel alive even after the window
/// is gone — a retain cycle (task keeps ViewModel, ViewModel keeps task) — and
/// `deinit`, which cancels the task, could never run. So the consumer captures
/// `self` weakly and upgrades to a strong reference only for the moment it applies
/// one completed state, then lets go before the next wait. Projection may normalize a removed library
/// back to All Media; applying that result assigns the local control value
/// directly and therefore cannot create a feedback intent.
@MainActor
@Observable
final class CatalogWindowViewModel {
    private enum CatalogMutationIntent {
        case addLibrary(URL)
        case removeLibrary(LibraryRootPath)
    }

    private(set) var sidebarSelection: SidebarSelection = .allMedia
    var state: CatalogWindowState = .empty

    @ObservationIgnored private let catalogStore: CatalogStore
    @ObservationIgnored private let catalogProjection: CatalogProjection
    @ObservationIgnored private let diagnostics: CatalogDiagnostics?
    @ObservationIgnored private let stallMonitor: MainRunLoopStallMonitor
    @ObservationIgnored private let startsStallMonitor: Bool
    @ObservationIgnored private let selectionStream: AsyncStream<SidebarSelection>
    @ObservationIgnored private let selectionContinuation: AsyncStream<SidebarSelection>.Continuation
    @ObservationIgnored private let mutationStream: AsyncStream<CatalogMutationIntent>
    @ObservationIgnored private let mutationContinuation: AsyncStream<CatalogMutationIntent>.Continuation

    @ObservationIgnored private var stateConsumptionTask: Task<Void, Never>?
    @ObservationIgnored private var catalogStartupTask: Task<Void, Never>?
    @ObservationIgnored private var selectionForwardingTask: Task<Void, Never>?
    @ObservationIgnored private var mutationForwardingTask: Task<Void, Never>?
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
        // Selection may discard obsolete pending values, but every accepted
        // add/remove command must survive until the serial consumer handles it.
        let (mutationStream, mutationContinuation) = AsyncStream<CatalogMutationIntent>.makeStream(
            bufferingPolicy: .unbounded
        )
        self.catalogStore = catalogStore
        self.catalogProjection = catalogProjection
        self.diagnostics = diagnostics
        self.stallMonitor = stallMonitor
        self.startsStallMonitor = startsStallMonitor
        self.selectionStream = selectionStream
        self.selectionContinuation = selectionContinuation
        self.mutationStream = mutationStream
        self.mutationContinuation = mutationContinuation
    }

    isolated deinit {
        // Cancel consumers before finishing their producers. Finishing normally
        // drains buffered AsyncStream values; cancellation prevents queued
        // mutations from starting after the ViewModel's ownership has ended.
        stateConsumptionTask?.cancel()
        catalogStartupTask?.cancel()
        selectionForwardingTask?.cancel()
        mutationForwardingTask?.cancel()
        selectionContinuation.finish()
        mutationContinuation.finish()
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
        let projection = catalogProjection
        let store = catalogStore
        let diagnostics = diagnostics
        let initialSelection = sidebarSelection

        startSelectionForwarding(projection: projection)
        startMutationForwarding(store: store, diagnostics: diagnostics)
        startStateConsumption(
            projection: projection,
            store: store,
            initialSelection: initialSelection
        )
        startCatalog(store: store, diagnostics: diagnostics)
    }

    func addLibrary(url: URL) {
        submitCatalogMutation(.addLibrary(url))
    }

    func removeLibrary(_ library: LibraryRoot) {
        submitCatalogMutation(.removeLibrary(library.path))
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

    private func startSelectionForwarding(projection: CatalogProjection) {
        selectionForwardingTask = Task { [projection, selectionStream] in
            for await selection in selectionStream {
                await projection.updateSidebarSelection(selection)
            }
        }
    }

    private func startMutationForwarding(store: CatalogStore, diagnostics: CatalogDiagnostics?) {
        // Mutations use one lossless consumer so Store sees the user's commands
        // in submission order. Cancellation is checked between commands: an
        // already-started SQLite transaction may finish, but the next queued
        // command must not begin after this owner is gone.
        mutationForwardingTask = Task { [mutationStream, store, diagnostics] in
            for await intent in mutationStream {
                guard !Task.isCancelled else {
                    break
                }
                await Self.performCatalogMutation(intent, store: store, diagnostics: diagnostics)
            }
        }
    }

    private func startStateConsumption(
        projection: CatalogProjection,
        store: CatalogStore,
        initialSelection: SidebarSelection
    ) {
        stateConsumptionTask = Task { [weak self, projection, store, initialSelection] in
            let signpost = OtosSignpost.ui.beginInterval("CatalogWindowStateStream")
            let states = await projection.states(
                store: store,
                initialSidebarSelection: initialSelection
            )
            OtosSignpost.ui.endInterval("CatalogWindowStateStream", signpost)
            for await nextState in states {
                // Strongify only for this loop body. Moving this guard outside
                // the loop would retain the ViewModel across the next indefinite
                // stream wait and make deinit-based cancellation unreachable.
                guard let self else {
                    break
                }
                applyState(nextState)
            }
        }
    }

    private func startCatalog(store: CatalogStore, diagnostics: CatalogDiagnostics?) {
        catalogStartupTask = Task { [store, diagnostics] in
            let signpost = OtosSignpost.catalog.beginInterval("CatalogStartIntent")
            do {
                try await store.start()
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

    private func submitCatalogMutation(_ intent: CatalogMutationIntent) {
        switch mutationContinuation.yield(intent) {
        case .enqueued:
            return
        case .dropped:
            // The stream is unbounded, so dropping indicates that its declared
            // lossless contract has been broken rather than normal backpressure.
            assertionFailure("Unbounded catalog mutation stream dropped an intent")
            OtosLog.ui.error("Catalog mutation intent was unexpectedly dropped")
        case .terminated:
            assertionFailure("Catalog mutation submitted after stream termination")
            OtosLog.ui.error("Catalog mutation intent submitted after termination")
        @unknown default:
            assertionFailure("Unknown catalog mutation stream yield result")
            OtosLog.ui.error("Catalog mutation intent returned an unknown yield result")
        }
    }

    private nonisolated static func performCatalogMutation(
        _ intent: CatalogMutationIntent,
        store: CatalogStore,
        diagnostics: CatalogDiagnostics?
    ) async {
        switch intent {
        case let .addLibrary(url):
            let signpost = OtosSignpost.ui.beginInterval("CatalogAddLibraryIntent")
            do {
                try await store.addLibrary(url: url)
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

        case let .removeLibrary(path):
            let signpost = OtosSignpost.ui.beginInterval("CatalogRemoveLibraryIntent")
            do {
                try await store.removeLibrary(path: path)
            } catch {
                OtosLog.catalog.error("Catalog remove library failed")
                await diagnostics?.record(
                    operation: "catalog.library.remove",
                    phase: "error",
                    fields: [
                        "rootPath": path.rawValue,
                        "error": String(describing: error),
                    ]
                )
            }
            OtosSignpost.ui.endInterval("CatalogRemoveLibraryIntent", signpost)
        }
    }
}
