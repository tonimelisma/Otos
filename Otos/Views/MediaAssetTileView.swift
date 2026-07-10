import AppKit
import Foundation
import OSLog
import QuartzCore

private final class FlippedView: NSView {
    override var isFlipped: Bool {
        true
    }
}

// Media tile view guide
//
// Pure renderer for controller-owned `TileContent`. The tile paints `content.image` when
// present and otherwise shows the placeholder face; it holds no asset-identity paint
// state and never clears a painted image while an asset stays bound — the no-blank
// invariant is structural in `TileContentStore`, not defended here. A nil image means
// the store has never painted this id (or budget-dropped an unpinned off-screen entry);
// for a visible pinned id the store guarantees a non-nil image after first paint.
// `prepareForReuse` only clears the layer for AppKit recycling; the next `render`
// repaints from the store. Lower-right kind badges (video duration / film icon / RAW)
// are derived from detail plus paint state on every render — no badge state survives reuse.

final class MediaAssetTileView: NSView {
    private typealias Layout = MediaAssetTileLayout

    private let contentView = FlippedView()
    private let imageView = NSImageView()
    private let kindBadge = FlippedView()
    private let badgeLabel = NSTextField(labelWithString: "")
    private let filmIconView = NSImageView()
    private let placeholderIconView = NSImageView()

    /// Aspect-fit face size for the currently painted image; nil while placeholder.
    private(set) var paintedImagePixelSize: CGSize?
    private var renderedBestKind: MediaKind?
    private var renderedDetail: MediaTileDetail?
    private var badgeContent: TileBadgeContent = .none
    /// Last SF Symbol name assigned to `placeholderIconView`; skip re-assign when unchanged.
    private var appliedPlaceholderIconName: String?

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

        kindBadge.wantsLayer = true
        kindBadge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        kindBadge.layer?.cornerRadius = Layout.badgeCornerRadius
        kindBadge.layer?.maskedCorners = [.layerMinXMaxYCorner]
        kindBadge.layer?.masksToBounds = true
        contentView.addSubview(kindBadge)

        badgeLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        badgeLabel.textColor = .white
        badgeLabel.alignment = .center
        badgeLabel.usesSingleLineMode = true
        badgeLabel.lineBreakMode = .byClipping
        kindBadge.addSubview(badgeLabel)

        filmIconView.image = MediaAssetTilePresentation.placeholderIcon(for: .video)
        filmIconView.imageScaling = .scaleProportionallyDown
        filmIconView.contentTintColor = .white
        kindBadge.addSubview(filmIconView)

        placeholderIconView.imageScaling = .scaleProportionallyDown
        placeholderIconView.contentTintColor = .secondaryLabelColor
        placeholderIconView.alphaValue = Layout.placeholderIconAlpha
        contentView.addSubview(placeholderIconView)

        contentView.layer?.borderColor = NSColor.controlAccentColor.cgColor
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

extension MediaAssetTileView {
    /// Idempotent render from store content. Fade only when the store reports a first
    /// async paint or a same-asset image replacement. Decision-free: nil image →
    /// placeholder; non-nil image → paint. The store owns the no-blank invariant.
    func render(_ content: TileContent?, change: TileContentChange) {
        guard let content else {
            clearLayerForReuse()
            return
        }
        renderedBestKind = content.detail.bestKind
        renderedDetail = content.detail

        if let image = content.image {
            applyImage(image, fade: change == .firstImage || change == .replacedImage)
        } else {
            imageView.layer?.contents = nil
            paintedImagePixelSize = nil
            updatePlaceholderPresentation()
        }
        configureBadge()
        needsLayout = true
    }

    private func configureBadge() {
        guard let detail = renderedDetail else {
            badgeContent = .none
            applyBadgeContent(.none)
            return
        }
        let content = MediaAssetTilePresentation.badgeContent(
            detail: detail,
            thumbnailPainted: paintedImagePixelSize != nil
        )
        badgeContent = content
        applyBadgeContent(content)
        setAccessibilityLabel(MediaAssetTilePresentation.accessibilityLabel(for: content))
    }

    private func applyBadgeContent(_ content: TileBadgeContent) {
        switch content {
        case let .durationText(text):
            badgeLabel.stringValue = text
            badgeLabel.isHidden = false
            filmIconView.isHidden = true
        case .rawLabel:
            badgeLabel.stringValue = Layout.rawLabel
            badgeLabel.isHidden = false
            filmIconView.isHidden = true
        case .filmIcon:
            badgeLabel.stringValue = ""
            badgeLabel.isHidden = true
            filmIconView.isHidden = false
        case .none:
            badgeLabel.stringValue = ""
            badgeLabel.isHidden = true
            filmIconView.isHidden = true
            kindBadge.isHidden = true
        }
    }

    private func applyImage(_ image: CGImage, fade: Bool) {
        if fade, let layer = imageView.layer {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = MediaGridAnimation.thumbnailFadeDuration
            layer.add(transition, forKey: "thumbnailFade")
        }
        imageView.layer?.contents = image
        paintedImagePixelSize = CGSize(width: CGFloat(image.width), height: CGFloat(image.height))
        updatePlaceholderPresentation()
    }

    private func clearLayerForReuse() {
        imageView.layer?.contents = nil
        paintedImagePixelSize = nil
        renderedBestKind = nil
        renderedDetail = nil
        badgeContent = .none
        appliedPlaceholderIconName = nil
        badgeLabel.stringValue = ""
        badgeLabel.isHidden = true
        filmIconView.isHidden = true
        kindBadge.isHidden = true
        updatePlaceholderPresentation()
        setSelected(false, animated: false)
        setAccessibilityLabel(nil)
    }

    func hitTestsThumbnailFace(at pointInWindow: CGPoint) -> Bool {
        let pointInTile = convert(pointInWindow, from: nil)
        let face = MediaAssetTilePresentation.thumbnailFaceRect(
            imagePixelSize: paintedImagePixelSize,
            bounds: bounds
        )
        return face.contains(pointInTile)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        clearLayerForReuse()
    }

    override func layout() {
        super.layout()
        contentView.frame = MediaAssetTilePresentation.contentRect(
            imagePixelSize: paintedImagePixelSize,
            bounds: bounds
        )
        imageView.frame = contentView.bounds
        updatePlaceholderPresentation()
        layoutKindBadge()
    }

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

    private func layoutKindBadge() {
        let contentBounds = contentView.bounds
        guard badgeContent != .none,
              MediaAssetTilePresentation.showsKindBadge(contentRect: contentBounds)
        else {
            kindBadge.isHidden = true
            return
        }

        let textWidth: CGFloat? = switch badgeContent {
        case .durationText, .rawLabel:
            badgeLabel.intrinsicContentSize.width
        case .filmIcon, .none:
            nil
        }
        let badgeWidth = Layout.kindBadgeWidth(textWidth: textWidth)
        let badgeHeight = Layout.badgeHeight
        guard let badgeFrame = Layout.kindBadgeFrame(
            contentBounds: contentBounds,
            badgeWidth: badgeWidth,
            badgeHeight: badgeHeight
        ) else {
            kindBadge.isHidden = true
            return
        }
        kindBadge.isHidden = false
        kindBadge.frame = badgeFrame
        if let textWidth {
            badgeLabel.frame = Layout.kindBadgeLabelFrame(
                badgeWidth: badgeWidth,
                textWidth: textWidth
            )
        }
        filmIconView.frame = NSRect(
            x: (badgeWidth - Layout.filmIconSize) / 2,
            y: (badgeHeight - Layout.filmIconSize) / 2,
            width: Layout.filmIconSize,
            height: Layout.filmIconSize
        )
    }

    private func updatePlaceholderPresentation() {
        let isPlaceholder = paintedImagePixelSize == nil
        contentView.layer?.backgroundColor = isPlaceholder
            ? NSColor.secondaryLabelColor.withAlphaComponent(0.12).cgColor
            : nil
        placeholderIconView.isHidden = !isPlaceholder
        guard isPlaceholder else {
            return
        }
        let iconName = MediaAssetTilePresentation.placeholderIconSystemName(for: renderedBestKind)
        if appliedPlaceholderIconName != iconName {
            placeholderIconView.image = MediaAssetTilePresentation.placeholderIcon(for: renderedBestKind)
            appliedPlaceholderIconName = iconName
        }
        placeholderIconView.frame = Layout.placeholderIconFrame(contentBounds: contentView.bounds)
    }
}
