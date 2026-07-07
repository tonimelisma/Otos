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
/// Projection states are consumed losslessly, query descriptor changes keep only
/// the newest pending value, and catalog mutations are lossless and serial. The
/// mutation lane is also where platform source monitors enter the catalog: volume
/// mount events, volume detach events, camera attach/detach, eject, and Forget all
/// use the same Store-owned intent path as fixed-library add/remove.
///
/// Why `weak self` in the state consumer: that task loops forever over the
/// Projection's state stream, and a task strongly retains whatever it captures. If
/// it held `self` strongly it would keep this ViewModel alive even after the window
/// is gone — a retain cycle (task keeps ViewModel, ViewModel keeps task) — and
/// `deinit`, which cancels the task, could never run. So the consumer captures
/// `self` weakly and upgrades to a strong reference only for the moment it applies
/// one completed state, then lets go before the next wait. Projection may normalize
/// a removed library back to All Media while preserving filter/sort; applying that
/// result carries the request generation used to build it, so stale projected
/// states cannot roll back a user's rapid query edits even when the user toggles
/// back to the same descriptor value.
@MainActor
@Observable
final class CatalogWindowViewModel {
    enum CatalogMutationIntent {
        case addLibrary(URL)
        case ensureLibrary(URL)
        case removeLibrary(LibraryRootPath)
        case ejectRemovableSource(LibraryRoot)
        case forgetRemovableSource(LibraryRoot)
        case attachRemovableVolume(RemovableVolumeAttachment)
        case quiesceRemovableSource(String)
        case resumeRemovableSource(String)
        case detachRemovableSource(String, RemovableSourceDetachReason)
    }

    private(set) var sidebarSelection: SidebarSelection = .allMedia
    private(set) var queryDescriptor: CatalogQueryDescriptor = .default
    var state: CatalogWindowState = .empty

    /// Where tiles resolve `thumbnailPath` into a file URL. Comes straight from the
    /// store's `nonisolated` directory so the view layer needs no store access.
    var thumbnailDirectory: URL? {
        catalogStore.thumbnailDirectory
    }

    var tileDetailReader: MediaTileDetailReader {
        mediaTileDetailReader
    }

    var tileImageCache: MediaTileImageCache {
        mediaTileImageCache
    }

    var uiStallMonitor: MainRunLoopStallMonitor {
        stallMonitor
    }

    var catalogDiagnostics: CatalogDiagnostics? {
        diagnostics
    }

    @ObservationIgnored let catalogStore: CatalogStore
    @ObservationIgnored private let catalogProjection: CatalogProjection
    @ObservationIgnored let enrichmentCoordinator: EnrichmentCoordinator?
    @ObservationIgnored let deviceStagingRegistry: DeviceStagingRegistry
    @ObservationIgnored private let mediaTileDetailReader: MediaTileDetailReader
    @ObservationIgnored private let mediaTileImageCache = MediaTileImageCache()
    @ObservationIgnored let diagnostics: CatalogDiagnostics?
    @ObservationIgnored private let stallMonitor: MainRunLoopStallMonitor
    @ObservationIgnored private let startsStallMonitor: Bool
    @ObservationIgnored private let startsEnrichment: Bool
    @ObservationIgnored private let queryStream: AsyncStream<CatalogQueryRequest>
    @ObservationIgnored private let queryContinuation: AsyncStream<CatalogQueryRequest>.Continuation
    @ObservationIgnored private let mutationStream: AsyncStream<CatalogMutationIntent>
    @ObservationIgnored let mutationContinuation: AsyncStream<CatalogMutationIntent>.Continuation
    // Newest-value: only the latest viewport is a useful priority hint; an obsolete
    // scroll position carries no value, so an intermediate one is dropped.
    @ObservationIgnored private let viewportStream: AsyncStream<[MediaAssetID]>
    @ObservationIgnored private let viewportContinuation: AsyncStream<[MediaAssetID]>.Continuation
    @ObservationIgnored var removableVolumeMonitor: RemovableVolumeMonitor?
    @ObservationIgnored var cameraSourceMonitor: CameraSourceMonitor?
    @ObservationIgnored var deviceCatalogTasks: [String: Task<Void, Never>] = [:]

    @ObservationIgnored private var stateConsumptionTask: Task<Void, Never>?
    @ObservationIgnored private var catalogStartupTask: Task<Void, Never>?
    @ObservationIgnored private var queryForwardingTask: Task<Void, Never>?
    @ObservationIgnored private var mutationForwardingTask: Task<Void, Never>?
    @ObservationIgnored private var viewportForwardingTask: Task<Void, Never>?
    @ObservationIgnored private var enrichmentStartTask: Task<Void, Never>?
    @ObservationIgnored var deviceStagingSweepTask: Task<Void, Never>?
    @ObservationIgnored var gridTelemetryTask: Task<Void, Never>?
    @ObservationIgnored var didRecordTerminationGridTelemetry = false
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var queryGeneration = CatalogQueryRequest.initial.generation

    init(
        catalogStore: CatalogStore = CatalogStore(),
        catalogProjection: CatalogProjection = CatalogProjection(),
        enrichmentCoordinator: EnrichmentCoordinator? = nil,
        diagnostics: CatalogDiagnostics? = .shared,
        stallMonitor: MainRunLoopStallMonitor = MainRunLoopStallMonitor(),
        startsStallMonitor: Bool = true,
        startsEnrichment: Bool = true
    ) {
        let (queryStream, queryContinuation) = AsyncStream<CatalogQueryRequest>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        // Selection may discard obsolete pending values, but every accepted
        // add/remove command must survive until the serial consumer handles it.
        let (mutationStream, mutationContinuation) = AsyncStream<CatalogMutationIntent>.makeStream(
            bufferingPolicy: .unbounded
        )
        let (viewportStream, viewportContinuation) = AsyncStream<[MediaAssetID]>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.catalogStore = catalogStore
        self.catalogProjection = catalogProjection
        mediaTileDetailReader = MediaTileDetailReader(store: catalogStore)
        let deviceStagingRegistry = DeviceStagingRegistry()
        self.deviceStagingRegistry = deviceStagingRegistry
        self.enrichmentCoordinator = enrichmentCoordinator ?? (
            startsEnrichment
                ? EnrichmentCoordinator(
                    store: catalogStore,
                    enricher: .live(
                        thumbnailDirectory: catalogStore.thumbnailDirectory
                            ?? FileManager.default.temporaryDirectory
                    ),
                    materialize: { url in
                        if let result = await deviceStagingRegistry.materialize(url) {
                            return result
                        }
                        return await EnrichmentCoordinator.liveMaterialize(url)
                    }
                )
                : nil
        )
        self.diagnostics = diagnostics
        self.stallMonitor = stallMonitor
        self.startsStallMonitor = startsStallMonitor
        self.startsEnrichment = startsEnrichment
        self.queryStream = queryStream
        self.queryContinuation = queryContinuation
        self.mutationStream = mutationStream
        self.mutationContinuation = mutationContinuation
        self.viewportStream = viewportStream
        self.viewportContinuation = viewportContinuation
    }

    isolated deinit {
        // Cancel consumers before finishing their producers. Finishing normally
        // drains buffered AsyncStream values; cancellation prevents queued
        // mutations from starting after the ViewModel's ownership has ended.
        stateConsumptionTask?.cancel()
        catalogStartupTask?.cancel()
        queryForwardingTask?.cancel()
        mutationForwardingTask?.cancel()
        viewportForwardingTask?.cancel()
        enrichmentStartTask?.cancel()
        deviceStagingSweepTask?.cancel()
        removableVolumeMonitor?.stop()
        cameraSourceMonitor?.stop()
        for task in deviceCatalogTasks.values {
            task.cancel()
        }
        deviceCatalogTasks.removeAll()
        gridTelemetryTask?.cancel()
        queryContinuation.finish()
        mutationContinuation.finish()
        viewportContinuation.finish()
        if let coordinator = enrichmentCoordinator {
            // The coordinator's supervisor strongly retains the coordinator, so it must be
            // told to stop or it (and the store) would outlive this window. shutdown() is
            // async and deinit cannot await, so hand it off; this owner is already gone.
            Task { await coordinator.shutdown() }
        }
        stallMonitor.stop()
    }
}

extension CatalogWindowViewModel {
    func start() {
        guard !hasStarted else {
            return
        }
        hasStarted = true

        let signpost = OtosSignpost.ui.beginInterval("CatalogWindowViewModelStart")
        OtosSignpost.ui.endInterval("CatalogWindowViewModelStart", signpost)
        OtosLog.ui.info("Catalog window view model started")
        Task { [diagnostics] in
            await diagnostics?.prepareForLifecycle()
        }
        if startsStallMonitor {
            stallMonitor.start(diagnostics: diagnostics)
        }

        // This is the sole query-intent task. AsyncStream provides ordered
        // delivery and bufferingNewest prevents obsolete clicks from building a
        // queue while Projection is busy publishing a large state.
        let projection = catalogProjection
        let store = catalogStore
        let diagnostics = diagnostics
        let initialRequest = CatalogQueryRequest(
            descriptor: queryDescriptor,
            generation: queryGeneration
        )

        startQueryForwarding(projection: projection)
        startMutationForwarding(store: store, coordinator: enrichmentCoordinator, diagnostics: diagnostics)
        startStateConsumption(
            projection: projection,
            store: store,
            initialRequest: initialRequest
        )
        startCatalog(store: store, diagnostics: diagnostics)
        startRemovableVolumeMonitoring()
        startDeviceStagingSweepThenCameraMonitoring()
        startGridTelemetryRecording(diagnostics: diagnostics)
        if startsEnrichment {
            startEnrichment()
        }
    }

    func addLibrary(url: URL) {
        submitCatalogMutation(.addLibrary(url))
    }

    func ensureLibrary(url: URL) {
        submitCatalogMutation(.ensureLibrary(url))
    }

    func removeLibrary(_ library: LibraryRoot) {
        submitCatalogMutation(.removeLibrary(library.path))
    }

    func ejectRemovableSource(_ source: LibraryRoot) {
        submitCatalogMutation(.ejectRemovableSource(source))
    }

    func forgetRemovableSource(_ source: LibraryRoot) {
        submitCatalogMutation(.forgetRemovableSource(source))
    }

    func selectSidebar(_ selection: SidebarSelection) {
        setQueryDescriptor(CatalogQueryDescriptor(
            scope: selection,
            filter: queryDescriptor.filter,
            sort: queryDescriptor.sort
        ))
    }

    func setMediaFilter(_ filter: MediaFilter) {
        setQueryDescriptor(CatalogQueryDescriptor(
            scope: queryDescriptor.scope,
            filter: filter,
            sort: queryDescriptor.sort
        ))
    }

    func clearMediaFilter() {
        setMediaFilter(.all)
    }

    func toggleMediaKind(_ kind: MediaKind, formatsInKind: [MediaFormatToken]) {
        var filter = queryDescriptor.filter
        if filter.kinds.remove(kind) == nil {
            filter.kinds.insert(kind)
        }
        filter.formats.subtract(formatsInKind)
        setMediaFilter(filter)
    }

    func toggleMediaFormat(_ format: MediaFormatToken, kind: MediaKind) {
        var filter = queryDescriptor.filter
        filter.kinds.remove(kind)
        if filter.formats.remove(format) == nil {
            filter.formats.insert(format)
        }
        setMediaFilter(filter)
    }

    func setSortField(_ field: MediaSortField) {
        setSortOrder(.defaultForField(field))
    }

    func setSortDirection(_ direction: MediaSortDirection) {
        setSortOrder(MediaSortOrder(field: queryDescriptor.sort.field, direction: direction))
    }

    func setSortOrder(_ sort: MediaSortOrder) {
        setQueryDescriptor(CatalogQueryDescriptor(
            scope: queryDescriptor.scope,
            filter: queryDescriptor.filter,
            sort: sort
        ))
    }

    private func setQueryDescriptor(_ descriptor: CatalogQueryDescriptor) {
        guard queryDescriptor != descriptor else { return }
        queryGeneration &+= 1
        queryDescriptor = descriptor
        sidebarSelection = descriptor.scope
        OtosLog.ui.info("Catalog query changed descriptor=\(descriptor.diagnosticDescription, privacy: .public)")
        OtosSignpost.ui.emitEvent("CatalogQueryDescriptorIntent")
        queryContinuation.yield(CatalogQueryRequest(
            descriptor: descriptor,
            generation: queryGeneration
        ))
    }

    /// The AppKit grid reports its visible identities here as the user scrolls. This is a
    /// pure priority hint for enrichment, so only the newest viewport is kept.
    func viewportChanged(_ orderedAssetIDs: [MediaAssetID]) {
        viewportContinuation.yield(orderedAssetIDs)
    }

    private func startEnrichment() {
        guard let coordinator = enrichmentCoordinator else {
            return
        }
        // updateViewport is delivered newest-value; the coordinator is the single owner of
        // the priority hint, so this forwards verbatim with no main-actor work.
        viewportForwardingTask = Task { [coordinator, viewportStream] in
            for await ids in viewportStream {
                await coordinator.updateViewport(ids)
            }
        }
        // Start the coordinator only after the shared initial load has completed, so its
        // first candidate query sees persisted catalog rows rather than an empty pre-load
        // database. A no-op launch rescan of an unchanged library fires no notification,
        // so a coordinator started too early could stay idle until some unrelated change.
        // `store.start()` is idempotent and shared, so this awaits the same load
        // `startCatalog` runs.
        enrichmentStartTask = Task { [coordinator, store = catalogStore] in
            do {
                try await store.start()
            } catch {
                OtosLog.persistence.error("Enrichment startup skipped because catalog start failed")
                return
            }
            await coordinator.start()
        }
    }

    private func startQueryForwarding(projection: CatalogProjection) {
        queryForwardingTask = Task { [projection, queryStream] in
            for await request in queryStream {
                await projection.updateQueryRequest(request)
            }
        }
    }

    private func startMutationForwarding(
        store: CatalogStore,
        coordinator: EnrichmentCoordinator?,
        diagnostics: CatalogDiagnostics?
    ) {
        // Mutations use one lossless consumer so Store sees the user's commands
        // in submission order. Cancellation is checked between commands: an
        // already-started SQLite transaction may finish, but the next queued
        // command must not begin after this owner is gone.
        mutationForwardingTask = Task { [mutationStream, store, coordinator, diagnostics] in
            for await intent in mutationStream {
                guard !Task.isCancelled else {
                    break
                }
                await Self.performCatalogMutation(
                    intent,
                    store: store,
                    coordinator: coordinator,
                    diagnostics: diagnostics
                )
            }
        }
    }

    private func startStateConsumption(
        projection: CatalogProjection,
        store: CatalogStore,
        initialRequest: CatalogQueryRequest
    ) {
        stateConsumptionTask = Task { [weak self, projection, store, initialRequest] in
            let signpost = OtosSignpost.ui.beginInterval("CatalogWindowStateStream")
            let states = await projection.states(
                store: store,
                initialRequest: initialRequest
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
        let operation = stallMonitor.beginOperation("CatalogWindowViewModel.applyState")
        defer { stallMonitor.endOperation(operation) }
        let signpost = OtosSignpost.ui.beginInterval("CatalogWindowStateApply")

        // Projection is authoritative for resolved library availability, but an
        // older publication can finish after a newer local query intent. Request
        // generations make that freshness check value-independent, covering rapid
        // A -> B -> A toggles that equality alone cannot distinguish.
        if nextState.queryGeneration == queryGeneration {
            queryDescriptor = nextState.queryDescriptor
            sidebarSelection = nextState.resolvedSidebarSelection
        } else if currentSelectionWasRemoved(in: nextState) {
            queryDescriptor = CatalogQueryDescriptor(
                scope: .allMedia,
                filter: queryDescriptor.filter,
                sort: queryDescriptor.sort
            )
            sidebarSelection = .allMedia
        } else {
            sidebarSelection = queryDescriptor.scope
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

    private func currentSelectionWasRemoved(in nextState: CatalogWindowState) -> Bool {
        guard case let .library(path) = queryDescriptor.scope,
              nextState.resolvedSidebarSelection == .allMedia
        else {
            return false
        }
        return !nextState.libraries.contains { $0.path == path }
            && !nextState.removableSources.contains { $0.path == path }
    }
}
