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
        case .loadingCatalog:
            // Never drawn: `MediaGridView` shows nothing while the catalog loads.
            ""
        case .noMedia:
            "No Media"
        case .noLocatedMedia:
            "No Located Media"
        case .nothingOnThisDay:
            "Nothing on This Day"
        case .noFilterMatches:
            "No Matching Media"
        case let .noSearchResults(text, _):
            "No Results for \u{201C}\(text)\u{201D}"
        case let .searchFailed(text):
            "Couldn\u{2019}t Search for \u{201C}\(text)\u{201D}"
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
        case .cardReading:
            "Reading Card"
        case .catalogIncompatible:
            "Catalog Incompatible"
        }
    }

    var message: String {
        switch self {
        case .loadingCatalog:
            ""
        case .noMedia:
            "Add a library with media files to begin."
        case .noLocatedMedia:
            "Photos and videos with location information appear here as they are cataloged."
        case let .nothingOnThisDay(day):
            OnThisDayPresentation.emptyMessage(day)
        case .noFilterMatches:
            "No media in this scope matches the active filters."
        case let .noSearchResults(_, stillReading) where stillReading > 0:
            "Otos is still reading \(stillReading.formatted()) \(stillReading == 1 ? "item" : "items") for search. They appear here if they match."
        case .noSearchResults:
            "Check the spelling or try a new search."
        case .searchFailed:
            "Otos tries again on its own. The results appear here when it succeeds."
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
            For faster browsing and import, insert the memory card directly or use the camera’s Mass Storage USB mode.
            """
        case let .cardReading(name):
            "Reading items from \(name). They appear here as they are found."
        case let .catalogIncompatible(problem):
            problem.errorDescription
        }
    }

    var systemImage: String {
        switch self {
        case .loadingCatalog:
            ""
        case .noMedia:
            "photo.on.rectangle"
        case .noLocatedMedia:
            "map"
        case .nothingOnThisDay:
            "calendar"
        case .noFilterMatches:
            "line.3.horizontal.decrease.circle"
        case .noSearchResults:
            "magnifyingglass"
        case .searchFailed:
            "exclamationmark.magnifyingglass"
        case .checkingLibraries, .libraryChecking:
            "externaldrive.badge.timemachine"
        case .noAvailableMedia, .libraryUnavailable:
            "externaldrive.badge.questionmark"
        case .deviceEnumerating:
            "camera.metering.matrix"
        case .cardReading:
            "sdcard"
        case .catalogIncompatible:
            "exclamationmark.triangle"
        }
    }

    var isProgressing: Bool {
        switch self {
        case .deviceEnumerating, .cardReading:
            true
        default:
            false
        }
    }
}
