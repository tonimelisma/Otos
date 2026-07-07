import AppKit
import Foundation

/// Grid selection policy guide
///
/// Pure, `nonisolated` helpers that decide selection membership independently of any
/// live `NSCollectionView`, so the grid's selection behavior is unit-testable without
/// AppKit lifecycle. The collection view owns the live selection
/// (`selectionIndexPaths`); these functions answer only "which selected identities
/// survive a structural change" and "in what order should a copy emit them".
enum MediaGridSelection {
    /// Drops identities that are no longer present after a structural apply, so a
    /// selected asset that disappeared (deleted, filtered out, scope changed) is never
    /// resurrected. `ordered` is the new display order; set membership is the contract.
    nonisolated static func pruned(
        _ selected: Set<MediaAssetID>,
        to ordered: [MediaAssetID]
    ) -> Set<MediaAssetID> {
        guard !selected.isEmpty else {
            return []
        }
        return selected.intersection(ordered)
    }

    /// The selected identities in display order. Copy emits URLs in the order the user
    /// sees tiles, not in hash order, so a pasted multi-selection is stable.
    nonisolated static func orderedSelection(
        _ selected: Set<MediaAssetID>,
        in ordered: [MediaAssetID]
    ) -> [MediaAssetID] {
        guard !selected.isEmpty else {
            return []
        }
        return ordered.filter(selected.contains)
    }

    /// Corrects AppKit's native shift-click (which toggles only the clicked item, the
    /// same as ⌘-click) into a Photos/Lightroom-style contiguous range. `base` is the
    /// selection recorded when `anchor` was last set by a plain or ⌘-click, so a chain of
    /// shift-clicks from the same anchor grows and shrinks the range instead of
    /// accumulating every intermediate click. Falls back to `{clicked}` (a plain click)
    /// when `anchor` or `clicked` is not present in the current display order — an
    /// anchor whose asset a structural apply removed must not resurrect a stale range.
    nonisolated static func shiftRangeSelection(
        anchor: MediaAssetID,
        clicked: MediaAssetID,
        base: Set<MediaAssetID>,
        orderedIDs: [MediaAssetID]
    ) -> Set<MediaAssetID> {
        guard
            let anchorIndex = orderedIDs.firstIndex(of: anchor),
            let clickedIndex = orderedIDs.firstIndex(of: clicked)
        else {
            return [clicked]
        }
        let range = orderedIDs[min(anchorIndex, clickedIndex) ... max(anchorIndex, clickedIndex)]
        return base.union(range)
    }

    /// The minimal delta that turns `current` into `target`: identities to deselect and
    /// identities to select. Applying only this delta — instead of deselecting everything
    /// and reselecting survivors — means an identity present in both sets receives no
    /// select/deselect call at all, so its tile's `isSelected` never changes and an
    /// animated selection ring never blinks for a survivor (spec 0047).
    nonisolated static func selectionDelta(
        current: Set<MediaAssetID>,
        target: Set<MediaAssetID>
    ) -> (toDeselect: Set<MediaAssetID>, toSelect: Set<MediaAssetID>) {
        (current.subtracting(target), target.subtracting(current))
    }
}

/// Media clipboard guide
///
/// Writes copied assets to a pasteboard as original file URLs (ADR 0012): one `NSURL`
/// per asset, in the given order, references only — no image or video bytes are read,
/// so copy is instant and never materializes a dataless cloud original. Finder pastes
/// the files; Messages and Mail attach them. The pasteboard is a parameter so the
/// write can be exercised against an isolated `NSPasteboard(name:)` in tests.
enum MediaGridClipboard {
    @discardableResult
    static func write(_ ids: [MediaAssetID], to pasteboard: NSPasteboard) -> Int {
        pasteboard.clearContents()
        guard !ids.isEmpty else {
            return 0
        }
        pasteboard.writeObjects(ids.map { $0.fileURL as NSURL })
        return ids.count
    }
}
