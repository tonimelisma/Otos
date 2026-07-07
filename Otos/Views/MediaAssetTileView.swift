import AppKit
import Foundation
import OSLog
import QuartzCore

private final class FlippedView: NSView {
    override var isFlipped: Bool {
        true
    }
}

private struct TilePaintRequest {
    let decision: TilePaintDecision
    let detail: MediaTileDetail
    let contentKey: String
    let cachedImage: CGImage?
    let thumbnailDirectory: URL?
    let imageCache: MediaTileImageCache?
}

final class MediaAssetTileView: NSView {
    private typealias Layout = MediaAssetTileLayout

    private let contentView = FlippedView()
    private let imageView = NSImageView()
    private let videoBadge = FlippedView()
    private let durationField = NSTextField(labelWithString: "")
    private let filmIconView = NSImageView()

    /// Identifies the image content the async load produced (thumbnail file plus its
    /// enrichment stamp). Equal keys mean the painted thumbnail can stay in place even
    /// when video badge text changes.
    private var currentImageContentKey: String?
    private var currentAssetID: MediaAssetID?
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

        videoBadge.wantsLayer = true
        videoBadge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        videoBadge.layer?.cornerRadius = Layout.badgeCornerRadius
        videoBadge.layer?.maskedCorners = [.layerMinXMaxYCorner]
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
}

extension MediaAssetTileView {
    @discardableResult
    func configure(
        detail: MediaTileDetail,
        thumbnailDirectory: URL?,
        imageCache: MediaTileImageCache?
    ) -> Bool {
        configureBadge(for: detail)
        needsLayout = true

        let key = MediaAssetTilePresentation.imageContentKey(detail)
        let cachedImage = detail.thumbnailPath.flatMap { _ in imageCache?.image(for: key) }
        let decision = MediaAssetTilePresentation.paintDecision(TilePaintContext(
            incomingKey: key,
            incomingThumbnailPath: detail.thumbnailPath,
            currentKey: currentImageContentKey,
            currentAssetID: currentAssetID,
            incomingAssetID: detail.id,
            cacheHasImage: cachedImage != nil,
            hasPaintedImage: currentImagePixelSize != nil
        ))
        return applyPaintDecision(TilePaintRequest(
            decision: decision,
            detail: detail,
            contentKey: key,
            cachedImage: cachedImage,
            thumbnailDirectory: thumbnailDirectory,
            imageCache: imageCache
        ))
    }

    private func configureBadge(for detail: MediaTileDetail) {
        shouldShowVideoBadge = MediaAssetTilePresentation.showsVideoBadge(detail)
        let badgeText = MediaAssetTilePresentation.videoBadgeText(detail)
        if let badgeText {
            durationField.stringValue = badgeText
            durationField.isHidden = false
            filmIconView.isHidden = true
        } else {
            durationField.stringValue = ""
            durationField.isHidden = true
            filmIconView.isHidden = !shouldShowVideoBadge
        }
        setAccessibilityLabel(accessibilityLabel(videoBadge: badgeText))
    }

    private func applyPaintDecision(_ request: TilePaintRequest) -> Bool {
        switch request.decision {
        case .paintCached:
            return paintCachedImage(
                request.cachedImage,
                detail: request.detail,
                contentKey: request.contentKey,
                thumbnailDirectory: request.thumbnailDirectory,
                imageCache: request.imageCache
            )
        case .keepCurrent:
            OtosSignpost.ui.emitEvent("MediaTileContentUnchanged")
            currentAssetID = request.detail.id
            return false
        case let .loadAsync(retainsCurrentImage):
            return startAsyncLoad(
                detail: request.detail,
                contentKey: request.contentKey,
                thumbnailDirectory: request.thumbnailDirectory,
                imageCache: request.imageCache,
                retainsCurrentImage: retainsCurrentImage
            )
        case .placeholder:
            cancelImageLoad()
            clearPaintedImage(for: request.detail.id, reason: "placeholder", enforcesInvariant: true)
            currentAssetID = request.detail.id
            currentImageContentKey = request.contentKey
            return false
        }
    }

    private func paintCachedImage(
        _ cachedImage: CGImage?,
        detail: MediaTileDetail,
        contentKey key: String,
        thumbnailDirectory: URL?,
        imageCache: MediaTileImageCache?
    ) -> Bool {
        guard let cachedImage else {
            OtosLog.ui.error("Media tile paint decision had cache hit without image")
            let retainsCurrentImage = currentAssetID == detail.id
            currentAssetID = detail.id
            currentImageContentKey = key
            loadThumbnailImage(
                detail: detail,
                thumbnailDirectory: thumbnailDirectory,
                imageCache: imageCache,
                retainsCurrentImage: retainsCurrentImage
            )
            return true
        }
        cancelImageLoad()
        currentAssetID = detail.id
        currentImageContentKey = key
        applyImage(cachedImage, assetID: detail.id, contentKey: key, reason: "cacheHit")
        return false
    }

    private func startAsyncLoad(
        detail: MediaTileDetail,
        contentKey key: String,
        thumbnailDirectory: URL?,
        imageCache: MediaTileImageCache?,
        retainsCurrentImage: Bool
    ) -> Bool {
        if !retainsCurrentImage {
            clearPaintedImage(for: detail.id, reason: "newIdentityLoad", enforcesInvariant: true)
        }
        currentAssetID = detail.id
        currentImageContentKey = key
        loadThumbnailImage(
            detail: detail,
            thumbnailDirectory: thumbnailDirectory,
            imageCache: imageCache,
            retainsCurrentImage: retainsCurrentImage
        )
        return true
    }

    /// Reads the thumbnail file off the main actor, then applies the result on the main
    /// actor only if this tile still represents the same image content.
    private func loadThumbnailImage(
        detail: MediaTileDetail,
        thumbnailDirectory: URL?,
        imageCache: MediaTileImageCache?,
        retainsCurrentImage: Bool
    ) {
        loadGeneration += 1
        let generation = loadGeneration
        loadTask?.cancel()
        let key = MediaAssetTilePresentation.imageContentKey(detail)
        GridTelemetry.recordTileLoadStarted()
        OtosSignpost.ui.emitEvent("MediaTileLoadStarted")
        loadTask = Task.detached(priority: .userInitiated) { [weak self, imageCache] in
            let loaded = MediaAssetTilePresentation.loadImage(detail: detail, thumbnailDirectory: thumbnailDirectory)
            if Task.isCancelled {
                return
            }
            if let image = loaded.image {
                imageCache?.insert(image, for: key)
            }
            await MainActor.run {
                guard let self else {
                    return
                }
                guard self.loadGeneration == generation,
                      self.currentAssetID == detail.id,
                      self.currentImageContentKey == key
                else {
                    GridTelemetry.recordTileLoadDropped()
                    OtosSignpost.ui.emitEvent("MediaTileLoadDropped")
                    return
                }
                guard let image = loaded.image else {
                    GridTelemetry.recordTileLoadNil()
                    OtosSignpost.ui.emitEvent("MediaTileLoadNil")
                    OtosLog.ui.debug(
                        """
                        Media tile thumbnail load returned nil assetID=\
                        \(detail.libraryRootPath.rawValue, privacy: .public)/\
                        \(detail.relativePath.rawValue, privacy: .public) \
                        retainedCurrent=\(retainsCurrentImage, privacy: .public)
                        """
                    )
                    return
                }
                self.applyImage(
                    image,
                    assetID: detail.id,
                    contentKey: key,
                    reason: "asyncLoad"
                )
                GridTelemetry.recordTileLoadApplied()
                OtosSignpost.ui.emitEvent("MediaTileLoadApplied")
            }
        }
    }

    private func cancelImageLoad() {
        loadTask?.cancel()
        loadTask = nil
        loadGeneration += 1
    }

    private func applyImage(
        _ image: CGImage,
        assetID: MediaAssetID,
        contentKey: String,
        reason _: String
    ) {
        imageView.layer?.contents = image
        currentAssetID = assetID
        currentImageContentKey = contentKey
        currentImagePixelSize = CGSize(width: CGFloat(image.width), height: CGFloat(image.height))
        updatePlaceholderBackground()
        needsLayout = true
    }

    private func clearPaintedImage(
        for incomingAssetID: MediaAssetID?,
        reason: String,
        enforcesInvariant: Bool
    ) {
        if let incomingAssetID, enforcesInvariant, currentAssetID == incomingAssetID, currentImagePixelSize != nil {
            GridTelemetry.recordWatchdog()
            OtosSignpost.ui.emitEvent("MediaTilePaintInvariantViolation")
            OtosLog.ui.error(
                "Media tile attempted to clear painted same-asset thumbnail reason=\(reason, privacy: .public)"
            )
            return
        }
        imageView.layer?.contents = nil
        currentImagePixelSize = nil
        updatePlaceholderBackground()
        needsLayout = true
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        OtosSignpost.ui.emitEvent("MediaTilePrepareForReuse")
        loadTask?.cancel()
        loadTask = nil
        loadGeneration += 1
        currentImageContentKey = nil
        currentAssetID = nil
        currentImagePixelSize = nil
        shouldShowVideoBadge = false
        clearPaintedImage(for: nil, reason: "reuse", enforcesInvariant: false)
        durationField.stringValue = ""
        durationField.isHidden = true
        filmIconView.isHidden = true
        videoBadge.isHidden = true
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
        layoutVideoBadge()
    }

    /// Draws or clears the selection ring. The ring lives on `contentView` so it
    /// hugs the thumbnail's actual aspect-fit face, not the transparent square cell.
    func setSelected(_ selected: Bool) {
        contentView.layer?.borderWidth = selected ? 3 : 0
        contentView.layer?.borderColor = selected ? NSColor.controlAccentColor.cgColor : nil
    }

    private func layoutVideoBadge() {
        let contentBounds = contentView.bounds
        guard shouldShowVideoBadge,
              MediaAssetTilePresentation.showsVideoBadge(contentRect: contentBounds)
        else {
            videoBadge.isHidden = true
            return
        }

        let hasDuration = !durationField.isHidden
        let badgeWidth = hasDuration
            ? Layout.videoBadgeWidth(durationTextWidth: durationField.intrinsicContentSize.width)
            : Layout.badgeMinWidth
        let badgeHeight = Layout.badgeHeight
        guard let badgeFrame = Layout.videoBadgeFrame(
            contentBounds: contentBounds,
            badgeWidth: badgeWidth,
            badgeHeight: badgeHeight
        ) else {
            videoBadge.isHidden = true
            return
        }
        videoBadge.isHidden = false
        videoBadge.frame = badgeFrame
        durationField.frame = Layout.videoBadgeDurationFrame(badgeWidth: badgeWidth)
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

    private func accessibilityLabel(videoBadge: String?) -> String? {
        if let videoBadge, !videoBadge.isEmpty {
            return "Video, \(videoBadge)"
        }
        return shouldShowVideoBadge ? "Video" : nil
    }
}
