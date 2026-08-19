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
    case noMedia
    case noFilterMatches
    case checkingLibraries
    case noAvailableMedia
    case libraryChecking
    case libraryUnavailable
    case deviceEnumerating(String)
    /// Catalog file was written by a newer or unrecognized Otos; nothing is
    /// loaded. Carries the typed compatibility result, not a pre-rendered
    /// string — `message` below is the one place that decides its wording,
    /// so a lower layer can't commit to user-facing prose before the mapper
    /// ever sees it (plan 0095 D-16-adjacent, the same class of defect
    /// `ImportBarPresentation.swift`'s honest-cause naming fixed for Failed).
    case catalogIncompatible(CatalogSchemaCompatibility)

    var diagnosticDescription: String {
        switch self {
        case .noMedia:
            "noMedia"
        case .noFilterMatches:
            "noFilterMatches"
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
        case .catalogIncompatible:
            "catalogIncompatible"
        }
    }
}

nonisolated struct CatalogDeviceConnectionBanner: Equatable {
    let identity: String
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
    var queryGeneration: UInt64 = 0

    var queryDescriptor: CatalogQueryDescriptor {
        mediaGrid.descriptor
    }

    static let empty = CatalogWindowState(
        title: "All Media",
        libraries: [],
        removableSources: [],
        importBatches: [],
        mediaGrid: .empty,
        filterOptions: .empty,
        resolvedSidebarSelection: .allMedia,
        mediaEmptyState: .noMedia,
        deviceConnectionBanner: nil
    )
}
