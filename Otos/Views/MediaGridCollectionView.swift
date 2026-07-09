import AppKit

/// The one `NSCollectionView` subclass in the app. It owns the mouse path so the
/// controller's selection model never races AppKit's native mouse selection.
///
/// `mouseDown(with:)` does **not** call `super.mouseDown`. AppKit's default
/// `mouseDown` runs a mouse-tracking loop whose selection-commit timing across the mouse
/// event sequence is not a stable, documented contract; the prior design read
/// `selectionIndexPaths` after `super.mouseDown` to correct the result and lost the race
/// (spec 0046). Instead this subclass finds the candidate item, confirms the click is
/// inside the tile's aspect-fit thumbnail face (spec 0049), preserves keyboard focus (the
/// one thing `super.mouseDown` would otherwise handle), and forwards `(hit, modifiers)` to
/// the controller, which computes the gesture against its own `GridSelection` and writes
/// `selectionIndexPaths` itself. Because AppKit's native selection tracking loop never
/// runs, there is no competing commit to overwrite the model's write, and the
/// mouseDown-vs-mouseUp timing is irrelevant. The grid uses neither rubber-band marquee
/// nor drag-reorder (grep-verified), so not calling `super` loses no functionality.
/// Programmatic `selectionIndexPaths =` / `selectItems` / `deselectItems` do not re-enter
/// `mouseDown`, so there is no feedback loop.
///
/// The controller is the only thing that owns selection semantics; this subclass forwards
/// the observed click and nothing else, keeping the AppKit boundary a thin renderer.
final class MediaGridCollectionView: NSCollectionView {
    /// Delivered from `mouseDown(with:)` with the item under the click location (`nil` for
    /// empty space) and the click's modifier flags. The controller wires this to
    /// `applyMouseSelection(hit:modifiers:)`, which owns the selection model and writes
    /// `selectionIndexPaths` as the last operation of the gesture.
    var onMouseSelection: ((IndexPath?, NSEvent.ModifierFlags) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let pointInCollectionView = convert(event.locationInWindow, from: nil)
        var hit = indexPathForItem(at: pointInCollectionView)
        // When the item is not yet materialized as a MediaAssetTileView (rare mid-scroll),
        // accept the full-square hit rather than treating it as a face miss — a miss would
        // make clicks during scroll feel dead. Letterbox rejection only applies once the
        // tile view is resolvable.
        if let candidate = hit,
           let item = item(at: candidate) as? MediaAssetCollectionItem,
           let tileView = item.view as? MediaAssetTileView,
           !tileView.hitTestsThumbnailFace(at: event.locationInWindow)
        {
            hit = nil
        }

        let modifiers = event.modifierFlags
        // `super.mouseDown` is intentionally not called: AppKit's native selection tracking
        // loop is the exact race the model-owned design removes. `makeFirstResponder`
        // preserves the keyboard focus that `super` would otherwise have handled.
        window?.makeFirstResponder(self)
        onMouseSelection?(hit, modifiers)
    }
}
