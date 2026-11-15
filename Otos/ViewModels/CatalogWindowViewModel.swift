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
    /// draws the batch's row: the run names its batch once the batch's first item is in the
    /// catalog, but the row exists only once Projection publishes it, which can be after the
    /// run has finished and stopped naming it.
    var importBatchesAwaitingTheirRow: [ImportBatchID: LibraryRootPath] = [:]
    /// Batches this window has already moved the user into (or declined to, because the
    /// user was elsewhere when the batch row first existed). A run moves the selection
    /// once; a user who goes back to the card is not pulled to the batch again.
    var followedImportBatches: Set<ImportBatchID> = []
    /// The last applied publication. Observed by hand rather than by the macro's tracked
    /// storage: a tracked `Equatable` property compares the old value with the new one on
    /// every set, and a window state's `==` walks every part it holds — on the owner's
    /// catalog the order's 158,000 identities and its stacks, on every enrichment batch, on
    /// the main actor. Projection yields only a state that changed (ADR 0005), so a set is a
    /// change by construction and notifies without comparing.
    var state: CatalogWindowState {
        get {
            access(keyPath: \.state)
            return appliedState
        }
        set {
            withMutation(keyPath: \.state) {
                appliedState = newValue
            }
        }
    }

    @ObservationIgnored private var appliedState: CatalogWindowState = .empty
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
    /// Edit state below is resolved only while the Edit pane is shown.
    var inspectorPane: InspectorPane?
    /// The one still photo the panel edits; nil disables its controls.
    var editTarget: EditTarget?
    /// The panel's values for `editTarget`: the saved recipe plus any change still being
    /// dragged.
    var editDraft = EditRecipe.neutral
    /// The newest live render of the draft, shown in place of the pane's stored preview
    /// until that preview carries the saved edit.
    var editLivePreview: EditLivePreview?
    /// The open target's facts; nil until it has been opened (the controls wait for them).
    var editPhotoFacts: EditPhotoFacts?
    /// The open target's upright full-resolution size, from the decode its edits render
    /// from; nil until it has been opened. Crop geometry and the edited photo's size come
    /// from this, never from the catalog row.
    var editOriginalPixelSize: CGSize?
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
    /// The Add Immich Account sheet while it is open.
    var immichAccountSheet: ImmichAccountSheetState?
    @ObservationIgnored var immichAddRequested: UInt64 = 0
    @ObservationIgnored var exportRequested: UInt64 = 0
    @ObservationIgnored var exportCancelledThrough: UInt64 = 0
    @ObservationIgnored var submittedExportCount = 0
    @ObservationIgnored var handledExportCount = 0
    /// The latest request for the loupe's player to show its trim UI.
    var videoTrimCommand: VideoTrimCommand?
    @ObservationIgnored var videoTrimGeneration: UInt64 = 0
    /// An edit value field holds the keyboard: the Edit menu's text commands act on it.
    var isEnteringEditValue = false
    /// The white balance picker is armed: the next loupe click picks a neutral point.
    var isPickingNeutral = false
    /// View ▸ Show Original (\\): the loupe shows the photo without its edit until it is
    /// turned off, the photo changes, or an edit is made.
    var isShowingOriginal = false
    /// The open photo rendered without its edit, for Show Original.
    var editOriginalPreview: EditLivePreview?
    /// The adjustment the keyboard acts on: chosen with , and . (Select Previous and Next
    /// Adjustment) and moved with = and − (Increase and Decrease Adjustment).
    var selectedEditControl: EditControl?
    /// The histogram of the photo the panel edits, as last rendered (DES-100).
    var editHistogram: EditHistogram?
    /// The crop tool is on: the loupe shows the whole frame with the crop over it.
    var isCropping = false
    /// The crop tool's straighten line is armed: the next drag on the canvas draws it.
    var isDrawingStraightenLine = false
    /// The photo edited with everything but its crop, which the crop tool draws over.
    var editCropBase: EditLivePreview?
    /// The crop tool's aspect choice and which way it stands; tool state, not saved.
    var cropAspect = CropAspect.free
    /// Which way the constrained aspect stands, once Rotate Aspect has said so; nil follows
    /// the crop's own shape (`cropAspectIsLandscape`), decided only once the frame is known.
    var cropAspectLandscapeChoice: Bool?
    /// What Auto straighten would do for the photo the panel edits; nil until it is known.
    var editAutoLevel: AutoLevelReading?
    /// The suggested crop of the frame last read; nil until one is known.
    var editAutoCrop: AutoCropReading?
    @ObservationIgnored var isDraggingCrop = false
    /// The saved edit. Every change to it can move the frame the suggested crop was read
    /// from, so it asks for a new reading (`requestEditAnalysis`).
    @ObservationIgnored var editSavedRecipe = EditRecipe.neutral {
        didSet { requestEditAnalysis() }
    }

    @ObservationIgnored var editDraggingControl: EditControl?
    @ObservationIgnored var editTargetTask: Task<Void, Never>?
    /// The photo `editTargetTask` is reading, while it runs.
    @ObservationIgnored var editTargetRequestedID: MediaAssetID?
    @ObservationIgnored let liveEditRenderer = LiveEditRenderer()
    @ObservationIgnored let editRenderStream: AsyncStream<EditRenderRequest>
    @ObservationIgnored let editRenderContinuation: AsyncStream<EditRenderRequest>.Continuation
    @ObservationIgnored var editRenderTask: Task<Void, Never>?
    @ObservationIgnored var editRenderRequested: UInt64 = 0
    @ObservationIgnored var editRenderPublished: UInt64 = 0
    @ObservationIgnored var editHistogramPublished: UInt64 = 0
    @ObservationIgnored let editCommandStream: AsyncStream<EditLaneCommand>
    @ObservationIgnored let editCommandContinuation: AsyncStream<EditLaneCommand>.Continuation
    @ObservationIgnored var editCommandTask: Task<Void, Never>?
    /// Readings of the photo for Auto straighten and Auto crop: newest-wins, since only the
    /// current frame's matters.
    @ObservationIgnored let editAnalysisStream: AsyncStream<EditAnalysisRequest>
    @ObservationIgnored let editAnalysisContinuation: AsyncStream<EditAnalysisRequest>.Continuation
    @ObservationIgnored var editAnalysisTask: Task<Void, Never>?
    /// The reading last asked for, so an unchanged frame is not read again.
    @ObservationIgnored var editAnalysisRequested: EditAnalysisRequest?
    /// Submitted and fully handled edit commands — saved, rendered and applied, or
    /// refused — so a caller can wait for an edit to settle without guessing a duration.
    @ObservationIgnored var submittedEditCommandCount = 0
    @ObservationIgnored var handledEditCommandCount = 0
    var photoInfo: PhotoInfo?
    @ObservationIgnored var photoInfoTask: Task<Void, Never>?
    @ObservationIgnored var faceCandidatesTask: Task<Void, Never>?
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
    @ObservationIgnored private let queryStream: AsyncStream<CatalogQueryRequest>
    @ObservationIgnored private let queryContinuation: AsyncStream<CatalogQueryRequest>.Continuation
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
    /// The plan the confirmation dialog shows, or nil when it is not shown. Confirming
    /// runs exactly this library at exactly this revision.
    var reorganizationConfirmation: ReorganizationConfirmation?
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

    @ObservationIgnored private var stateConsumptionTask: Task<Void, Never>?
    @ObservationIgnored private var catalogStartupTask: Task<Void, Never>?
    @ObservationIgnored private var queryForwardingTask: Task<Void, Never>?
    @ObservationIgnored private var mutationForwardingTask: Task<Void, Never>?
    @ObservationIgnored var mediaChoiceForwardingTask: Task<Void, Never>?
    @ObservationIgnored var stackKeyForwardingTask: Task<Void, Never>?
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
    var loupeVideoState: LoupeVideoState?
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
        catalogProjection: CatalogProjection = CatalogProjection(),
        enrichmentCoordinator: EnrichmentCoordinator? = nil,
        metadataRefresher: MetadataRefresher? = nil,
        immichAccounts: ImmichAccounts? = nil,
        stallMonitor: MainRunLoopStallMonitor = MainRunLoopStallMonitor(),
        startsStallMonitor: Bool = true,
        startsEnrichment: Bool = true,
        startsSourceMonitoring: Bool = true,
        preferencesDomain: PreferencesDomain,
        previewLoader: (any PreviewLoading)? = nil,
        videoLoader: VideoPreviewLoader? = nil,
        workspace: any WorkspaceOpening = LaunchServicesWorkspace(),
        calendarDayReader: @escaping @Sendable () -> CalendarDay = { CalendarDay.today() },
        calendarNotificationCenter: NotificationCenter = .default,
        tileContentStore: TileContentStore = TileContentStore(),
        volumeCapacity: @escaping VolumeCapacityReader,
        trashFiles: MediaTrashCoordinator.FileOperations
    ) {
        self.volumeCapacity = volumeCapacity
        self.workspace = workspace
        self.tileContentStore = tileContentStore
        self.calendarDayReader = calendarDayReader
        self.calendarNotificationCenter = calendarNotificationCenter
        today = calendarDayReader()
        // Curation undo entries are registered from store completions, outside any
        // AppKit event; groups are opened and closed explicitly (APP-039).
        windowUndoManager.groupsByEvent = false
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
        // A live render is newest-wins; a save is a command that must survive in order.
        let (editRenderStream, editRenderContinuation) = AsyncStream<EditRenderRequest>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let (editCommandStream, editCommandContinuation) = AsyncStream<EditLaneCommand>.makeStream(
            bufferingPolicy: .unbounded
        )
        let (editAnalysisStream, editAnalysisContinuation) = AsyncStream<EditAnalysisRequest>.makeStream(
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
        searchLanguages = SearchLanguages.resolved(
            stored: preferences.object(forKey: Self.searchLanguagesDefaultsKey) as? [String],
            systemPreferred: Locale.preferredLanguages
        )
        let storedDismissedIdentities = preferences.string(forKey: Self.dismissedCameraBannersDefaultsKey)
        dismissedCameraBannerIdentities = Set(
            (storedDismissedIdentities ?? "").split(separator: "\n").map { DeviceIdentity(rawValue: String($0)) }
        )
        importPreferences = ImportPreferencesStore.load(defaults: preferences)
        exportSettings = ExportSettingsStore.load(defaults: preferences)
        self.catalogStore = catalogStore
        self.catalogProjection = catalogProjection
        mediaTileDetailReader = MediaTileDetailReader(store: catalogStore)
        let deviceStagingRegistry = DeviceStagingRegistry()
        self.deviceStagingRegistry = deviceStagingRegistry
        let immichAccounts = immichAccounts ?? (startsEnrichment ? ImmichAccounts(store: catalogStore, volumeCapacity: volumeCapacity) : nil)
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
            volumeCapacity: volumeCapacity
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
            ? PhotoSearchIndex(
                store: catalogStore,
                thumbnailDirectory: catalogStore.thumbnailDirectory,
                bundle: Bundle(for: CatalogWindowViewModel.self)
            )
            : nil
        photoDescriptionWriter = startsEnrichment && enrichmentCoordinator == nil
            ? PhotoDescriptionWriter(
                store: catalogStore,
                searchIndex: photoSearchIndex,
                thumbnailDirectory: catalogStore.thumbnailDirectory,
                describe: PhotoDescriber.live
            )
            : nil
        anniversaryTitleWriter = photoDescriptionWriter.map { writer in
            AnniversaryTitleWriter(store: catalogStore, descriptions: writer, writeTitle: AnniversaryTitler.live)
        }
        self.stallMonitor = stallMonitor
        self.startsStallMonitor = startsStallMonitor
        self.startsEnrichment = startsEnrichment
        self.startsSourceMonitoring = startsSourceMonitoring
        if let previewLoader {
            self.previewLoader = previewLoader
        } else {
            self.previewLoader = PreviewImageLoader(
                derivedImageDirectory: catalogStore.thumbnailDirectory,
                materializationRequester: materializationCoordinator
            )
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
        self.editRenderStream = editRenderStream
        self.editRenderContinuation = editRenderContinuation
        self.editCommandStream = editCommandStream
        self.editCommandContinuation = editCommandContinuation
        self.editAnalysisStream = editAnalysisStream
        self.editAnalysisContinuation = editAnalysisContinuation
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
    }

    isolated deinit {
        // Cancel consumers before finishing their producers. Finishing normally
        // drains buffered AsyncStream values; cancellation prevents queued
        // mutations from starting after the ViewModel's ownership has ended.
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
        stateConsumptionTask?.cancel()
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
        queryForwardingTask?.cancel()
        mutationForwardingTask?.cancel()
        mediaChoiceForwardingTask?.cancel()
        stackKeyForwardingTask?.cancel()
        editTargetTask?.cancel()
        editRenderTask?.cancel()
        editCommandTask?.cancel()
        editAnalysisTask?.cancel()
        handOffTask?.cancel()
        exportTask?.cancel()
        immichIntentTask?.cancel()
        immichStatusTask?.cancel()
        mediaTrashTask?.cancel()
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
        placeNameTask?.cancel()
        focusedKindTask?.cancel()
        currentTargetChoiceTask?.cancel()
        viewportForwardingTask?.cancel()
        enrichmentStartTask?.cancel()
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
        queryContinuation.finish()
        mutationContinuation.finish()
        importIntentContinuation.finish()
        mediaTrashIntentContinuation.finish()
        duplicatesIntentContinuation.finish()
        peopleIntentContinuation.finish()
        mediaChoiceContinuation.finish()
        stackKeyContinuation.finish()
        editRenderContinuation.finish()
        editCommandContinuation.finish()
        editAnalysisContinuation.finish()
        handOffContinuation.finish()
        exportContinuation.finish()
        immichIntentContinuation.finish()
        viewportContinuation.finish()
        // The owners below must be told to stop or their own loops would keep them, and
        // the store, alive past this window: the enrichment supervisor strongly retains
        // its coordinator. `shutdown()` is async and teardown cannot await, so one task,
        // which nothing here outlives to own, stops them side by side — an import's
        // shutdown waits for its run, and nothing else should wait behind that.
        // Materialization stops after enrichment, which feeds it.
        let mediaOps = mediaOperationCoordinator
        let mediaTrash = mediaTrashCoordinator
        let enrichment = enrichmentCoordinator
        let materialization = materializationCoordinator
        let refresher = metadataRefresher
        let immich = immichAccounts
        // swiftlint:disable:next unowned_view_model_task
        Task {
            await withDiscardingTaskGroup { group in
                group.addTask { await immich?.shutdown() }
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
        startReadingsRefresh()
        startAnniversaryTitles()
        startFacesReadRefresh()
        // The Store's first command: it compares duplicates as the user chose. A duplicates
        // build that the catalog's load lets run before it is followed by another, since the
        // handoff is a change of which files are copies.
        submitCatalogMutation(.setDuplicatesReach(duplicatesReach))
        startMutationForwarding(store: store, coordinator: enrichmentCoordinator)
        startMediaChoiceForwarding(store: store)
        startStackKeyForwarding(store: store)
        startEditing(store: store)
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
        startCatalog(store: store)
        startMediaTrash()
        startDuplicatesIntentConsumer()
        startPeopleIntentConsumer()
        if startsSourceMonitoring {
            startRemovableVolumeMonitoring()
            startDeviceStagingSweepThenCameraMonitoring()
        }
        startMediaOperationsIfNeeded()
        if startsEnrichment {
            startImmichAccounts(store: store)
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
            generation: queryGeneration,
            expandedStacks: expandedStacks
        ))
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
        queryContinuation.yield(CatalogQueryRequest(
            descriptor: queryDescriptor,
            generation: queryGeneration,
            expandedStacks: stacks
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
        enrichmentStartTask = Task { [
            coordinator, materializationCoordinator, metadataRefresher, renderSignatureRefresher, previewFaceReader, photoSearchIndex,
            placeNameReader, photoDescriptionWriter, store = catalogStore
        ] in
            do {
                try await store.start()
            } catch {
                OtosLog.persistence.error("Enrichment startup skipped because catalog start failed")
                return
            }
            await materializationCoordinator.start()
            await coordinator.start()
            await renderSignatureRefresher?.start()
            await previewFaceReader?.start()
            await placeNameReader?.start()
            await photoSearchIndex?.start()
            await photoDescriptionWriter?.start()
            await metadataRefresher?.refresh()
        }
    }

    private func startQueryForwarding(projection: CatalogProjection) {
        queryForwardingTask = Task { [projection, queryStream, photoSearchIndex] in
            // Before the first request, so no search reaches a projection without its index.
            if let photoSearchIndex {
                await projection.attachSearchIndex(photoSearchIndex)
            }
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
            gridSelection = gridSelection.pruned(to: nextState.mediaGrid.content)
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
        OtosLog.ui.noticeOperation("launch.firstGrid", phase: "applied", fields: [
            "ms": "\(DiagnosticsTiming.milliseconds(since: launchStartedAt))",
            "catalogMs": catalogLoadedMs.map { "\($0)" } ?? "unknown",
            "applyMs": "\(applyMs)",
            "items": "\(items)",
            "scope": state.resolvedSidebarSelection.diagnosticDescription,
            "emptyState": state.mediaEmptyState?.diagnosticDescription ?? "none",
        ])
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
            options: state.filterOptions
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
        guard let language = state.filterOptions.placeNameLanguage ?? filter.places?.language else {
            return
        }
        let towns = state.filterOptions.countries.first { $0.name == place.country }?.towns ?? []
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

    /// The window's title, the one every scope is named by: the person a person's photos
    /// show, else the title Projection published for the scope shown
    /// (`CatalogWindowPolicy.title(for:libraries:)`).
    var windowTitle: String {
        shownPerson?.displayName ?? state.title
    }

    /// The window's subtitle, under its title (DES-012 L3, DES-034): `Filtered` while a filter
    /// narrows the scope, so a scope that looks short is never mistaken for the whole of it
    /// (DES-029: never the filter glyph's color alone), and `Searching…` while the search's
    /// query is being read and the window keeps what it showed (ADR 0048). The duplicates
    /// list and People ignore the filter, so they never claim to be filtered.
    var windowSubtitle: String {
        let filtered = queryDescriptor.filter.isActive && !showsDuplicatesList && !showsPeopleList
        let searching = state.searchPhase == .reading && queryDescriptor.search != nil
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
                "The disk \"\(displayName)\" couldn't be ejected because it's in use."
        case let .failed(description):
            ejectAlertMessage = description
        }
    }

    /// Whether the pane shows the scope the sidebar has selected. From a selection intent
    /// until Projection publishes that scope, the pane still shows the scope the user left;
    /// nothing on it is the user's to act on, because one user action acts on the scope the
    /// user sees selected. Every act on the pane's content reads this: the targets
    /// (`targetIDs`), the edit controls (`canEdit`), the Info pane's face acts, drag-out, a
    /// stack badge, opening the loupe or compare, the duplicates list's and the People
    /// gallery's acts and the menu bar's person items, the map's stacks and Play Story. How
    /// the pane looks meanwhile is unchanged: no design rule covers it.
    var showsSelectedScope: Bool {
        state.resolvedSidebarSelection == queryDescriptor.scope
    }

    /// The All Media row, while two or more fixed libraries exist. The sidebar draws no row
    /// before the catalog has loaded: a lone row would read as the whole sidebar (APP-044).
    var showsAllMediaRow: Bool {
        state.isCatalogLoaded && SidebarSelectionPolicy.showsAllMedia(libraries: state.libraries)
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
