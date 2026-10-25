import AppKit

/// The one `NSCollectionView` subclass in the app. It owns the mouse path so the
/// controller's selection model never races AppKit's native mouse selection.
///
/// `mouseDown(with:)` does **not** call `super.mouseDown`. AppKit's default
/// `mouseDown` runs a mouse-tracking loop whose selection-commit timing across the mouse
/// event sequence is not a stable, documented contract, so reading `selectionIndexPaths`
/// after `super.mouseDown` to correct the result races AppKit's own commit. Instead this
/// subclass finds the candidate item, confirms the click is inside the tile's
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
    var onMediaChoiceKey: ((MediaChoice) -> Void)?
    /// Strip only: Z toggles loupe zoom, I toggles the info overlay — fallbacks for the
    /// View-menu items that own those keys (APP-040/041).
    /// When true, ←/→ are forwarded to `onArrowKey` instead of native collection nav.
    var forwardsArrowKeys = false
    /// The item under the cursor, or `nil` when the pointer is outside the grid.
    /// Reported only on change. The controller owns what hover *means*; this view
    /// owns only the geometry question, for the same reason it owns `mouseDown`.
    var onHoverChanged: ((IndexPath?) -> Void)?
    /// Context click on a tile's thumbnail face. The controller decides what the hit
    /// does to the selection and returns the menu; empty space has no menu.
    var onContextMenu: ((IndexPath) -> NSMenu?)?
    /// The pointer has travelled `MediaGridDragPolicy.dragThreshold` from a mouse-down
    /// on this tile; the controller starts the dragging session (ADR 0028).
    var onDragBegin: ((IndexPath, NSEvent) -> Void)?
    /// The view entered a window. The controller claims first responder then when it
    /// appeared before the window existed (`NSViewControllerRepresentable` can show the
    /// view first).
    var onMovedToWindow: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            onMovedToWindow?()
        }
    }

    /// A plain mouse-down on a selected tile whose selection change is waiting for
    /// mouse-up, in case the gesture becomes a drag (`MediaGridClickDecision`).
    private var deferredPlainClick: (hit: IndexPath, modifiers: NSEvent.ModifierFlags)?
    /// Where the current mouse-down on a tile happened, in this view's coordinates.
    private var dragOrigin: (point: NSPoint, hit: IndexPath)?

    private var hoverTrackingArea: NSTrackingArea?
    private var hoveredIndexPath: IndexPath?

    /// One tracking area for the whole grid rather than one per tile. Scrolling
    /// moves tiles under a stationary cursor without producing a single mouse
    /// event, so per-tile enter/exit is structurally unable to stay correct;
    /// `refreshHover()` is what closes that gap, and it needs a single owner of
    /// the current hovered item to compare against.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        updateHover(forWindowLocation: event.locationInWindow)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateHover(forWindowLocation: event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHovered(nil)
    }

    /// Where the pointer is, in window coordinates, or `nil` when it is not over
    /// this view at all. Injected rather than read inline so the one piece of
    /// ambient global state this view depends on has an explicit owner — and so
    /// a test can place the pointer instead of depending on where the developer
    /// happened to leave the mouse.
    var pointerLocationInWindow: () -> NSPoint? = { nil }

    /// Recomputes hover with no mouse event to prompt it. The controller calls
    /// this whenever tiles move under a possibly-stationary cursor — every
    /// scroll tick, and after a structural apply — which is precisely when
    /// AppKit reports nothing.
    func refreshHover() {
        guard let locationInWindow = pointerLocationInWindow(),
              visibleRect.contains(convert(locationInWindow, from: nil))
        else {
            setHovered(nil)
            return
        }
        // Delivered unconditionally rather than through `setHovered`'s change
        // guard: after a reorder the same index path can hold a *different*
        // asset, so an unchanged index path is not evidence of unchanged hover.
        // The controller dedups on asset identity, which is the identity that
        // actually decides which tile lights up.
        let indexPath = indexPathForItem(at: convert(locationInWindow, from: nil))
        hoveredIndexPath = indexPath
        onHoverChanged?(indexPath)
    }

    private func updateHover(forWindowLocation locationInWindow: NSPoint) {
        setHovered(indexPathForItem(at: convert(locationInWindow, from: nil)))
    }

    private func setHovered(_ indexPath: IndexPath?) {
        guard hoveredIndexPath != indexPath else {
            return
        }
        hoveredIndexPath = indexPath
        onHoverChanged?(indexPath)
    }

    override func mouseDown(with event: NSEvent) {
        let pointInCollectionView = convert(event.locationInWindow, from: nil)
        var hit = indexPathForItem(at: pointInCollectionView)
        if let candidate = hit, !clickHitsThumbnailFace(candidate, event: event) {
            hit = nil
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        window?.makeFirstResponder(self)
        deferredPlainClick = nil
        dragOrigin = hit.map { (pointInCollectionView, $0) }

        let decision = MediaGridDragPolicy.decision(
            hasHit: hit != nil,
            hitIsSelected: hit.map { selectionIndexPaths.contains($0) } ?? false,
            isPlainClick: modifiers.isEmpty,
            clickCount: event.clickCount
        )
        switch decision {
        case .select:
            onMouseSelection?(hit, event.modifierFlags)
        case .deferUntilMouseUp:
            if let hit {
                deferredPlainClick = (hit, event.modifierFlags)
            }
        case .doubleClick:
            onMouseSelection?(hit, event.modifierFlags)
            if let hit {
                onDoubleClickHit?(hit)
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin else {
            super.mouseDragged(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - origin.point.x, point.y - origin.point.y) >= MediaGridDragPolicy.dragThreshold else {
            return
        }
        // A drag is not a click: the deferred collapse never happens.
        deferredPlainClick = nil
        dragOrigin = nil
        onDragBegin?(origin.hit, event)
    }

    override func mouseUp(with event: NSEvent) {
        if let deferred = deferredPlainClick {
            deferredPlainClick = nil
            onMouseSelection?(deferred.hit, deferred.modifiers)
        }
        dragOrigin = nil
        super.mouseUp(with: event)
    }

    /// Right-click and control-click. The same face test as `mouseDown` so a click in
    /// a tile's letterbox is empty space for both buttons.
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = indexPathForItem(at: point), clickHitsThumbnailFace(hit, event: event) else {
            return nil
        }
        window?.makeFirstResponder(self)
        return onContextMenu?(hit)
    }

    override func keyDown(with event: NSEvent) {
        let chars = event.charactersIgnoringModifiers ?? ""
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.subtracting(.shift).isEmpty,
           let choice = MediaChoice(keyCharacter: chars)
        {
            onMediaChoiceKey?(choice)
            return
        }
        // Any other bare letter goes to the menu bar first. The single-letter commands
        // (E, C, I, Z) are menu items; NSCollectionView's own keyDown would swallow the
        // letter as type-select, so they would never fire while the grid has focus.
        if modifiers.isEmpty, chars.count == 1, chars.unicodeScalars.allSatisfy(CharacterSet.letters.contains),
           NSApp?.mainMenu?.performKeyEquivalent(with: event) == true
        {
            return
        }
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
