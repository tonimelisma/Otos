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

    /// AppKit drives selection from `NSCollectionView`; the tile only renders it.
    override var isSelected: Bool {
        didSet { tileView?.setSelected(isSelected) }
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
        OtosSignpost.ui.emitEvent("MediaGridSlowCellConfiguration")
        OtosLog.ui.debug(
            """
            Media grid slow cell assetID=\(detail.libraryRootPath.rawValue, privacy: .public)/\
            \(detail.relativePath.rawValue, privacy: .public) configureMs=\(elapsedMs, privacy: .public)
            """
        )
        return startedLoad
    }
}
