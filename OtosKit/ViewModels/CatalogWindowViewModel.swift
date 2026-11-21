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
/// Projection states are newest-wins: a relay off the main actor puts each publication
/// in a `NewestValueMailbox` as it arrives, and the main-actor consumer applies the
/// newest one there is when it runs, so a state a newer one replaced while the main
/// thread was busy is never applied. Query descriptor changes keep only the newest
/// pending value, and catalog mutations are lossless and serial. The
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
        case removeLibrary(LibraryRoot)
        case moveLibrary(LibraryRootPath, LibraryOrderMove)
        case ejectRemovableSource(LibraryRoot)
        case forgetRemovableSource(LibraryRoot)
        case attachRemovableVolume(RemovableVolumeAttachment)
        case quiesceRemovableSource(DeviceIdentity)
        case resumeRemovableSource(DeviceIdentity)
        case detachRemovableSource(DeviceIdentity, RemovableSourceDetachReason)
        case acknowledgeIdentityRemaps([Int64])
        case setDuplicatesReach(DuplicatesReach)
        case setRawPairing(RawPairing)
    }

    /// What a finished mutation tells the user, when it tells them anything.
    enum CatalogMutationReport: Equatable {
        case eject(RemovableEjectOutcome)
        /// The removal waits for the owner holding the library and runs when it releases it.
        case removalWaiting(LibraryRemovalNotice)
    }

    private(set) var sidebarSelection: SidebarSelection = .allMedia
    private(set) var queryDescriptor: CatalogQueryDescriptor = .default {
        didSet {
            if oldValue.scope != queryDescriptor.scope {
                rebuildShownPersonMenu()
            }
        }
    }

    /// The stacks the user expanded in the grid (ADR 0052), sent with every query request.
    private(set) var expandedStacks: Set<PhotoStackID> = []
    private(set) var isFilterPresented = false
    /// The toolbar search field's text, as typed (ADR 0048); `queryDescriptor.search` is the
    /// search it makes.
    private(set) var searchText = ""
    /// The languages the user searches in (`SearchLanguages`): stored, else the system's
    /// preferred languages.
    private(set) var searchLanguages: [String] = []
    /// What Settings offers: the languages search can recognise and translate.
    private(set) var searchLanguageChoices: [SearchLanguageChoice] = []
    /// Bumped by Edit ▸ Find; the window focuses its search field on each change.
    private(set) var searchFocusRequest: UInt64 = 0
    private(set) var ejectingSourceIdentities: Set<DeviceIdentity> = []
    var ejectAlertMessage: String?
    /// A removal that waits for the library to be free, shown once as an alert in Settings.
    var libraryRemovalNotice: LibraryRemovalNotice?
    /// Last drawn signature per source, so the apply log records what changed on screen
    /// rather than a timer's sample of it (B4).
    var lastDrawnSignature: [LibraryRootPath: String] = [:]
    /// Batches a run has started copying into, each with its card, until the sidebar first
    /// draws the batch's row or the user leaves the card's row: the run names its batch once
    /// the batch's first item is in the catalog, but the row exists only once Projection
    /// publishes it, which can be after the run has finished and stopped naming it.
    var importBatchesAwaitingTheirRow: [ImportBatchID: LibraryRootPath] = [:]
    /// Batches this window has already moved the user into (or declined to, because the
    /// user was elsewhere when the batch row first existed or left the card's row before). A run moves the selection
    /// once; a user who goes back to the card is not pulled to the batch again.
    var followedImportBatches: Set<ImportBatchID> = []
    /// The last applied publication, observed part by part (`CatalogWindowParts`): a view
    /// reads the parts it shows from `parts` and depends on those alone. `state` is the
    /// whole value, for the view model's own work and for tests; a reader of it depends on
    /// every part. Projection yields only a state that changed (ADR 0005), and applying one
    /// notifies only the parts it changed.
    var state: CatalogWindowState {
        get { parts.state }
        set { parts.apply(newValue) }
    }

    @ObservationIgnored let parts = CatalogWindowParts()
    /// How many publications `applyState` has applied: one per state the window took in.
    @ObservationIgnored private(set) var appliedStateCount = 0
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
    private(set) var dismissedCameraBannerIdentities: Set<DeviceIdentity>
    /// The Info pane's and the Edit pane's sections the person folded, remembered across
    /// launches. Same persistence pattern as `gridColumnCount`: the panes are handed these
    /// and fold through `toggleInfoSectionFold` and `toggleEditSectionFold`, never through
    /// `@AppStorage`, which writes `UserDefaults.standard` whatever domain the window was
    /// given (ADR 0020).
    private(set) var foldedInfoSections: Set<PhotoInfo.SectionID>
    private(set) var foldedEditSections: Set<EditSection>
    /// Ephemeral mouse-selection truth (selection, ⇧-range anchor, base islands). Owned
    /// here so grid and filmstrip renderers share one model across mode switches; mutated
    /// only through the intents in `CatalogWindowViewModelSelection.swift`. Not
    /// `private(set)` because those intents live in a separate file and Swift's
    /// `private(set)` is file-scoped.
    var gridSelection = GridSelection.empty {
        didSet {
            refreshOrderedSelection()
            refreshOpenWithMenu()
        }
    }

    /// Selected identities in current display order, kept by `refreshOrderedSelection` as
    /// the selection or the grid's order changes. Stored rather than derived on each read, so
    /// what reads the targets — the toolbar, the Info pane, the menus — depends on the
    /// selection's order and not on the whole grid: a hide elsewhere re-renders none of them.
    /// Written only by `refreshOrderedSelection` (in the selection file, so not `private(set)`).
    var orderedSelectedAssetIDs: [MediaAssetID] = []

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

    /// The map the user last looked at in Places: the newest viewport report. Kept
    /// across a visit to a place under it so Back returns to the same map. Written only
    /// by `mapViewportChanged`.
    var mapViewport: MapViewport?
    /// The stacks drawn on the Places map for `mapViewport`, from the cluster lane.
    var mapClusters: [MapPlaceCluster] = []
    /// The camera the Places map should adopt next: fit on entry and on a filter
    /// change, the last viewport on return from a place, a zoom step on ⌘= / ⌘−.
    var mapCameraRequest: MapCameraRequest?
    /// The user's marks and the on-screen groups while working through Duplicates
    /// (ADR 0042). Window state, not catalog state: marks are a decision in progress.
    var duplicatesSession = DuplicatesSession()
    /// What the user is doing in People (ADR 0047): the people selected in the gallery, the
    /// open sheet or question, and whether the browser was opened on a person from the
    /// gallery. Window state, not catalog state.
    var peopleSession = PeopleSession()
    /// The toolbar menu of the person whose photos the browser shows; nil elsewhere. Written
    /// only by `rebuildShownPersonMenu`, on a new People state or scope.
    var shownPersonMenu: PersonMenu?
    /// The people each face of the targets could be, as `PeopleAssignment` last ranked them
    /// for those photos (`refreshTargetFaces`).
    var faceCandidates = FaceCandidates.none {
        didSet { rebuildTargetFaceMenu() }
    }

    /// The targets' faces as the photo menus and the Info pane offer them, built once per
    /// change of the targets, People or the ranking (`refreshTargetFaces`); nil while the
    /// targets hold no face People shows.
    var targetFaceMenu: FaceMenu?
    /// Whether the Info pane's photo was read for faces and how many it holds, as the catalog
    /// last said (`startFacesReadRefresh`).
    var photoFacesRead: PhotoFacesRead?
    /// The targets' faces as the catalog last gave them, read by key for exactly the targets
    /// (`startFacesReadRefresh`); `.none` before the first read and for no targets.
    @ObservationIgnored var targetPhotoFaces = PhotoFaces.none
    /// The Person sheet's row of the person it names, read by key as it opens
    /// (`CatalogStore.newestFaces(of:limit:)`); nil before it lands.
    var personSheetFaces: (person: PersonID, faces: [FaceTile])?
    /// The targets and pane `targetFaceMenu` was last built for: a change lets go of an Info
    /// row's outline.
    @ObservationIgnored var targetFacesKey: TargetFacesKey?
    @ObservationIgnored var facesReadTask: Task<Void, Never>?
    /// Rings `facesReadTask`: every new target and People state.
    @ObservationIgnored var facesReadDoorbell: AsyncStream<Void>.Continuation?
    /// The faces outlined on their photos: the face the pointer is over in the Info pane, or
    /// the faces of the face-menu item highlighted in a photo's context menu.
    var outlinedFaces: [FaceID] = []
    /// The People acts submitted that the store has not answered (`PendingPeopleActs`).
    @ObservationIgnored var pendingPeopleActs = PendingPeopleActs()
    /// People as every surface shows it: the published state with `pendingPeopleActs` laid
    /// over it (`showPendingPeopleActs`); nil until People is first published.
    var shownPeople: CatalogPeopleState?
    /// Face crops decoded this process, shared by every face tile (DES-110).
    @ObservationIgnored let faceTileImages = FaceTileImages()

    /// Media kind of `focusedAssetID`, read once per focus change through the same
    /// `tileDetailReader` the panes use. Views must not guess kind: guessing is what
    /// drew a play button on still photographs. `nil` means "not yet
    /// known" and renders no affordance — MED-002, unknown stays unknown.
    var focusedAssetKind: MediaKind?
    /// The motion movie of the focused Live Photo (ADR 0041), read with its kind; nil for
    /// anything else and until known. The loupe offers to play it.
    var focusedLivePhotoMotion: MediaAssetID?
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
    /// nil when targets differ, exceed `currentTargetChoiceLimit`, are none, or their
    /// choices could not be read. Written only by `refreshCurrentTargetChoice()`.
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
    /// The trailing inspector's pane, nil while it is hidden (Info, APP-041; Edit, ADR 0036).
    /// The edit session resolves its photo only while the Edit pane is shown.
    var inspectorPane: InspectorPane?
    /// The window's edit feature (ADR 0036): the panel, the crop tool, the edit commands and
    /// their lanes. The window holds it for its life and is its only strong owner; the session
    /// reads the window and calls its intents through the narrow context made here
    /// (`makeEditSessionWindow`). Lazy because that context refers to this window, which can
    /// be referred to only once `init` has initialized it; made on its first read, which a
    /// window that starts makes in `start()`.
    @ObservationIgnored private(set) lazy var editSession = EditSession(
        window: makeEditSessionWindow(),
        tileDetailReader: mediaTileDetailReader,
        materialization: materializationCoordinator,
        undoManager: windowUndoManager
    )
    /// The hand-off being prepared, for the status bar; nil when none is.
    var handOffProgress: HandOffProgress?
    var handOffAlertMessage: String?
    @ObservationIgnored let handOffPreparer: HandOffPreparer
    @ObservationIgnored let handOffStream: AsyncStream<HandOffRequest>
    @ObservationIgnored let handOffContinuation: AsyncStream<HandOffRequest>.Continuation
    @ObservationIgnored var handOffTask: Task<Void, Never>?
    @ObservationIgnored var handOffRequested: UInt64 = 0
    @ObservationIgnored var handOffCancelledThrough: UInt64 = 0
    @ObservationIgnored var submittedHandOffCount = 0
    @ObservationIgnored var handledHandOffCount = 0
    /// File ▸ Export…'s remembered choices; set in `init` from the injected `preferences`.
    var exportSettings: ExportSettings
    /// The export sheet, while it is shown.
    var exportSheet: ExportSheet?
    /// The export being written, for the status bar; nil when none is.
    var exportProgress: ExportProgress?
    /// An export that did not do everything asked, for its alert.
    var exportReport: ExportReport?
    @ObservationIgnored let exportStream: AsyncStream<ExportRequest>
    @ObservationIgnored let exportContinuation: AsyncStream<ExportRequest>.Continuation
    @ObservationIgnored var exportTask: Task<Void, Never>?
    /// Reads the languages Settings offers for search, once per session.
    @ObservationIgnored var searchLanguageChoicesTask: Task<Void, Never>?
    /// Immich accounts (ADR 0046): the one owner of their sessions and syncs. Nil for a
    /// window that starts no background work.
    @ObservationIgnored let immichAccounts: ImmichAccounts?
    @ObservationIgnored let immichIntentStream: AsyncStream<ImmichAccountIntent>
    @ObservationIgnored let immichIntentContinuation: AsyncStream<ImmichAccountIntent>.Continuation
    @ObservationIgnored var immichIntentTask: Task<Void, Never>?
    @ObservationIgnored var immichStatusTask: Task<Void, Never>?
    /// What each account's server last answered, for the sidebar and Settings.
    var immichAccountStatuses: [LibraryRootPath: ImmichAccountStatus] = [:]
    /// The one owner of what background work runs and since when (ADR 0058); the window
    /// watches its owners once they are built (`startBackgroundOwners`).
    @ObservationIgnored let activityBoard = ActivityBoard()
    @ObservationIgnored var activityTask: Task<Void, Never>?
    /// What the sidebar's Activity line and its popover show (DES-124), as the board last
    /// published it.
    var activity = ActivitySnapshot()
    /// The Add Immich Account sheet while it is open.
    var immichAccountSheet: ImmichAccountSheetState?
    @ObservationIgnored var immichAddRequested: UInt64 = 0
    @ObservationIgnored var exportRequested: UInt64 = 0
    @ObservationIgnored var exportCancelledThrough: UInt64 = 0
    @ObservationIgnored var submittedExportCount = 0
    @ObservationIgnored var handledExportCount = 0
    var photoInfo: PhotoInfo?
    @ObservationIgnored var photoInfoTask: Task<Void, Never>?
    @ObservationIgnored var faceCandidatesTask: Task<Void, Never>?
    /// Reads the Person sheet's row of faces as the sheet opens; a sheet for another person
    /// cancels it.
    @ObservationIgnored var personSheetFacesTask: Task<Void, Never>?
    /// The Info pane's place-name lookup for its located item; a new target cancels it.
    @ObservationIgnored var placeNameTask: Task<Void, Never>?
    @ObservationIgnored var placeNameLookup: PlaceNameLookup = .mapKit
    /// Names the Info pane's scene labels in the Mac's language (`SceneLabelNames`).
    @ObservationIgnored let sceneLabelNames = SceneLabelNames(bundle: Bundle(for: CatalogWindowViewModel.self))
    /// Re-reads In This Photo and Description as they are read (`startReadingsRefresh`).
    @ObservationIgnored var readingsRefreshTask: Task<Void, Never>?
    /// Rings `readingsRefreshTask`: search's index and the description writer ring it as they
    /// read, and every Info read rings it as it lands.
    @ObservationIgnored var readingsDoorbell: AsyncStream<Void>.Continuation?
    /// Whether descriptions can be written on this Mac, for the Info pane's owed state.
    @ObservationIgnored var descriptionAvailability: @Sendable () -> PhotoDescriptionAvailability = {
        PhotoDescriber.liveAvailability
    }

    /// The window's undo stack: likes (APP-039), Move to Trash (ADR 0022) and edits (ADR
    /// 0036). One window, one manager, owned here so Edit ▸ Undo renders `undoMenuState`
    /// rather than searching a responder chain that ends in an AppKit collection view.
    @ObservationIgnored let windowUndoManager = UndoManager()
    var undoMenuState = UndoMenuState()
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
    /// Whether Duplicates also lists copies in two different libraries or accounts, such as
    /// a library and the Immich server that mirrors it (ADR 0042). Off by default: a mirror
    /// the user keeps on purpose is not waste. Settings ▸ General is its one editor.
    var findsDuplicatesAcrossLibraries: Bool
    /// Whether a RAW and its processed file (JPEG, HEIF) show as one photo (ADR 0052). On by
    /// default, as Apple Photos and Lightroom Classic pair them; Settings ▸ General is its one
    /// editor.
    var showsRawPairsAsOne: Bool
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
    /// without re-decoding. Injected so a test can give it a small budget.
    @ObservationIgnored let tileContentStore: TileContentStore
    /// The choices submitted that the catalog has not been read back with (DES-120): every
    /// tile-detail read answers through it.
    @ObservationIgnored let mediaChoiceOverlay: MediaChoiceOverlay
    /// The tiles a choice just changed, which the grid reconfigures in place.
    var tileChoiceChange = TileChoiceChange()
    /// A choice the catalog could not record, while its alert shows.
    var mediaChoiceFailure: MediaChoiceFailure?

    var tileDetailReader: MediaTileDetailReader {
        mediaTileDetailReader
    }

    var uiStallMonitor: MainRunLoopStallMonitor {
        stallMonitor
    }

    @ObservationIgnored let catalogStore: CatalogStore
    @ObservationIgnored let catalogProjection: CatalogProjection
    @ObservationIgnored let enrichmentCoordinator: EnrichmentCoordinator?
    /// Re-reads metadata an older MediaMetadata revision produced, from local bytes only
    /// (ADR 0039); runs once per launch with enrichment.
    @ObservationIgnored let metadataRefresher: MetadataRefresher?
    /// Signs stored thumbnails for same-photo duplicates (ADR 0042); starts with enrichment.
    @ObservationIgnored let renderSignatureRefresher: RenderSignatureRefresher?
    /// Reads Immich stills' faces from their stored previews (ADR 0047); starts with
    /// enrichment.
    @ObservationIgnored let previewFaceReader: PreviewFaceReader?
    /// Names the map's cells for the Places filter (ADR 0040); starts with enrichment.
    @ObservationIgnored let placeNameReader: PlaceNameReader?
    /// Keyword search's index (ADR 0048), paired with the live enrichment pipeline like the
    /// render signature refresher: it reads the thumbnails enrichment writes.
    @ObservationIgnored let photoSearchIndex: PhotoSearchIndex?
    /// Writes stills' descriptions with Apple's on-device model (ADR 0053), from the stored
    /// previews and readings enrichment and search write; starts with enrichment.
    @ObservationIgnored let photoDescriptionWriter: PhotoDescriptionWriter?
    /// Writes On This Day's titles from its photos' descriptions (ADR 0053).
    @ObservationIgnored let anniversaryTitleWriter: AnniversaryTitleWriter?
    /// The launch's one derived-folder load, started with the background owners.
    @ObservationIgnored let derivedFolderLoad: DerivedFolderLoad?
    @ObservationIgnored let materializationCoordinator: MaterializationCoordinator
    /// Reads a volume's free space for every free-space floor this window's owners keep
    /// (ADR 0027): the system's reading in the app, a test's own so no outcome depends on
    /// how full the machine running it is.
    @ObservationIgnored let volumeCapacity: VolumeCapacityReader
    @ObservationIgnored let deviceStagingRegistry: DeviceStagingRegistry
    @ObservationIgnored private let mediaTileDetailReader: MediaTileDetailReader
    @ObservationIgnored private let stallMonitor: MainRunLoopStallMonitor
    @ObservationIgnored private let startsStallMonitor: Bool
    @ObservationIgnored private let startsEnrichment: Bool
    /// Which background owners `start` starts: every one, except in a tour that leaves some
    /// out (`BackgroundOwners.configured`).
    @ObservationIgnored let backgroundOwners: BackgroundOwners
    /// Runs the owners' heavy loads one at a time (ADR 0055). Closed until this
    /// window's first grid (`op=launch.firstGrid`), told what each query's view needs, and
    /// shut at teardown, all synchronously from here.
    @ObservationIgnored let loadAdmission: LoadAdmission
    /// Whether heavy background work may start now (ADR 0057): the machine's conditions,
    /// delivered by the app's `MachineConditionsMonitor`, asked by every owner of heavy work.
    @ObservationIgnored let backgroundRoom: BackgroundRoom
    /// The newest scope paint (`op=ui.sidebarSelectionToPaint phase=finish`), the fact a
    /// tour's sidebar step waits on.
    private(set) var lastSidebarPaint: SidebarPaintReport?
    /// The newest moment every visible tile showed what the catalog holds for it, the fact a
    /// scroll waits on.
    private(set) var lastVisibleThumbnails: VisibleThumbnailsReport?
    /// The newest act whose result reached the grid (`op=ui.actToResult phase=finish`), the
    /// fact a sandboxed tour's act step waits on.
    private(set) var lastActResult: ActResultReport?
    /// The newest measured continuous scroll's frames (`op=ui.scrollHitches phase=finish`),
    /// the fact a tour's continuous-scroll step waits on.
    private(set) var lastScrollHitches: ScrollHitchReport?
    /// How far this launch's background work has settled, once it has reached the first stage
    /// (`LaunchSettlement`, `op=owners.settled`). What a tour's Duplicates step waits on
    /// (`duplicatesBuilt`), and a tour that starts like a person's session
    /// (`SmokeTour.Configuration.start`, `launchWork`).
    private(set) var launchSettlement: LaunchSettlement?
    /// Whether the window shows the groups the launch owed: the launch has reached
    /// `duplicatesBuilt` and the window has applied groups. Every build answers a request no
    /// older than the launch's, the first the duplicates owner takes, so any groups the window
    /// shows then are that build's or a newer one's. Set once (`settleLaunch`,
    /// `applyDuplicatesState`), so a later build changes nothing.
    var showsLaunchDuplicates = false
    /// Removable-volume and camera monitoring observe hardware attached to the host
    /// machine, so a `true` default would make behavior depend on whatever card or
    /// camera happens to be plugged in. Production starts them; tests that assert on
    /// catalog content opt out so their result is a property of the fixture alone.
    @ObservationIgnored private let startsSourceMonitoring: Bool
    /// Backs grid/strip zoom persistence (`gridColumnCountDefaultsKey` /
    /// `stripTileEdgeDefaultsKey`) and, since it's the ViewModel's only injected
    /// `PreferenceStore` seam, also import preferences (`importPreferences`,
    /// `ImportPreferencesStore`) — no default value, so a caller cannot reach the
    /// production `UserDefaults.standard` domain by omitting it (ADR 0020).
    /// The ViewModel owns its `PreferenceStore` instance for synchronous UI
    /// preferences; media-operation actors receive the same `PreferencesDomain`
    /// and each creates its own actor-owned instance.
    @ObservationIgnored let preferences: any PreferenceStore
    @ObservationIgnored let preferencesDomain: PreferencesDomain
    /// Queries and Move to Trash's hides, in the order the user acted, to Projection's one
    /// consumer (`CatalogProjectionIntent`).
    @ObservationIgnored private let projectionIntentStream: AsyncStream<CatalogProjectionIntent>
    @ObservationIgnored let projectionIntentContinuation: AsyncStream<CatalogProjectionIntent>.Continuation
    @ObservationIgnored private let mutationStream: AsyncStream<CatalogMutationIntent>
    @ObservationIgnored let mutationContinuation: AsyncStream<CatalogMutationIntent>.Continuation
    @ObservationIgnored let mediaChoiceStream: AsyncStream<MediaChoiceCommand>
    @ObservationIgnored let mediaChoiceContinuation: AsyncStream<MediaChoiceCommand>.Continuation
    /// Make Key Photo and its undo, in order, one consumer (ADR 0052).
    @ObservationIgnored let stackKeyStream: AsyncStream<StackKeyCommand>
    @ObservationIgnored let stackKeyContinuation: AsyncStream<StackKeyCommand>.Continuation
    // Newest-value: only the latest viewport is a useful priority hint; an obsolete
    // scroll position carries no value, so an intermediate one is dropped.
    @ObservationIgnored private let viewportStream: AsyncStream<[MediaAssetID]>
    @ObservationIgnored private let viewportContinuation: AsyncStream<[MediaAssetID]>.Continuation
    @ObservationIgnored var removableVolumeMonitor: RemovableVolumeMonitor?
    @ObservationIgnored var cameraSourceMonitor: CameraSourceMonitor?
    @ObservationIgnored var deviceCatalogTasks: [DeviceIdentity: Task<Void, Never>] = [:]
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
    /// Destination mappings for Settings display, including unavailable sources whose
    /// runtime mapping is retained. Assigned only by `removableDestinationsTask`, the one
    /// consumer of the coordinator's ordered `destinationsStream()`.
    var removableDestinations: [LibraryRootPath: LibraryRootPath] = [:]
    @ObservationIgnored var removableDestinationsTask: Task<Void, Never>?
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
    /// Sources whose Import the user clicked and whose coordinator presentation has not drawn
    /// the click yet (DES-120): drawn as a held click from the click on.
    var heldImportClicks: Set<LibraryRootPath> = []
    /// Import clicks per source, numbered as submitted and as the coordinator took them.
    @ObservationIgnored var submittedImportClicks: [LibraryRootPath: UInt64] = [:]
    @ObservationIgnored var deliveredImportClicks: [LibraryRootPath: UInt64] = [:]
    /// The plan the confirmation dialog shows, or nil when it is not shown. Confirming
    /// runs exactly this library at exactly this revision.
    var reorganizationConfirmation: ReorganizationConfirmation?
    /// The outcome alert of a reorganization that could not start or stopped, or nil.
    var reorganizationAlert: ReorganizationAlert?
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
    /// Remap batches already carried into selection, focus and tiles. A batch stays in
    /// published states until the Store has deleted it, so this keeps it applied once.
    @ObservationIgnored var appliedIdentityRemapBatchIDs: Set<Int64> = []
    @ObservationIgnored var reorganizationRunnerInstance: LibraryReorganizationRunner?
    /// The reorganization preview or run in flight; at most one.
    @ObservationIgnored var reorganizationTask: Task<Void, Never>?
    @ObservationIgnored let mediaTrashCoordinator: MediaTrashCoordinator
    @ObservationIgnored var mediaTrashEventTask: Task<Void, Never>?
    /// Undo, redo and the answers to trash prompts travel in one lossless ordered stream:
    /// "undo, then redo" must reach the queue as that pair, never as redo's Store mark
    /// overtaking undo's put-back. Started by `startMediaTrash`.
    @ObservationIgnored let mediaTrashIntentStream: AsyncStream<TrashIntent>
    @ObservationIgnored let mediaTrashIntentContinuation: AsyncStream<TrashIntent>.Continuation
    @ObservationIgnored var mediaTrashIntentTask: Task<Void, Never>?
    /// Keep All Copies and its undo, in the order the user acted (ADR 0032 rule 5).
    @ObservationIgnored let duplicatesIntentStream: AsyncStream<DuplicatesIntent>
    @ObservationIgnored let duplicatesIntentContinuation: AsyncStream<DuplicatesIntent>.Continuation
    @ObservationIgnored var duplicatesIntentTask: Task<Void, Never>?
    /// People acts and their undo, in the order the user acted (ADR 0032 rule 5).
    @ObservationIgnored let peopleIntentStream: AsyncStream<PeopleIntent>
    @ObservationIgnored let peopleIntentContinuation: AsyncStream<PeopleIntent>.Continuation
    @ObservationIgnored var peopleIntentTask: Task<Void, Never>?

    /// Applies Projection's newest publication on the main actor (`startStateConsumption`).
    @ObservationIgnored private var stateConsumptionTask: Task<Void, Never>?
    /// Carries Projection's publications into the consumer's mailbox, off the main actor.
    @ObservationIgnored private var stateRelayTask: Task<Void, Never>?
    @ObservationIgnored private var catalogStartupTask: Task<Void, Never>?
    /// The one consumer of the Store's open reports (`CatalogStore.openings`).
    @ObservationIgnored private var catalogOpeningTask: Task<Void, Never>?
    /// What the catalog's open last reported (DES-121); read only before its load applies.
    private(set) var catalogOpening = CatalogOpening()
    /// The catalog's load failed: the window will never load this session.
    private(set) var catalogLoadFailed = false
    /// A frame was presented while the catalog had not loaded (`waitingFramePresented()`):
    /// from then on the window says what the open is doing. Never cleared, so a click while
    /// the catalog opens keeps the sidebar's rows; an open within the first frame shows none.
    private(set) var catalogOpeningFramePresented = false
    @ObservationIgnored private var queryForwardingTask: Task<Void, Never>?
    @ObservationIgnored private var mutationForwardingTask: Task<Void, Never>?
    @ObservationIgnored var mediaChoiceForwardingTask: Task<Void, Never>?
    @ObservationIgnored var stackKeyForwardingTask: Task<Void, Never>?
    /// Choices sent to the forwarding consumer, and choices it has finished with —
    /// accepted, refused or failed. Equal means every choice's outcome has been applied.
    /// Observed, so a wait on `hasSettledMediaChoices` (the tour's next act) hears each
    /// outcome; no view reads them.
    var submittedMediaChoiceCount = 0
    var handledMediaChoiceCount = 0
    /// The large-download question's read for a command its targets' reading does not cover
    /// (APP-045), the one Move to Trash step that can wait: a second command waits for it
    /// rather than racing it.
    @ObservationIgnored var trashSizingTask: Task<Void, Never>?
    /// The large-download question's answer for the current targets, read when they change
    /// (APP-045, `CatalogWindowViewModelTrash.swift`): a revision pair and one doorbell loop
    /// (ADR 0032). `trashQuestionReading` is the newest finished pass's, of exactly its files.
    @ObservationIgnored var trashQuestionRequested: UInt64 = 0
    @ObservationIgnored var trashQuestionCovered: UInt64 = 0
    @ObservationIgnored var trashQuestionContinuation: AsyncStream<Void>.Continuation?
    @ObservationIgnored var trashQuestionTask: Task<Void, Never>?
    @ObservationIgnored var trashQuestionReading: TrashQuestionReading?
    /// One undo target per Move to Trash command, so a command whose mark failed or hid
    /// nothing takes exactly its own entry off the undo stack. `UndoManager` does not retain
    /// targets, so they are kept here for the window's life: one small object per command.
    @ObservationIgnored var trashUndoTargets: [MediaTrashBatchID: TrashUndoTarget] = [:]
    /// Tests hold the Store's mark at its suspension, or fail it, here; nil in the app.
    @ObservationIgnored let trashMarkHook: (@Sendable () async throws -> Void)?
    /// Tests hold an undo's file work at its suspension here, before the queue puts anything
    /// back; nil in the app.
    @ObservationIgnored let trashUndoHook: (@Sendable () async -> Void)?
    /// The scope whose waiting pane has had a frame presented (`waitingFramePresented()`):
    /// its indicator shows. Cleared by every scope intent.
    private(set) var waitingFramePresentedScope: SidebarSelection?
    @ObservationIgnored private var viewportForwardingTask: Task<Void, Never>?
    /// Waits, once the first grid has been applied, for each stage of the launch's settlement
    /// in turn (`op=owners.settled`, `op=owners.quiescent`).
    @ObservationIgnored private var ownerStartTask: Task<Void, Never>?
    /// The catalog's start, then `BackgroundOwnerSet.start()`: true once every owner has
    /// started, false when the catalog failed to start and none did. A settled fact about the
    /// owners means something only after it (`untilOwnersCaughtUp()`).
    @ObservationIgnored private var ownersStart: Task<Bool, Never>?
    /// The owners started at the first grid, kept so a session's end can report each one's
    /// status (`ownerStatuses()`).
    @ObservationIgnored private var backgroundOwnerSet: BackgroundOwnerSet?
    @ObservationIgnored var deviceStagingSweepTask: Task<Void, Never>?
    @ObservationIgnored var gridTelemetryTask: Task<Void, Never>?
    /// One owned pane-preview request (or downloading retry) per slot. Superseded
    /// requests cancel before enqueueing another full-size decode.
    @ObservationIgnored var paneRequestTasks: [PaneSlot: Task<Void, Never>] = [:]
    @ObservationIgnored private var hasStarted = false
    /// When `start()` ran, which the app calls as launch finishes, and how long the catalog
    /// took to load from then: the parts of `op=launch.firstGrid`, logged once, when the
    /// first state the catalog's load answers is applied.
    @ObservationIgnored private var launchStartedAt: ContinuousClock.Instant?
    @ObservationIgnored private var catalogLoadedMs: Int?
    @ObservationIgnored private var firstGridLogged = false
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
    /// The Places map's cluster lane (ADR 0040, `CatalogWindowViewModelMap.swift`): a
    /// revision pair and one doorbell-driven loop. A request is a count, never a flag a
    /// finishing pass clears (ADR 0032).
    @ObservationIgnored var mapClusterRequested: UInt64 = 0
    @ObservationIgnored var mapClusterCovered: UInt64 = 0
    @ObservationIgnored var mapClusterContinuation: AsyncStream<Void>.Continuation?
    @ObservationIgnored var mapClusterTask: Task<Void, Never>?
    @ObservationIgnored var mapCameraRevision: UInt64 = 0
    /// A fit the map has not yet confirmed: the request's revision and whether it still
    /// carries the margin. MapKit clamps a camera it cannot show (a two-continent library
    /// with margin exceeds its zoom-out at a window's width), so the fit is checked
    /// against the viewport that followed it and re-asked once without margin.
    @ObservationIgnored var mapPendingFit: (revision: UInt64, padded: Bool)?
    /// What the newest click on a stack did, until the next click starts another gesture:
    /// the gesture a double-click's second click belongs to (`mapMouseDown(clickCount:)`).
    @ObservationIgnored var mapStackClick: MapStackClick?
    /// The map the user left for an area or a stack, which Back returns to: taken when they
    /// leave, so a camera flight that settles after does not move it (APP-058).
    @ObservationIgnored var mapLeftViewport: MapViewport?
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
    /// The loupe's video, or Live Photo motion: being prepared, playable, or not playable
    /// and why. Set in the frame of the act that asks for it, so the pane answers at once
    /// (DES-086, DES-120); cleared when focus or mode moves away from its asset.
    var loupeVideo: LoupeVideo?
    /// The loupe's player, when its video is ready.
    var loupeVideoState: LoupeVideoState? {
        if case let .ready(state) = loupeVideo {
            state
        } else {
            nil
        }
    }

    /// Changes the ready player's state in place; nothing when no player is ready.
    func updateLoupeVideoState(_ change: (inout LoupeVideoState) -> Void) {
        guard case var .ready(state) = loupeVideo else { return }
        change(&state)
        loupeVideo = .ready(state)
    }

    /// The one in-flight loupe video preparation (materialize + build player). Named so
    /// a focus move can cancel the previous asset's preparation before starting another.
    @ObservationIgnored var loupeVideoPrepareTask: Task<Void, Never>?
    /// The newest read of the focused asset's kind. A focus move replaces it: the older
    /// read's answer belongs to an asset no longer focused.
    @ObservationIgnored var focusedKindTask: Task<Void, Never>?

    /// Today in the user's calendar: the day On This Day asks about (ADR 0049). Read at
    /// init and replaced only by `applyCalendarDay(_:)`, when the platform reports the day
    /// or the time zone changed (`CatalogWindowViewModelStory.swift`).
    var today: CalendarDay
    /// Reads today when the platform reports a change; tests inject a fixed answer.
    @ObservationIgnored let calendarDayReader: @Sendable () -> CalendarDay
    /// Where the platform's day and time-zone reports are observed.
    @ObservationIgnored let calendarNotificationCenter: NotificationCenter
    @ObservationIgnored var calendarDayObservers: [any NSObjectProtocol] = []
    @ObservationIgnored var calendarDayContinuation: AsyncStream<Void>.Continuation?
    /// The one consumer of the day reports: a newest-wins doorbell, since only today's
    /// value matters, read after the report arrives.
    @ObservationIgnored var calendarDayTask: Task<Void, Never>?
    /// The story playing over On This Day, nil when none is (ADR 0049). Written only by
    /// the story intents in `CatalogWindowViewModelStory.swift`.
    var story: StoryPlayback?
    /// The year the On This Day collection should bring keyboard focus to: the year a
    /// closed story was on. The view applies each request once, by its revision.
    var onThisDayFocusRequest: OnThisDayFocusRequest?
    /// On This Day's titles by anniversary, as the title writer publishes them (ADR 0053).
    var anniversaryTitles: [CalendarDay: String] = [:]
    @ObservationIgnored var anniversaryTitleRequests: AsyncStream<[AnniversaryTitleWriter.Anniversary]>.Continuation?
    @ObservationIgnored var anniversaryTitleTask: Task<Void, Never>?
    /// Counts focus changes: `setFocus` adds one on every call, the same item included. A
    /// story's state and every report made for it carry the visit they belong to.
    @ObservationIgnored var focusVisit: UInt64 = 0
    /// The current still's hold. Cancelled when the item changes or the story pauses or
    /// closes; a hold that wakes for another visit does nothing.
    @ObservationIgnored var storyHoldTask: Task<Void, Never>?
    /// Waits for the current video's end or failure report.
    @ObservationIgnored var storyVideoWatchTask: Task<Void, Never>?
    @ObservationIgnored var storySignpost: OSSignpostIntervalState?

    init(
        catalogStore: CatalogStore,
        catalogProjection: CatalogProjection? = nil,
        loadAdmission: LoadAdmission? = nil,
        backgroundRoom: BackgroundRoom = BackgroundRoom(),
        enrichmentCoordinator: EnrichmentCoordinator? = nil,
        metadataRefresher: MetadataRefresher? = nil,
        immichAccounts: ImmichAccounts? = nil,
        stallMonitor: MainRunLoopStallMonitor = MainRunLoopStallMonitor(),
        startsStallMonitor: Bool = true,
        startsEnrichment: Bool = true,
        startsSourceMonitoring: Bool = true,
        backgroundOwners: BackgroundOwners = .all,
        paneOriginalDownloads: PaneOriginalDownloads = .whenNeeded,
        preferencesDomain: PreferencesDomain,
        previewLoader: (any PreviewLoading)? = nil,
        videoLoader: VideoPreviewLoader? = nil,
        workspace: any WorkspaceOpening = LaunchServicesWorkspace(),
        calendarDayReader: @escaping @Sendable () -> CalendarDay = { CalendarDay.today() },
        calendarNotificationCenter: NotificationCenter = .default,
        tileContentStore: TileContentStore = TileContentStore(),
        volumeCapacity: @escaping VolumeCapacityReader,
        trashFiles: MediaTrashCoordinator.FileOperations,
        trashFileStatus: @escaping MediaTrashCoordinator.StatusReader = { FileMaterialization.status(of: $0) },
        trashMarkHook: (@Sendable () async throws -> Void)? = nil,
        trashUndoHook: (@Sendable () async -> Void)? = nil
    ) {
        self.trashMarkHook = trashMarkHook
        self.trashUndoHook = trashUndoHook
        self.volumeCapacity = volumeCapacity
        self.workspace = workspace
        self.tileContentStore = tileContentStore
        self.calendarDayReader = calendarDayReader
        self.calendarNotificationCenter = calendarNotificationCenter
        today = calendarDayReader()
        // Curation undo entries are registered from store completions, outside any
        // AppKit event; groups are opened and closed explicitly (APP-039).
        windowUndoManager.groupsByEvent = false
        // Lossless: a hide must reach Projection before the report that its mark landed, and
        // a query is applied in turn (each is cheap; a pass builds the newest).
        let (projectionIntentStream, projectionIntentContinuation) = AsyncStream<CatalogProjectionIntent>.makeStream(
            bufferingPolicy: .unbounded
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
        let (duplicatesIntentStream, duplicatesIntentContinuation) = AsyncStream<DuplicatesIntent>.makeStream(
            bufferingPolicy: .unbounded
        )
        let (peopleIntentStream, peopleIntentContinuation) = AsyncStream<PeopleIntent>.makeStream(
            bufferingPolicy: .unbounded
        )
        let (mediaChoiceStream, mediaChoiceContinuation) = AsyncStream<MediaChoiceCommand>.makeStream(
            bufferingPolicy: .unbounded
        )
        let (viewportStream, viewportContinuation) = AsyncStream<[MediaAssetID]>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        // Every hand-off is handed over, in order.
        let (handOffStream, handOffContinuation) = AsyncStream<HandOffRequest>.makeStream(bufferingPolicy: .unbounded)
        let (exportStream, exportContinuation) = AsyncStream<ExportRequest>.makeStream(bufferingPolicy: .unbounded)
        self.preferencesDomain = preferencesDomain
        preferences = preferencesDomain.makeDefaults()
        let storedColumns = preferences.integer(forKey: Self.gridColumnCountDefaultsKey)
        gridColumnCount = GridColumnCount.validated(storedColumns)
        let storedStrip = preferences.object(forKey: Self.stripTileEdgeDefaultsKey) as? Double
        stripTileEdge = Self.clampedStripTileEdge(storedStrip.map { CGFloat($0) })
        advanceAfterMediaChoice = preferences.bool(forKey: Self.advanceAfterMediaChoiceDefaultsKey)
        asksBeforeLargeTrashDownload = preferences.object(forKey: Self.asksBeforeLargeTrashDownloadDefaultsKey)
            as? Bool ?? true
        findsDuplicatesAcrossLibraries = preferences.bool(forKey: Self.findsDuplicatesAcrossLibrariesDefaultsKey)
        showsRawPairsAsOne = preferences.object(forKey: Self.showsRawPairsAsOneDefaultsKey) as? Bool ?? true
        searchLanguages = SearchLanguages.resolved(
            stored: preferences.object(forKey: Self.searchLanguagesDefaultsKey) as? [String],
            systemPreferred: Locale.preferredLanguages
        )
        let storedDismissedIdentities = preferences.string(forKey: Self.dismissedCameraBannersDefaultsKey)
        dismissedCameraBannerIdentities = Set(
            (storedDismissedIdentities ?? "").split(separator: "\n").map { DeviceIdentity(rawValue: String($0)) }
        )
        foldedInfoSections = Self.foldedSections(stored: preferences.string(forKey: Self.foldedInfoSectionsDefaultsKey))
        foldedEditSections = Self.foldedSections(stored: preferences.string(forKey: Self.foldedEditSectionsDefaultsKey))
        importPreferences = ImportPreferencesStore.load(defaults: preferences)
        exportSettings = ExportSettingsStore.load(defaults: preferences)
        self.catalogStore = catalogStore
        let loadAdmission = loadAdmission ?? LoadAdmission(room: backgroundRoom)
        self.loadAdmission = loadAdmission
        self.backgroundRoom = backgroundRoom
        // A projection a test makes keeps its own admission; the window's shares this one, so
        // its duplicates builds and People passes take turns with the owners started here.
        self.catalogProjection = catalogProjection
            ?? CatalogProjection(volumeCapacity: volumeCapacity, backgroundOwners: backgroundOwners, admission: loadAdmission)
        let mediaChoiceOverlay = MediaChoiceOverlay()
        self.mediaChoiceOverlay = mediaChoiceOverlay
        mediaTileDetailReader = MediaTileDetailReader(store: catalogStore, choices: mediaChoiceOverlay)
        let deviceStagingRegistry = DeviceStagingRegistry()
        self.deviceStagingRegistry = deviceStagingRegistry
        let immichAccounts = immichAccounts ?? (startsEnrichment
            ? ImmichAccounts(store: catalogStore, volumeCapacity: volumeCapacity, admission: loadAdmission)
            : nil)
        self.immichAccounts = immichAccounts
        let materializationCoordinator = MaterializationCoordinator(
            store: catalogStore,
            // Dispatch on what the root *is*, not on what its path looks like. The
            // previous form asked the device registry to recognise a camera file by
            // string-prefixing the URL, and fell through to the *cloud* provider when
            // that missed — so a one-character prefix bug sent every camera file to
            // iCloud, which refused it as a permission error on a path that did not
            // exist. A device root is never servable by the cloud provider, and a
            // device root with no live session is a state, not a fallback (APP-018).
            executor: { [weak catalogStore, weak immichAccounts] request in
                switch await catalogStore?.rootKind(for: request.id.libraryRootPath) {
                case .deviceMTP:
                    guard let result = await deviceStagingRegistry.materialize(request.id.fileURL) else {
                        return MaterializationResult(outcome: .deviceUnavailable, rerequestCount: 0, elapsedMs: 0)
                    }
                    return result
                case .immichAccount:
                    // An account's originals arrive over HTTP from its server, through the
                    // owner of its session; never routed to the cloud provider (ADR 0046 §4).
                    guard let immichAccounts else {
                        return MaterializationResult(outcome: .requestFailed, rerequestCount: 0, elapsedMs: 0)
                    }
                    return await immichAccounts.downloadOriginal(request)
                case .library, .removableVolume, nil:
                    return await FileMaterialization.materialize(request)
                }
            },
            volumeCapacity: volumeCapacity,
            room: backgroundRoom
        )
        self.materializationCoordinator = materializationCoordinator
        handOffPreparer = HandOffPreparer(
            directory: catalogStore.handOffDirectory,
            materialization: materializationCoordinator
        )
        mediaTrashCoordinator = MediaTrashCoordinator(
            store: catalogStore,
            materializationRequester: materializationCoordinator,
            files: trashFiles,
            status: trashFileStatus,
            volumeCapacity: volumeCapacity
        )
        // One analyzer reads every face, a still's preview and a video's frames, so the
        // model loads once.
        let faceAnalysis = FaceAnalyzer.bundledAnalysis()
        self.enrichmentCoordinator = enrichmentCoordinator ?? (
            startsEnrichment
                ? EnrichmentCoordinator(
                    store: catalogStore,
                    enricher: .live(
                        thumbnailDirectory: catalogStore.thumbnailDirectory
                            ?? FileManager.default.temporaryDirectory,
                        analyzeFaces: faceAnalysis
                    ),
                    materializationRequester: materializationCoordinator,
                    cameraRangeAccess: deviceStagingRegistry.makeCameraRangeAccess(),
                    remoteRangeAccess: immichAccounts?.rangeAccess()
                )
                : nil
        )
        // The live refresher reads real files, so it pairs with the live enrichment
        // pipeline: a caller that injects its own coordinator controls enrichment and gets
        // only the refresher it injects.
        self.metadataRefresher = metadataRefresher ?? (
            startsEnrichment && enrichmentCoordinator == nil
                ? MetadataRefresher(store: catalogStore) { [materializationCoordinator] in
                    await materializationCoordinator.locality(of: $0)
                }
                : nil
        )
        renderSignatureRefresher = startsEnrichment && enrichmentCoordinator == nil
            ? RenderSignatureRefresher(store: catalogStore, thumbnailDirectory: catalogStore.thumbnailDirectory)
            : nil
        previewFaceReader = startsEnrichment && enrichmentCoordinator == nil
            ? PreviewFaceReader(
                store: catalogStore, thumbnailDirectory: catalogStore.thumbnailDirectory, analyzeFaces: faceAnalysis
            )
            : nil
        placeNameReader = startsEnrichment && enrichmentCoordinator == nil ? PlaceNameReader(store: catalogStore) : nil
        photoSearchIndex = startsEnrichment && enrichmentCoordinator == nil
            ? catalogStore.searchIndexDirectory.map { vectorDirectory in
                PhotoSearchIndex(
                    store: catalogStore,
                    thumbnailDirectory: catalogStore.thumbnailDirectory,
                    vectorDirectory: vectorDirectory,
                    bundle: Bundle(for: CatalogWindowViewModel.self),
                    textReader: SearchTextReader(startSession: SearchTextChild.start, room: backgroundRoom),
                    admission: loadAdmission,
                    room: backgroundRoom
                )
            }
            : nil
        photoDescriptionWriter = startsEnrichment && enrichmentCoordinator == nil
            ? PhotoDescriptionWriter(
                store: catalogStore,
                thumbnailDirectory: catalogStore.thumbnailDirectory,
                describe: PhotoDescriber.live,
                admission: loadAdmission
            )
            : nil
        anniversaryTitleWriter = photoDescriptionWriter.map { writer in
            AnniversaryTitleWriter(store: catalogStore, descriptions: writer, writeTitle: AnniversaryTitler.live)
        }
        derivedFolderLoad = startsEnrichment ? DerivedFolderLoad(store: catalogStore, admission: loadAdmission) : nil
        self.stallMonitor = stallMonitor
        self.startsStallMonitor = startsStallMonitor
        self.startsEnrichment = startsEnrichment
        self.startsSourceMonitoring = startsSourceMonitoring
        self.backgroundOwners = backgroundOwners
        // The panes' one way to an original's bytes; a read-only tour's never downloads.
        let paneOriginals: any MaterializationRequesting = switch paneOriginalDownloads {
        case .whenNeeded: materializationCoordinator
        case .never: ReadOnlyOriginals(coordinator: materializationCoordinator)
        }
        if let previewLoader {
            self.previewLoader = previewLoader
        } else {
            self.previewLoader = PreviewImageLoader(
                derivedImageDirectory: catalogStore.thumbnailDirectory,
                materializationRequester: paneOriginals
            )
        }
        if let videoLoader {
            self.videoLoader = videoLoader
        } else {
            self.videoLoader = VideoPreviewLoader(materializationRequester: paneOriginals)
        }
        self.projectionIntentStream = projectionIntentStream
        self.projectionIntentContinuation = projectionIntentContinuation
        self.mutationStream = mutationStream
        self.mutationContinuation = mutationContinuation
        self.importIntentStream = importIntentStream
        self.importIntentContinuation = importIntentContinuation
        self.mediaTrashIntentStream = mediaTrashIntentStream
        self.mediaTrashIntentContinuation = mediaTrashIntentContinuation
        self.duplicatesIntentStream = duplicatesIntentStream
        self.duplicatesIntentContinuation = duplicatesIntentContinuation
        self.peopleIntentStream = peopleIntentStream
        self.peopleIntentContinuation = peopleIntentContinuation
        self.mediaChoiceStream = mediaChoiceStream
        self.mediaChoiceContinuation = mediaChoiceContinuation
        let stackKeyChannel = AsyncStream<StackKeyCommand>.makeStream(bufferingPolicy: .unbounded)
        stackKeyStream = stackKeyChannel.stream
        stackKeyContinuation = stackKeyChannel.continuation
        self.viewportStream = viewportStream
        self.viewportContinuation = viewportContinuation
        self.handOffStream = handOffStream
        self.handOffContinuation = handOffContinuation
        self.exportStream = exportStream
        self.exportContinuation = exportContinuation
        let (immichIntentStream, immichIntentContinuation) = AsyncStream<ImmichAccountIntent>.makeStream(
            bufferingPolicy: .unbounded
        )
        self.immichIntentStream = immichIntentStream
        self.immichIntentContinuation = immichIntentContinuation
        // The restored query is the first one Projection sees (APP-043), so launch never
        // flashes the default collection before the user's own.
        if let place = Self.loadBrowserPlace(from: preferences, today: today) {
            pendingPlaceRestore = place
            queryDescriptor = place.descriptor
            sidebarSelection = place.descriptor.scope
        }
        // The paint and visible-thumbnail facts the monitor and the tile store report on the
        // main thread, republished as this window's state.
        stallMonitor.onIntentPainted = { [weak self] report in
            self?.intentPainted(report)
        }
        tileContentStore.onVisibleThumbnailsComplete = { [weak self] report in
            self?.lastVisibleThumbnails = report
        }
        stallMonitor.onActResult = { [weak self] report in
            self?.lastActResult = report
        }
        stallMonitor.onScrollHitches = { [weak self] report in
            self?.lastScrollHitches = report
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
        // Ends the relay's subscription, which lets Projection tear down when it was the last.
        stateRelayTask?.cancel()
        for observer in calendarDayObservers {
            calendarNotificationCenter.removeObserver(observer)
        }
        calendarDayTask?.cancel()
        calendarDayContinuation?.finish()
        storyHoldTask?.cancel()
        storyVideoWatchTask?.cancel()
        mapClusterTask?.cancel()
        mapClusterContinuation?.finish()
        catalogStartupTask?.cancel()
        catalogOpeningTask?.cancel()
        queryForwardingTask?.cancel()
        mutationForwardingTask?.cancel()
        mediaChoiceForwardingTask?.cancel()
        stackKeyForwardingTask?.cancel()
        handOffTask?.cancel()
        exportTask?.cancel()
        immichIntentTask?.cancel()
        immichStatusTask?.cancel()
        activityTask?.cancel()
        trashSizingTask?.cancel()
        trashQuestionTask?.cancel()
        trashQuestionContinuation?.finish()
        mediaTrashEventTask?.cancel()
        mediaTrashIntentTask?.cancel()
        duplicatesIntentTask?.cancel()
        peopleIntentTask?.cancel()
        openWithMenuTask?.cancel()
        photoInfoTask?.cancel()
        readingsRefreshTask?.cancel()
        readingsDoorbell?.finish()
        anniversaryTitleTask?.cancel()
        anniversaryTitleRequests?.finish()
        facesReadTask?.cancel()
        facesReadDoorbell?.finish()
        faceCandidatesTask?.cancel()
        personSheetFacesTask?.cancel()
        placeNameTask?.cancel()
        focusedKindTask?.cancel()
        currentTargetChoiceTask?.cancel()
        viewportForwardingTask?.cancel()
        ownerStartTask?.cancel()
        ownersStart?.cancel()
        // Before the owners are told to stop: a heavy load still waiting never starts.
        loadAdmission.shutdown()
        deviceStagingSweepTask?.cancel()
        importPresentationTask?.cancel()
        removableDestinationsTask?.cancel()
        reorganizationTask?.cancel()
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
        projectionIntentContinuation.finish()
        mutationContinuation.finish()
        importIntentContinuation.finish()
        mediaTrashIntentContinuation.finish()
        duplicatesIntentContinuation.finish()
        peopleIntentContinuation.finish()
        mediaChoiceContinuation.finish()
        stackKeyContinuation.finish()
        handOffContinuation.finish()
        exportContinuation.finish()
        immichIntentContinuation.finish()
        viewportContinuation.finish()
        // The owners below must be told to stop or their own loops would keep them, and
        // the store, alive past this window: the enrichment supervisor strongly retains
        // its coordinator. `shutdown()` is async and teardown cannot await, so one task,
        // which nothing here outlives to own, stops them side by side — an import's
        // shutdown waits for its run, and nothing else should wait behind that.
        // Materialization stops after enrichment, which feeds it. The search index's pass holds
        // it for as long as a text reading takes, and its shutdown ends that reading's child.
        let mediaOps = mediaOperationCoordinator
        let mediaTrash = mediaTrashCoordinator
        let enrichment = enrichmentCoordinator
        let materialization = materializationCoordinator
        let refresher = metadataRefresher
        let immich = immichAccounts
        let searchIndex = photoSearchIndex
        let derivedFolder = derivedFolderLoad
        let activityBoard = activityBoard
        // swiftlint:disable:next unowned_view_model_task
        Task {
            await withDiscardingTaskGroup { group in
                group.addTask { await activityBoard.shutdown() }
                group.addTask { await derivedFolder?.shutdown() }
                group.addTask { await immich?.shutdown() }
                group.addTask { await searchIndex?.shutdown() }
                group.addTask { await mediaOps?.shutdown() }
                group.addTask { await mediaTrash.shutdown() }
                group.addTask { await refresher?.shutdown() }
                group.addTask {
                    await enrichment?.shutdown()
                    await materialization.shutdown()
                }
            }
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
        launchStartedAt = .now
        // Quit is the one moment the place is written: `willTerminate` runs for every
        // ordinary quit, and the write is a single small preference value.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.persistBrowserPlace()
                // The derived folder's session ends clean only with no change in flight.
                self?.catalogStore.derivedFolder?.closeSession()
            }
        }

        let signpost = OtosSignpost.ui.beginInterval("CatalogWindowViewModelStart")
        OtosSignpost.ui.endInterval("CatalogWindowViewModelStart", signpost)
        OtosLog.ui.info("Catalog window view model started")
        if startsStallMonitor {
            stallMonitor.start()
        }

        // The sole Projection-intent task: queries and Move to Trash's hides, in order. Each
        // query is applied in turn, cheaply; a pass builds only the newest.
        let projection = catalogProjection
        let store = catalogStore
        let initialRequest = CatalogQueryRequest(
            descriptor: queryDescriptor,
            generation: queryGeneration
        )

        startQueryForwarding(projection: projection)
        startReadingsRefresh()
        startAnniversaryTitles()
        startFacesReadRefresh()
        // The Store's first command: it compares duplicates as the user chose. A duplicates
        // build that the catalog's load lets run before it is followed by another, since the
        // handoff is a change of which files are copies.
        submitCatalogMutation(.setDuplicatesReach(duplicatesReach))
        // And it pairs a RAW with its processed file as the user chose, before the first order
        // read builds stacks.
        submitCatalogMutation(.setRawPairing(rawPairing))
        startMutationForwarding(store: store, coordinator: enrichmentCoordinator)
        startMediaChoiceForwarding(writer: .store(store))
        startStackKeyForwarding(store: store)
        editSession.startEditing(store: store)
        startHandOff(store: store)
        startExport()
        searchLanguageChoicesTask = Task { [weak self] in
            let choices = await SearchLanguages.choices()
            self?.searchLanguageChoices = choices
        }
        startMapClustering()
        startCalendarDayMonitoring()
        startStateConsumption(
            projection: projection,
            store: store,
            initialRequest: initialRequest
        )
        startCatalogOpening(store: store)
        startCatalog(store: store)
        startMediaTrash()
        startDuplicatesIntentConsumer()
        startPeopleIntentConsumer()
        if startsSourceMonitoring {
            startRemovableVolumeMonitoring()
            startDeviceStagingSweepThenCameraMonitoring()
        }
        startMediaOperationsIfNeeded()
        if startsEnrichment, backgroundOwners.starts(.immich) {
            startImmichAccounts()
        }
        // The background owners start once the first grid is applied
        // (`startBackgroundOwners`); the restored view's load runs first when the admission
        // opens.
        loadAdmission.want(BackgroundLoad.needed(by: queryDescriptor))
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
        // The heavy load this view needs runs next (People's pass, the search index's load).
        loadAdmission.want(BackgroundLoad.needed(by: descriptor))
        let generation = queryGeneration
        let vm = diagnosticID
        OtosLog.ui.info(
            "Catalog query changed vm=\(vm, privacy: .public) generation=\(generation, privacy: .public) descriptor=\(descriptor.diagnosticDescription, privacy: .public)"
        )
        if scopeChanged {
            // A new wait: its indicator waits for its own first presented frame.
            waitingFramePresentedScope = nil
            stallMonitor.beginIntentToPaint(scope: descriptor.scope)
            // The paint's other end is `intentPainted`'s checkpoint: what the process paid
            // between the two (CPU, disk, page-ins) is the paint's own.
            ResourceCheckpoint.record("paintStart", fields: ["scope": descriptor.scope.diagnosticDescription])
        }
        projectionIntentContinuation.yield(.query(CatalogQueryRequest(
            descriptor: descriptor,
            generation: queryGeneration,
            expandedStacks: expandedStacks
        )))
    }

    /// The one writer of `expandedStacks`: Photo ▸ Expand Stack / Collapse Stack, S and a
    /// click on a stack's badge all arrive here (ADR 0052). Expanding re-derives the order
    /// under the same descriptor, so the selection and the browser place stay.
    func setExpandedStacks(_ stacks: Set<PhotoStackID>) {
        guard stacks != expandedStacks else { return }
        expandedStacks = stacks
        OtosLog.ui.noticeOperation("stack.expansion", phase: "submitted", fields: [
            "vm": diagnosticID,
            "expanded": "\(stacks.count)",
            "generation": "\(queryGeneration)",
        ])
        projectionIntentContinuation.yield(.query(CatalogQueryRequest(
            descriptor: queryDescriptor,
            generation: queryGeneration,
            expandedStacks: stacks
        )))
    }

    /// The AppKit grid reports its visible identities here as the user scrolls. This is a
    /// pure priority hint for enrichment, so only the newest viewport is kept.
    func viewportChanged(_ orderedAssetIDs: [MediaAssetID]) {
        if viewMode == .grid, !orderedAssetIDs.isEmpty {
            gridViewportCenterID = orderedAssetIDs[orderedAssetIDs.count / 2]
        }
        viewportContinuation.yield(orderedAssetIDs)
    }

    /// Starts the background owners, once, when the first grid has been applied: before it,
    /// every owner's first walk and load read the catalog beside the window's first read and
    /// took launch from 2.2 s with none running to 2.8 s with all (ADR 0055). The
    /// heavy loads also wait for the admission this opens, so the duplicates builds and People
    /// passes the projection asked for meanwhile start now too, one at a time.
    ///
    /// The owners and their order are `BackgroundOwnerSet`'s. Every owner's tasks run below
    /// the window's priority (`TaskPriority.backgroundOwner`), inherited from this one. Once
    /// they are started, the task waits for every one of them to owe nothing and logs when
    /// (`op=owners.quiescent`, from the launch).
    private func startBackgroundOwners() {
        loadAdmission.open()
        guard startsEnrichment, ownerStartTask == nil, let coordinator = enrichmentCoordinator else {
            return
        }
        // The first query is readied as the last of the heavy loads; the search field's focus
        // readies it at once if it comes first.
        photoSearchIndex?.prepareWhenAdmitted()
        // updateViewport is delivered newest-value; the coordinator is the single owner of
        // the priority hint, so this forwards verbatim with no main-actor work.
        viewportForwardingTask = Task { [coordinator, viewportStream, immichAccounts] in
            for await ids in viewportStream {
                await coordinator.updateViewport(ids)
                // An account row on screen paints from its server's own images, fetched ahead
                // of the backlog: enrichment reads its original only in ranges, for metadata.
                await immichAccounts?.showVisible(ids)
            }
        }
        let owners = BackgroundOwnerSet(
            store: catalogStore,
            projection: catalogProjection,
            materialization: materializationCoordinator,
            enrichment: coordinator,
            immich: immichAccounts,
            renderSignatures: renderSignatureRefresher,
            previewFaces: previewFaceReader,
            placeNames: placeNameReader,
            searchIndex: photoSearchIndex,
            descriptions: photoDescriptionWriter,
            metadata: metadataRefresher,
            derivedFolder: derivedFolderLoad,
            starts: backgroundOwners
        )
        let launchStartedAt = launchStartedAt ?? .now
        backgroundOwnerSet = owners
        activityTask = Task { [weak self, board = activityBoard] in
            for await snapshot in board.snapshots {
                guard let self else { break }
                activity = snapshot
            }
        }
        // The first grid follows the catalog's load, so each owner's first candidate query
        // sees persisted rows. `store.start()` is idempotent and shared: it returns the load
        // `startCatalog` ran, and a failed load starts no owner.
        let ownersStart = Task(priority: .backgroundOwner) { [owners, store = catalogStore, board = activityBoard, room = backgroundRoom] () -> Bool in
            do {
                try await store.start()
            } catch {
                OtosLog.persistence.error("Background owners skipped because catalog start failed")
                return false
            }
            // Watched before they start, so the board hears each owner's first request.
            await board.watch(owners.activityOwners(), room: room)
            await owners.start()
            return true
        }
        self.ownersStart = ownersStart
        ownerStartTask = Task(priority: .backgroundOwner) { [weak self, owners, store = catalogStore] in
            do {
                try await store.start()
            } catch {
                // Logged by `ownersStart`, which starts no owner.
                return
            }
            // The duplicates stage is the groups owner's own covered request, so it is waited
            // on beside the owners' start, which runs the metadata pass to its end. The
            // settled stages list every owner, so they wait for every owner to have started.
            do {
                try await owners.untilLaunchDuplicatesBuilt()
                let backlog = await BackgroundOwnerQuiescence.statuses(of: owners.quiescentOwners())
                    .filter(\.worksBacklog).map(\.owner)
                BackgroundOwnerQuiescence.logSettled(.duplicatesBuilt, sinceLaunch: launchStartedAt, backlog: backlog)
                self?.settleLaunch(.duplicatesBuilt)
                guard await ownersStart.value else { return }
                let caughtUp = try await BackgroundOwnerQuiescence.untilCaughtUp(owners.quiescentOwners())
                BackgroundOwnerQuiescence.logSettled(
                    .launchWork, sinceLaunch: launchStartedAt, backlog: caughtUp.filter(\.backlog).map(\.owner)
                )
                self?.settleLaunch(.launchWork)
                let facts = try await BackgroundOwnerQuiescence.untilQuiescent(owners.quiescentOwners(), store: store)
                BackgroundOwnerQuiescence.log(facts, sinceLaunch: launchStartedAt)
                self?.settleLaunch(.ownersQuiescent)
            } catch {
                // Cancelled at teardown: the window closed before its owners settled.
            }
        }
    }

    /// Records the stage the launch has settled to; at `duplicatesBuilt`, whether the window
    /// already shows groups.
    func settleLaunch(_ settlement: LaunchSettlement) {
        guard launchSettlement.map({ settlement > $0 }) ?? true else { return }
        if parts.duplicates != nil {
            showsLaunchDuplicates = true
        }
        launchSettlement = settlement
    }

    /// Returns once every background owner has caught up to this call
    /// (`BackgroundOwnerQuiescence.untilCaughtUp`): taken up the Store changes yielded to it by
    /// then and covered what it owed after them, or working only its backlog. What a session
    /// waits on after it changed the catalog the launch's stages were judged on, as a tour that
    /// adds its library does once that library's first walk is complete: the launch's stages,
    /// judged on the catalog before it, say nothing of the work the walk's rows raised. Judged
    /// from once every owner has started when the call comes first. Nil when no owner was
    /// started, or the catalog failed to start.
    func untilOwnersCaughtUp() async throws -> [OwnerCaughtUp]? {
        guard let ownersStart, let owners = backgroundOwnerSet, await ownersStart.value else {
            return nil
        }
        return try await BackgroundOwnerQuiescence.untilCaughtUp(owners.quiescentOwners())
    }

    /// Every started background owner's status now, quiescent or not; empty before the owners
    /// start or when none was started.
    func ownerStatuses() async -> [OwnerStatus] {
        guard let owners = backgroundOwnerSet else {
            return []
        }
        return await BackgroundOwnerQuiescence.statuses(of: owners.quiescentOwners())
    }

    /// A scope's surface painted: published for whoever waits on a paint, and a checkpoint.
    private func intentPainted(_ report: SidebarPaintReport) {
        lastSidebarPaint = report
        ResourceCheckpoint.record("paint", fields: [
            "scope": report.scope.diagnosticDescription,
            "tileCacheMB": "\(tileContentStore.imageBytes / 1_048_576)",
            "tileEntries": "\(tileContentStore.count)",
        ], storeUse: storeUse)
    }

    /// Reads the Store's cumulative use for a resource checkpoint, from any thread.
    var storeUse: @Sendable () -> CatalogStoreUse {
        { [catalogStore] in catalogStore.use() }
    }

    private func startQueryForwarding(projection: CatalogProjection) {
        queryForwardingTask = Task { [projection, projectionIntentStream, photoSearchIndex] in
            await Self.forwardProjectionIntents(projectionIntentStream, to: projection, searchIndex: photoSearchIndex)
        }
    }

    /// The one consumer of the window's Projection intents, in submission order, off the main
    /// actor: each intent reaches Projection as soon as Projection is free, never after the
    /// main thread's next turn. A loop on the main actor resumed only between main-thread
    /// turns, so a Move to Trash's hide queued one turn behind every intent before it (about
    /// 70 ms a turn in a Debug build; `docs/research/2026-11-16-trash-visible-time.md`).
    @concurrent
    nonisolated static func forwardProjectionIntents(
        _ intents: AsyncStream<CatalogProjectionIntent>,
        to projection: CatalogProjection,
        searchIndex: PhotoSearchIndex?
    ) async {
        // Before the first request, so no search reaches a projection without its index.
        if let searchIndex {
            await projection.attachSearchIndex(searchIndex)
        }
        for await intent in intents {
            await projection.apply(intent, sentAt: .now)
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
        mutationForwardingTask = Task { [weak self, mutationStream, store, coordinator, previewLoader] in
            for await intent in mutationStream {
                guard !Task.isCancelled else {
                    break
                }
                let report = await Self.performCatalogMutation(
                    intent,
                    store: store,
                    coordinator: coordinator,
                    previewLoader: previewLoader,
                    importer: self?.mediaOperationCoordinator,
                    immichAccounts: self?.immichAccounts
                )
                if let report {
                    self?.handleMutationReport(report, for: intent)
                }
            }
        }
    }

    private func startStateConsumption(
        projection: CatalogProjection,
        store: CatalogStore,
        initialRequest: CatalogQueryRequest
    ) {
        let mailbox = NewestValueMailbox<CatalogWindowState>()
        // Off the main actor: it takes each publication the moment Projection yields it and
        // puts it in the mailbox, so a publication never waits for a main-thread turn holding
        // a state a newer one has replaced.
        stateRelayTask = Task(priority: .userInitiated) { [projection, store, initialRequest] in
            let signpost = OtosSignpost.ui.beginInterval("CatalogWindowStateStream")
            let states = await projection.states(
                store: store,
                initialRequest: initialRequest
            )
            OtosSignpost.ui.endInterval("CatalogWindowStateStream", signpost)
            await Self.relayStates(states, into: mailbox)
        }
        startApplyingStates(from: mailbox)
    }

    /// The window's one consumer of Projection's publications: on the main actor, it applies
    /// the newest state in `mailbox` each time it runs (`applyState`).
    func startApplyingStates(from mailbox: NewestValueMailbox<CatalogWindowState>) {
        stateConsumptionTask = Task(priority: .userInitiated) { [weak self, mailbox] in
            for await delivery in mailbox {
                // Strongify only for this loop body. Moving this guard outside
                // the loop would retain the ViewModel across the next indefinite
                // stream wait and make deinit-based cancellation unreachable.
                guard let self else {
                    break
                }
                applyState(delivery.value, superseded: delivery.superseded, waited: delivery.waited)
            }
        }
    }

    /// Puts every publication of `states` in `mailbox`, as it arrives, until the stream ends.
    /// `@concurrent`: on the cooperative pool, so no main-thread turn stands between a
    /// publication and the mailbox; the window's consumer then applies the newest one there
    /// is when it runs (`NewestValueMailbox`).
    @concurrent
    nonisolated static func relayStates(
        _ states: AsyncStream<CatalogWindowState>,
        into mailbox: NewestValueMailbox<CatalogWindowState>
    ) async {
        for await state in states {
            mailbox.put(state)
        }
        mailbox.finish()
    }

    /// Reads what the Store's open reports until it ends. Weak across each wait, so the loop
    /// keeps nothing alive; the stream finishes when the open does.
    private func startCatalogOpening(store: CatalogStore) {
        catalogOpeningTask = Task { [weak self, openings = store.openings] in
            for await opening in openings {
                guard let self else {
                    break
                }
                applyCatalogOpening(opening)
            }
        }
    }

    /// The Store's newest open report (DES-121).
    func applyCatalogOpening(_ opening: CatalogOpening) {
        guard opening != catalogOpening else {
            return
        }
        catalogOpening = opening
        OtosLog.ui.noticeOperation("ui.catalogOpening", phase: "reported", fields: [
            "vm": diagnosticID,
            "opening": opening.diagnosticDescription,
            "shown": "\(catalogOpeningFramePresented)",
        ])
    }

    private func startCatalog(store: CatalogStore) {
        catalogStartupTask = Task { [weak self, store] in
            do {
                try await store.start()
                if let self, let launchStartedAt {
                    catalogLoadedMs = DiagnosticsTiming.milliseconds(since: launchStartedAt)
                }
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
                return
            } catch {
                OtosLog.persistence.error("Catalog start failed")
                OtosLog.catalog.error(
                    "op=catalog.start phase=error error=\(String(describing: error), privacy: .public)"
                )
                self?.catalogLoadFailed = true
                return
            }
            // A reorganization the last process left journaled is finished here, once. Its
            // root has been held since the Store loaded, so nothing touched it meanwhile.
            do {
                try await LibraryReorganizationRunner.recoverJournal(store: store)
            } catch {
                OtosLog.catalog.errorOperation("reorganization.recover", phase: "failed", fields: [
                    "error": String(describing: error),
                ])
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
    /// already-updated model. `superseded` counts the publications a newer one replaced
    /// before the window could apply them, which it never applies (`NewestValueMailbox`);
    /// `waited` is how long this one waited for the main actor (`deliveryWaitUs`).
    func applyState(_ nextState: CatalogWindowState, superseded: Int = 0, waited: Duration = .zero) {
        var nextState = nextState
        if let catalogCompatibilityProblem {
            nextState.libraries = []
            nextState.removableSources = []
            nextState.mediaGrid = .empty
            nextState.mediaEmptyState = .catalogIncompatible(catalogCompatibilityProblem)
        }
        let previousState = state
        appliedStateCount += 1
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
            // The resolved filter can have let go of places named in a language the catalog
            // no longer holds (ADR 0051); adopting it clears them from the popover too.
            if let held = queryDescriptor.filter.places, nextState.queryDescriptor.filter.places == nil {
                OtosLog.ui.noticeOperation("filter.places", phase: "released", fields: [
                    "vm": diagnosticID,
                    "language": held.language.identifier,
                    "held": "\(held.keys.count)",
                ])
            }
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
        // What changed is read from the publication, never by walking it: Projection hands an
        // unchanged grid content on as the same one (`sharingUnchanged`), so one pointer
        // comparison says whether the order, its days or its stacks moved, and every check
        // below asks the content's index about the selection and focus alone.
        let contentChanged = !previousState.mediaGrid.sharesContent(with: nextState.mediaGrid)
        // Before anything compares the new order with the old: a remapped selection or
        // focus must already carry its new identity, or the prune below would drop it.
        applyPendingIdentityRemaps(nextState.pendingIdentityRemaps)
        if contentChanged {
            carrySelectionIntoStacks(nextState.mediaGrid.stacks)
        }
        applyMapState(previous: previousState, next: nextState)
        applyOnThisDayState(previous: previousState, next: nextState)
        applyDuplicatesState(previous: previousState, next: nextState)
        applyPeopleState(previous: previousState, next: nextState)

        // A new scope is a different collection, so the user's place in the old one means
        // nothing there. A filter or sort change narrows or reorders the same collection,
        // so whatever survives stays selected and focused (APP-042).
        let descriptorChanged = previousState.mediaGrid.descriptor != nextState.mediaGrid.descriptor
        let scopeChanged = previousState.mediaGrid.descriptor.scope != nextState.mediaGrid.descriptor.scope
        if scopeChanged {
            clearGridSelection(reason: "scopeChange")
        } else if contentChanged {
            let pruned = gridSelection.pruned(to: nextState.mediaGrid.content)
            if pruned != gridSelection {
                gridSelection = pruned
            }
            refreshOrderedSelection()
        }
        if descriptorChanged || contentChanged {
            reconcileFocusAfterGridChange(
                previousOrder: previousState.mediaGrid.content,
                scopeChanged: scopeChanged
            )
        }
        restoreBrowserPlaceIfReady()
        followRunsIntoTheirBatches()
        // A scope drawn by a pane in place of the grid paints when that pane has its content;
        // the grid's own structural apply ends the interval for every other scope.
        if let surface = nextState.detailSurface, nextState.detailSurfaceHasContent {
            stallMonitor.completeIntentToPaint(appliedScope: nextState.resolvedSidebarSelection, surface: surface.rawValue)
        }

        OtosSignpost.ui.endInterval("CatalogWindowStateApply", signpost)

        let itemCount = nextState.mediaGrid.orderedAssetIDs.count
        let previousItemCount = previousState.mediaGrid.orderedAssetIDs.count
        let mediaContentChanged = descriptorChanged || contentChanged
        let handoff = CatalogGridHandoff(
            updateID: updateID,
            itemCount: itemCount,
            previousItemCount: previousItemCount,
            itemDelta: itemCount - previousItemCount,
            selection: nextState.resolvedSidebarSelection.diagnosticDescription,
            emptyState: nextState.mediaEmptyState?.diagnosticDescription ?? "none",
            mediaContentChanged: mediaContentChanged,
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
            "superseded": "\(superseded)",
            "deliveryWaitUs": "\(DiagnosticsTiming.microseconds(since: applyStart - waited, now: applyStart))",
            "applyMs": "\(applyMs)",
        ])
        logFirstGridIfLoaded(nextState, items: itemCount, applyMs: applyMs)
    }

    /// Launch to the first grid, once: the first applied state the catalog's load answers,
    /// whatever it holds. `catalogMs` is launch to the catalog's load finishing; the rest is
    /// the window's first publication and this apply.
    private func logFirstGridIfLoaded(_ state: CatalogWindowState, items: Int, applyMs: Int) {
        guard !firstGridLogged, let launchStartedAt, state.mediaEmptyState != .loadingCatalog else {
            return
        }
        firstGridLogged = true
        startBackgroundOwners()
        OtosLog.ui.noticeOperation("launch.firstGrid", phase: "applied", fields: [
            "ms": "\(DiagnosticsTiming.milliseconds(since: launchStartedAt))",
            "catalogMs": catalogLoadedMs.map { "\($0)" } ?? "unknown",
            "applyMs": "\(applyMs)",
            "items": "\(items)",
            "scope": state.resolvedSidebarSelection.diagnosticDescription,
            "emptyState": state.mediaEmptyState?.diagnosticDescription ?? "none",
        ])
        ResourceCheckpoint.record("firstGrid", fields: ["items": "\(items)"], storeUse: storeUse)
    }

    func clearEjectingSourceIdentity(_ identity: DeviceIdentity) {
        ejectingSourceIdentities.remove(identity)
    }

    func beginEjectingSource(_ identity: DeviceIdentity) {
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
        setQueryDescriptor(descriptorShowing(selection))
    }

    /// The descriptor for showing `selection`, by the user's choice or automatically. A
    /// filter belongs to the sidebar row it was set in: another row starts unfiltered, while
    /// the row's own leaves (an area or stack under the map, a person, a duplicate group)
    /// keep it, so a stack's count is what it opens on (owner decision, 2026-11-12;
    /// Lightroom Classic's unlocked Library filter). Sort and search stay.
    func descriptorShowing(_ selection: SidebarSelection) -> CatalogQueryDescriptor {
        let sameRow = selection.sidebarRow == queryDescriptor.scope.sidebarRow
        return CatalogQueryDescriptor(
            scope: selection,
            filter: sameRow ? queryDescriptor.filter : .all,
            sort: queryDescriptor.sort,
            search: queryDescriptor.search
        )
    }

    func setMediaFilter(_ filter: MediaFilter) {
        setQueryDescriptor(CatalogQueryDescriptor(
            scope: queryDescriptor.scope,
            filter: filter,
            sort: queryDescriptor.sort,
            search: queryDescriptor.search
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
        setMediaFilter(queryDescriptor.filter.settingKind(kind, included: included))
    }

    func setMediaFileType(_ fileType: MediaFormatToken, kind: MediaKind, included: Bool) {
        setMediaFilter(queryDescriptor.filter.settingFileType(
            fileType,
            kind: kind,
            included: included,
            options: parts.filterOptions
        ))
    }

    func setMediaChoice(_ choice: MediaChoice, included: Bool) {
        setMediaFilter(queryDescriptor.filter.settingChoice(choice, included: included))
    }

    /// The Places filter (ADR 0051): a country, or one town in it, named in the language the
    /// popover offers them in — or, for a held place the catalog names no more, the
    /// filter's own. With neither there is no row to check.
    func setPlaceFilter(_ place: PlaceFilterKey, included: Bool) {
        let filter = queryDescriptor.filter
        guard let language = parts.filterOptions.placeNameLanguage ?? filter.places?.language else {
            return
        }
        let towns = parts.filterOptions.countries.first { $0.name == place.country }?.towns ?? []
        setMediaFilter(filter.settingPlace(place, included: included, towns: towns, language: language))
    }

    /// Choosing a sort while searching orders the results by it instead of by relevance.
    func setSortOrder(_ sort: MediaSortOrder) {
        // A scope that fixes its order disables the control; a stray call changes nothing.
        guard canChangeSort else {
            return
        }
        var search = queryDescriptor.search
        search?.order = .sort
        setQueryDescriptor(CatalogQueryDescriptor(
            scope: queryDescriptor.scope,
            filter: queryDescriptor.filter,
            sort: sort,
            search: search
        ))
    }

    /// Search menu's Relevance: the results best match first. Only offered while searching.
    func orderSearchByRelevance() {
        guard var search = queryDescriptor.search else { return }
        search.order = .relevance
        setQueryDescriptor(CatalogQueryDescriptor(
            scope: queryDescriptor.scope,
            filter: queryDescriptor.filter,
            sort: queryDescriptor.sort,
            search: search
        ))
    }

    /// Settings ▸ General ▸ Search Languages: the languages recognition favours. Stored; a
    /// search on screen is searched again with them.
    func setSearchLanguages(_ languages: [String]) {
        guard languages != searchLanguages else { return }
        searchLanguages = languages
        preferences.set(languages, forKey: Self.searchLanguagesDefaultsKey)
        guard var search = queryDescriptor.search else { return }
        search.languages = languages
        setQueryDescriptor(CatalogQueryDescriptor(
            scope: queryDescriptor.scope,
            filter: queryDescriptor.filter,
            sort: queryDescriptor.sort,
            search: search
        ))
    }

    func focusSearch() {
        searchFocusRequest &+= 1
    }

    /// The search field took focus — clicked, tabbed to, or Edit ▸ Find (`focusSearch`): the
    /// user is about to search what the window shows, so the index readies the first query
    /// (`PhotoSearchIndex.prepareForSearch`). Nothing is asked while a search is shown, whose
    /// encoder is ready already.
    func searchFieldFocused() {
        guard queryDescriptor.search == nil else { return }
        photoSearchIndex?.prepareForSearch()
    }

    /// Returns once what the search field's focus readied has ended: the text tower's warm
    /// prediction or its load (`PhotoSearchIndex.searchIntentReadied`). What the tour waits on
    /// to submit a query as a person who types does; nothing waits when there is no index.
    func searchIntentReadied() async {
        await photoSearchIndex?.searchIntentReadied()
    }

    /// The window's title, the one every scope is named by: the person a person's photos
    /// show, else the selected scope's (`CatalogWindowPolicy.title(for:libraries:)`) — the
    /// one Projection published once the scope's state is applied, and the same policy's
    /// answer from the click until then (DES-118). Before the catalog loads, the scope's own
    /// name where the scope alone gives it, else the app's name (DES-121).
    var windowTitle: String {
        if let person = shownPerson {
            return person.displayName
        }
        guard !showsSelectedScope else {
            return parts.title
        }
        guard parts.isCatalogLoaded else {
            return CatalogWindowPolicy.titleWithoutCatalog(for: queryDescriptor.scope) ?? "Otos"
        }
        return CatalogWindowPolicy.title(for: queryDescriptor.scope, libraries: parts.libraries + parts.removableSources)
    }

    /// The window's subtitle, under its title (DES-012 L3, DES-034): `Filtered` while a filter
    /// narrows the scope, so a scope that looks short is never mistaken for the whole of it
    /// (DES-029: never the filter glyph's color alone), and `Searching…` while the search's
    /// query is being read and the window keeps what it showed (ADR 0048). The duplicates
    /// list and People ignore the filter, so they never claim to be filtered.
    var windowSubtitle: String {
        let ignoresFilter = detailPane.surface == .duplicates || detailPane.surface == .people
        let filtered = queryDescriptor.filter.isActive && !ignoresFilter
        let searching = parts.searchPhase?.isSearching == true && queryDescriptor.search != nil
        return [filtered ? "Filtered" : nil, searching ? "Searching\u{2026}" : nil]
            .compactMap(\.self)
            .joined(separator: " \u{00B7} ")
    }

    /// The search field's text (ADR 0048). Typing a new search orders by relevance; editing
    /// one keeps the order chosen for it; an empty field ends the search.
    func setSearchText(_ text: String) {
        searchText = text
        let order = queryDescriptor.search?.order ?? .relevance
        let search = CatalogSearch(text: text, order: order, languages: searchLanguages)
        guard search != queryDescriptor.search else { return }
        setQueryDescriptor(CatalogQueryDescriptor(
            scope: queryDescriptor.scope,
            filter: queryDescriptor.filter,
            sort: queryDescriptor.sort,
            search: search
        ))
    }

    /// An In This Photo chip (ADR 0050): searches for the Vision label `identifier` itself, by
    /// its English name, so the chip finds its own label whatever the Mac's language; the field
    /// shows the name the chip shows. Editing the field searches for what it then holds.
    func searchForLabel(_ identifier: String) {
        let name = photoInfo?.recognized?.labels?.first { $0.identifier == identifier }?.name
            ?? SceneLabelNames.englishName(identifier)
        searchText = name
        let order = queryDescriptor.search?.order ?? .relevance
        let search = CatalogSearch(text: name, order: order, languages: searchLanguages, label: identifier)
        guard search != queryDescriptor.search else { return }
        setQueryDescriptor(CatalogQueryDescriptor(
            scope: queryDescriptor.scope,
            filter: queryDescriptor.filter,
            sort: queryDescriptor.sort,
            search: search
        ))
    }
}

// MARK: - Sidebar selection policy

//
// Applies `SidebarSelectionPolicy` when projected sources change, plus eject-alert and
// removal-notice dismissal. Automatic selection still goes through `setQueryDescriptor`.

extension CatalogWindowViewModel {
    func applyAutomaticSidebarSelection(_ selection: SidebarSelection) {
        setQueryDescriptor(descriptorShowing(selection))
    }

    func dismissEjectAlert() {
        ejectAlertMessage = nil
    }

    func dismissLibraryRemovalNotice() {
        libraryRemovalNotice = nil
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

    func handleMutationReport(_ report: CatalogMutationReport, for intent: CatalogMutationIntent) {
        switch report {
        case let .eject(outcome):
            handleEjectOutcome(outcome, for: intent)
        case let .removalWaiting(notice):
            libraryRemovalNotice = notice
        }
    }

    func handleEjectOutcome(_ outcome: RemovableEjectOutcome, for intent: CatalogMutationIntent) {
        guard case let .ejectRemovableSource(root) = intent,
              let identity = root.deviceIdentity
        else {
            return
        }
        clearEjectingSourceIdentity(identity)
        switch outcome {
        case .ejected:
            return
        case let .busy(displayName):
            ejectAlertMessage =
                "The disk “\(displayName)” couldn’t be ejected because it’s in use."
        case let .failed(description):
            ejectAlertMessage = description
        }
    }

    /// Whether the selected scope's state has been applied. From a selection intent until
    /// Projection publishes that scope, the pane shows the selected scope waiting
    /// (`detailPane`, DES-118) and draws nothing of the scope left. Every act on the pane's
    /// content still reads this, as a defence for anything that keeps state of the scope
    /// left: the targets (`targetIDs`), the edit controls (`canEdit`), the Info pane's face
    /// acts, drag-out, a stack badge, opening the loupe or compare, the duplicates list's and
    /// the People gallery's acts and the menu bar's person items, the map's stacks and Play
    /// Story.
    var showsSelectedScope: Bool {
        // Before the catalog loads no scope's state has been applied: the empty state's
        // scope is a placeholder, so every scope waits (DES-121).
        parts.isCatalogLoaded && parts.resolvedSidebarSelection == queryDescriptor.scope
    }

    /// What the detail pane draws (DES-118): the selected scope's surface from the click on,
    /// waiting until its state is applied. Its indicator is shown once a frame has been
    /// presented while waiting (`waitingFramePresented()`), never before: a scope whose
    /// state arrives within the frame of the click shows none.
    var detailPane: CatalogDetailPane {
        let scope = queryDescriptor.scope
        guard !showsSelectedScope else {
            return CatalogDetailPane(surface: scope.detailSurface, content: .shown)
        }
        return CatalogDetailPane(
            surface: scope.detailSurface,
            content: .waiting(showsIndicator: waitingFramePresentedScope == scope)
        )
    }

    /// The waiting pane reports that a frame showing it was presented: the selected scope's
    /// state did not arrive within the frame of the click, so its indicator appears. A report
    /// for a scope no longer waited on changes nothing.
    func waitingFramePresented() {
        let scope = queryDescriptor.scope
        guard !showsSelectedScope, waitingFramePresentedScope != scope else {
            return
        }
        waitingFramePresentedScope = scope
        if !parts.isCatalogLoaded, !catalogOpeningFramePresented {
            catalogOpeningFramePresented = true
            OtosLog.ui.noticeOperation("ui.catalogOpening", phase: "shown", fields: [
                "vm": diagnosticID,
                "opening": catalogOpening.diagnosticDescription,
            ])
        }
        OtosLog.ui.noticeOperation("ui.detailPane", phase: "indicator", fields: [
            "vm": diagnosticID,
            "scope": scope.diagnosticDescription,
            "generation": "\(queryGeneration)",
        ])
    }

    /// The All Media row, while two or more fixed libraries exist. Before the catalog has
    /// loaded the sidebar draws no row (APP-044) until a frame has shown the window waiting;
    /// then the rows that stand for the libraries and accounts the open read before updating
    /// show, and only those (DES-121).
    var showsAllMediaRow: Bool {
        sidebarFixedLibraryCount.map(SidebarSelectionPolicy.showsAllMedia(fixedLibraryCount:)) ?? false
    }

    /// How many libraries and accounts the sidebar's fixed rows stand for: the loaded
    /// catalog's, or while it opens, what the open read, once the window has shown it waiting.
    /// Nil while nothing about them may be claimed.
    var sidebarFixedLibraryCount: Int? {
        if parts.isCatalogLoaded {
            return SidebarSelectionPolicy.fixedLibraryCount(libraries: parts.libraries)
        }
        guard !catalogLoadFailed else {
            return nil
        }
        return catalogOpeningStatus?.memberRootCount
    }

    /// The opening status the waiting pane draws (DES-121), nil when it draws none.
    var catalogOpeningPresentation: CatalogOpeningPresentation? {
        catalogOpeningStatus.map { CatalogOpeningPresentation(opening: $0, failed: catalogLoadFailed) }
    }

    /// What the window says while its catalog opens (DES-121): nil once it has loaded, and
    /// until a frame has been presented without it, so an open the first frame outlasts is
    /// the only one that shows anything.
    var catalogOpeningStatus: CatalogOpening? {
        guard !parts.isCatalogLoaded, catalogOpeningFramePresented else {
            return nil
        }
        return catalogOpening
    }

    func currentSelectionWasRemoved(in nextState: CatalogWindowState) -> Bool {
        switch queryDescriptor.scope {
        case let .library(path):
            !nextState.libraries.contains { $0.path == path }
                && !nextState.removableSources.contains { $0.path == path }
        case let .importBatch(batchID):
            !nextState.importBatches.contains { $0.batchID == batchID }
        case .places, .mapArea, .mapStack, .onThisDay:
            !SidebarSelectionPolicy.showsPlaces(libraries: nextState.libraries)
        case let .duplicateGroup(group):
            // The group is gone — resolved, or its copies moved — so its leaf is too. Groups
            // not built yet say nothing about it.
            nextState.duplicates.map { !$0.groups.contains { $0.id == group } } ?? false
        case .duplicates, .people, .person:
            // Stays while selected, empty or not (ADR 0042, ADR 0047), while libraries exist.
            !SidebarSelectionPolicy.showsPlaces(libraries: nextState.libraries)
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
    static let searchLanguagesDefaultsKey = "search.languages"
    static let findsDuplicatesAcrossLibrariesDefaultsKey = "duplicates.acrossLibraries"
    static let showsRawPairsAsOneDefaultsKey = "stacks.rawPairsAsOne"
    static let dismissedCameraBannersDefaultsKey = "dismissedCameraConnectionBannerIdentities"
    static let foldedInfoSectionsDefaultsKey = "infoPane.foldedSections"
    static let foldedEditSectionsDefaultsKey = "editPanel.foldedSections"

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

    /// Folds the Info pane's `section`, or opens it when folded, and persists the folded set.
    func toggleInfoSectionFold(_ section: PhotoInfo.SectionID) {
        foldedInfoSections.formSymmetricDifference([section])
        preferences.set(Self.storedFolds(foldedInfoSections), forKey: Self.foldedInfoSectionsDefaultsKey)
    }

    /// Folds the Edit pane's `section`, or opens it when folded, and persists the folded set.
    func toggleEditSectionFold(_ section: EditSection) {
        foldedEditSections.formSymmetricDifference([section])
        preferences.set(Self.storedFolds(foldedEditSections), forKey: Self.foldedEditSectionsDefaultsKey)
    }

    /// The stored form: the sections' names, sorted, comma-separated.
    private static func storedFolds(_ folded: Set<some RawRepresentable<String>>) -> String {
        folded.map(\.rawValue).sorted().joined(separator: ",")
    }

    /// The folded sections a stored value names; a name no section has any more is dropped.
    static func foldedSections<Section: RawRepresentable<String> & Hashable>(stored: String?) -> Set<Section> {
        Set((stored ?? "").split(separator: ",").compactMap { Section(rawValue: String($0)) })
    }

    /// A no-op re-dismiss does not re-persist, matching `setGridColumnCount`'s pattern.
    func dismissCameraConnectionBanner(_ identity: DeviceIdentity) {
        guard !dismissedCameraBannerIdentities.contains(identity) else {
            return
        }
        dismissedCameraBannerIdentities.insert(identity)
        preferences.set(
            dismissedCameraBannerIdentities.sorted().map(\.rawValue).joined(separator: "\n"),
            forKey: Self.dismissedCameraBannersDefaultsKey
        )
    }
}
