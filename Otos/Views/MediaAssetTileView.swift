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
    let asset: MediaAsset
    let contentKey: String
    let cachedImage: CGImage?
    let thumbnailDirectory: URL?
    let imageCache: MediaTileImageCache?
}

final class MediaAssetTileView: NSView {
    private typealias Layout = MediaAssetTileLayout

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

        textScrim.wantsLayer = true
        textScrim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        textScrim.layer?.cornerRadius = Layout.scrimCornerRadius
        textScrim.layer?.maskedCorners = [.layerMaxXMinYCorner]
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
        videoBadge.layer?.maskedCorners = [.layerMinXMaxYCorner]
        videoBadge.layer?.masksToBounds = true
        contentView.addSubview(videoBadge)

        durationField.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        durationField.textColor = .white
        durationField.alignment = .right
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
        asset: MediaAsset,
        thumbnailDirectory: URL?,
        imageCache: MediaTileImageCache?
    ) -> Bool {
        configureOverlayText(for: asset)
        needsLayout = true

        let key = MediaAssetTilePresentation.imageContentKey(asset)
        let cachedImage = asset.thumbnailPath.flatMap { _ in imageCache?.image(for: key) }
        let decision = MediaAssetTilePresentation.paintDecision(TilePaintContext(
            incomingKey: key,
            incomingThumbnailPath: asset.thumbnailPath,
            currentKey: currentImageContentKey,
            currentAssetID: currentAssetID,
            incomingAssetID: asset.id,
            cacheHasImage: cachedImage != nil,
            hasPaintedImage: currentImagePixelSize != nil
        ))
        return applyPaintDecision(TilePaintRequest(
            decision: decision,
            asset: asset,
            contentKey: key,
            cachedImage: cachedImage,
            thumbnailDirectory: thumbnailDirectory,
            imageCache: imageCache
        ))
    }

    private func configureOverlayText(for asset: MediaAsset) {
        titleField.stringValue = MediaAssetTilePresentation.title(asset)
        dateField.stringValue = MediaAssetTilePresentation.captureDateText(asset)
        shouldShowVideoBadge = MediaAssetTilePresentation.showsVideoBadge(asset)
        let badgeText = MediaAssetTilePresentation.videoBadgeText(asset)
        if let badgeText {
            durationField.stringValue = badgeText
            durationField.isHidden = false
            filmIconView.isHidden = true
        } else {
            durationField.stringValue = ""
            durationField.isHidden = true
            filmIconView.isHidden = !shouldShowVideoBadge
        }
        setAccessibilityLabel(accessibilityLabel(
            title: titleField.stringValue,
            date: dateField.stringValue,
            videoBadge: badgeText ?? (shouldShowVideoBadge ? "Video" : "")
        ))
    }

    private func applyPaintDecision(_ request: TilePaintRequest) -> Bool {
        switch request.decision {
        case .paintCached:
            return paintCachedImage(
                request.cachedImage,
                asset: request.asset,
                contentKey: request.contentKey,
                thumbnailDirectory: request.thumbnailDirectory,
                imageCache: request.imageCache
            )
        case .keepCurrent:
            OtosSignpost.ui.emitEvent("MediaTileContentUnchanged")
            currentAssetID = request.asset.id
            return false
        case let .loadAsync(retainsCurrentImage):
            return startAsyncLoad(
                asset: request.asset,
                contentKey: request.contentKey,
                thumbnailDirectory: request.thumbnailDirectory,
                imageCache: request.imageCache,
                retainsCurrentImage: retainsCurrentImage
            )
        case .placeholder:
            cancelImageLoad()
            clearPaintedImage(for: request.asset.id, reason: "placeholder", enforcesInvariant: true)
            currentAssetID = request.asset.id
            currentImageContentKey = request.contentKey
            return false
        }
    }

    private func paintCachedImage(
        _ cachedImage: CGImage?,
        asset: MediaAsset,
        contentKey key: String,
        thumbnailDirectory: URL?,
        imageCache: MediaTileImageCache?
    ) -> Bool {
        guard let cachedImage else {
            OtosLog.ui.error("Media tile paint decision had cache hit without image")
            let retainsCurrentImage = currentAssetID == asset.id
            currentAssetID = asset.id
            currentImageContentKey = key
            loadThumbnailImage(
                asset: asset,
                thumbnailDirectory: thumbnailDirectory,
                imageCache: imageCache,
                retainsCurrentImage: retainsCurrentImage
            )
            return true
        }
        cancelImageLoad()
        currentAssetID = asset.id
        currentImageContentKey = key
        applyImage(cachedImage, assetID: asset.id, contentKey: key, reason: "cacheHit")
        return false
    }

    private func startAsyncLoad(
        asset: MediaAsset,
        contentKey key: String,
        thumbnailDirectory: URL?,
        imageCache: MediaTileImageCache?,
        retainsCurrentImage: Bool
    ) -> Bool {
        if !retainsCurrentImage {
            clearPaintedImage(for: asset.id, reason: "newIdentityLoad", enforcesInvariant: true)
        }
        currentAssetID = asset.id
        currentImageContentKey = key
        loadThumbnailImage(
            asset: asset,
            thumbnailDirectory: thumbnailDirectory,
            imageCache: imageCache,
            retainsCurrentImage: retainsCurrentImage
        )
        return true
    }

    /// Reads the thumbnail file off the main actor, then applies the result on the main
    /// actor only if this tile still represents the same image content.
    private func loadThumbnailImage(
        asset: MediaAsset,
        thumbnailDirectory: URL?,
        imageCache: MediaTileImageCache?,
        retainsCurrentImage: Bool
    ) {
        loadGeneration += 1
        let generation = loadGeneration
        loadTask?.cancel()
        let key = MediaAssetTilePresentation.imageContentKey(asset)
        OtosSignpost.ui.emitEvent("MediaTileLoadStarted")
        loadTask = Task.detached(priority: .userInitiated) { [weak self, imageCache] in
            let loaded = MediaAssetTilePresentation.loadImage(asset: asset, thumbnailDirectory: thumbnailDirectory)
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
                      self.currentAssetID == asset.id,
                      self.currentImageContentKey == key
                else {
                    OtosSignpost.ui.emitEvent("MediaTileLoadDropped")
                    return
                }
                guard let image = loaded.image else {
                    OtosSignpost.ui.emitEvent("MediaTileLoadNil")
                    OtosLog.ui.debug(
                        """
                        Media tile thumbnail load returned nil assetID=\
                        \(asset.libraryRootPath.rawValue, privacy: .public)/\
                        \(asset.relativePath.rawValue, privacy: .public) \
                        retainedCurrent=\(retainsCurrentImage, privacy: .public)
                        """
                    )
                    return
                }
                self.applyImage(
                    image,
                    assetID: asset.id,
                    contentKey: key,
                    reason: "asyncLoad"
                )
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
            OtosSignpost.ui.emitEvent("MediaTilePaintInvariantViolation")
            OtosLog.ui.error(
                "Media tile attempted to clear painted same-asset thumbnail reason=\(reason, privacy: .public)"
            )
            return
        }
        imageView.image = nil
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
              contentBounds.width > 0,
              contentBounds.height > 0
        else {
            textScrim.isHidden = true
            return
        }

        let showsDate = !dateField.stringValue.isEmpty && visibility.showsDate
        dateField.isHidden = !showsDate
        guard let frames = Layout.textScrimFrames(
            contentBounds: contentBounds,
            titleTextWidth: titleField.intrinsicContentSize.width,
            dateTextWidth: dateField.intrinsicContentSize.width,
            showsDate: showsDate
        ) else {
            textScrim.isHidden = true
            return
        }
        textScrim.isHidden = false
        textScrim.frame = frames.scrim
        titleField.frame = frames.title
        dateField.frame = frames.date ?? .zero
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
            ? max(Layout.badgeMinWidth, ceil(durationField.intrinsicContentSize.width) + Layout.scrimPaddingX)
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
        durationField.frame = NSRect(
            x: Layout.scrimPaddingX,
            y: 3,
            width: max(badgeWidth - Layout.scrimPaddingX, 0),
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

    private func accessibilityLabel(title: String, date: String, videoBadge: String) -> String {
        var parts = [title]
        if !date.isEmpty {
            parts.append(date)
        }
        if !videoBadge.isEmpty {
            parts.append(videoBadge)
        }
        return parts.joined(separator: ", ")
    }
}
