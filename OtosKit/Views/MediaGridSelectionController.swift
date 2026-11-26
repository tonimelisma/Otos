import AppKit
import OSLog

// Media collection selection guide
//
// This file contains the AppKit-only selection surface for the media grid.
// SwiftUI provides the surrounding commands and window state. Selection *truth* lives
// in `CatalogWindowViewModel` as a pure `GridSelection` value; this controller is a
// renderer of that value. Copy is a ViewModel intent (`copyCurrentTargets`), not a
// responder-chain action here.
//
// Mouse selection is model-owned. `MediaGridCollectionView.mouseDown(with:)` does
// **not** call `super.mouseDown`, so AppKit's native mouse-selection tracking loop
// never runs and there is no commit to race; it forwards `(hit, modifiers)` here.
// `applyMouseSelection(hit:modifiers:)` calls the injected ViewModel intent
// synchronously, receives the updated `GridSelection` as the return value, and writes
// `selectionIndexPaths` from it as the last operation of the gesture via
// `applySelectionDelta`. Because the model is the truth and the write is last, the
// mouseDown-vs-mouseUp timing that broke the prior read-then-correct design is
// irrelevant.
//
// `selectedIdentities()` (a read of `selectionIndexPaths`) is used only to (a) reconcile
// the model's `selection` field after native *keyboard* selection (⌘A, ⇧-arrows — which
// stay native and write `selectionIndexPaths` directly) and (b) compute the minimal write
// delta. It is never used to *decide* a gesture or to prune/clear the model after a
// structural apply — those writes live in `CatalogWindowViewModel.applyState`.
//
// Programmatic `selectItems`/`deselectItems` fire `didSelect`/`didDeselect` synchronously.
// `isApplyingModelSelection` suppresses those echoes so a half-applied live set never
// stomps the model (and never resets `base`, which would break ⇧-chain contraction).

// MARK: - Selection

extension MediaGridViewController: NSCollectionViewDelegate {
    /// Reconcile native keyboard selection upward. Programmatic delta writes also land
    /// here synchronously; while `isApplyingModelSelection` is set they must not adopt
    /// the (by definition half-applied) live set into the model.
    func collectionView(_: NSCollectionView, didSelectItemsAt _: Set<IndexPath>) {
        guard !isApplyingModelSelection else {
            logSelection(reason: "select")
            return
        }
        _ = selectionHandlers.reconcileNative(selectedIdentities())
        logSelection(reason: "select")
    }

    func collectionView(_: NSCollectionView, didDeselectItemsAt _: Set<IndexPath>) {
        guard !isApplyingModelSelection else {
            logSelection(reason: "deselect")
            return
        }
        _ = selectionHandlers.reconcileNative(selectedIdentities())
        logSelection(reason: "deselect")
    }
}

extension MediaGridViewController {
    /// Called by `MediaGridCollectionView.mouseDown(with:)` (which does not call
    /// `super.mouseDown`, so AppKit's native mouse selection never runs). `hit` is the item
    /// under the click location (`nil` for empty space); `modifiers` are the click's flags.
    /// Forwards the gesture to the ViewModel-owned model synchronously and writes
    /// `selectionIndexPaths` from the returned value as the last operation.
    func applyMouseSelection(hit: IndexPath?, modifiers: NSEvent.ModifierFlags) {
        let shift = modifiers.contains(.shift)
        let command = modifiers.contains(.command)
        let orderedIDs = structure.orderedIDs
        let live = selectedIdentities()

        let clicked: MediaAssetID? = if let hit {
            structure.id(at: hit)
        } else {
            nil
        }

        // Empty-space with ⇧/⌘ is a no-op (no marquee); leave model and AppKit alone.
        if clicked == nil, shift || command {
            logSelection(reason: "shiftEmptySpace")
            return
        }

        let updated = selectionHandlers.applyClick(clicked, modifiers, orderedIDs)
        let reason = if clicked == nil {
            "emptySpace"
        } else {
            switch (shift, command) {
            case (false, false):
                "plainClick"
            case (false, true):
                "commandClick"
            case (true, false):
                "shiftRange"
            case (true, true):
                "commandShiftRange"
            }
        }
        applySelectionDelta(from: live, to: updated.selection)
        logSelection(reason: reason)
    }

    /// Applies only the identities that actually change between `current` and `target`,
    /// so a survivor present in both never receives a select/deselect call (this is what
    /// keeps the animated selection ring from blinking on a survivor).
    func applySelectionDelta(from current: Set<MediaAssetID>, to target: Set<MediaAssetID>) {
        let delta = GridSelection.selectionDelta(current: current, target: target)
        isApplyingModelSelection = true
        defer { isApplyingModelSelection = false }
        if !delta.toDeselect.isEmpty {
            let paths = Set(delta.toDeselect.compactMap { structure.indexPath(of: $0) })
            collectionView.deselectItems(at: paths)
        }
        if !delta.toSelect.isEmpty {
            let paths = Set(delta.toSelect.compactMap { structure.indexPath(of: $0) })
            collectionView.selectItems(at: paths, scrollPosition: [])
        }
    }
}

extension MediaGridViewController {
    /// The live selection as stable identities, read from the collection view's own
    /// selection. This is a *render output* read: used only to compute the minimal write
    /// delta and to reconcile the model after native keyboard selection — never to decide
    /// a gesture or to prune the model after a structural apply.
    func selectedIdentities() -> Set<MediaAssetID> {
        Set(collectionView.selectionIndexPaths.compactMap { structure.id(at: $0) })
    }

    /// Model → view, one direction. Idempotent; safe to call at any point where the
    /// data source already contains the model's identities (apply completion, SwiftUI
    /// update). Identities not yet in the data source are skipped and re-rendered by
    /// the next apply completion.
    func renderSelectionFromModel(reason: String) {
        applySelectionDelta(
            from: selectedIdentities(),
            to: selectionHandlers.currentSelection().selection
        )
        logSelection(reason: reason)
    }

    func logSelection(reason: String) {
        guard OtosUIVerbose.enabled else {
            return
        }
        let count = collectionView.selectionIndexPaths.count
        OtosLog.ui.debug(
            """
            Media grid selection changed count=\(count, privacy: .public) \
            reason=\(reason, privacy: .public)
            """
        )
    }

    /// Current ViewModel-owned selection model (test and diagnostic read).
    var gridSelection: GridSelection {
        selectionHandlers.currentSelection()
    }
}

/// Drag-out (ADR 0028). The view detected the drag; this builds one dragging item per
/// asset — the hand-off's writer (`CatalogWindowViewModel.dragWriters(for:)`), the on-screen
/// tile's frame and a snapshot of it as the drag image, or the origin tile's frame for
/// assets scrolled out of view — and starts the session with the controller's source. No
/// byte read, no materialization here: a promise prepares its file when the receiver asks.
extension MediaGridViewController {
    func beginDrag(from hit: IndexPath, event: NSEvent) {
        guard let hitID = structure.id(at: hit) else {
            return
        }
        let ids = MediaGridDragPolicy.draggedIDs(
            hit: hitID,
            selection: selectedIdentities(),
            orderedIDs: structure.orderedIDs
        )
        let originFrame = collectionView.layoutAttributesForItem(at: hit)?.frame ?? .zero
        let writers = selectionHandlers.dragWriters(ids)
        let items: [NSDraggingItem] = zip(ids, writers).map { id, writer in
            let item = NSDraggingItem(pasteboardWriter: writer)
            if let indexPath = structure.indexPath(of: id),
               let tile = collectionView.item(at: indexPath)?.view
            {
                let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame ?? originFrame
                item.setDraggingFrame(frame, contents: Self.snapshot(of: tile))
            } else {
                item.setDraggingFrame(originFrame, contents: nil)
            }
            return item
        }
        guard !items.isEmpty else {
            OtosLog.ui.notice("op=ui.dragOut.refused reason=scopeLeft count=\(ids.count, privacy: .public)")
            return
        }
        dragSource.onEnd = { operation in
            OtosLog.ui.notice(
                "op=ui.dragOut.end count=\(ids.count, privacy: .public) operation=\(operation.rawValue, privacy: .public)"
            )
        }
        collectionView.beginDraggingSession(with: items, event: event, source: dragSource)
        OtosLog.ui.notice("op=ui.dragOut.begin count=\(ids.count, privacy: .public)")
    }

    private static func snapshot(of view: NSView) -> NSImage? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return nil
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
    }
}
