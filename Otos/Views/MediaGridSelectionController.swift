import AppKit
import OSLog

// Media collection selection guide
//
// This file contains the AppKit-only selection and copy surface for the media grid.
// SwiftUI provides the surrounding commands and window state, but AppKit owns the
// live collection selection and responder chain. Keeping that bridge here gives one
// path for mouse selection, command validation, and Edit > Copy.
//
// Mouse selection is model-owned (spec 0046). The grid owns a pure `GridSelection`
// value — selection, ⇧-range anchor, and base "islands" — as the single source of
// truth. `MediaGridCollectionView.mouseDown(with:)` does **not** call `super.mouseDown`,
// so AppKit's native mouse-selection tracking loop never runs and there is no commit to
// race; it forwards `(hit, modifiers)` here. `applyMouseSelection(hit:modifiers:)`
// computes the next `GridSelection` from the model alone (never from
// `collectionView.selectionIndexPaths`), then writes `selectionIndexPaths` from the
// model as the last operation of the gesture via `applySelectionDelta`. Because the model
// is the truth and the write is last, the mouseDown-vs-mouseUp timing that broke the
// prior read-then-correct design is irrelevant. Programmatic `selectItems`/`deselectItems`
// do not re-enter `mouseDown`, so there is no feedback loop.
//
// `selectedIdentities()` (a read of `selectionIndexPaths`) is used only to (a) reconcile
// the model's `selection` field after native *keyboard* selection (⌘A, ⇧-arrows — which
// stay native and write `selectionIndexPaths` directly) and (b) compute the minimal write
// delta. It is never used to *decide* a gesture: the gesture is computed solely from
// `gridSelection`.
//
// The `didSelectItemsAt`/`didDeselectItemsAt` delegate methods are pure telemetry.
//
// Copy writes original file URLs to the pasteboard in display order. It does not read
// media bytes, decode thumbnails, or materialize cloud placeholders; it only maps the
// collection view's selected identities back through `MediaAssetID.fileURL`.

// MARK: - Selection and copy

extension MediaGridViewController: NSCollectionViewDelegate {
    /// Telemetry only: mouse selection semantics live in `applyMouseSelection`, driven by
    /// `MediaGridCollectionView`'s mouseDown capture, and programmatic selection changes
    /// (structural-apply restore, gesture writes) also route through these.
    func collectionView(_: NSCollectionView, didSelectItemsAt _: Set<IndexPath>) {
        logSelection(reason: "select")
    }

    func collectionView(_: NSCollectionView, didDeselectItemsAt _: Set<IndexPath>) {
        logSelection(reason: "deselect")
    }
}

extension MediaGridViewController {
    /// Called by `MediaGridCollectionView.mouseDown(with:)` (which does not call
    /// `super.mouseDown`, so AppKit's native mouse selection never runs). `hit` is the item
    /// under the click location (`nil` for empty space); `modifiers` are the click's flags.
    /// This is the single owner of the gesture: it computes the next `GridSelection` from
    /// the model alone and writes `selectionIndexPaths` from it as the last operation.
    func applyMouseSelection(hit: IndexPath?, modifiers: NSEvent.ModifierFlags) {
        let shift = modifiers.contains(.shift)
        let command = modifiers.contains(.command)

        // Reconcile the model's selection field with any native keyboard change (⌘A,
        // ⇧-arrows) since the last gesture, so the model observes keyboard selection
        // without ever being read as input to its own computation. Anchor/base are left
        // as-is on keyboard selection (native behavior).
        gridSelection = gridSelection.reconcilingSelection(selectedIdentities())

        let orderedIDs = mutationGate.displayedOrderedIDs

        guard let hit, let clicked = dataSource.itemIdentifier(for: hit) else {
            // Empty-space click. A plain empty-space click clears selection, anchor, and
            // base; a ⇧/⌘ empty-space click would begin a marquee in native AppKit, but the
            // grid has no marquee, so it is a no-op that leaves the selection and anchor.
            if !shift, !command {
                gridSelection = gridSelection.clearedBySpace()
                applySelectionDelta(from: selectedIdentities(), to: gridSelection.selection)
                logSelection(reason: "emptySpace")
            } else {
                logSelection(reason: "shiftEmptySpace")
            }
            return
        }

        let reason: String
        let rangeChanged: Bool
        switch (shift, command) {
        case (false, false):
            gridSelection = gridSelection.plainClick(clicked)
            rangeChanged = false
            reason = "plainClick"
        case (false, true):
            gridSelection = gridSelection.commandClick(clicked)
            rangeChanged = false
            reason = "commandClick"
        case (true, false):
            let before = gridSelection.selection
            gridSelection = gridSelection.shiftClick(clicked, orderedIDs: orderedIDs)
            rangeChanged = gridSelection.selection != before
            reason = "shiftRange"
        case (true, true):
            let before = gridSelection.selection
            gridSelection = gridSelection.commandShiftClick(clicked, orderedIDs: orderedIDs)
            rangeChanged = gridSelection.selection != before
            reason = "commandShiftRange"
        }
        if rangeChanged {}
        applySelectionDelta(from: selectedIdentities(), to: gridSelection.selection)
        logSelection(reason: reason)
    }

    /// Applies only the identities that actually change between `current` and `target`,
    /// so a survivor present in both never receives a select/deselect call (spec 0047:
    /// this is what keeps the animated selection ring from blinking on a survivor).
    func applySelectionDelta(from current: Set<MediaAssetID>, to target: Set<MediaAssetID>) {
        let delta = GridSelection.selectionDelta(current: current, target: target)
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
    /// a gesture.
    func selectedIdentities() -> Set<MediaAssetID> {
        Set(collectionView.selectionIndexPaths.compactMap { dataSource.itemIdentifier(for: $0) })
    }

    /// Restores selection after a structural apply by pruning the model to the surviving
    /// identities, then writing the delta. Applying only the delta — rather than
    /// deselecting everything and reselecting survivors — means a surviving tile's
    /// `isSelected` never changes, so its animated selection ring (spec 0047) never blinks
    /// on an apply that does not actually touch its selection state. The model's anchor and
    /// base follow the same identity rule: an anchor whose asset disappeared clears both,
    /// and an anchor that survives keeps a base pruned of dead identities so a later
    /// shift-range target never contains an identity the grid no longer has (F6).
    func restoreSelection(_ preserved: Set<MediaAssetID>, in ordered: [MediaAssetID]) {
        // `preserved` is the pre-apply selection snapshot; reconcile the model's selection
        // to it, then prune to survivors. (They are normally equal — the model is the
        // truth — but reconcile defensively in case a native keyboard change happened
        // between snapshot and completion.)
        let reconciled = gridSelection.reconcilingSelection(preserved)
        gridSelection = reconciled.selection.isEmpty
            ? GridSelection.empty
            : reconciled.pruned(to: ordered)
        applySelectionDelta(from: selectedIdentities(), to: gridSelection.selection)
        logSelection(reason: "restore")
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

    func clearSelection(reason: String) {
        gridSelection = .empty
        let current = collectionView.selectionIndexPaths
        guard !current.isEmpty else {
            return
        }
        collectionView.deselectItems(at: current)
        logSelection(reason: reason)
    }
}
