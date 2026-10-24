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
        case moveLibrary(from: Int, to: Int)
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
    /// Last drawn signature per source, so the apply log records what changed on screen
    /// rather than a timer's sample of it (B4).
    var lastDrawnSignature: [LibraryRootPath: String] = [:]
    /// Batches this window has already moved the user into (or declined to, because the
    /// user was elsewhere when the batch row first existed). A run moves the selection
    /// once; a user who goes back to the card is not pulled to the batch again.
    var followedImportBatches: Set<ImportBatchID> = []
    var state: CatalogWindowState = .empty
    /// User-adjustable grid density (APP-006), 3–9. `private(set)` so the only way to
    /// change it is the `setGridColumnCount(_:)` intent below — the one clamp/persist/publish
    /// path every zoom surface shares (compiler-enforced single owner). Set in `init`, not a
    /// property default, because its initial value depends on the injected
    /// `preferences`.
    private(set) var gridColumnCount: Int
    /// Filmstrip square tile edge in points (48–192). Same persistence pattern as
    /// `gridColumnCount`; loupe/compare strips read this for frame height and layout.
    private(set) var stripTileEdge: CGFloat
    /// Camera-connection banner identities the user has dismissed. Same persistence
    /// pattern as `gridColumnCount`; injected into `MediaGridView` rather than read via
    /// `@AppStorage`, which would silently fall back to `UserDefaults.standard`
    /// regardless of the ViewModel's own injected `preferences` (ADR 0020).
    private(set) var dismissedCameraBannerIdentities: Set<String>
    /// Ephemeral mouse-selection truth (selection, ⇧-range anchor, base islands). Owned
    /// here so grid and filmstrip renderers share one model across mode switches; mutated
    /// only through the intents in `CatalogWindowViewModelSelection.swift`. Not
    /// `private(set)` because those intents live in a separate file and Swift's
    /// `private(set)` is file-scoped.
    var gridSelection = GridSelection.empty {
        didSet { refreshOpenWithMenu() }
    }

    /// Browser presentation (grid / loupe / compare). Default `.grid`; restored at launch
    /// from the browser place (APP-043).
    /// Mutated only through view-mode intents (separate file; Swift `private(set)` is
    /// file-scoped).
    var viewMode: BrowserViewMode = .grid {
        didSet { refreshOpenWithMenu() }
    }

    /// Loupe focus identity within the current display order. Compare does not retarget
    /// this; exit-to-grid keeps it so the grid can center on return.
    var focusedAssetID: MediaAssetID? {
        didSet { refreshOpenWithMenu() }
    }

    /// Media kind of `focusedAssetID`, read once per focus change through the same
    /// `tileDetailReader` the panes use. Views must not guess kind: guessing is what
    /// drew a play button on still photographs. `nil` means "not yet
    /// known" and renders no affordance — MED-002, unknown stays unknown.
    var focusedAssetKind: MediaKind?
    /// Symmetric compare pair (positional left/right slots). Empty outside compare mode.
    var comparePair = ComparePair.empty {
        didSet { refreshOpenWithMenu() }
    }

    /// Which compare pane was most recently replaced (click/slide/entry). Drives strip
    /// focus centering; defaults to `.right` on entry.
    var lastReplacedComparePane: PanePosition?
    /// The pane targeted by the next curation command in compare mode. This is separate
    /// from `lastReplacedComparePane`: a choice changes metadata, while pane focus is a
    /// navigation concern and must remain stable when the detail projection refreshes.
    var activeComparePane: PanePosition = .right {
        didSet { refreshOpenWithMenu() }
    }

    /// The current targets' original file URLs in display order — what Open, Open
    /// With and Share act on. Written only by `refreshOpenWithMenu()`
    /// (`CatalogWindowViewModelOpenWith.swift`), which the five target writers above
    /// trigger from `didSet`, so toolbar and menus render a stored value rather than
    /// re-resolving the selection on every body evaluation.
    var currentTargetFileURLs: [URL] = []
    /// The one curation choice every current target holds, for the toolbar control;
    /// nil when targets differ, exceed `currentTargetChoiceLimit`, or are none.
    /// Written only by `refreshCurrentTargetChoice()`.
    var currentTargetChoice: MediaChoice?
    @ObservationIgnored var currentTargetChoiceTask: Task<Void, Never>?
    /// What File ▸ Open / Open With render for the current targets. Written only by
    /// `refreshOpenWithMenu()`'s completed build.
    var openWithMenu: OpenWithMenuModel = .empty
    /// Owns the share picker while it is on screen.
    @ObservationIgnored let sharePickerPresenter = SharePickerPresenter()
    /// The toolbar Share button's AppKit host, the anchor every Share path presents
    /// from (APP-036). Weak: the toolbar owns it; nil while the button is off screen.
    @ObservationIgnored weak var shareAnchorView: NSView?
    /// Loupe zoom (APP-040): what the zoom view measured, and the one command it has
    /// been asked to apply. Written only in `CatalogWindowViewModelLoupeZoom.swift`.
    var loupeZoomReport: LoupeZoomReport?
    var loupeZoomCommand: LoupeZoomCommand?
    @ObservationIgnored var loupeZoomGeneration: UInt64 = 0
    /// Focused assets whose full-resolution decode has been requested this focus.
    @ObservationIgnored var fullResolutionRequestedIDs: Set<MediaAssetID> = []
    /// The focused asset whose "decode already sufficient" outcome has been logged, so
    /// the per-report re-evaluation records it once per focus.
    @ObservationIgnored var fullResolutionSkipLoggedID: MediaAssetID?
    /// Loupe info overlay (APP-041): session-only toggle and the facts it shows.
    var showsLoupeInfo = false
    var loupeInfo: LoupeInfoModel?
    @ObservationIgnored var loupeInfoTask: Task<Void, Never>?
    /// Undo stack for curation choices (APP-039). One window, one manager, owned here
    /// so Edit ▸ Undo renders `curationUndoState` rather than searching a responder
    /// chain that ends in an AppKit collection view.
    @ObservationIgnored let curationUndoManager = UndoManager()
    var curationUndoState = CurationUndoState()
    /// App icons for `openWithMenu.applications`, resolved once per model change.
    @ObservationIgnored var openWithApplicationIcons: [URL: NSImage] = [:]
    /// When enabled, a successful choice advances to the next surviving item in display
    /// order. The preference is read and written here so grid, loupe, compare, keyboard,
    /// and menu commands share one behavior owner.
    var advanceAfterMediaChoice: Bool
    /// Whether a Move to Trash that must download more than
    /// `LargeTrashDownloadPrompt.thresholdBytes` asks first (Plan 0104). One preference
    /// with two editors: the prompt's `Do not ask again` and Settings ▸ General.
    var asksBeforeLargeTrashDownload: Bool
    /// The large-download question awaiting an answer; nil when none.
    var largeTrashDownloadPrompt: LargeTrashDownloadPrompt?
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

    /// Decoded-image owner shared by grid, strip, and loupe/compare panes.
    /// Single owner per docs/architecture:83. The ViewModel, not the grid
    /// controller, owns it so loupe/compare panes hit the grid's decoded cache
    /// without re-decoding.
    @ObservationIgnored let tileContentStore = TileContentStore()

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
    /// production `UserDefaults.standard` domain by omitting it (ADR 0020).
    /// The ViewModel owns its `UserDefaults` instance for synchronous UI
    /// preferences; media-operation actors receive the same `PreferencesDomain`
    /// and each creates its own actor-owned instance.
    @ObservationIgnored let preferences: any PreferenceStore
    @ObservationIgnored let preferencesDomain: PreferencesDomain
    @ObservationIgnored private let queryStream: AsyncStream<CatalogQueryRequest>
    @ObservationIgnored private let queryContinuation: AsyncStream<CatalogQueryRequest>.Continuation
    @ObservationIgnored private let mutationStream: AsyncStream<CatalogMutationIntent>
    @ObservationIgnored let mutationContinuation: AsyncStream<CatalogMutationIntent>.Continuation
    @ObservationIgnored let mediaChoiceStream: AsyncStream<MediaChoiceCommand>
    @ObservationIgnored let mediaChoiceContinuation: AsyncStream<MediaChoiceCommand>.Continuation
    // Newest-value: only the latest viewport is a useful priority hint; an obsolete
    // scroll position carries no value, so an intermediate one is dropped.
    @ObservationIgnored private let viewportStream: AsyncStream<[MediaAssetID]>
    @ObservationIgnored private let viewportContinuation: AsyncStream<[MediaAssetID]>.Continuation
    @ObservationIgnored var removableVolumeMonitor: RemovableVolumeMonitor?
    @ObservationIgnored var cameraSourceMonitor: CameraSourceMonitor?
    @ObservationIgnored var deviceCatalogTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var mediaOperationCoordinator: MediaOperationCoordinator?
    @ObservationIgnored var importPresentationTask: Task<Void, Never>?
    /// Import intents travel in one lossless, ordered stream with one consumer, so "change
    /// the destination, then Import" reaches the coordinator in that order. Started with
    /// the coordinator (`startImportIntentConsumer`); an intent made before then waits.
    @ObservationIgnored let importIntentStream: AsyncStream<ImportIntent>
    @ObservationIgnored let importIntentContinuation: AsyncStream<ImportIntent>.Continuation
    @ObservationIgnored var importIntentTask: Task<Void, Never>?
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
    /// Sources with a Cancel in flight, for the import bar's transient
    /// "Stopping…" variant (`import-bar.md` state E, cancelling). The
    /// coordinator has no state for this — it is UI-only, set the moment
    /// `cancelImport` is called and cleared once that source's presentation
    /// leaves `.executing` (`applyImportPresentations`).
    var cancellingImportSources: Set<LibraryRootPath> = []
    var showsReorganizationConfirmation = false
    var reorganizationSummaryText: String?
    var reorganizationAlertMessage: String?
    var trashAlertMessage: String?
    var trashFailedIDs: [MediaAssetID] = []
    /// The trash queue as the bottom status bar reports it (DES-089); idle when nothing
    /// is waiting to move to the Trash.
    var trashQueueState = MediaTrashCoordinator.QueueState.idle
    /// Questions the trash queue needs answered, oldest first; the window presents the
    /// first (Plan 0104 D3/D4).
    var trashDecisions: [MediaTrashCoordinator.Decision] = []
    /// The failure alert's message line; set with `trashAlertMessage`.
    var trashAlertDetail = ""
    var identityRemapEpoch: UInt64 = 0
    var identityRemapBatch: CatalogIdentityRemapBatch?
    @ObservationIgnored var reorganizationRunner: LibraryReorganizationRunner?
    @ObservationIgnored let mediaTrashCoordinator: MediaTrashCoordinator
    @ObservationIgnored var mediaTrashEventTask: Task<Void, Never>?
    /// Undo, redo and the answers to trash prompts travel in one lossless ordered stream:
    /// "undo, then redo" must reach the queue as that pair, never as redo's Store mark
    /// overtaking undo's put-back. Started by `startMediaTrash`.
    @ObservationIgnored let mediaTrashIntentStream: AsyncStream<TrashIntent>
    @ObservationIgnored let mediaTrashIntentContinuation: AsyncStream<TrashIntent>.Continuation
    @ObservationIgnored var mediaTrashIntentTask: Task<Void, Never>?

    @ObservationIgnored private var stateConsumptionTask: Task<Void, Never>?
    @ObservationIgnored private var catalogStartupTask: Task<Void, Never>?
    @ObservationIgnored private var queryForwardingTask: Task<Void, Never>?
    @ObservationIgnored private var mutationForwardingTask: Task<Void, Never>?
    @ObservationIgnored var mediaChoiceForwardingTask: Task<Void, Never>?
    /// Choices sent to the forwarding consumer, and choices it has finished with —
    /// accepted, refused or failed. Equal means every choice's outcome has been applied.
    @ObservationIgnored var submittedMediaChoiceCount = 0
    @ObservationIgnored var handledMediaChoiceCount = 0
    @ObservationIgnored var mediaTrashTask: Task<Void, Never>?
    @ObservationIgnored private var viewportForwardingTask: Task<Void, Never>?
    @ObservationIgnored private var enrichmentStartTask: Task<Void, Never>?
    @ObservationIgnored var deviceStagingSweepTask: Task<Void, Never>?
    @ObservationIgnored var gridTelemetryTask: Task<Void, Never>?
    /// One owned pane-preview request (or downloading retry) per slot. Superseded
    /// requests cancel before enqueueing another full-size decode.
    @ObservationIgnored var paneRequestTasks: [PaneSlot: Task<Void, Never>] = [:]
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored var queryGeneration = CatalogQueryRequest.initial.generation
    @ObservationIgnored var userHasChosenSource = false
    @ObservationIgnored var hasAppliedInitialDefault = false
    /// The place Otos quit in (APP-043, ADR 0031), loaded at init and consumed once by
    /// `restoreBrowserPlaceIfReady()`. Any other query drops it: once the user (or the
    /// launch default) has gone somewhere else, an old place would be a surprise jump.
    @ObservationIgnored var pendingPlaceRestore: BrowserPlace?
    /// The grid's middle visible item from the newest viewport report — what quit saves
    /// as the grid's place, because the grid centers on it when it comes back.
    @ObservationIgnored var gridViewportCenterID: MediaAssetID?
    /// `NSApplication.willTerminateNotification` registration that saves the place.
    @ObservationIgnored var terminationObserver: (any NSObjectProtocol)?
    @ObservationIgnored let previewLoader: any PreviewLoading
    /// Distinguishes this view model's diagnostics from another's in a shared log.
    @ObservationIgnored let diagnosticID = String(UUID().uuidString.prefix(8))
    /// LaunchServices seam for Open / Open With; tests inject a recorder.
    @ObservationIgnored let workspace: any WorkspaceOpening
    /// The one in-flight Open With menu build; a newer target set cancels it.
    @ObservationIgnored var openWithMenuTask: Task<Void, Never>?
    /// The newest hand-off of targets to LaunchServices (see `open(_:with:origin:)`).
    @ObservationIgnored var openTask: Task<Void, Never>?
    @ObservationIgnored let videoLoader: VideoPreviewLoader
    var loupeVideoState: LoupeVideoState?
    /// The one in-flight loupe video preparation (materialize + build player). Named so
    /// a focus move can cancel the previous asset's preparation before starting another.
    @ObservationIgnored var loupeVideoPrepareTask: Task<Void, Never>?
    /// The newest read of the focused asset's kind. A focus move replaces it: the older
    /// read's answer belongs to an asset no longer focused.
    @ObservationIgnored var focusedKindTask: Task<Void, Never>?

    init(
        catalogStore: CatalogStore,
        catalogProjection: CatalogProjection = CatalogProjection(),
        enrichmentCoordinator: EnrichmentCoordinator? = nil,
        stallMonitor: MainRunLoopStallMonitor = MainRunLoopStallMonitor(),
        startsStallMonitor: Bool = true,
        startsEnrichment: Bool = true,
        startsSourceMonitoring: Bool = true,
        preferencesDomain: PreferencesDomain,
        previewLoader: (any PreviewLoading)? = nil,
        videoLoader: VideoPreviewLoader? = nil,
        workspace: any WorkspaceOpening = LaunchServicesWorkspace()
    ) {
        self.workspace = workspace
        // Curation undo entries are registered from store completions, outside any
        // AppKit event; groups are opened and closed explicitly (APP-039).
        curationUndoManager.groupsByEvent = false
        let (queryStream, queryContinuation) = AsyncStream<CatalogQueryRequest>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        // Selection may discard obsolete pending values, but every accepted
        // add/remove command must survive until the serial consumer handles it.
        let (mutationStream, mutationContinuation) = AsyncStream<CatalogMutationIntent>.makeStream(
            bufferingPolicy: .unbounded
        )
        let (importIntentStream, importIntentContinuation) = AsyncStream<ImportIntent>.makeStream(
            bufferingPolicy: .unbounded
        )
        let (mediaTrashIntentStream, mediaTrashIntentContinuation) = AsyncStream<TrashIntent>.makeStream(
            bufferingPolicy: .unbounded
        )
        let (mediaChoiceStream, mediaChoiceContinuation) = AsyncStream<MediaChoiceCommand>.makeStream(
            bufferingPolicy: .unbounded
        )
        let (viewportStream, viewportContinuation) = AsyncStream<[MediaAssetID]>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.preferencesDomain = preferencesDomain
        preferences = preferencesDomain.makeDefaults()
        let storedColumns = preferences.integer(forKey: Self.gridColumnCountDefaultsKey)
        gridColumnCount = GridColumnCount.validated(storedColumns)
        let storedStrip = preferences.object(forKey: Self.stripTileEdgeDefaultsKey) as? Double
        stripTileEdge = Self.clampedStripTileEdge(storedStrip.map { CGFloat($0) })
        advanceAfterMediaChoice = preferences.bool(forKey: Self.advanceAfterMediaChoiceDefaultsKey)
        asksBeforeLargeTrashDownload = preferences.object(forKey: Self.asksBeforeLargeTrashDownloadDefaultsKey)
            as? Bool ?? true
        let storedDismissedIdentities = preferences.string(forKey: Self.dismissedCameraBannersDefaultsKey)
        dismissedCameraBannerIdentities = Set(
            (storedDismissedIdentities ?? "").split(separator: "\n").map(String.init)
        )
        importPreferences = ImportPreferencesStore.load(defaults: preferences)
        self.catalogStore = catalogStore
        self.catalogProjection = catalogProjection
        mediaTileDetailReader = MediaTileDetailReader(store: catalogStore)
        let deviceStagingRegistry = DeviceStagingRegistry()
        self.deviceStagingRegistry = deviceStagingRegistry
        let materializationCoordinator = MaterializationCoordinator(
            store: catalogStore,
            // Dispatch on what the root *is*, not on what its path looks like. The
            // previous form asked the device registry to recognise a camera file by
            // string-prefixing the URL, and fell through to the *cloud* provider when
            // that missed — so a one-character prefix bug sent every camera file to
            // iCloud, which refused it as a permission error on a path that did not
            // exist. A device root is never servable by the cloud provider, and a
            // device root with no live session is a state, not a fallback (APP-018).
            executor: { [weak catalogStore] request in
                let kind = await catalogStore?.rootKind(for: request.id.libraryRootPath)
                guard kind == .deviceMTP else {
                    return await FileMaterialization.materialize(
                        request.id.fileURL,
                        persistence: .forPriority(request.priority)
                    )
                }
                guard let result = await deviceStagingRegistry.materialize(request.id.fileURL) else {
                    return MaterializationResult(outcome: .deviceUnavailable, rerequestCount: 0, elapsedMs: 0)
                }
                return result
            }
        )
        self.materializationCoordinator = materializationCoordinator
        mediaTrashCoordinator = MediaTrashCoordinator(
            store: catalogStore,
            materializationRequester: materializationCoordinator
        )
        self.enrichmentCoordinator = enrichmentCoordinator ?? (
            startsEnrichment
                ? EnrichmentCoordinator(
                    store: catalogStore,
                    enricher: .live(
                        thumbnailDirectory: catalogStore.thumbnailDirectory
                            ?? FileManager.default.temporaryDirectory
                    ),
                    materializationRequester: materializationCoordinator,
                    cameraRangeAccess: deviceStagingRegistry.makeCameraRangeAccess()
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
        self.importIntentStream = importIntentStream
        self.importIntentContinuation = importIntentContinuation
        self.mediaTrashIntentStream = mediaTrashIntentStream
        self.mediaTrashIntentContinuation = mediaTrashIntentContinuation
        self.mediaChoiceStream = mediaChoiceStream
        self.mediaChoiceContinuation = mediaChoiceContinuation
        self.viewportStream = viewportStream
        self.viewportContinuation = viewportContinuation
        // The restored query is the first one Projection sees (APP-043), so launch never
        // flashes the default collection before the user's own.
        if let place = Self.loadBrowserPlace(from: preferences) {
            pendingPlaceRestore = place
            queryDescriptor = place.descriptor
            sidebarSelection = place.descriptor.scope
        }
    }

    isolated deinit {
        // Cancel consumers before finishing their producers. Finishing normally
        // drains buffered AsyncStream values; cancellation prevents queued
        // mutations from starting after the ViewModel's ownership has ended.
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
        stateConsumptionTask?.cancel()
        catalogStartupTask?.cancel()
        queryForwardingTask?.cancel()
        mutationForwardingTask?.cancel()
        mediaChoiceForwardingTask?.cancel()
        mediaTrashTask?.cancel()
        mediaTrashEventTask?.cancel()
        mediaTrashIntentTask?.cancel()
        openWithMenuTask?.cancel()
        loupeInfoTask?.cancel()
        focusedKindTask?.cancel()
        currentTargetChoiceTask?.cancel()
        viewportForwardingTask?.cancel()
        enrichmentStartTask?.cancel()
        deviceStagingSweepTask?.cancel()
        importPresentationTask?.cancel()
        importIntentTask?.cancel()
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
        importIntentContinuation.finish()
        mediaTrashIntentContinuation.finish()
        mediaChoiceContinuation.finish()
        viewportContinuation.finish()
        if let mediaOps = mediaOperationCoordinator {
            Task { await mediaOps.shutdown() }
        }
        let mediaTrash = mediaTrashCoordinator
        Task { await mediaTrash.shutdown() }
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
        // Quit is the one moment the place is written: `willTerminate` runs for every
        // ordinary quit, and the write is a single small preference value.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.persistBrowserPlace()
            }
        }

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
        startMediaChoiceForwarding(store: store)
        startStateConsumption(
            projection: projection,
            store: store,
            initialRequest: initialRequest
        )
        startCatalog(store: store)
        startMediaTrash()
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
        guard queryDescriptor != descriptor else {
            OtosLog.ui.noticeOperation("ui.intent", phase: "unchanged", fields: [
                "vm": diagnosticID,
                "generation": "\(queryGeneration)",
                "scope": String(describing: descriptor.scope),
            ])
            return
        }
        if let pending = pendingPlaceRestore, pending.descriptor != descriptor {
            pendingPlaceRestore = nil
            OtosLog.ui.notice("op=browserPlace.restore phase=dropped reason=queryChanged")
        }
        let scopeChanged = descriptor.scope != queryDescriptor.scope
        queryGeneration &+= 1
        queryDescriptor = descriptor
        sidebarSelection = descriptor.scope
        let generation = queryGeneration
        let vm = diagnosticID
        OtosLog.ui.info(
            "Catalog query changed vm=\(vm, privacy: .public) generation=\(generation, privacy: .public) descriptor=\(descriptor.diagnosticDescription, privacy: .public)"
        )
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
        if viewMode == .grid, !orderedAssetIDs.isEmpty {
            gridViewportCenterID = orderedAssetIDs[orderedAssetIDs.count / 2]
        }
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
        enrichmentStartTask = Task { [coordinator, materializationCoordinator, store = catalogStore] in
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
        next.mediaEmptyState = .catalogIncompatible(problem)
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
            nextState.mediaEmptyState = .catalogIncompatible(catalogCompatibilityProblem)
        }
        let previousState = state
        applySidebarSelectionPolicy(previous: previousState, next: nextState)

        let updateID = stallMonitor.reserveUpdateID()
        let applyStart = ContinuousClock.now
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

        // A new scope is a different collection, so the user's place in the old one means
        // nothing there. A filter or sort change narrows or reorders the same collection,
        // so whatever survives stays selected and focused (APP-042).
        let descriptorChanged = previousState.mediaGrid.descriptor != nextState.mediaGrid.descriptor
        let scopeChanged = previousState.mediaGrid.descriptor.scope != nextState.mediaGrid.descriptor.scope
        let orderChanged = previousState.mediaGrid.orderedAssetIDs != nextState.mediaGrid.orderedAssetIDs
        if scopeChanged {
            clearGridSelection(reason: "scopeChange")
        } else if orderChanged {
            gridSelection = gridSelection.selection.isEmpty
                ? .empty
                : gridSelection.pruned(to: nextState.mediaGrid.orderedAssetIDs)
        }
        if descriptorChanged || orderChanged {
            reconcileFocusAfterGridChange(
                previousOrderedIDs: previousState.mediaGrid.orderedAssetIDs,
                scopeChanged: scopeChanged
            )
        }
        restoreBrowserPlaceIfReady()

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
            timestamp: .now
        )
        stallMonitor.recordGridHandoff(handoff)

        let applyMs = DiagnosticsTiming.milliseconds(since: applyStart)
        OtosLog.ui.noticeOperation("ui.state.apply", phase: "finish", fields: [
            "vm": diagnosticID,
            "updateID": "\(updateID)",
            "intentScope": String(describing: queryDescriptor.scope),
            "stateGeneration": "\(nextState.queryGeneration)",
            "intentGeneration": "\(queryGeneration)",
            "scope": String(describing: nextState.resolvedSidebarSelection),
            "items": "\(itemCount)",
            "delta": "\(itemCount - previousItemCount)",
            "libraries": "\(nextState.libraries.count)",
            "applyMs": "\(applyMs)",
        ])
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

    func setMediaChoice(_ choice: MediaChoice, included: Bool) {
        setMediaFilter(queryDescriptor.filter.settingChoice(choice, included: included))
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
        // Attaching a card or camera takes the user to it, wherever they were (APP-002,
        // ADR 0014). It needs a loaded previous state to diff against: the first loaded
        // state is the launch, which the one-time default below owns.
        if !(previous.libraries.isEmpty && previous.removableSources.isEmpty),
           let attached = SidebarSelectionPolicy.selectionOnAttach(
               previous: previous.removableSources,
               next: next.removableSources
           )
        {
            OtosLog.ui.noticeOperation("sidebar.autoSelect", phase: "attach", fields: [
                "selection": String(describing: attached),
            ])
            applyAutomaticSidebarSelection(attached)
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
        OtosLog.ui.noticeOperation("sidebar.autoSelect", phase: "initialDefault", fields: [
            "vm": diagnosticID,
            "libraries": "\(next.libraries.count)",
            "stateGeneration": "\(next.queryGeneration)",
        ])
        // A restored scope that still exists is where the user was; it replaces the
        // launch default (ADR 0031). One that is gone falls back to the default, keeping
        // the restored filter and sort, and the rest of the place is dropped with it.
        if pendingPlaceRestore != nil {
            // All Media is a row only with two or more fixed libraries, so a remembered
            // All Media in a smaller set is as gone as a removed library.
            let allMediaHidden = queryDescriptor.scope == .allMedia
                && !SidebarSelectionPolicy.showsAllMedia(libraries: next.libraries)
            guard currentSelectionWasRemoved(in: next) || allMediaHidden else {
                return
            }
            pendingPlaceRestore = nil
            OtosLog.ui.notice("op=browserPlace.restore phase=dropped reason=scopeGone")
        }
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

/// User-adjustable grid density (APP-006), 3–9. This is rendering/UI state, not catalog
/// truth, so it never touches the query-descriptor stream or Store/Projection: it is a
/// plain published property with a persistence side effect. Every zoom surface — the View
/// menu, toolbar buttons, and AppKit pinch gesture through a callback — calls
/// `setGridColumnCount(_:)`, and `gridColumnCount` is `private(set)`, so there is exactly
/// one clamp/persist/publish path regardless of which surface originated the request.
extension CatalogWindowViewModel {
    /// Not `private`: `init` also reads this key to load the stored preference.
    static let gridColumnCountDefaultsKey = "mediaGridColumnCount"
    static let stripTileEdgeDefaultsKey = "mediaStripTileEdge"
    static let advanceAfterMediaChoiceDefaultsKey = "advanceAfterMediaChoice"
    static let asksBeforeLargeTrashDownloadDefaultsKey = "trash.asksBeforeLargeDownload"
    static let dismissedCameraBannersDefaultsKey = "dismissedCameraConnectionBannerIdentities"

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

    /// A no-op re-dismiss does not re-persist, matching `setGridColumnCount`'s pattern.
    func dismissCameraConnectionBanner(_ identity: String) {
        guard !dismissedCameraBannerIdentities.contains(identity) else {
            return
        }
        dismissedCameraBannerIdentities.insert(identity)
        preferences.set(
            dismissedCameraBannerIdentities.sorted().joined(separator: "\n"),
            forKey: Self.dismissedCameraBannersDefaultsKey
        )
    }
}
