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
// Copy writes original file URLs to the pasteboard in display order. It does not read
// media bytes, decode thumbnails, or materialize cloud placeholders; it only maps the
// collection view's selected identities back through `MediaAssetID.fileURL`.

// MARK: - Selection and copy

extension MediaAssetCollectionViewController: NSCollectionViewDelegate {
    /// User clicks drive native selection; we only observe it for telemetry. The
    /// programmatic restore below uses select/deselectItems, which do not call these
    /// delegate methods, so restore cannot feed back into itself.
    func collectionView(_: NSCollectionView, didSelectItemsAt _: Set<IndexPath>) {
        logSelection(reason: "select")
    }

    func collectionView(_: NSCollectionView, didDeselectItemsAt _: Set<IndexPath>) {
        logSelection(reason: "deselect")
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
            in: applyGate.displayedOrderedIDs
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
    /// selected identities that still exist. select/deselectItems update the tiles'
    /// rings without re-entering the delegate.
    func restoreSelection(_ preserved: Set<MediaAssetID>, in ordered: [MediaAssetID]) {
        let current = collectionView.selectionIndexPaths
        if !current.isEmpty {
            collectionView.deselectItems(at: current)
        }
        let survivors = MediaGridSelection.pruned(preserved, to: ordered)
        let paths = Set(survivors.compactMap { dataSource.indexPath(for: $0) })
        if !paths.isEmpty {
            collectionView.selectItems(at: paths, scrollPosition: [])
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
        let current = collectionView.selectionIndexPaths
        guard !current.isEmpty else {
            return
        }
        collectionView.deselectItems(at: current)
        logSelection(reason: reason)
    }
}
