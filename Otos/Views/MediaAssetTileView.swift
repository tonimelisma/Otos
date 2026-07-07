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
    /// Centered on the gray placeholder square while no thumbnail has painted yet
    /// (spec 0047) — distinct from `filmIconView`, which lives inside the video badge.
    private let placeholderIconView = NSImageView()

    /// Identifies the image content the async load produced (thumbnail file plus its
    /// enrichment stamp). Equal keys mean the painted thumbnail can stay in place even
    /// when video badge text changes.
    private var currentImageContentKey: String?
    private var currentAssetID: MediaAssetID?
    private var currentImagePixelSize: CGSize?
    private var currentBestKind: MediaKind?
    /// This item's column in the grid at last configure, used only to stagger the
    /// thumbnail-arrival fade per column (spec 0047); has no effect on paint decisions.
    private var currentColumn = 0
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

        placeholderIconView.imageScaling = .scaleProportionallyDown
        placeholderIconView.contentTintColor = .secondaryLabelColor
        placeholderIconView.alphaValue = Layout.placeholderIconAlpha
        contentView.addSubview(placeholderIconView)

        // A single opaque color; borderWidth alone (0 or 3) toggles ring visibility, so
        // the color never needs to change and the deselect animation never fades a color.
        contentView.layer?.borderColor = NSColor.controlAccentColor.cgColor
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
        imageCache: MediaTileImageCache?,
        column: Int
    ) -> Bool {
        currentColumn = column
        currentBestKind = detail.bestKind
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
        applyImage(cachedImage, assetID: detail.id, contentKey: key, application: .cacheHit)
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
                    application: .asyncLoad
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

    /// `cacheHit` applications (a scroll-back repaint, or a recycled cell's synchronous
    /// repaint) stay instant — fading those would read as flicker and contradict the
    /// no-blank invariant's spirit. `asyncLoad` applications add a fade: this single
    /// mechanism covers first paint (placeholder → image) and a same-asset
    /// newer-thumbnail replacement (old → new crossfade, invariant-safe because the old
    /// contents persist on the layer through the transition). The fade is staggered per
    /// column so a batch of tiles landing together ripples left-to-right instead of
    /// popping in unison.
    private func applyImage(
        _ image: CGImage,
        assetID: MediaAssetID,
        contentKey: String,
        application: TilePaintApplication
    ) {
        if application == .asyncLoad, let layer = imageView.layer {
            let stagger = Double(currentColumn) * MediaGridAnimation.thumbnailStaggerPerColumn
            let transition = CATransition()
            transition.type = .fade
            transition.duration = MediaGridAnimation.thumbnailFadeDuration
            transition.beginTime = CACurrentMediaTime() + stagger
            transition.fillMode = .backwards
            layer.add(transition, forKey: "thumbnailFade")
        }
        imageView.layer?.contents = image
        currentAssetID = assetID
        currentImageContentKey = contentKey
        currentImagePixelSize = CGSize(width: CGFloat(image.width), height: CGFloat(image.height))
        updatePlaceholderPresentation()
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
        updatePlaceholderPresentation()
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
        currentBestKind = nil
        currentColumn = 0
        shouldShowVideoBadge = false
        clearPaintedImage(for: nil, reason: "reuse", enforcesInvariant: false)
        durationField.stringValue = ""
        durationField.isHidden = true
        filmIconView.isHidden = true
        videoBadge.isHidden = true
        updatePlaceholderPresentation()
        setSelected(false, animated: false)
        setAccessibilityLabel(nil)
    }

    override func layout() {
        super.layout()
        contentView.frame = MediaAssetTilePresentation.contentRect(
            imagePixelSize: currentImagePixelSize,
            bounds: bounds
        )
        imageView.frame = contentView.bounds
        updatePlaceholderPresentation()
        layoutVideoBadge()
    }

    /// Draws or clears the selection ring. The ring lives on `contentView` so it
    /// hugs the thumbnail's actual aspect-fit face, not the transparent square cell.
    /// `animated` fades the ring in/out (spec 0047); `prepareForReuse` passes `false` so
    /// a recycled item never shows a stale animation from its previous asset.
    func setSelected(_ selected: Bool, animated: Bool) {
        guard let layer = contentView.layer else {
            return
        }
        let newWidth: CGFloat = selected ? 3 : 0
        if animated, layer.borderWidth != newWidth {
            let animation = CABasicAnimation(keyPath: "borderWidth")
            animation.fromValue = layer.borderWidth
            animation.toValue = newWidth
            animation.duration = selected
                ? MediaGridAnimation.selectionRingInDuration
                : MediaGridAnimation.selectionRingOutDuration
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(animation, forKey: "selectionRing")
        } else {
            layer.removeAnimation(forKey: "selectionRing")
        }
        layer.borderWidth = newWidth
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

    /// Owns the placeholder background and its centered media-kind icon together so the
    /// two can never disagree about whether a thumbnail has painted (spec 0047).
    private func updatePlaceholderPresentation() {
        let isPlaceholder = currentImagePixelSize == nil
        contentView.layer?.backgroundColor = isPlaceholder
            ? NSColor.secondaryLabelColor.withAlphaComponent(0.12).cgColor
            : nil
        placeholderIconView.isHidden = !isPlaceholder
        guard isPlaceholder else {
            return
        }
        placeholderIconView.image = NSImage(
            systemSymbolName: MediaAssetTilePresentation.placeholderIconSystemName(for: currentBestKind),
            accessibilityDescription: nil
        )
        placeholderIconView.frame = Layout.placeholderIconFrame(contentBounds: contentView.bounds)
    }

    private func accessibilityLabel(videoBadge: String?) -> String? {
        if let videoBadge, !videoBadge.isEmpty {
            return "Video, \(videoBadge)"
        }
        return shouldShowVideoBadge ? "Video" : nil
    }
}
