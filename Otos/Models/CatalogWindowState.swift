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
    case noFilterMatches
    /// A search matched nothing in a scope that holds items (ADR 0048). Carries the text and
    /// how many items search has not read yet, which may still match.
    case noSearchResults(String, stillReading: Int)
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
        case .noFilterMatches:
            "noFilterMatches"
        case let .noSearchResults(_, stillReading):
            "noSearchResults stillReading=\(stillReading)"
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

nonisolated struct CatalogDeviceConnectionBanner: Equatable {
    let identity: DeviceIdentity
    let message: String
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
    var mediaEmptyState: CatalogMediaEmptyState
    var deviceConnectionBanner: CatalogDeviceConnectionBanner?
    /// The Places map's content: the located items in display order and the count left
    /// off the map. Set only while the resolved scope is `.places` (ADR 0040).
    var map: CatalogMapState?
    /// Duplicate groups across the fixed libraries (ADR 0042), in every scope: the sidebar's
    /// Duplicates row exists while any group is active, and the list draws under `.duplicates`.
    /// Nil until Projection has built them once: they are built after the rest of the
    /// window state is published, so detection never holds back the sidebar or the grid.
    var duplicates: CatalogDuplicatesState?
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
