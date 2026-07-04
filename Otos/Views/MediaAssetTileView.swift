import AppKit
import Foundation
import OSLog

/// Media tile guide
///
/// One reusable AppKit item and its view render a single grid cell. The collection
/// bridge (`MediaAssetCollectionView`) owns viewport, reuse, and structure; this file
/// owns only how one tile paints itself: title, video badge, thumbnail, and capture
/// date. Keeping it separate keeps each file focused and lets the tile's pure policy
/// (`MediaAssetTilePresentation`) be unit-tested without any AppKit lifecycle.
///
/// The thumbnail read/decode runs off the main actor (never on the scroll thread);
/// a generation token discards a load that resolves after the reusable tile has
/// moved on to another asset. Capture-date text is cheap scalar UI text and is
/// assigned synchronously, so a date-only enrichment update does not clear the
/// already-painted thumbnail.
final class MediaAssetCollectionItem: NSCollectionViewItem {
    private var tileView: MediaAssetTileView? {
        view as? MediaAssetTileView
    }

    /// AppKit sets `isSelected` on the reusable item as the collection view's
    /// selection changes (user clicks and the controller's post-apply restore). The
    /// tile draws the accent ring from this, so selection appearance is driven by one
    /// source — the collection view's selection — not tracked separately in the view.
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
    func configure(asset: MediaAsset, thumbnailDirectory: URL?) -> Bool {
        guard let tileView else {
            return false
        }
        let signpost = OtosSignpost.ui.beginInterval("MediaGridCellConfiguration")
        defer {
            OtosSignpost.ui.endInterval("MediaGridCellConfiguration", signpost)
        }
        let start = Date()
        let startedLoad = tileView.configure(asset: asset, thumbnailDirectory: thumbnailDirectory)
        let elapsedMs = DiagnosticsTiming.milliseconds(since: start)
        guard elapsedMs >= 5 else {
            return startedLoad
        }
        OtosSignpost.ui.emitEvent("MediaGridSlowCellConfiguration")
        OtosLog.ui.error(
            """
            Media grid slow cell assetID=\(asset.libraryRootPath.rawValue, privacy: .public)/\
            \(asset.relativePath.rawValue, privacy: .public) configureMs=\(elapsedMs, privacy: .public)
            """
        )
        return startedLoad
    }
}

/// Ferries a freshly loaded thumbnail from the background loader to the main
/// actor. `CGImage` is immutable and Sendable, so no unchecked wrapper is needed;
/// the main actor only assigns it to the layer.
private struct LoadedTile {
    let image: CGImage?
}

private final class MediaAssetTileView: NSView {
    private let imageView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let dateField = NSTextField(labelWithString: "")
    private let videoIconView = NSImageView()

    /// Identifies the image content the async load produced (thumbnail file plus its
    /// enrichment stamp). Equal keys mean the painted thumbnail can stay in place even
    /// when capture-date text changes.
    private var currentImageContentKey: String?
    /// Bumped on every (re)configure and reuse so an in-flight load that resolves after
    /// the tile was handed to another asset is discarded instead of painting stale data.
    private var loadGeneration = 0
    private var loadTask: Task<Void, Never>?

    override var isFlipped: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.masksToBounds = true

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.layer?.contentsGravity = .resizeAspect
        addSubview(imageView)

        titleField.font = .systemFont(ofSize: 12, weight: .medium)
        titleField.textColor = .labelColor
        titleField.usesSingleLineMode = true
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.cell?.truncatesLastVisibleLine = true
        addSubview(titleField)

        dateField.font = .systemFont(ofSize: 10, weight: .regular)
        dateField.textColor = .secondaryLabelColor
        dateField.usesSingleLineMode = true
        dateField.lineBreakMode = .byTruncatingTail
        addSubview(dateField)

        videoIconView.image = NSImage(systemSymbolName: "video.fill", accessibilityDescription: "Video")
        videoIconView.imageScaling = .scaleProportionallyDown
        videoIconView.contentTintColor = .secondaryLabelColor
        addSubview(videoIconView)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @discardableResult
    func configure(asset: MediaAsset, thumbnailDirectory: URL?) -> Bool {
        let isVideo = MediaAssetTilePresentation.isVideo(asset)
        titleField.stringValue = MediaAssetTilePresentation.title(asset)
        dateField.stringValue = MediaAssetTilePresentation.captureDateText(asset)
        videoIconView.isHidden = !isVideo
        layer?.backgroundColor = isVideo
            ? NSColor.systemBlue.withAlphaComponent(0.20).cgColor
            : NSColor.secondaryLabelColor.withAlphaComponent(0.12).cgColor
        setAccessibilityLabel(titleField.stringValue)
        needsLayout = true

        let key = MediaAssetTilePresentation.imageContentKey(asset)
        guard key != currentImageContentKey else {
            OtosSignpost.ui.emitEvent("MediaTileContentUnchanged")
            return false
        }
        currentImageContentKey = key
        loadThumbnailImage(asset: asset, thumbnailDirectory: thumbnailDirectory)
        return true
    }

    /// Draws or clears the selection ring. It uses the layer border rather than the
    /// background so it is independent of the video/neutral `backgroundColor` that
    /// `configure` rewrites on every reuse; a border ring is never clobbered by a
    /// same-identity content refresh.
    func setSelected(_ selected: Bool) {
        layer?.borderWidth = selected ? 3 : 0
        layer?.borderColor = selected ? NSColor.controlAccentColor.cgColor : nil
    }

    /// Reads the thumbnail file off the main actor, then applies the result on the main
    /// actor only if this tile still represents the same image content.
    private func loadThumbnailImage(asset: MediaAsset, thumbnailDirectory: URL?) {
        loadGeneration += 1
        let generation = loadGeneration
        loadTask?.cancel()
        OtosSignpost.ui.emitEvent("MediaTileLoadStarted")
        loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            let loaded = MediaAssetTilePresentation.loadImage(asset: asset, thumbnailDirectory: thumbnailDirectory)
            if Task.isCancelled {
                return
            }
            await MainActor.run {
                guard let self else {
                    return
                }
                guard self.loadGeneration == generation else {
                    OtosSignpost.ui.emitEvent("MediaTileLoadDropped")
                    return
                }
                self.imageView.image = nil
                self.imageView.layer?.contents = loaded.image
                OtosSignpost.ui.emitEvent("MediaTileLoadApplied")
            }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        OtosSignpost.ui.emitEvent("MediaTilePrepareForReuse")
        loadTask?.cancel()
        loadTask = nil
        loadGeneration += 1
        currentImageContentKey = nil
        imageView.image = nil
        imageView.layer?.contents = nil
        titleField.stringValue = ""
        dateField.stringValue = ""
        videoIconView.isHidden = true
        setSelected(false)
        setAccessibilityLabel(nil)
    }

    override func layout() {
        super.layout()
        imageView.frame = bounds
        let inset: CGFloat = 8
        let iconSize: CGFloat = 13
        let iconVisible = !videoIconView.isHidden
        videoIconView.frame = NSRect(
            x: max(bounds.width - inset - iconSize, inset),
            y: inset,
            width: iconSize,
            height: iconSize
        )
        let iconAllowance = iconVisible ? iconSize + 6 : 0
        titleField.frame = NSRect(
            x: inset,
            y: inset - 1,
            width: max(bounds.width - inset * 2 - iconAllowance, 0),
            height: 17
        )
        dateField.frame = NSRect(
            x: inset,
            y: max(bounds.height - inset - 14, inset),
            width: max(bounds.width - inset * 2, 0),
            height: 14
        )
    }
}

/// Keeps content-type, fallback-title, capture-date, and thumbnail-load policy
/// independent from reusable AppKit view state so each can be tested directly.
enum MediaAssetTilePresentation {
    static func isVideo(_ asset: MediaAsset) -> Bool {
        asset.bestKind == .video
    }

    static func title(_ asset: MediaAsset) -> String {
        if let name = asset.name {
            return name
        }
        return URL(fileURLWithPath: asset.relativePath.rawValue).lastPathComponent
    }

    /// The capture date shown on the tile, formatted with a value-type style (Sendable,
    /// safe off the main actor). Empty when nothing is known — never a fabricated date.
    nonisolated static func captureDateText(_ asset: MediaAsset) -> String {
        guard let date = asset.bestCaptureDate else {
            return ""
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    /// Distinguishes the async image load result: the thumbnail file plus the full
    /// `(size, mtime)` enrichment stamp that changes when the file is re-thumbnailed
    /// (size is included because bytes can change while mtime seconds stay equal).
    /// Capture-date text is not part of image identity, so a date-only update does
    /// not clear and reload the thumbnail.
    nonisolated static func imageContentKey(_ asset: MediaAsset) -> String {
        let thumbnail = asset.thumbnailPath ?? ""
        let size = asset.enrichedSourceSize ?? -1
        let stamp = asset.enrichedSourceMTimeSeconds ?? -1
        return "\(thumbnail)#\(size)#\(stamp)"
    }

    /// Loads the thumbnail (if enriched and a directory exists).
    /// Pure and `nonisolated`, so it runs on a background executor. `fileprivate` because
    /// it returns the file-private `LoadedTile` ferry.
    fileprivate nonisolated static func loadImage(asset: MediaAsset, thumbnailDirectory: URL?) -> LoadedTile {
        let image = asset.thumbnailPath.flatMap { name in
            thumbnailDirectory.flatMap { ThumbnailStore.load(name, in: $0) }
        }
        return LoadedTile(image: image)
    }
}
