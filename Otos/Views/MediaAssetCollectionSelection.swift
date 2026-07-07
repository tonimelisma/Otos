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
// Shift-click range selection (spec 0046): `NSCollectionView` treats a mouse
// shift-click identically to a ⌘-click — it toggles only the clicked item — because
// `shouldSelectItemsAt` is documented approve/refuse-only and cannot return a superset
// of the proposed selection. `handleUserSelectionEvent` corrects that native two-item
// toggle into a Photos/Lightroom-style contiguous range by applying the delta
// (`deselectItems`/`selectItems`) synchronously inside the same delegate turn, so no
// paint happens between AppKit's native result and the correction and nothing flickers.
// Programmatic `selectItems`/`deselectItems` do not re-enter these delegate methods, so
// the correction cannot feed back into itself.
//
// Both native delegate methods route through the one handler because a single click can
// fire either or both, and native shift/⌘-click each toggle exactly one item (no
// collateral change to any other item), so an `indexPaths.count == 1` call is always
// unambiguous for those two modifiers. A *plain* click is the one case where two calls
// can fire for a single physical click — `didSelectItemsAt` for the newly clicked item
// and, if a different single item was previously selected, `didDeselectItemsAt` for the
// old one, in unspecified order — so plain-click anchor updates trust only the `select`
// call and ignore the paired `deselect` call, keeping anchor assignment order-independent.
//
// `selectionAnchorID`/`anchorBaseSelection` are ephemeral correction state, not a second
// selection truth: `collectionView.selectionIndexPaths` remains authoritative, and the
// anchor is pruned or cleared everywhere the selection itself is pruned or cleared.
//
// Copy writes original file URLs to the pasteboard in display order. It does not read
// media bytes, decode thumbnails, or materialize cloud placeholders; it only maps the
// collection view's selected identities back through `MediaAssetID.fileURL`.

// MARK: - Selection and copy

enum UserSelectionEventKind {
    case select
    case deselect
}

extension MediaAssetCollectionViewController: NSCollectionViewDelegate {
    func collectionView(_: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        handleUserSelectionEvent(indexPaths: indexPaths, kind: .select, event: NSApp.currentEvent)
    }

    func collectionView(_: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        handleUserSelectionEvent(indexPaths: indexPaths, kind: .deselect, event: NSApp.currentEvent)
    }
}

extension MediaAssetCollectionViewController {
    /// Single entry point for both native selection delegate callbacks. `event` is a
    /// parameter (rather than read from `NSApp.currentEvent` internally) so tests can
    /// drive this with a synthesized `NSEvent` without touching the app's live event
    /// stream. Only single-item, left-mouse events are ever click-like; everything else
    /// (keyboard ⇧+arrows, marquee/rubber-band drags reporting many items at once, ⌘A)
    /// falls through to plain logging and leaves the anchor untouched, matching native
    /// behavior for those gestures.
    func handleUserSelectionEvent(indexPaths: Set<IndexPath>, kind: UserSelectionEventKind, event: NSEvent?) {
        guard
            indexPaths.count == 1,
            let clicked = dataSource.itemIdentifier(for: indexPaths.first!),
            let event,
            event.type == .leftMouseDown || event.type == .leftMouseUp
        else {
            logSelection(reason: kind == .select ? "select" : "deselect")
            return
        }

        if event.modifierFlags.contains(.shift), let anchor = selectionAnchorID {
            if applyShiftRangeCorrection(anchor: anchor, clicked: clicked) {
                OtosSignpost.ui.emitEvent("MediaGridShiftRangeApplied")
            }
            logSelection(reason: "shiftRange")
            return
        }

        // A shift-click with no anchor (or a ⌘-click, which never has a collateral
        // deselect call) is unambiguous regardless of which callback fired. Only a plain
        // click's paired deselect-of-the-old-selection call must be ignored here.
        let isPlainClick = !event.modifierFlags.contains(.shift) && !event.modifierFlags.contains(.command)
        guard !isPlainClick || kind == .select else {
            logSelection(reason: "deselect")
            return
        }

        selectionAnchorID = clicked
        anchorBaseSelection = selectedIdentities()
        logSelection(reason: "anchorSet")
    }

    /// Computes the full corrected range and applies only the delta against the current
    /// (already native-toggled) selection. Returns `false` when the computed target
    /// already matches the current selection, so callers can skip a redundant signpost.
    private func applyShiftRangeCorrection(anchor: MediaAssetID, clicked: MediaAssetID) -> Bool {
        let current = selectedIdentities()
        let target = MediaGridSelection.shiftRangeSelection(
            anchor: anchor,
            clicked: clicked,
            base: anchorBaseSelection,
            orderedIDs: mutationGate.displayedOrderedIDs
        )
        guard target != current else {
            return false
        }
        applySelectionDelta(from: current, to: target)
        return true
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
    /// shift-click anchor is pruned by the same identity rule: an anchor whose asset
    /// disappeared must not resurrect a stale range on the next shift-click.
    func restoreSelection(_ preserved: Set<MediaAssetID>, in ordered: [MediaAssetID]) {
        let current = selectedIdentities()
        let survivors = MediaGridSelection.pruned(preserved, to: ordered)
        applySelectionDelta(from: current, to: survivors)
        if let anchor = selectionAnchorID, !ordered.contains(anchor) {
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
