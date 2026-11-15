import Foundation

// Window-state model guide
//
// Projection builds these values away from the MainActor and the ViewModel assigns
// them to SwiftUI. They describe the final UI state only: fixed/removable row
// groups, resolved sidebar scope, visible IDs, empty-state meaning, filter options,
// and optional selected-camera guidance. Views should render these values instead
// of re-querying or re-deriving catalog truth.

/// Why the media browser is empty. Projection chooses the reason so the view
/// can stay declarative and avoid re-deriving catalog state in `body`.
nonisolated enum CatalogMediaEmptyState: Equatable {
    /// The catalog's first load has not finished, so whether there is any media is
    /// not known yet. Nothing is claimed: the grid draws nothing (APP-044).
    case loadingCatalog
    case noMedia
    /// The Places scope holds nothing: no cataloged item in the fixed libraries carries
    /// a location yet (ADR 0040).
    case noLocatedMedia
    /// The On This Day scope holds nothing: no item in the fixed libraries was captured on
    /// this day's month and day in an earlier year, nor on its day of the month in an
    /// earlier month (ADR 0049).
    case nothingOnThisDay(CalendarDay)
    case noFilterMatches
    /// A search matched nothing in a scope that holds items (ADR 0048). Carries the text and
    /// how many items search has not read yet, which may still match.
    case noSearchResults(String, stillReading: Int)
    /// A search whose query could not be read, in a scope that holds items (ADR 0048): the
    /// grid holds this rather than the scope unsearched, until a reading succeeds. Carries the
    /// text.
    case searchFailed(String)
    case checkingLibraries
    case noAvailableMedia
    case libraryChecking
    case libraryUnavailable
    case deviceEnumerating(String)
    /// A card is being scanned and nothing on it has been seen yet: its items appear as
    /// the scan reaches them (ADR 0013), so it is neither empty nor done.
    case cardReading(String)
    /// Catalog file was written by a newer or unrecognized Otos; nothing is
    /// loaded. Carries the typed compatibility result, not a pre-rendered
    /// string — `CatalogMediaEmptyStatePresentation.message` is the one place
    /// that decides its wording, so a lower layer can't commit to
    /// user-facing prose before the mapper ever sees it, the same class of
    /// defect `ImportBarPresentation.swift`'s honest-cause naming fixed for
    /// Failed.
    case catalogIncompatible(CatalogSchemaCompatibility)

    var diagnosticDescription: String {
        switch self {
        case .loadingCatalog:
            "loadingCatalog"
        case .noMedia:
            "noMedia"
        case .noLocatedMedia:
            "noLocatedMedia"
        case .nothingOnThisDay:
            "nothingOnThisDay"
        case .noFilterMatches:
            "noFilterMatches"
        case let .noSearchResults(_, stillReading):
            "noSearchResults stillReading=\(stillReading)"
        case .searchFailed:
            "searchFailed"
        case .checkingLibraries:
            "checkingLibraries"
        case .noAvailableMedia:
            "noAvailableMedia"
        case .libraryChecking:
            "libraryChecking"
        case .libraryUnavailable:
            "libraryUnavailable"
        case .deviceEnumerating:
            "deviceEnumerating"
        case .cardReading:
            "cardReading"
        case .catalogIncompatible:
            "catalogIncompatible"
        }
    }
}

/// Where a shown search's query stands (ADR 0048, DES-108). Projection publishes it; the
/// window renders it and derives nothing.
nonisolated enum CatalogSearchPhase: Equatable {
    /// The query is being read: the state is the last one shown, kept, and the window says
    /// it is searching. Nothing ends this but the reader's report that the reading ended.
    case reading
    /// Read: the grid holds the matches, or `noSearchResults` when none matched.
    case read
    /// The query could not be read: the grid holds `searchFailed`, never the scope
    /// unsearched, until a reading succeeds.
    case failed
}

nonisolated struct CatalogDeviceConnectionBanner: Equatable {
    let identity: DeviceIdentity
    let message: String
}

/// A pane that draws a scope in place of the media grid.
nonisolated enum CatalogDetailSurface: String, Equatable {
    case people
    case duplicates
    case onThisDay
    case placesMap
}

nonisolated extension SidebarSelection {
    /// The pane that draws this scope in place of the media grid; nil where the grid does.
    var detailSurface: CatalogDetailSurface? {
        switch self {
        case .people: .people
        case .duplicates: .duplicates
        case .onThisDay: .onThisDay
        case .places: .placesMap
        case .allMedia, .library, .mapArea, .mapStack, .importBatch, .allImports, .person, .duplicateGroup: nil
        }
    }
}

/// What the detail pane shows (DES-118): always the scope the sidebar has selected — its
/// surface, title and bar from the click on — and whether that scope's state has been
/// applied. Until it has, the pane draws the surface's bar with what is known without the
/// scope's read and nothing of the scope left; the one indeterminate indicator appears once
/// a frame has been presented without the state, so a scope whose state arrives within the
/// frame of the click never shows one.
nonisolated struct CatalogDetailPane: Equatable {
    enum Content: Equatable {
        /// The selected scope's state is applied: the pane draws it.
        case shown
        /// The selected scope's state has not been applied yet.
        case waiting(showsIndicator: Bool)
    }

    /// The pane the selected scope is drawn in; nil for the media browser.
    let surface: CatalogDetailSurface?
    let content: Content

    /// Whether the pane draws `surface` with its scope's state.
    func shows(_ surface: CatalogDetailSurface) -> Bool {
        self.surface == surface && content == .shown
    }
}

/// Final UI-ready catalog state.
nonisolated struct CatalogWindowState: Equatable {
    var title: String
    var libraries: [CatalogLibraryState]
    var removableSources: [CatalogLibraryState]
    /// Nonempty import batches newest-first (sidebar Imports section).
    var importBatches: [ImportBatchSummary] = []
    var mediaGrid: CatalogMediaGridState
    var filterOptions: CatalogFilterOptions
    var resolvedSidebarSelection: SidebarSelection
    /// What the window says about its empty scope; nil while the scope holds items.
    var mediaEmptyState: CatalogMediaEmptyState?
    var deviceConnectionBanner: CatalogDeviceConnectionBanner?
    /// The Places map's content: the located items in display order and the count left
    /// off the map. Set only while the resolved scope is `.places` (ADR 0040).
    var map: CatalogMapState?
    /// On This Day's anniversaries in play order. Set only while the resolved scope is
    /// `.onThisDay` (ADR 0049).
    var onThisDay: CatalogOnThisDayState?
    /// Duplicate groups across the fixed libraries (ADR 0042), in every scope: the sidebar's
    /// Duplicates row exists while any group is active, and the list draws under `.duplicates`.
    /// Nil until Projection has built them once: they are built after the rest of the
    /// window state is published, so detection never holds back the sidebar or the grid.
    var duplicates: CatalogDuplicatesState?
    /// People (ADR 0047): the gallery and the unchecked tally, from
    /// `PeopleAssignment`; nil until the first build. Like the duplicate groups, the same in
    /// every scope.
    var people: CatalogPeopleState?
    /// Where the shown search stands (ADR 0048); nil while nothing is searched.
    var searchPhase: CatalogSearchPhase?
    var queryGeneration: UInt64 = 0
    /// Remaps committed but not yet acknowledged by the window, read with the ordered
    /// IDs. The window applies each batch once, before it shows the new identities.
    var pendingIdentityRemaps: [CatalogIdentityRemapBatch] = []

    var queryDescriptor: CatalogQueryDescriptor {
        mediaGrid.descriptor
    }

    /// Whether the catalog's first load has applied; before it the window claims nothing
    /// about the catalog (APP-044).
    var isCatalogLoaded: Bool {
        mediaEmptyState != .loadingCatalog
    }

    /// The pane that draws this state's scope in place of the media grid; nil where the grid
    /// does.
    var detailSurface: CatalogDetailSurface? {
        resolvedSidebarSelection.detailSurface
    }

    /// Whether `detailSurface` has what it draws: the People gallery and the duplicates list
    /// claim nothing until their owners first build (APP-044); the map and On This Day draw
    /// the state they are given.
    var detailSurfaceHasContent: Bool {
        switch detailSurface {
        case .people: people != nil
        case .duplicates: duplicates != nil
        case .onThisDay, .placesMap: true
        case nil: false
        }
    }

    /// This state as Projection publishes it after `previous`: every library-sized part
    /// equal to `previous`'s is `previous`'s own — the grid's content, the map, On This Day,
    /// the duplicate groups, People, the filter's options and the import batches — and the
    /// grid's position index is built. The comparing is done here, off the main actor, once;
    /// the window then tells an unchanged part by identity (`sharesContent(with:)`, and the
    /// standard collections' own identity check behind `==`), so applying a publication
    /// costs in what changed (ADR 0005).
    func sharingUnchanged(with previous: CatalogWindowState?) -> CatalogWindowState {
        var shared = self
        if let previous {
            shared.mediaGrid = mediaGrid.sharingContent(of: previous.mediaGrid)
            if map == previous.map {
                shared.map = previous.map
            }
            if onThisDay == previous.onThisDay {
                shared.onThisDay = previous.onThisDay
            }
            if duplicates == previous.duplicates {
                shared.duplicates = previous.duplicates
            }
            if people == previous.people {
                shared.people = previous.people
            }
            if filterOptions == previous.filterOptions {
                shared.filterOptions = previous.filterOptions
            }
            if importBatches == previous.importBatches {
                shared.importBatches = previous.importBatches
            }
        }
        shared.mediaGrid.content.prepareIndex()
        return shared
    }

    /// This state without `hidden`, the items a Move to Trash took off the window before the
    /// Store's mark (`CatalogProjection.hide(_:batch:)`): out of the grid's order with their
    /// day buckets and stacks, off the map, out of On This Day's runs and out of the duplicate
    /// groups, where a group left with one copy is resolved. Costs in what it removes past
    /// one walk of each part that holds one of them; a part that holds none is this state's
    /// own, so a state holding none of them is returned as it is. A person's photo count and
    /// the filter's counts keep their last read until the read of the mark.
    func hidingItems(_ hidden: Set<MediaAssetID>) -> CatalogWindowState {
        guard !hidden.isEmpty else {
            return self
        }
        var shown = self
        shown.mediaGrid = mediaGrid.hiding(hidden)
        if let map, map.located.contains(where: { hidden.contains($0.id) }) {
            shown.map = CatalogMapState(located: map.located.filter { !hidden.contains($0.id) })
        }
        if let onThisDay, !mediaGrid.sharesContent(with: shown.mediaGrid) {
            shown.onThisDay = onThisDay.keeping(shown.mediaGrid.orderedAssetIDs, from: mediaGrid.content, hidden: hidden)
        }
        if let duplicates {
            shown.duplicates = duplicates.hiding(hidden)
        }
        return shown
    }

    /// What the window shows before the catalog has loaded: no title, no sources, no
    /// items, and no claim about whether media exists (APP-044).
    static let empty = CatalogWindowState(
        title: "",
        libraries: [],
        removableSources: [],
        importBatches: [],
        mediaGrid: .empty,
        filterOptions: .empty,
        resolvedSidebarSelection: .allMedia,
        mediaEmptyState: .loadingCatalog,
        deviceConnectionBanner: nil
    )
}
