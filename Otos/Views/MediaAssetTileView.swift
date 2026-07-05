import AppKit
import Foundation
import OSLog

/// Media tile guide
///
/// One reusable AppKit item and its view render a single grid cell. The collection
/// bridge (`MediaAssetCollectionView`) owns viewport, reuse, and structure; this file
/// owns only how one tile paints itself: thumbnail face, filename/date overlays,
/// video badge, and selection ring. Keeping it separate keeps each file focused and
/// lets the tile's pure policy (`MediaAssetTilePresentation`) be unit-tested without
/// any AppKit lifecycle.
///
/// The thumbnail read/decode runs off the main actor (never on the scroll thread);
/// a generation token discards a load that resolves after the reusable tile has
/// moved on to another asset. Overlay text is cheap scalar UI state and is assigned
/// synchronously, so date- or duration-only enrichment updates do not clear the
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
    let pixelSize: CGSize?
}

private final class FlippedView: NSView {
    override var isFlipped: Bool {
        true
    }
}

private final class MediaAssetTileView: NSView {
    private enum Layout {
        static let contentCornerRadius: CGFloat = 4
        static let scrimCornerRadius: CGFloat = 3
        static let overlayInset: CGFloat = 6
        static let scrimPaddingX: CGFloat = 5
        static let scrimPaddingY: CGFloat = 4
        static let titleHeight: CGFloat = 14
        static let dateHeight: CGFloat = 12
        static let lineGap: CGFloat = 1
        static let badgeHeight: CGFloat = 20
        static let badgeMinWidth: CGFloat = 22
        static let filmIconSize: CGFloat = 13
    }

    private let contentView = FlippedView()
    private let imageView = NSImageView()
    private let textScrim = FlippedView()
    private let titleField = NSTextField(labelWithString: "")
    private let dateField = NSTextField(labelWithString: "")
    private let videoBadge = FlippedView()
    private let durationField = NSTextField(labelWithString: "")
    private let filmIconView = NSImageView()

    /// Identifies the image content the async load produced (thumbnail file plus its
    /// enrichment stamp). Equal keys mean the painted thumbnail can stay in place even
    /// when overlay text changes.
    private var currentImageContentKey: String?
    private var currentImagePixelSize: CGSize?
    private var shouldShowVideoBadge = false
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
        layer?.backgroundColor = nil

        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = Layout.contentCornerRadius
        contentView.layer?.masksToBounds = true
        addSubview(contentView)

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.layer?.contentsGravity = .resizeAspect
        contentView.addSubview(imageView)

        textScrim.wantsLayer = true
        textScrim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        textScrim.layer?.cornerRadius = Layout.scrimCornerRadius
        textScrim.layer?.masksToBounds = true
        contentView.addSubview(textScrim)

        titleField.font = .systemFont(ofSize: 11, weight: .medium)
        titleField.textColor = .white
        titleField.usesSingleLineMode = true
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.cell?.truncatesLastVisibleLine = true
        textScrim.addSubview(titleField)

        dateField.font = .systemFont(ofSize: 9, weight: .regular)
        dateField.textColor = .white
        dateField.usesSingleLineMode = true
        dateField.lineBreakMode = .byTruncatingTail
        textScrim.addSubview(dateField)

        videoBadge.wantsLayer = true
        videoBadge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        videoBadge.layer?.cornerRadius = Layout.scrimCornerRadius
        videoBadge.layer?.masksToBounds = true
        contentView.addSubview(videoBadge)

        durationField.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        durationField.textColor = .white
        durationField.alignment = .center
        durationField.usesSingleLineMode = true
        durationField.lineBreakMode = .byClipping
        videoBadge.addSubview(durationField)

        filmIconView.image = NSImage(systemSymbolName: "film", accessibilityDescription: "Video")
        filmIconView.imageScaling = .scaleProportionallyDown
        filmIconView.contentTintColor = .white
        videoBadge.addSubview(filmIconView)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @discardableResult
    func configure(asset: MediaAsset, thumbnailDirectory: URL?) -> Bool {
        titleField.stringValue = MediaAssetTilePresentation.title(asset)
        dateField.stringValue = MediaAssetTilePresentation.captureDateText(asset)
        shouldShowVideoBadge = MediaAssetTilePresentation.showsVideoBadge(asset)
        if let badgeText = MediaAssetTilePresentation.videoBadgeText(asset) {
            durationField.stringValue = badgeText
            durationField.isHidden = false
            filmIconView.isHidden = true
        } else {
            durationField.stringValue = ""
            durationField.isHidden = true
            filmIconView.isHidden = !shouldShowVideoBadge
        }
        setAccessibilityLabel(accessibilityLabel(title: titleField.stringValue, date: dateField.stringValue))
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
                self.currentImagePixelSize = loaded.pixelSize
                self.updatePlaceholderBackground()
                self.needsLayout = true
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
        currentImagePixelSize = nil
        shouldShowVideoBadge = false
        imageView.image = nil
        imageView.layer?.contents = nil
        titleField.stringValue = ""
        dateField.stringValue = ""
        durationField.stringValue = ""
        durationField.isHidden = true
        filmIconView.isHidden = true
        videoBadge.isHidden = true
        textScrim.isHidden = true
        updatePlaceholderBackground()
        setSelected(false)
        setAccessibilityLabel(nil)
    }

    override func layout() {
        super.layout()
        contentView.frame = MediaAssetTilePresentation.contentRect(
            imagePixelSize: currentImagePixelSize,
            bounds: bounds
        )
        imageView.frame = contentView.bounds
        updatePlaceholderBackground()
        layoutTextScrim()
        layoutVideoBadge()
    }

    /// Draws or clears the selection ring. The ring lives on `contentView` so it
    /// hugs the thumbnail's actual aspect-fit face, not the transparent square cell.
    func setSelected(_ selected: Bool) {
        contentView.layer?.borderWidth = selected ? 3 : 0
        contentView.layer?.borderColor = selected ? NSColor.controlAccentColor.cgColor : nil
    }

    private func layoutTextScrim() {
        let contentBounds = contentView.bounds
        let visibility = MediaAssetTilePresentation.overlayVisibility(contentRect: contentBounds)
        guard !titleField.stringValue.isEmpty,
              contentBounds.width > Layout.overlayInset * 2,
              contentBounds.height > Layout.overlayInset * 2
        else {
            textScrim.isHidden = true
            return
        }

        let showsDate = !dateField.stringValue.isEmpty && visibility.showsDate
        dateField.isHidden = !showsDate
        let desiredHeight = Layout.scrimPaddingY * 2
            + Layout.titleHeight
            + (showsDate ? Layout.lineGap + Layout.dateHeight : 0)
        let availableWidth = max(contentBounds.width - Layout.overlayInset * 2, 0)
        let availableHeight = max(contentBounds.height - Layout.overlayInset * 2, 0)
        let scrimHeight = min(desiredHeight, availableHeight)
        textScrim.isHidden = scrimHeight <= 0 || availableWidth <= 0
        textScrim.frame = NSRect(
            x: Layout.overlayInset,
            y: Layout.overlayInset,
            width: availableWidth,
            height: scrimHeight
        )
        let textWidth = max(availableWidth - Layout.scrimPaddingX * 2, 0)
        titleField.frame = NSRect(
            x: Layout.scrimPaddingX,
            y: Layout.scrimPaddingY - 1,
            width: textWidth,
            height: Layout.titleHeight
        )
        dateField.frame = NSRect(
            x: Layout.scrimPaddingX,
            y: Layout.scrimPaddingY + Layout.titleHeight + Layout.lineGap - 1,
            width: textWidth,
            height: Layout.dateHeight
        )
    }

    private func layoutVideoBadge() {
        let contentBounds = contentView.bounds
        let visibility = MediaAssetTilePresentation.overlayVisibility(contentRect: contentBounds)
        guard shouldShowVideoBadge, visibility.showsVideoBadge else {
            videoBadge.isHidden = true
            return
        }

        let hasDuration = !durationField.isHidden
        let badgeWidth = hasDuration
            ? max(Layout.badgeMinWidth, ceil(durationField.intrinsicContentSize.width) + Layout.scrimPaddingX * 2)
            : Layout.badgeMinWidth
        let badgeHeight = Layout.badgeHeight
        guard contentBounds.width >= badgeWidth + Layout.overlayInset * 2,
              contentBounds.height >= badgeHeight + Layout.overlayInset * 2
        else {
            videoBadge.isHidden = true
            return
        }
        videoBadge.isHidden = false
        videoBadge.frame = NSRect(
            x: contentBounds.width - Layout.overlayInset - badgeWidth,
            y: contentBounds.height - Layout.overlayInset - badgeHeight,
            width: badgeWidth,
            height: badgeHeight
        )
        durationField.frame = NSRect(
            x: Layout.scrimPaddingX,
            y: 3,
            width: max(badgeWidth - Layout.scrimPaddingX * 2, 0),
            height: 14
        )
        filmIconView.frame = NSRect(
            x: (badgeWidth - Layout.filmIconSize) / 2,
            y: (badgeHeight - Layout.filmIconSize) / 2,
            width: Layout.filmIconSize,
            height: Layout.filmIconSize
        )
    }

    private func updatePlaceholderBackground() {
        contentView.layer?.backgroundColor = currentImagePixelSize == nil
            ? NSColor.secondaryLabelColor.withAlphaComponent(0.12).cgColor
            : nil
    }

    private func accessibilityLabel(title: String, date: String) -> String {
        var parts = [title]
        if !date.isEmpty {
            parts.append(date)
        }
        if !durationField.stringValue.isEmpty {
            parts.append(durationField.stringValue)
        }
        return parts.joined(separator: ", ")
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
        return RelativeDateText.string(for: date)
    }

    nonisolated static func captureDateText(
        _ asset: MediaAsset,
        now: Date,
        calendar: Calendar
    ) -> String {
        guard let date = asset.bestCaptureDate else {
            return ""
        }
        return RelativeDateText.string(for: date, now: now, calendar: calendar)
    }

    nonisolated static func videoBadgeText(_ asset: MediaAsset) -> String? {
        guard showsVideoBadge(asset),
              let durationSeconds = asset.durationSeconds,
              durationSeconds.isFinite
        else {
            return nil
        }
        let wholeSeconds = max(0, Int64(durationSeconds.rounded(.down)))
        let duration = Duration.seconds(wholeSeconds)
        if wholeSeconds >= 3600 {
            return duration.formatted(.time(pattern: .hourMinuteSecond))
        }
        return duration.formatted(.time(pattern: .minuteSecond))
    }

    nonisolated static func showsVideoBadge(_ asset: MediaAsset) -> Bool {
        asset.bestKind == .video
    }

    nonisolated static func contentRect(imagePixelSize: CGSize?, bounds: CGRect) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else {
            return bounds
        }
        guard let imagePixelSize,
              imagePixelSize.width > 0,
              imagePixelSize.height > 0
        else {
            return bounds.integral
        }
        let scale = min(bounds.width / imagePixelSize.width, bounds.height / imagePixelSize.height)
        let fittedWidth = min(bounds.width, max(1, (imagePixelSize.width * scale).rounded()))
        let fittedHeight = min(bounds.height, max(1, (imagePixelSize.height * scale).rounded()))
        return CGRect(
            x: bounds.minX + ((bounds.width - fittedWidth) / 2).rounded(),
            y: bounds.minY + ((bounds.height - fittedHeight) / 2).rounded(),
            width: fittedWidth,
            height: fittedHeight
        )
    }

    nonisolated static func overlayVisibility(contentRect: CGRect) -> MediaAssetTileOverlayVisibility {
        MediaAssetTileOverlayVisibility(
            showsDate: contentRect.width >= 44 && contentRect.height >= 34,
            showsVideoBadge: contentRect.width >= 56 && contentRect.height >= 72
        )
    }

    /// Distinguishes the async image load result: the thumbnail file plus the full
    /// `(size, mtime)` enrichment stamp that changes when the file is re-thumbnailed
    /// (size is included because bytes can change while mtime seconds stay equal).
    /// Capture-date and duration text are not part of image identity, so overlay-only
    /// updates do not clear and reload the thumbnail.
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
        return LoadedTile(
            image: image,
            pixelSize: image.map { CGSize(width: CGFloat($0.width), height: CGFloat($0.height)) }
        )
    }
}

nonisolated struct MediaAssetTileOverlayVisibility: Equatable {
    let showsDate: Bool
    let showsVideoBadge: Bool
}
