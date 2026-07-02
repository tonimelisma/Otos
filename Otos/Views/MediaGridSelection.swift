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
