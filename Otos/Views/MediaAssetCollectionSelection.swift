import AppKit
import OSLog

// Media collection selection guide
//
// This file contains the AppKit-only selection and copy surface for the media grid.
// SwiftUI provides the surrounding commands and window state, but AppKit owns the
// live collection selection and responder chain. Keeping that bridge here gives one
// path for mouse selection, command validation, and Edit > Copy without mirroring
// selected IDs into a second model.
//
// Shift-click range selection (spec 0046): `NSCollectionView` treats a mouse shift-click
// identically to a ⌘-click — it toggles only the clicked item — because
// `shouldSelectItemsAt` is documented approve/refuse-only and cannot return a superset of
// the proposed selection. The click itself is the authoritative event, so we capture it
// where AppKit consumes it: `MediaGridCollectionView.mouseDown(with:)` records the
// hit-tested item and modifier flags, runs the native selection tracking loop
// (`super.mouseDown`), and then calls `mouseSelectionFinished(hit:modifiers:)` — at which
// point native selection is final. That handler corrects a native shift-toggle into a
// Photos/Lightroom-style contiguous range by applying only the delta
// (`deselectItems`/`selectItems`) within the same event turn, so no paint happens between
// the native result and the correction and nothing flickers. Programmatic
// `selectItems`/`deselectItems` do not re-enter the tracking loop, so the correction
// cannot feed back into itself.
//
// Capturing at mouseDown is what fixes the case delegate inference cannot: a *plain* click
// that collapses a multi-selection onto an already-selected item fires **no**
// `didSelectItemsAt` for the clicked item (only `didDeselectItemsAt` for the ones
// dropped), so a delegate-only handler never learns what was clicked and leaves a stale
// anchor. Because `mouseSelectionFinished` is handed the clicked item directly and reads
// the settled selection, the anchor is set correctly even in that case. The native
// `didSelectItemsAt`/`didDeselectItemsAt` delegate methods are therefore pure telemetry.
//
// `selectionAnchorID`/`anchorBaseSelection` are ephemeral correction state, not a second
// selection truth: `collectionView.selectionIndexPaths` remains authoritative, and the
// anchor and its base are pruned or cleared everywhere the selection itself is pruned or
// cleared. Keyboard ⇧+arrow selection stays native and never touches the anchor.
//
// Copy writes original file URLs to the pasteboard in display order. It does not read
// media bytes, decode thumbnails, or materialize cloud placeholders; it only maps the
// collection view's selected identities back through `MediaAssetID.fileURL`.

// MARK: - Selection and copy

extension MediaAssetCollectionViewController: NSCollectionViewDelegate {
    /// Telemetry only: mouse selection semantics live in `mouseSelectionFinished`, driven
    /// by `MediaGridCollectionView`'s mouseDown capture, and programmatic selection changes
    /// (structural-apply restore, shift-range correction) also route through these.
    func collectionView(_: NSCollectionView, didSelectItemsAt _: Set<IndexPath>) {
        logSelection(reason: "select")
    }

    func collectionView(_: NSCollectionView, didDeselectItemsAt _: Set<IndexPath>) {
        logSelection(reason: "deselect")
    }
}

extension MediaAssetCollectionViewController {
    /// Called by `MediaGridCollectionView` after `super.mouseDown` returns, i.e. once
    /// native selection is final. `hit` is the item under the click location (`nil` for
    /// empty space); `modifiers` are the click's modifier flags. This is the single owner
    /// of the shift-range anchor. When both ⇧ and ⌘ are held, ⇧ wins (a range extension
    /// takes precedence over a toggle).
    func mouseSelectionFinished(hit: IndexPath?, modifiers: NSEvent.ModifierFlags) {
        let shift = modifiers.contains(.shift)
        let command = modifiers.contains(.command)

        guard let hit, let clicked = dataSource.itemIdentifier(for: hit) else {
            // Empty-space click. A plain empty-space click natively clears the selection,
            // so the anchor is meaningless and is cleared; a ⇧/⌘ empty-space click can
            // begin a marquee, so the anchor and base are left intact.
            if !shift, !command {
                selectionAnchorID = nil
                anchorBaseSelection = []
            }
            logSelection(reason: "mouseEmpty")
            return
        }

        // ⇧ with an existing anchor: extend the contiguous range from the anchor. The
        // anchor and base are unchanged so a chain of shift-clicks keeps recomputing from
        // the same origin (grows and shrinks instead of accumulating intermediate clicks).
        if shift, let anchor = selectionAnchorID {
            let current = selectedIdentities()
            let target = MediaGridSelection.shiftRangeSelection(
                anchor: anchor,
                clicked: clicked,
                base: anchorBaseSelection,
                orderedIDs: mutationGate.displayedOrderedIDs
            )
            if target != current {
                applySelectionDelta(from: current, to: target)
                OtosSignpost.ui.emitEvent("MediaGridShiftRangeApplied")
            }
            logSelection(reason: "shiftRange")
            return
        }

        // Plain click, ⌘-click, or ⇧-click with no anchor: the clicked item becomes the
        // new anchor and the current (post native-toggle/collapse) selection becomes the
        // base. The clicked item is known here even when a plain multi-selection collapse
        // fired no `didSelectItemsAt` for it (the F5 fix).
        selectionAnchorID = clicked
        anchorBaseSelection = selectedIdentities()
        logSelection(reason: "anchorSet")
    }

    /// Applies only the identities that actually change between `current` and `target`,
    /// so a survivor present in both never receives a select/deselect call (spec 0047:
    /// this is what keeps the animated selection ring from blinking on a survivor).
    func applySelectionDelta(from current: Set<MediaAssetID>, to target: Set<MediaAssetID>) {
        let delta = MediaGridSelection.selectionDelta(current: current, target: target)
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

extension MediaAssetCollectionViewController: NSUserInterfaceValidations {
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

extension MediaAssetCollectionViewController {
    /// Copy arrives here through the responder chain: the collection view is first
    /// responder but does not implement copy:, so the action travels to this
    /// controller. We write the selected assets' original file URLs to the general
    /// pasteboard in display order (ADR 0012). No image or video bytes are read.
    @objc func copy(_: Any?) {
        let ordered = MediaGridSelection.orderedSelection(
            selectedIdentities(),
            in: mutationGate.displayedOrderedIDs
        )
        let signpost = OtosSignpost.ui.beginInterval("MediaGridCopy")
        let count = MediaGridClipboard.write(ordered, to: .general)
        OtosSignpost.ui.endInterval("MediaGridCopy", signpost)
        OtosSignpost.ui.emitEvent("MediaGridCopyInvoked")
        OtosLog.ui.info("Media grid copy wrote fileURLs count=\(count, privacy: .public)")
    }

    /// The live selection as stable identities, read from the collection view's own
    /// selection so there is no second copy of selection state to keep in sync.
    func selectedIdentities() -> Set<MediaAssetID> {
        Set(collectionView.selectionIndexPaths.compactMap { dataSource.itemIdentifier(for: $0) })
    }

    /// Restores selection after a structural apply: survivors are the previously
    /// selected identities that still exist. Applying only the delta — rather than
    /// deselecting everything and reselecting survivors — means a surviving tile's
    /// `isSelected` never changes, so its animated selection ring (spec 0047) never
    /// blinks on an apply that does not actually touch its selection state. The
    /// shift-click anchor and its base follow the same identity rule: an anchor whose
    /// asset disappeared clears both, and an anchor that survives keeps a base pruned of
    /// any dead identities so a later shift-range target never contains an identity the
    /// grid no longer has (F6) — that would otherwise make the computed target never equal
    /// the live selection and misfire the shift-range signpost on every shift-click.
    func restoreSelection(_ preserved: Set<MediaAssetID>, in ordered: [MediaAssetID]) {
        let current = selectedIdentities()
        let survivors = MediaGridSelection.pruned(preserved, to: ordered)
        applySelectionDelta(from: current, to: survivors)
        if let anchor = selectionAnchorID, ordered.contains(anchor) {
            anchorBaseSelection = MediaGridSelection.pruned(anchorBaseSelection, to: ordered)
        } else {
            selectionAnchorID = nil
            anchorBaseSelection = []
        }
        logSelection(reason: "restore")
    }

    func logSelection(reason: String) {
        let count = collectionView.selectionIndexPaths.count
        OtosSignpost.ui.emitEvent("MediaGridSelectionChanged")
        OtosLog.ui.debug(
            """
            Media grid selection changed count=\(count, privacy: .public) \
            reason=\(reason, privacy: .public)
            """
        )
    }

    func clearSelection(reason: String) {
        selectionAnchorID = nil
        anchorBaseSelection = []
        let current = collectionView.selectionIndexPaths
        guard !current.isEmpty else {
            return
        }
        collectionView.deselectItems(at: current)
        logSelection(reason: reason)
    }
}
