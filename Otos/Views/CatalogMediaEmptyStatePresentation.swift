import Foundation

/// Pure display mapper for `CatalogMediaEmptyState`, beside `MediaGridView` the
/// same way `ImportBarPresentation.swift` sits beside `ImportPlanFooter.swift`:
/// the model enum (`Otos/Models/CatalogWindowState.swift`) carries the fact,
/// this file is the one place that decides its wording. `.catalogIncompatible`
/// carries the typed `CatalogSchemaCompatibility` rather than a pre-rendered
/// string specifically so this mapper — not a lower layer — owns the moment
/// that value becomes user-facing prose.
extension CatalogMediaEmptyState {
    var title: String {
        switch self {
        case .noMedia:
            "No Media"
        case .noFilterMatches:
            "No Matching Media"
        case .checkingLibraries:
            "Checking Libraries"
        case .noAvailableMedia:
            "No Available Media"
        case .libraryChecking:
            "Checking Library"
        case .libraryUnavailable:
            "Library Unavailable"
        case .deviceEnumerating:
            "Reading Items"
        case .catalogIncompatible:
            "Catalog Incompatible"
        }
    }

    var message: String {
        switch self {
        case .noMedia:
            "Add a library with media files to begin."
        case .noFilterMatches:
            "No media in this scope matches the active filters."
        case .checkingLibraries:
            "Otos is checking whether saved library folders are reachable."
        case .noAvailableMedia:
            "Cataloged media exists, but its libraries are not currently reachable."
        case .libraryChecking:
            "Otos is checking whether the selected library folder is reachable."
        case .libraryUnavailable:
            "The selected library folder is not currently reachable."
        case let .deviceEnumerating(name):
            """
            Reading items from \(name). This can take several minutes on this connection. \
            For faster browsing and import, insert the memory card directly or use the camera's Mass Storage USB mode.
            """
        case let .catalogIncompatible(problem):
            problem.errorDescription
        }
    }

    var systemImage: String {
        switch self {
        case .noMedia:
            "photo.on.rectangle"
        case .noFilterMatches:
            "line.3.horizontal.decrease.circle"
        case .checkingLibraries, .libraryChecking:
            "externaldrive.badge.timemachine"
        case .noAvailableMedia, .libraryUnavailable:
            "externaldrive.badge.questionmark"
        case .deviceEnumerating:
            "camera.metering.matrix"
        case .catalogIncompatible:
            "exclamationmark.triangle"
        }
    }

    var isProgressing: Bool {
        if case .deviceEnumerating = self {
            return true
        }
        return false
    }
}
