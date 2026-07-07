import AppKit

/// The one `NSCollectionView` subclass in the app. It exists solely to observe the click
/// that AppKit's selection machinery consumes.
///
/// `mouseDown(with:)` runs AppKit's native selection tracking loop synchronously: it does
/// not return until the click is fully processed (the tracking loop has seen mouse-up,
/// the selection is final, and the `didSelectItemsAt`/`didDeselectItemsAt` delegate
/// callbacks have been delivered). So when `super.mouseDown` returns, the handler receives
/// the authoritative `(clicked item, modifiers)` pair that the delegate callbacks cannot
/// reliably provide on their own — most importantly, a plain click that collapses a
/// multi-selection onto an already-selected item fires **no** `didSelectItemsAt` for the
/// clicked item (only `didDeselectItemsAt` for the ones dropped), so delegate-only
/// inference has no way to learn what was clicked. Capturing the hit-test result before
/// `super` and reading the settled selection after it closes that hole (spec 0046, F5).
///
/// The controller is the only thing that owns selection semantics; this subclass forwards
/// the observed click and nothing else, keeping the AppKit boundary a thin renderer.
final class MediaGridCollectionView: NSCollectionView {
    /// Delivered after `super.mouseDown(with:)` returns, i.e. once native selection is
    /// final. The `IndexPath?` is the item under the click location (`nil` for empty
    /// space); the modifiers are the click's modifier flags. The controller wires this to
    /// `mouseSelectionFinished(hit:modifiers:)`.
    var onMouseSelectionFinished: ((IndexPath?, NSEvent.ModifierFlags) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let hit = indexPathForItem(at: convert(event.locationInWindow, from: nil))
        let modifiers = event.modifierFlags
        super.mouseDown(with: event)
        onMouseSelectionFinished?(hit, modifiers)
    }
}
