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
    private(set) var ejectingSourceIdentities: Set<String> = []
    var ejectAlertMessage: String?
    var state: CatalogWindowState = .empty
    /// User-adjustable grid density (spec 0048), 3–9. `private(set)` so the only way to
    /// change it is the `setGridColumnCount(_:)` intent below — the one clamp/persist/publish
    /// path every zoom surface shares (compiler-enforced single owner). Set in `init`, not a
    /// property default, because its initial value depends on the injected
    /// `gridColumnCountDefaults`.
    private(set) var gridColumnCount: Int

    /// Where tiles resolve `thumbnailPath` into a file URL. Comes straight from the
    /// store's `nonisolated` directory so the view layer needs no store access.
    var thumbnailDirectory: URL? {
        catalogStore.thumbnailDirectory
    }

    var tileDetailReader: MediaTileDetailReader {
        mediaTileDetailReader
    }

    var uiStallMonitor: MainRunLoopStallMonitor {
        stallMonitor
    }

    @ObservationIgnored let catalogStore: CatalogStore
    @ObservationIgnored private let catalogProjection: CatalogProjection
    @ObservationIgnored let enrichmentCoordinator: EnrichmentCoordinator?
    @ObservationIgnored let deviceStagingRegistry: DeviceStagingRegistry
    @ObservationIgnored private let mediaTileDetailReader: MediaTileDetailReader
    @ObservationIgnored private let stallMonitor: MainRunLoopStallMonitor
    @ObservationIgnored private let startsStallMonitor: Bool
    @ObservationIgnored private let startsEnrichment: Bool
    @ObservationIgnored private let gridColumnCountDefaults: UserDefaults
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
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var queryGeneration = CatalogQueryRequest.initial.generation
    @ObservationIgnored var userHasChosenSource = false
    @ObservationIgnored var hasAppliedInitialDefault = false

    init(
        catalogStore: CatalogStore = CatalogStore(),
        catalogProjection: CatalogProjection = CatalogProjection(),
        enrichmentCoordinator: EnrichmentCoordinator? = nil,
        stallMonitor: MainRunLoopStallMonitor = MainRunLoopStallMonitor(),
        startsStallMonitor: Bool = true,
        startsEnrichment: Bool = true,
        gridColumnCountDefaults: UserDefaults = .standard
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
        self.gridColumnCountDefaults = gridColumnCountDefaults
        let storedColumns = gridColumnCountDefaults.integer(forKey: Self.gridColumnCountDefaultsKey)
        gridColumnCount = GridColumnCount.validated(storedColumns)
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
        if startsStallMonitor {
            stallMonitor.start()
        }

        // This is the sole query-intent task. AsyncStream provides ordered
        // delivery and bufferingNewest prevents obsolete clicks from building a
        // queue while Projection is busy publishing a large state.
        let projection = catalogProjection
        let store = catalogStore
        let initialRequest = CatalogQueryRequest(
            descriptor: queryDescriptor,
            generation: queryGeneration
        )

        startQueryForwarding(projection: projection)
        startMutationForwarding(store: store, coordinator: enrichmentCoordinator)
        startStateConsumption(
            projection: projection,
            store: store,
            initialRequest: initialRequest
        )
        startCatalog(store: store)
        startRemovableVolumeMonitoring()
        startDeviceStagingSweepThenCameraMonitoring()
        if startsEnrichment {
            startEnrichment()
        }
    }

    /// Not `private`: the sidebar/filter/sort intent wrappers live in
    /// query-intent methods and funnel through this one writer, which is the
    /// only place `queryDescriptor`/`sidebarSelection` (both `private(set)`) change on a
    /// user intent. Kept here beside those properties so their private setters stay valid.
    func setQueryDescriptor(_ descriptor: CatalogQueryDescriptor) {
        guard queryDescriptor != descriptor else { return }
        queryGeneration &+= 1
        queryDescriptor = descriptor
        sidebarSelection = descriptor.scope
        OtosLog.ui.info("Catalog query changed descriptor=\(descriptor.diagnosticDescription, privacy: .public)")
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
        coordinator: EnrichmentCoordinator?
    ) {
        // Mutations use one lossless consumer so Store sees the user's commands
        // in submission order. Cancellation is checked between commands: an
        // already-started SQLite transaction may finish, but the next queued
        // command must not begin after this owner is gone.
        mutationForwardingTask = Task { [weak self, mutationStream, store, coordinator] in
            for await intent in mutationStream {
                guard !Task.isCancelled else {
                    break
                }
                let ejectOutcome = await Self.performCatalogMutation(
                    intent,
                    store: store,
                    coordinator: coordinator
                )
                if let ejectOutcome {
                    await self?.handleEjectOutcome(ejectOutcome, for: intent)
                }
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

    private func startCatalog(store: CatalogStore) {
        catalogStartupTask = Task { [store] in
            do {
                try await store.start()
            } catch {
                OtosLog.persistence.error("Catalog start failed")
                OtosLog.catalog.error(
                    "op=catalog.start phase=error error=\(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    private func applyState(_ nextState: CatalogWindowState) {
        let previousState = state
        applySidebarSelectionPolicy(previous: previousState, next: nextState)

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
            applyAutomaticSidebarSelection(
                SidebarSelectionPolicy.selectionOnSelectedSourceRemoved(
                    libraries: nextState.libraries,
                    removableSources: nextState.removableSources
                )
            )
        } else {
            sidebarSelection = queryDescriptor.scope
        }

        state = nextState
        OtosSignpost.ui.endInterval("CatalogWindowStateApply", signpost)

        let itemCount = nextState.mediaGrid.orderedAssetIDs.count
        let previousItemCount = previousState.mediaGrid.orderedAssetIDs.count
        let mediaIdentityChanged = previousState.mediaGrid.descriptor != nextState.mediaGrid.descriptor
            || previousState.mediaGrid.orderedAssetIDs != nextState.mediaGrid.orderedAssetIDs
        let handoff = CatalogGridHandoff(
            updateID: updateID,
            itemCount: itemCount,
            previousItemCount: previousItemCount,
            itemDelta: itemCount - previousItemCount,
            selection: nextState.resolvedSidebarSelection.diagnosticDescription,
            emptyState: nextState.mediaEmptyState.diagnosticDescription,
            mediaIdentityChanged: mediaIdentityChanged,
            detailRefreshGeneration: nextState.mediaGrid.detailRefreshGeneration,
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

    func clearEjectingSourceIdentity(_ identity: String) {
        ejectingSourceIdentities.remove(identity)
    }

    func beginEjectingSource(_ identity: String) {
        ejectingSourceIdentities.insert(identity)
    }
}

// MARK: - Catalog query intents

//
// Sidebar-scope, media-filter, and sort intents. Each builds a new
// `CatalogQueryDescriptor` and funnels through the single `setQueryDescriptor(_:)`
// writer — the one place `queryDescriptor`/`sidebarSelection` change on a user intent.

extension CatalogWindowViewModel {
    func selectSidebar(_ selection: SidebarSelection) {
        userHasChosenSource = true
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
}

// MARK: - Sidebar selection policy

//
// Applies `SidebarSelectionPolicy` when projected sources change, plus eject-alert
// dismissal. Automatic selection still goes through `setQueryDescriptor`.

extension CatalogWindowViewModel {
    func applyAutomaticSidebarSelection(_ selection: SidebarSelection) {
        setQueryDescriptor(CatalogQueryDescriptor(
            scope: selection,
            filter: queryDescriptor.filter,
            sort: queryDescriptor.sort
        ))
    }

    func dismissEjectAlert() {
        ejectAlertMessage = nil
    }

    func applySidebarSelectionPolicy(previous: CatalogWindowState, next: CatalogWindowState) {
        // Compare against previously *available* identities so a remembered card that
        // flips unavailable → available (the common re-insert case) still counts as
        // newly attached and auto-selects.
        let previousAvailableIdentities = Set(
            previous.removableSources.filter(\.isAvailable).compactMap(\.deviceIdentity)
        )
        let newlyAttached = next.removableSources.filter { source in
            guard source.isAvailable, let identity = source.deviceIdentity else {
                return false
            }
            return !previousAvailableIdentities.contains(identity)
        }
        if let attached = newlyAttached.max(by: { left, right in
            (left.lastSeenAt ?? .distantPast) < (right.lastSeenAt ?? .distantPast)
        }), let selection = SidebarSelectionPolicy.selectionOnAttach(attached: attached) {
            applyAutomaticSidebarSelection(selection)
            return
        }

        // Do not latch the initial default on a pre-load empty world (zero roots of
        // both kinds). That state can publish before `store.start()` finishes; latching
        // there would skip the real startup default once libraries/cards appear.
        guard !userHasChosenSource, !hasAppliedInitialDefault,
              !(next.libraries.isEmpty && next.removableSources.isEmpty)
        else {
            return
        }
        hasAppliedInitialDefault = true
        applyAutomaticSidebarSelection(
            SidebarSelectionPolicy.defaultSelection(
                libraries: next.libraries,
                removableSources: next.removableSources
            )
        )
    }

    func handleEjectOutcome(_ outcome: RemovableEjectOutcome, for intent: CatalogMutationIntent) {
        guard case let .ejectRemovableSource(root) = intent,
              let identity = root.deviceIdentity
        else {
            return
        }
        clearEjectingSourceIdentity(identity)
        switch outcome {
        case .ejected, .cancelled:
            return
        case let .busy(displayName):
            ejectAlertMessage =
                "The disk \"\(displayName)\" couldn't be ejected because it's in use."
        case let .failed(description):
            ejectAlertMessage = description
        }
    }

    func currentSelectionWasRemoved(in nextState: CatalogWindowState) -> Bool {
        guard case let .library(path) = queryDescriptor.scope else {
            return false
        }
        return !nextState.libraries.contains { $0.path == path }
            && !nextState.removableSources.contains { $0.path == path }
    }
}

// MARK: - Grid zoom intent

/// User-adjustable grid density (spec 0048), 3–9. This is rendering/UI state, not catalog
/// truth, so it never touches the query-descriptor stream or Store/Projection: it is a
/// plain published property with a persistence side effect. Every zoom surface — the View
/// menu and toolbar slider directly, the AppKit pinch gesture through a callback — calls
/// `setGridColumnCount(_:)`, and `gridColumnCount` is `private(set)`, so there is exactly
/// one clamp/persist/publish path regardless of which surface originated the request.
extension CatalogWindowViewModel {
    /// Not `private`: `init` also reads this key to load the stored preference.
    static let gridColumnCountDefaultsKey = "mediaGridColumnCount"

    /// Clamps into 3–9, persists, and publishes; a no-op re-request does not re-persist.
    func setGridColumnCount(_ requested: Int) {
        let clamped = GridColumnCount.clamped(requested)
        guard clamped != gridColumnCount else {
            return
        }
        gridColumnCount = clamped
        gridColumnCountDefaults.set(clamped, forKey: Self.gridColumnCountDefaultsKey)
    }

    func zoomInGrid() {
        setGridColumnCount(gridColumnCount - 1)
    }

    func zoomOutGrid() {
        setGridColumnCount(gridColumnCount + 1)
    }
}
