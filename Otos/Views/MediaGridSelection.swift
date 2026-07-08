import AppKit
import Foundation

/// Grid selection helpers guide
///
/// Pure, `nonisolated` helpers for the model-owned selection (spec 0046). The selection
/// model itself — selection set, ⇧-range anchor, and base "islands" — lives in
/// `GridSelection`; this enum keeps only the two operations that do not need model state:
/// the minimal write delta (`selectionDelta`) and copy's display-order projection
/// (`orderedSelection`). Both are value-level and unit-testable without AppKit lifecycle.
enum MediaGridSelection {
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
