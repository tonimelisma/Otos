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

/// Ferries a freshly loaded thumbnail and its capture-date label from the background
/// loader to the main actor. `@unchecked Sendable` is sound here: the `NSImage` is
/// created inside the loader, never mutated, and handed across exactly once.
private struct LoadedTile: @unchecked Sendable {
    let image: NSImage?
    let dateText: String
}

private final class MediaAssetTileView: NSView {
    private let imageView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let dateField = NSTextField(labelWithString: "")
    private let videoIconView = NSImageView()

    /// Identifies the content the async load produced (thumbnail file + its enrichment
    /// stamp + the displayed date). Equal keys mean nothing visible changed, so a 10 Hz
    /// detail refresh of an unchanged tile does not re-decode or re-format anything.
    private var currentContentKey: String?
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
            return
        }
        currentContentKey = key
        loadThumbnailAndDate(asset: asset, thumbnailDirectory: thumbnailDirectory)
    }

    /// Reads the thumbnail file and formats the date off the main actor (file I/O,
    /// decode, and formatting must never run on the scroll thread), then applies the
    /// result on the main actor only if this tile still represents the same content.
    private func loadThumbnailAndDate(asset: MediaAsset, thumbnailDirectory: URL?) {
        loadGeneration += 1
        let generation = loadGeneration
        loadTask?.cancel()
        loadTask = Task.detached(priority: .utility) { [weak self] in
            let loaded = MediaAssetTilePresentation.load(asset: asset, thumbnailDirectory: thumbnailDirectory)
            if Task.isCancelled {
                return
            }
            await MainActor.run {
                guard let self, self.loadGeneration == generation else {
                    return
                }
                self.imageView.image = loaded.image
                self.dateField.stringValue = loaded.dateText
            }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        loadGeneration += 1
        currentContentKey = nil
        imageView.image = nil
        titleField.stringValue = ""
        dateField.stringValue = ""
        videoIconView.isHidden = true
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
        MediaEligibility.isVideo(contentTypeIdentifier: asset.contentTypeIdentifier)
    }

    static func isCatalogMedia(_ asset: MediaAsset) -> Bool {
        MediaEligibility.isCatalogMedia(contentTypeIdentifier: asset.contentTypeIdentifier)
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
