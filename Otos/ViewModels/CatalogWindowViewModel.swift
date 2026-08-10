import AppKit
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
    private(set) var isFilterPresented = false
    private(set) var ejectingSourceIdentities: Set<String> = []
    var ejectAlertMessage: String?
    var state: CatalogWindowState = .empty
    /// User-adjustable grid density (spec 0048), 3–9. `private(set)` so the only way to
    /// change it is the `setGridColumnCount(_:)` intent below — the one clamp/persist/publish
    /// path every zoom surface shares (compiler-enforced single owner). Set in `init`, not a
    /// property default, because its initial value depends on the injected
    /// `preferences`.
    private(set) var gridColumnCount: Int
    /// Filmstrip square tile edge in points (48–192). Same persistence pattern as
    /// `gridColumnCount`; loupe/compare strips read this for frame height and layout.
    private(set) var stripTileEdge: CGFloat
    /// Ephemeral mouse-selection truth (selection, ⇧-range anchor, base islands). Owned
    /// here so grid and filmstrip renderers share one model across mode switches; mutated
    /// only through the intents in `CatalogWindowViewModelSelection.swift`. Not
    /// `private(set)` because those intents live in a separate file and Swift's
    /// `private(set)` is file-scoped.
    var gridSelection = GridSelection.empty
    /// Session-only browser presentation (grid / loupe / compare). Default `.grid`.
    /// Mutated only through view-mode intents (separate file; Swift `private(set)` is
    /// file-scoped).
    var viewMode: BrowserViewMode = .grid
    /// Loupe focus identity within the current display order. Compare does not retarget
    /// this; exit-to-grid keeps it so Stage C can center the grid on return.
    var focusedAssetID: MediaAssetID?
    /// Symmetric compare pair (positional left/right slots). Empty outside compare mode.
    var comparePair = ComparePair.empty
    /// Which compare pane was most recently replaced (click/slide/entry). Drives strip
    /// focus centering; defaults to `.right` on entry.
    var lastReplacedComparePane: PanePosition?
    /// Full-size decodes keyed by pane slot and bound to the asset they belong to.
    /// Views render `image` only when `id` matches the pane's expected asset.
    var panePreviews: [PaneSlot: PanePreview] = [:]
    /// Slots currently awaiting deliberate materialization / retry.
    var downloadingSlots: Set<PaneSlot> = []
    /// Set when catalog open refuses a future/unrecognized schema. Projection
    /// publications must not clear the incompatible empty surface while this is set.
    @ObservationIgnored private(set) var catalogCompatibilityProblem: CatalogSchemaCompatibility?

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
    @ObservationIgnored let materializationCoordinator: MaterializationCoordinator?
    @ObservationIgnored let deviceStagingRegistry: DeviceStagingRegistry
    @ObservationIgnored private let mediaTileDetailReader: MediaTileDetailReader
    @ObservationIgnored private let stallMonitor: MainRunLoopStallMonitor
    @ObservationIgnored private let startsStallMonitor: Bool
    @ObservationIgnored private let startsEnrichment: Bool
    /// Removable-volume and camera monitoring observe hardware attached to the host
    /// machine, so a `true` default would make behavior depend on whatever card or
    /// camera happens to be plugged in. Production starts them; tests that assert on
    /// catalog content opt out so their result is a property of the fixture alone.
    @ObservationIgnored private let startsSourceMonitoring: Bool
    /// Backs grid/strip zoom persistence (`gridColumnCountDefaultsKey` /
    /// `stripTileEdgeDefaultsKey`) and, since it's the ViewModel's only injected
    /// `UserDefaults` seam, also import preferences (`importPreferences`,
    /// `ImportPreferencesStore`) — no default value, so a caller cannot reach the
    /// production `UserDefaults.standard` domain by omitting it (plan 0066 Stage 2).
    // UserDefaults is documented thread-safe; shared across ViewModel (MainActor) and
    // MediaOperationCoordinator/LibraryReorganizationRunner (actor) without isolation hop.
    @ObservationIgnored nonisolated(unsafe) let preferences: UserDefaults
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
    @ObservationIgnored var mediaOperationCoordinator: MediaOperationCoordinator?
    @ObservationIgnored var importPresentationTask: Task<Void, Never>?
    @ObservationIgnored var mediaOperationStartTask: Task<Void, Never>?

    /// Per-source import plan summaries for the footer (scalar only; no full plan map).
    var importPresentations: [MediaOperationSourcePresentation] = []
    /// Cached destination mappings for Settings display, including unavailable
    /// sources whose runtime mapping is retained (Stage 5). Updated from the
    /// coordinator's `allDestinations()` after presentation changes and after
    /// explicit destination intents.
    var removableDestinations: [LibraryRootPath: LibraryRootPath] = [:]
    /// Settings Import tab bindings; persisted through `ImportPreferencesStore`. Set in
    /// `init`, not a property default, because its initial value depends on the
    /// injected `preferences`.
    var importPreferences: ImportPreferences
    /// Per-source session ImportPreferences cache (Stage 7), seeded from
    /// ImportPreferences and discarded on detach. Authoritative store is the
    /// coordinator's `sessionPreferences`; this mirrors it for SwiftUI.
    var sessionPreferencesBySource: [LibraryRootPath: ImportPreferences] = [:]
    var showsReorganizationConfirmation = false
    var reorganizationSummaryText: String?
    var reorganizationAlertMessage: String?
    var identityRemapEpoch: UInt64 = 0
    var identityRemapBatch: CatalogIdentityRemapBatch?
    @ObservationIgnored var reorganizationRunner: LibraryReorganizationRunner?

    @ObservationIgnored private var stateConsumptionTask: Task<Void, Never>?
    @ObservationIgnored private var catalogStartupTask: Task<Void, Never>?
    @ObservationIgnored private var queryForwardingTask: Task<Void, Never>?
    @ObservationIgnored private var mutationForwardingTask: Task<Void, Never>?
    @ObservationIgnored private var viewportForwardingTask: Task<Void, Never>?
    @ObservationIgnored private var enrichmentStartTask: Task<Void, Never>?
    @ObservationIgnored var deviceStagingSweepTask: Task<Void, Never>?
    @ObservationIgnored var gridTelemetryTask: Task<Void, Never>?
    /// One owned pane-preview request (or downloading retry) per slot. Superseded
    /// requests cancel before enqueueing another full-size decode.
    @ObservationIgnored var paneRequestTasks: [PaneSlot: Task<Void, Never>] = [:]
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var queryGeneration = CatalogQueryRequest.initial.generation
    @ObservationIgnored var userHasChosenSource = false
    @ObservationIgnored var hasAppliedInitialDefault = false
    @ObservationIgnored let previewLoader: any PreviewLoading
    @ObservationIgnored let videoLoader: VideoPreviewLoader
    var loupeVideoState: LoupeVideoState?

    init(
        catalogStore: CatalogStore,
        catalogProjection: CatalogProjection = CatalogProjection(),
        enrichmentCoordinator: EnrichmentCoordinator? = nil,
        stallMonitor: MainRunLoopStallMonitor = MainRunLoopStallMonitor(),
        startsStallMonitor: Bool = true,
        startsEnrichment: Bool = true,
        startsSourceMonitoring: Bool = true,
        preferences: UserDefaults,
        previewLoader: (any PreviewLoading)? = nil,
        videoLoader: VideoPreviewLoader? = nil
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
        self.preferences = preferences
        let storedColumns = preferences.integer(forKey: Self.gridColumnCountDefaultsKey)
        gridColumnCount = GridColumnCount.validated(storedColumns)
        let storedStrip = preferences.object(forKey: Self.stripTileEdgeDefaultsKey) as? Double
        stripTileEdge = Self.clampedStripTileEdge(storedStrip.map { CGFloat($0) })
        importPreferences = ImportPreferencesStore.load(defaults: preferences)
        self.catalogStore = catalogStore
        self.catalogProjection = catalogProjection
        mediaTileDetailReader = MediaTileDetailReader(store: catalogStore)
        let deviceStagingRegistry = DeviceStagingRegistry()
        self.deviceStagingRegistry = deviceStagingRegistry
        let materializationCoordinator = MaterializationCoordinator(
            store: catalogStore,
            executor: { url in
                if let result = await deviceStagingRegistry.materialize(url) {
                    return result
                }
                return await FileMaterialization.materialize(url)
            }
        )
        self.materializationCoordinator = materializationCoordinator
        self.enrichmentCoordinator = enrichmentCoordinator ?? (
            startsEnrichment
                ? EnrichmentCoordinator(
                    store: catalogStore,
                    enricher: .live(
                        thumbnailDirectory: catalogStore.thumbnailDirectory
                            ?? FileManager.default.temporaryDirectory
                    ),
                    materializationRequester: materializationCoordinator
                )
                : nil
        )
        self.stallMonitor = stallMonitor
        self.startsStallMonitor = startsStallMonitor
        self.startsEnrichment = startsEnrichment
        self.startsSourceMonitoring = startsSourceMonitoring
        if let previewLoader {
            self.previewLoader = previewLoader
        } else {
            self.previewLoader = PreviewImageLoader(materializationRequester: materializationCoordinator)
        }
        if let videoLoader {
            self.videoLoader = videoLoader
        } else {
            self.videoLoader = VideoPreviewLoader(materializationRequester: materializationCoordinator)
        }
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
        importPresentationTask?.cancel()
        mediaOperationStartTask?.cancel()
        removableVolumeMonitor?.stop()
        cameraSourceMonitor?.stop()
        for task in deviceCatalogTasks.values {
            task.cancel()
        }
        deviceCatalogTasks.removeAll()
        gridTelemetryTask?.cancel()
        for task in paneRequestTasks.values {
            task.cancel()
        }
        paneRequestTasks.removeAll()
        queryContinuation.finish()
        mutationContinuation.finish()
        viewportContinuation.finish()
        if let mediaOps = mediaOperationCoordinator {
            Task { await mediaOps.shutdown() }
        }
        if let coordinator = enrichmentCoordinator {
            // The coordinator's supervisor strongly retains the coordinator, so it must be
            // told to stop or it (and the store) would outlive this window. shutdown() is
            // async and deinit cannot await, so hand it off; this owner is already gone.
            let materializationCoordinator = materializationCoordinator
            Task {
                await coordinator.shutdown()
                await materializationCoordinator?.shutdown()
            }
        } else {
            let materializationCoordinator = materializationCoordinator
            Task { await materializationCoordinator?.shutdown() }
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
        if startsSourceMonitoring {
            startRemovableVolumeMonitoring()
            startDeviceStagingSweepThenCameraMonitoring()
        }
        startMediaOperationsIfNeeded()
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
        let scopeChanged = descriptor.scope != queryDescriptor.scope
        queryGeneration &+= 1
        queryDescriptor = descriptor
        sidebarSelection = descriptor.scope
        OtosLog.ui.info("Catalog query changed descriptor=\(descriptor.diagnosticDescription, privacy: .public)")
        if scopeChanged {
            stallMonitor.beginIntentToPaint(scope: descriptor.scope)
        }
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
        enrichmentStartTask = Task {
            [coordinator, materializationCoordinator, store = catalogStore] in
            do {
                try await store.start()
            } catch {
                OtosLog.persistence.error("Enrichment startup skipped because catalog start failed")
                return
            }
            await materializationCoordinator?.start()
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
                    self?.handleEjectOutcome(ejectOutcome, for: intent)
                }
            }
        }
    }

    private func startStateConsumption(
        projection: CatalogProjection,
        store: CatalogStore,
        initialRequest: CatalogQueryRequest
    ) {
        stateConsumptionTask = Task(priority: .userInitiated) { [weak self, projection, store, initialRequest] in
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
        catalogStartupTask = Task { [weak self, store] in
            do {
                try await store.start()
            } catch let CatalogStoreError.unsupportedCatalogSchema(problem) {
                OtosLog.persistence.error(
                    "Catalog start refused problem=\(problem.errorDescription, privacy: .public)"
                )
                OtosLog.catalog.error(
                    "op=catalog.start phase=schemaRefused problem=\(String(describing: problem), privacy: .public)"
                )
                await MainActor.run {
                    self?.applyCatalogCompatibilityProblem(problem)
                }
            } catch {
                OtosLog.persistence.error("Catalog start failed")
                OtosLog.catalog.error(
                    "op=catalog.start phase=error error=\(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    /// Surfaces a typed catalog-schema refusal on the empty/error surface without
    /// loading roots or starting scans. Projection publications must not overwrite it.
    func applyCatalogCompatibilityProblem(_ problem: CatalogSchemaCompatibility) {
        catalogCompatibilityProblem = problem
        var next = state
        next.libraries = []
        next.removableSources = []
        next.mediaGrid = .empty
        next.mediaEmptyState = .catalogIncompatible(problem.errorDescription)
        applyState(next)
    }

    /// Projection → ViewModel state assignment. Selection prune/clear for grid
    /// identity changes runs here (before SwiftUI re-renders and before any
    /// AppKit structural apply) so the collection view only ever *renders* the
    /// already-updated model.
    func applyState(_ nextState: CatalogWindowState) {
        var nextState = nextState
        if let catalogCompatibilityProblem {
            nextState.libraries = []
            nextState.removableSources = []
            nextState.mediaGrid = .empty
            nextState.mediaEmptyState = .catalogIncompatible(catalogCompatibilityProblem.errorDescription)
        }
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

        let descriptorChanged = previousState.mediaGrid.descriptor != nextState.mediaGrid.descriptor
        let orderChanged = previousState.mediaGrid.orderedAssetIDs != nextState.mediaGrid.orderedAssetIDs
        if descriptorChanged {
            clearGridSelection(reason: "descriptorChange")
        } else if orderChanged {
            gridSelection = gridSelection.selection.isEmpty
                ? .empty
                : gridSelection.pruned(to: nextState.mediaGrid.orderedAssetIDs)
        }
        if descriptorChanged || orderChanged {
            reconcileFocusAfterGridChange(
                previousOrderedIDs: previousState.mediaGrid.orderedAssetIDs,
                descriptorChanged: descriptorChanged
            )
        }

        OtosSignpost.ui.endInterval("CatalogWindowStateApply", signpost)

        let itemCount = nextState.mediaGrid.orderedAssetIDs.count
        let previousItemCount = previousState.mediaGrid.orderedAssetIDs.count
        let mediaIdentityChanged = descriptorChanged || orderChanged
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

    func showFilter() {
        setFilterPresented(true)
    }

    func setFilterPresented(_ isPresented: Bool) {
        isFilterPresented = isPresented
    }

    func setMediaKind(_ kind: MediaKind, included: Bool) {
        setMediaFilter(queryDescriptor.filter.settingKind(
            kind,
            included: included,
            options: state.filterOptions
        ))
    }

    func setMediaFileType(_ fileType: MediaFileTypeOption, kind: MediaKind, included: Bool) {
        setMediaFilter(queryDescriptor.filter.settingFileType(
            fileType,
            kind: kind,
            included: included,
            options: state.filterOptions
        ))
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
        // Attach-time selection hijack is removed (0071 §13, decision 7+13):
        // attaching a card never moves the user. Launch-time selection of a
        // connected card is still handled via the initial default below.

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
        switch queryDescriptor.scope {
        case let .library(path):
            !nextState.libraries.contains { $0.path == path }
                && !nextState.removableSources.contains { $0.path == path }
        case let .importBatch(batchID):
            !nextState.importBatches.contains { $0.batchID == batchID }
        case .allMedia, .allImports:
            false
        }
    }
}

// MARK: - Grid zoom intent

/// User-adjustable grid density (spec 0048), 3–9. This is rendering/UI state, not catalog
/// truth, so it never touches the query-descriptor stream or Store/Projection: it is a
/// plain published property with a persistence side effect. Every zoom surface — the View
/// menu, toolbar buttons, and AppKit pinch gesture through a callback — calls
/// `setGridColumnCount(_:)`, and `gridColumnCount` is `private(set)`, so there is exactly
/// one clamp/persist/publish path regardless of which surface originated the request.
extension CatalogWindowViewModel {
    /// Not `private`: `init` also reads this key to load the stored preference.
    static let gridColumnCountDefaultsKey = "mediaGridColumnCount"
    static let stripTileEdgeDefaultsKey = "mediaStripTileEdge"

    /// Clamps into 3–9, persists, and publishes; a no-op re-request does not re-persist.
    func setGridColumnCount(_ requested: Int) {
        let clamped = GridColumnCount.clamped(requested)
        guard clamped != gridColumnCount else {
            return
        }
        gridColumnCount = clamped
        preferences.set(clamped, forKey: Self.gridColumnCountDefaultsKey)
    }

    func zoomInGrid() {
        setGridColumnCount(gridColumnCount - 1)
    }

    func zoomOutGrid() {
        setGridColumnCount(gridColumnCount + 1)
    }

    /// Clamps into 48…192, persists, and publishes; a no-op re-request does not re-persist.
    func setStripTileEdge(_ requested: CGFloat) {
        let clamped = Self.clampedStripTileEdge(requested)
        guard clamped != stripTileEdge else {
            return
        }
        stripTileEdge = clamped
        preferences.set(Double(clamped), forKey: Self.stripTileEdgeDefaultsKey)
    }

    static func clampedStripTileEdge(_ requested: CGFloat?) -> CGFloat {
        guard let requested, requested.isFinite else {
            return MediaGridPresentation.defaultStripTileEdge
        }
        return min(
            MediaGridPresentation.maxStripTileEdge,
            max(MediaGridPresentation.minStripTileEdge, requested)
        )
    }
}
