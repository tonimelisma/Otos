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
/// The thumbnail read/decode and date formatting run off the main actor (never on the
/// scroll thread); a generation token discards a load that resolves after the reusable
/// tile has moved on to another asset.
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

    func configure(asset: MediaAsset, thumbnailDirectory: URL?) {
        guard let tileView else {
            return
        }
        let signpost = OtosSignpost.ui.beginInterval("MediaGridCellConfiguration")
        defer {
            OtosSignpost.ui.endInterval("MediaGridCellConfiguration", signpost)
        }
        let start = Date()
        tileView.configure(asset: asset, thumbnailDirectory: thumbnailDirectory)
        let elapsedMs = DiagnosticsTiming.milliseconds(since: start)
        guard elapsedMs >= 5 else {
            return
        }
        OtosSignpost.ui.emitEvent("MediaGridSlowCellConfiguration")
        OtosLog.ui.error(
            """
            Media grid slow cell assetID=\(asset.libraryRootPath.rawValue, privacy: .public)/\
            \(asset.relativePath.rawValue, privacy: .public) configureMs=\(elapsedMs, privacy: .public)
            """
        )
    }
}

/// Ferries a freshly loaded thumbnail and its capture-date label from the
/// background loader to the main actor. `CGImage` is immutable and Sendable, so
/// no unchecked wrapper is needed; the main actor only assigns it to the layer.
private struct LoadedTile {
    let image: CGImage?
    let dateText: String
}

private final class MediaAssetTileView: NSView {
    private let imageView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let dateField = NSTextField(labelWithString: "")
    private let videoIconView = NSImageView()

    /// Identifies the content the async load produced (thumbnail file + its enrichment
    /// stamp + the displayed date). Equal keys mean nothing visible changed, so a
    /// detail refresh of an unchanged tile does not re-decode or re-format anything.
    private var currentContentKey: String?
    private var currentDiagnosticID: String?
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

    func configure(asset: MediaAsset, thumbnailDirectory: URL?) {
        currentDiagnosticID = MediaAssetTilePresentation.diagnosticID(asset)
        let isVideo = MediaAssetTilePresentation.isVideo(asset)
        titleField.stringValue = MediaAssetTilePresentation.title(asset)
        videoIconView.isHidden = !isVideo
        layer?.backgroundColor = isVideo
            ? NSColor.systemBlue.withAlphaComponent(0.20).cgColor
            : NSColor.secondaryLabelColor.withAlphaComponent(0.12).cgColor
        setAccessibilityLabel(titleField.stringValue)
        needsLayout = true

        let key = MediaAssetTilePresentation.contentKey(asset)
        guard key != currentContentKey else {
            OtosSignpost.ui.emitEvent("MediaTileContentUnchanged")
            let diagnosticID = currentDiagnosticID ?? "unknown"
            OtosLog.ui.debug(
                "Media tile content unchanged assetID=\(diagnosticID, privacy: .public)"
            )
            return
        }
        currentContentKey = key
        loadThumbnailAndDate(asset: asset, thumbnailDirectory: thumbnailDirectory)
    }

    /// Draws or clears the selection ring. It uses the layer border rather than the
    /// background so it is independent of the video/neutral `backgroundColor` that
    /// `configure` rewrites on every reuse; a border ring is never clobbered by a
    /// same-identity content refresh.
    func setSelected(_ selected: Bool) {
        layer?.borderWidth = selected ? 3 : 0
        layer?.borderColor = selected ? NSColor.controlAccentColor.cgColor : nil
    }

    /// Reads the thumbnail file and formats the date off the main actor (file I/O,
    /// decode, and formatting must never run on the scroll thread), then applies the
    /// result on the main actor only if this tile still represents the same content.
    private func loadThumbnailAndDate(asset: MediaAsset, thumbnailDirectory: URL?) {
        loadGeneration += 1
        let generation = loadGeneration
        let diagnosticID = MediaAssetTilePresentation.diagnosticID(asset)
        let thumbnailPath = asset.thumbnailPath ?? "none"
        loadTask?.cancel()
        OtosSignpost.ui.emitEvent("MediaTileLoadStarted")
        OtosLog.ui.debug(
            """
            Media tile load started assetID=\(diagnosticID, privacy: .public) \
            thumbnailPath=\(thumbnailPath, privacy: .public)
            """
        )
        loadTask = Task.detached(priority: .utility) { [weak self] in
            let loaded = MediaAssetTilePresentation.load(asset: asset, thumbnailDirectory: thumbnailDirectory)
            if Task.isCancelled {
                return
            }
            await MainActor.run {
                guard let self else {
                    return
                }
                guard self.loadGeneration == generation else {
                    OtosSignpost.ui.emitEvent("MediaTileLoadDropped")
                    OtosLog.ui.debug(
                        "Media tile load dropped assetID=\(diagnosticID, privacy: .public)"
                    )
                    return
                }
                self.imageView.image = nil
                self.imageView.layer?.contents = loaded.image
                self.dateField.stringValue = loaded.dateText
                OtosSignpost.ui.emitEvent("MediaTileLoadApplied")
                OtosLog.ui.debug(
                    """
                    Media tile load applied assetID=\(diagnosticID, privacy: .public) \
                    hasImage=\(loaded.image != nil, privacy: .public)
                    """
                )
            }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        OtosSignpost.ui.emitEvent("MediaTilePrepareForReuse")
        let diagnosticID = currentDiagnosticID ?? "unknown"
        OtosLog.ui.debug(
            "Media tile prepared for reuse assetID=\(diagnosticID, privacy: .public)"
        )
        loadTask?.cancel()
        loadTask = nil
        loadGeneration += 1
        currentContentKey = nil
        currentDiagnosticID = nil
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

    nonisolated static func diagnosticID(_ asset: MediaAsset) -> String {
        asset.libraryRootPath.rawValue + "/" + asset.relativePath.rawValue
    }

    /// The capture date shown on the tile, formatted with a value-type style (Sendable,
    /// safe off the main actor). Empty when nothing is known — never a fabricated date.
    nonisolated static func captureDateText(_ asset: MediaAsset) -> String {
        guard let date = asset.bestCaptureDate else {
            return ""
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    /// Distinguishes everything the async tile load produces: the thumbnail file, the
    /// full `(size, mtime)` enrichment stamp that changes when the file is re-thumbnailed
    /// (size is included because bytes can change while mtime seconds stay equal), and the
    /// displayed date.
    nonisolated static func contentKey(_ asset: MediaAsset) -> String {
        let thumbnail = asset.thumbnailPath ?? ""
        let size = asset.enrichedSourceSize ?? -1
        let stamp = asset.enrichedSourceMTimeSeconds ?? -1
        let date = asset.bestCaptureDate?.timeIntervalSince1970 ?? -1
        return "\(thumbnail)#\(size)#\(stamp)#\(date)"
    }

    /// Loads the thumbnail (if enriched and a directory exists) and formats the date.
    /// Pure and `nonisolated`, so it runs on a background executor. `fileprivate` because
    /// it returns the file-private `LoadedTile` ferry.
    fileprivate nonisolated static func load(asset: MediaAsset, thumbnailDirectory: URL?) -> LoadedTile {
        let image = asset.thumbnailPath.flatMap { name in
            thumbnailDirectory.flatMap { ThumbnailStore.load(name, in: $0) }
        }
        return LoadedTile(image: image, dateText: captureDateText(asset))
    }
}
