import Foundation

/// Sidebar selection policy guide
///
/// Pure rules for which sidebar row should be selected and whether the All Media
/// aggregate row exists. `CatalogWindowViewModel` applies these rules when projected
/// sources change; `CatalogWindowPolicy` uses them when resolving invalid scopes.
/// This type has no side effects and is fully unit-tested without SwiftUI.
nonisolated enum SidebarSelectionPolicy {
    /// Whether the "All Media" aggregate row/selection should exist.
    /// True iff there are 2+ fixed libraries. All Media never includes removables.
    static func showsAllMedia(libraries: [CatalogLibraryState]) -> Bool {
        fixedLibraries(in: libraries).count >= 2
    }

    /// Selection at launch or when no explicit user sidebar choice is in effect.
    /// Priority: connected removable/camera (most-recently attached) → single library → All Media.
    static func defaultSelection(
        libraries: [CatalogLibraryState],
        removableSources: [CatalogLibraryState]
    ) -> SidebarSelection {
        if let removable = mostRecentlyAttachedConnectedSource(in: removableSources) {
            return .library(removable.path)
        }
        let fixed = fixedLibraries(in: libraries)
        if fixed.count == 1, let library = fixed.first {
            return .library(library.path)
        }
        return .allMedia
    }

    /// When the currently selected source disappears, fall back to `defaultSelection`.
    static func selectionOnSelectedSourceRemoved(
        libraries: [CatalogLibraryState],
        removableSources: [CatalogLibraryState]
    ) -> SidebarSelection {
        defaultSelection(libraries: libraries, removableSources: removableSources)
    }

    /// Removable/camera rows visible in the main-window sidebar (connected only).
    static func sidebarVisibleRemovableSources(_ removableSources: [CatalogLibraryState]) -> [CatalogLibraryState] {
        removableSources.filter(\.isAvailable)
    }

    private static func fixedLibraries(in libraries: [CatalogLibraryState]) -> [CatalogLibraryState] {
        libraries.filter { $0.kind == .library }
    }

    private static func mostRecentlyAttachedConnectedSource(
        in removableSources: [CatalogLibraryState]
    ) -> CatalogLibraryState? {
        sidebarVisibleRemovableSources(removableSources).max { left, right in
            (left.lastSeenAt ?? .distantPast) < (right.lastSeenAt ?? .distantPast)
        }
    }

    // MARK: - Status ownership (`import-bar.md` "Ownership of status")

    /// Whether the import bar is currently on screen for the operation that
    /// produced `presentation` — true exactly when the current selection is
    /// that operation's removable row, the only row the bar is drawn on
    /// (DES-040: one fact, one owner).
    static func barOwnsStatus(
        sidebarSelection: SidebarSelection,
        presentation: MediaOperationSourcePresentation
    ) -> Bool {
        sidebarSelection == .library(presentation.sourcePath)
    }

    /// The removable row's own indicator while its card is being prepared
    /// (states A–B). Once a run executes, its progress is the batch row's
    /// indicator instead — that is where the copied items arrive — so this row
    /// never shows a determinate bar of its own.
    static func removableIndicator(
        presentation: MediaOperationSourcePresentation?,
        sidebarSelection: SidebarSelection
    ) -> SidebarStatusIndicator {
        guard let presentation,
              !barOwnsStatus(sidebarSelection: sidebarSelection, presentation: presentation)
        else {
            return .none
        }
        return switch presentation.state {
        case let .waitingForMetadata(done, total):
            .determinate(completed: done, total: total)
        case .inventory, .planning:
            .indeterminate
        default:
            .none
        }
    }

    /// The batch row's own indicator — live only while its operation is
    /// actively `.executing`; a settled or failed batch shows its ordinary
    /// accessory instead (DES-040 covers in-progress status, not terminal
    /// states).
    static func batchIndicator(
        batchID: ImportBatchID,
        presentations: [MediaOperationSourcePresentation],
        sidebarSelection: SidebarSelection
    ) -> SidebarStatusIndicator {
        guard let presentation = presentations.first(where: { $0.batchID == batchID }),
              case let .executing(progress) = presentation.state
        else {
            return .none
        }
        if barOwnsStatus(sidebarSelection: sidebarSelection, presentation: presentation) {
            return .none
        }
        return .determinate(completed: progress.completedCount, total: progress.totalCount)
    }
}

/// A sidebar row's status indicator, per `import-bar.md` "Ownership of status":
/// at most one row shows this at a time, and only while the bar is off screen
/// for that operation.
nonisolated enum SidebarStatusIndicator: Equatable {
    case none
    case indeterminate
    case determinate(completed: Int, total: Int)
}
