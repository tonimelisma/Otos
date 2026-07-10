import AppKit
import OSLog

// Media collection selection guide
//
// This file contains the AppKit-only selection and copy surface for the media grid.
// SwiftUI provides the surrounding commands and window state. Selection *truth* lives
// in `CatalogWindowViewModel` as a pure `GridSelection` value; this controller is a
// renderer of that value plus the responder-chain copy path.
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
//
// Copy writes original file URLs to the pasteboard in display order. It does not read
// media bytes, decode thumbnails, or materialize cloud placeholders; it only maps the
// collection view's selected identities back through `MediaAssetID.fileURL`.

// MARK: - Selection and copy

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
        let orderedIDs = mutationGate.displayedOrderedIDs
        let live = selectedIdentities()

        let clicked: MediaAssetID? = if let hit {
            dataSource.itemIdentifier(for: hit)
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
            let paths = Set(delta.toDeselect.compactMap { dataSource.indexPath(for: $0) })
            collectionView.deselectItems(at: paths)
        }
        if !delta.toSelect.isEmpty {
            let paths = Set(delta.toSelect.compactMap { dataSource.indexPath(for: $0) })
            collectionView.selectItems(at: paths, scrollPosition: [])
        }
    }
}

extension MediaGridViewController: NSUserInterfaceValidations {
    /// Edit > Copy and its command-key equivalent are enabled only when something is
    /// selected. AppKit asks this controller because it is the responder-chain object
    /// that implements `copy(_:)`.
    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) {
            return !collectionView.selectionIndexPaths.isEmpty
        }
        return true
    }
}

extension MediaGridViewController {
    /// Copy arrives here through the responder chain: the collection view is first
    /// responder but does not implement copy:, so the action travels to this
    /// controller. We write the selected assets' original file URLs to the general
    /// pasteboard in display order (ADR 0012). No image or video bytes are read.
    @objc func copy(_: Any?) {
        let ordered = GridSelection.orderedSelection(
            selectedIdentities(),
            in: mutationGate.displayedOrderedIDs
        )
        let signpost = OtosSignpost.ui.beginInterval("MediaGridCopy")
        let count = MediaGridClipboard.write(ordered, to: .general)
        OtosSignpost.ui.endInterval("MediaGridCopy", signpost)
        OtosLog.ui.info("Media grid copy wrote fileURLs count=\(count, privacy: .public)")
    }

    /// The live selection as stable identities, read from the collection view's own
    /// selection. This is a *render output* read: used only to compute the minimal write
    /// delta and to reconcile the model after native keyboard selection — never to decide
    /// a gesture or to prune the model after a structural apply.
    func selectedIdentities() -> Set<MediaAssetID> {
        Set(collectionView.selectionIndexPaths.compactMap { dataSource.itemIdentifier(for: $0) })
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
