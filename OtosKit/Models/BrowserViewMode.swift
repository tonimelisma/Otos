import Foundation

/// Browser view-mode guide
///
/// Browser presentation: grid, loupe (large image + filmstrip), or compare (two images +
/// filmstrip). Default is `.grid`. Mode state lives on `CatalogWindowViewModel`; it is
/// saved at quit and restored at launch with the rest of the browser place (APP-043).
///
/// Pure policy helpers below own entry focus, arrow navigation, and prune-survivor focus
/// so the LrC-inspired rules are unit-tested without UI.
nonisolated enum BrowserViewMode: String, CaseIterable, Identifiable, Equatable {
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
        orderedIDs: some MediaDisplayOrder
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
        return orderedIDs.orderedIDs.first
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

    /// When a structural apply or a filter/sort change removes the focused asset, move
    /// focus to its nearest survivor (`nearestSurvivor`); with no prior focus, or none
    /// that survives, the first surviving item.
    static func pruneFocus(
        previous: MediaAssetID?,
        previousOrderedIDs: some MediaDisplayOrder,
        survivingOrderedIDs: some MediaDisplayOrder
    ) -> MediaAssetID? {
        guard let previous else {
            return survivingOrderedIDs.orderedIDs.first
        }
        return nearestSurvivor(
            of: previous,
            previousOrderedIDs: previousOrderedIDs,
            surviving: survivingOrderedIDs
        ) ?? survivingOrderedIDs.orderedIDs.first
    }

    /// The item itself if it survives, else the closest survivor in the order the user
    /// was looking at: the first later survivor, else the closest earlier one.
    ///
    /// The *previous* order is the frame of reference, not the surviving one. After a
    /// deletion the two agree; after a filter the surviving list is a different, much
    /// shorter sequence, so an index carried into it lands somewhere unrelated to where
    /// the user was. Walking the old order finds what was physically next to them.
    static func nearestSurvivor(
        of id: MediaAssetID,
        previousOrderedIDs: some MediaDisplayOrder,
        surviving: some MediaMembership
    ) -> MediaAssetID? {
        if surviving.contains(id) {
            return id
        }
        guard let priorIndex = previousOrderedIDs.position(of: id) else {
            return nil
        }
        let previous = previousOrderedIDs.orderedIDs
        if let later = previous[(priorIndex + 1)...].first(where: surviving.contains) {
            return later
        }
        return previous[..<priorIndex].last(where: surviving.contains)
    }
}
