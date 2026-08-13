import AppKit

/// The one `NSCollectionView` subclass in the app. It owns the mouse path so the
/// controller's selection model never races AppKit's native mouse selection.
///
/// `mouseDown(with:)` does **not** call `super.mouseDown`. AppKit's default
/// `mouseDown` runs a mouse-tracking loop whose selection-commit timing across the mouse
/// event sequence is not a stable, documented contract; the prior design read
/// `selectionIndexPaths` after `super.mouseDown` to correct the result and lost the race.
/// Instead this subclass finds the candidate item, confirms the click is inside the tile's
/// aspect-fit thumbnail face, preserves keyboard focus, and forwards `(hit, modifiers)` to
/// the controller, which computes the gesture against its own `GridSelection` and writes
/// `selectionIndexPaths` itself.
///
/// Double-click (`clickCount == 2`) on an unmodified hit forwards `onDoubleClickHit`
/// after the selection write so loupe entry sees the updated selection. Return opens
/// loupe from grid; Escape / arrows in strip mode are forwarded via key handlers.
/// In strip mode vertical/extension keys and select-all are consumed so native
/// multi-selection cannot corrupt focus/pair invariants.
final class MediaGridCollectionView: NSCollectionView {
    /// Delivered from `mouseDown(with:)` with the item under the click location (`nil` for
    /// empty space) and the click's modifier flags. The controller wires this to
    /// `applyMouseSelection(hit:modifiers:)`, which owns the selection model and writes
    /// `selectionIndexPaths` as the last operation of the gesture.
    var onMouseSelection: ((IndexPath?, NSEvent.ModifierFlags) -> Void)?
    /// Unmodified double-click hit; the controller resolves the identity.
    var onDoubleClickHit: ((IndexPath) -> Void)?
    /// Grid: Return opens loupe. Strip: Esc exits; arrows move focus when forwarded.
    var onReturnKey: (() -> Void)?
    var onEscapeKey: (() -> Void)?
    var onArrowKey: ((Int) -> Void)?
    /// When true, ←/→ are forwarded to `onArrowKey` instead of native collection nav.
    var forwardsArrowKeys = false

    override func mouseDown(with event: NSEvent) {
        let pointInCollectionView = convert(event.locationInWindow, from: nil)
        var hit = indexPathForItem(at: pointInCollectionView)
        if let candidate = hit, !clickHitsThumbnailFace(candidate, event: event) {
            hit = nil
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        window?.makeFirstResponder(self)
        onMouseSelection?(hit, event.modifierFlags)

        if modifiers.isEmpty, event.clickCount == 2, let hit {
            onDoubleClickHit?(hit)
        }
    }

    override func keyDown(with event: NSEvent) {
        let chars = event.charactersIgnoringModifiers ?? ""
        if chars == "\r" || chars == "\n" {
            onReturnKey?()
            return
        }
        if event.keyCode == 53 { // Escape
            onEscapeKey?()
            return
        }
        if forwardsArrowKeys {
            switch event.keyCode {
            case 123: // left
                onArrowKey?(-1)
                return
            case 124: // right
                onArrowKey?(1)
                return
            case 125, 126: // down, up — meaningless in a single row
                return
            case 115, 119: // Home, End
                return
            case 116, 121: // PageUp, PageDown
                return
            default:
                // ⇧+←/→ and other extension chords: consume in strip mode.
                if event.modifierFlags.contains(.shift)
                    || event.modifierFlags.contains(.command)
                {
                    return
                }
            }
        }
        super.keyDown(with: event)
    }

    override func selectAll(_ sender: Any?) {
        guard !forwardsArrowKeys else {
            return
        }
        super.selectAll(sender)
    }

    private func clickHitsThumbnailFace(_ candidate: IndexPath, event: NSEvent) -> Bool {
        guard let item = item(at: candidate) as? MediaGridItem,
              let tileView = item.view as? MediaAssetTileView
        else {
            return true
        }
        return tileView.hitTestsThumbnailFace(at: event.locationInWindow)
    }
}
