import AppKit
import Foundation
import OSLog

// Collection item guide
//
// One reusable AppKit item hosts one `MediaAssetTileView`. The collection bridge
// owns structure and reuse; the item simply forwards AppKit lifecycle events and
// records slow synchronous configuration spans.

final class MediaAssetCollectionItem: NSCollectionViewItem {
    private var tileView: MediaAssetTileView? {
        view as? MediaAssetTileView
    }

    /// AppKit drives selection from `NSCollectionView`; the tile only renders it. This is
    /// reassigned both for a real selection change and when binding a recycled item to an
    /// already-selected asset — `prepareForReuse` resets to unselected, then AppKit sets
    /// `isSelected = true` again as the tile scrolls back into view — so a selected tile
    /// re-fades its ring on scroll-in. That is accepted as polish (spec 0047), not a
    /// defect: distinguishing the two would need a hook AppKit does not expose, and the
    /// fade reads as intentional. During a *structural apply* a surviving on-screen tile
    /// still never re-fades, because `restoreSelection` is delta-based and never reassigns
    /// a survivor's `isSelected`.
    override var isSelected: Bool {
        didSet { tileView?.setSelected(isSelected, animated: true) }
    }

    override func loadView() {
        view = MediaAssetTileView()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        tileView?.prepareForReuse()
    }

    @discardableResult
    func configure(
        detail: MediaTileDetail,
        thumbnailDirectory: URL?,
        imageCache: MediaTileImageCache?
    ) -> Bool {
        guard let tileView else {
            return false
        }
        let signpost = OtosSignpost.ui.beginInterval("MediaGridCellConfiguration")
        defer { OtosSignpost.ui.endInterval("MediaGridCellConfiguration", signpost) }

        let start = Date()
        let startedLoad = tileView.configure(
            detail: detail,
            thumbnailDirectory: thumbnailDirectory,
            imageCache: imageCache
        )
        let elapsedMs = DiagnosticsTiming.milliseconds(since: start)
        guard elapsedMs >= 5 else {
            return startedLoad
        }
        OtosLog.ui.debug(
            """
            Media grid slow cell assetID=\(detail.libraryRootPath.rawValue, privacy: .public)/\
            \(detail.relativePath.rawValue, privacy: .public) configureMs=\(elapsedMs, privacy: .public)
            """
        )
        return startedLoad
    }
}
