import AppKit
import Foundation
import OSLog

// Collection item guide
//
// One reusable AppKit item hosts one `MediaAssetTileView`. The collection bridge
// owns structure, sticky `TileContentStore`, and decode; the item forwards AppKit
// lifecycle and records slow synchronous configuration spans.

final class MediaGridItem: NSCollectionViewItem {
    var onMediaChoice: ((MediaChoice) -> Void)? {
        didSet { tileView?.onMediaChoice = onMediaChoice }
    }

    private var tileView: MediaAssetTileView? {
        view as? MediaAssetTileView
    }

    /// AppKit drives selection from `NSCollectionView`; the tile only renders it. This is
    /// reassigned both for a real selection change and when binding a recycled item to an
    /// already-selected asset — `prepareForReuse` resets to unselected, then AppKit sets
    /// `isSelected = true` again as the tile scrolls back into view — so a selected tile
    /// re-fades its ring on scroll-in. That is accepted as polish, not a defect:
    /// distinguishing the two would need a hook AppKit does not expose, and the fade
    /// reads as intentional. During a *structural apply* a surviving on-screen tile
    /// still never re-fades, because `renderSelectionFromModel` is delta-based and never
    /// reassigns a survivor's `isSelected`.
    override var isSelected: Bool {
        didSet { tileView?.setSelected(isSelected, animated: true) }
    }

    override func loadView() {
        view = MediaAssetTileView()
        tileView?.onMediaChoice = onMediaChoice
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        tileView?.prepareForReuse()
    }

    /// Hover is owned by `MediaGridBridge`; the item only forwards it, the same
    /// way it forwards selection.
    func setChoiceControlVisible(_ visible: Bool) {
        tileView?.setChoiceControlVisible(visible)
    }

    /// The tile's outlined face boxes, owned by `MediaGridBridge` like hover.
    func setFaceOutlines(_ boxes: [CGRect]) {
        tileView?.setFaceOutlines(boxes)
    }

    var isChoiceControlVisible: Bool {
        tileView?.isChoiceControlVisible ?? false
    }

    func render(content: TileContent?, change: TileContentChange) {
        guard let tileView else {
            return
        }
        let signpost = OtosSignpost.ui.beginInterval("MediaGridCellConfiguration")
        defer { OtosSignpost.ui.endInterval("MediaGridCellConfiguration", signpost) }

        let start = ContinuousClock.now
        tileView.render(content, change: change)
        let elapsedMs = DiagnosticsTiming.milliseconds(since: start)
        guard elapsedMs >= 5, let content else {
            return
        }
        OtosLog.ui.debug(
            """
            Media grid slow cell assetID=\(content.detail.libraryRootPath.rawValue, privacy: .public)/\
            \(content.detail.relativePath.rawValue, privacy: .public) configureMs=\(elapsedMs, privacy: .public)
            """
        )
    }
}
