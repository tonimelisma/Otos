import Foundation

/// Browser view-mode guide
///
/// Session-only browser presentation: grid, loupe (large image + filmstrip), or compare
/// (two images + filmstrip). Default is `.grid`. Mode state lives on
/// `CatalogWindowViewModel` and is never persisted (same policy as sort/filter, APP-014).
///
/// Pure policy helpers below own entry focus, arrow navigation, and prune-survivor focus
/// so the LrC-inspired rules are unit-tested without UI.
enum BrowserViewMode: String, CaseIterable, Identifiable, Equatable {
    case grid
    case loupe
    case compare

    var id: String {
        rawValue
    }

    var help: String {
        switch self {
        case .grid:
            "Grid"
        case .loupe:
            "Loupe"
        case .compare:
            "Compare"
        }
    }

    /// SF Symbol verified available on the current macOS baseline.
    var systemImage: String {
        switch self {
        case .grid:
            "square.grid.2x2"
        case .loupe:
            "squares.below.rectangle"
        case .compare:
            "rectangle.split.2x1"
        }
    }

    var keyboardShortcutDigit: Character {
        switch self {
        case .grid:
            "1"
        case .loupe:
            "2"
        case .compare:
            "3"
        }
    }
}

/// Pure focus/navigation policy for loupe (and shared prune rules). No AppKit, no I/O.
nonisolated enum BrowserModePolicy {
    /// Focus when entering loupe: explicit id, else selection anchor, else first selected
    /// in display order, else first item in scope.
    static func loupeEntryFocus(
        preferredID: MediaAssetID?,
        selection: GridSelection,
        orderedIDs: [MediaAssetID]
    ) -> MediaAssetID? {
        if let preferredID, orderedIDs.contains(preferredID) {
            return preferredID
        }
        if let anchor = selection.anchor, orderedIDs.contains(anchor) {
            return anchor
        }
        let orderedSelected = GridSelection.orderedSelection(selection.selection, in: orderedIDs)
        if let first = orderedSelected.first {
            return first
        }
        return orderedIDs.first
    }

    /// Next/previous neighbor in display order. Returns `current` when already at the end
    /// (or when `current` is missing and there is no fallback).
    static func neighbor(
        of current: MediaAssetID?,
        in orderedIDs: [MediaAssetID],
        delta: Int
    ) -> MediaAssetID? {
        guard !orderedIDs.isEmpty else {
            return nil
        }
        guard let current, let index = orderedIDs.firstIndex(of: current) else {
            return orderedIDs.first
        }
        let next = index + delta
        guard orderedIDs.indices.contains(next) else {
            return current
        }
        return orderedIDs[next]
    }

    /// When a structural apply removes the focused asset, move focus to the nearest
    /// survivor by prior index (prefer the item that slid into the same slot, else the
    /// previous survivor).
    static func pruneFocus(
        previous: MediaAssetID?,
        previousOrderedIDs: [MediaAssetID],
        survivingOrderedIDs: [MediaAssetID]
    ) -> MediaAssetID? {
        guard let previous else {
            return survivingOrderedIDs.first
        }
        if survivingOrderedIDs.contains(previous) {
            return previous
        }
        guard let priorIndex = previousOrderedIDs.firstIndex(of: previous) else {
            return survivingOrderedIDs.first
        }
        if survivingOrderedIDs.indices.contains(priorIndex) {
            return survivingOrderedIDs[priorIndex]
        }
        if priorIndex > 0, survivingOrderedIDs.indices.contains(priorIndex - 1) {
            return survivingOrderedIDs[priorIndex - 1]
        }
        return survivingOrderedIDs.last
    }
}
