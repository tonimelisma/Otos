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

    /// When a source attaches, the selection to switch to, or nil for fixed-library attach.
    static func selectionOnAttach(attached: CatalogLibraryState) -> SidebarSelection? {
        guard attached.kind != .library else {
            return nil
        }
        return .library(attached.path)
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
}
