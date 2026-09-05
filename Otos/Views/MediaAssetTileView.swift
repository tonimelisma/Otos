import AppKit
import Foundation
import OSLog
import QuartzCore

private final class FlippedView: NSView {
    override var isFlipped: Bool {
        true
    }
}

private final class MediaChoiceButton: NSButton {
    let toggle: MediaChoiceToggle
    /// Last symbol assigned; skip the NSImage lookup when the state is unchanged,
    /// because render runs on every reconfigure pass during scrolling.
    private var appliedSymbol: String?

    init(toggle: MediaChoiceToggle) {
        self.toggle = toggle
        super.init(frame: .zero)
        imagePosition = .imageOnly
        isBordered = false
        focusRingType = .none
        setAccessibilityElement(false)
        toolTip = toggle.actionLabel
        wantsLayer = true
        // Half of MediaAssetTileLayout.choiceButtonSize: the accent disc is round.
        layer?.cornerRadius = MediaAssetTileLayout.choiceButtonSize / 2
        setOn(false)
    }

    /// Outline at rest, filled on an accent disc when the item carries this act.
    ///
    /// Two independent carriers, because neither may be colour alone (DES-068):
    /// the glyph switches outline -> filled, and the disc appears behind it. The
    /// glyph stays at full contrast rather than taking the accent itself —
    /// tinting the glyph made the selected act read *dimmer* than the unselected
    /// one in grayscale, because accent desaturates to a mid grey below both
    /// white and black.
    func setOn(_ isOn: Bool) {
        let symbol = toggle.symbol(isOn: isOn)
        if symbol != appliedSymbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: toggle.actionLabel)
            appliedSymbol = symbol
        }
        contentTintColor = isOn ? .white : .labelColor
        layer?.backgroundColor = isOn ? NSColor.controlAccentColor.cgColor : nil
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
    private let choiceControl = NSVisualEffectView()
    private var choiceButtons: [MediaChoiceButton] = []
    var onMediaChoice: ((MediaChoice) -> Void)?

    /// Aspect-fit face size for the currently painted image; nil while placeholder.
    private(set) var paintedImagePixelSize: CGSize?
    private var renderedBestKind: MediaKind?
    private var renderedDetail: MediaTileDetail?
    private var renderedFormattedDuration: String?
    private var badgeContent: TileBadgeContent = .none
    /// Last SF Symbol name assigned to `placeholderIconView`; skip re-assign when unchanged.
    private var appliedPlaceholderIconName: String?
    private var appliedBadgeContent: TileBadgeContent = .none

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

        choiceControl.material = .hudWindow
        choiceControl.blendingMode = .withinWindow
        choiceControl.state = .active
        choiceControl.wantsLayer = true
        choiceControl.layer?.cornerRadius = 5
        choiceControl.layer?.masksToBounds = true
        choiceControl.isHidden = true
        // Sibling of `contentView` rather than a child, so the 4pt corner radius
        // and `masksToBounds` cannot clip it — but positioned from `contentRect`
        // in `layout()`, so it still tracks the thumbnail face (DES-066).
        addSubview(choiceControl)
        for toggle in MediaChoiceToggle.allCases {
            let button = MediaChoiceButton(toggle: toggle)
            button.target = self
            button.action = #selector(choiceButtonClicked(_:))
            choiceControl.addSubview(button)
            choiceButtons.append(button)
        }

        contentView.layer?.borderColor = NSColor.controlAccentColor.cgColor

        // Accessibility: the tile is the unit VoiceOver navigates. A bare NSView
        // subclass is not an element by default — setting only a label leaves
        // VoiceOver nothing to land on.
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        imageView.setAccessibilityElement(false)
        badgeLabel.setAccessibilityElement(false)
        filmIconView.setAccessibilityElement(false)
        placeholderIconView.setAccessibilityElement(false)
        setAccessibilityCustomActions(MediaChoice.allCases.map { choice in
            NSAccessibilityCustomAction(
                name: choice.accessibilityActionLabel,
                handler: { [weak self] in
                    guard let self else { return false }
                    onMediaChoice?(choice)
                    return true
                }
            )
        })
    }

    /// Hover visibility is assigned by `MediaGridBridge`, the one owner of "which
    /// tile is under the cursor" — the tile does not track the mouse itself.
    ///
    /// A per-tile `NSTrackingArea` cannot answer this correctly in a scrolling
    /// collection view: AppKit delivers `mouseEntered` to a tile that scrolls
    /// *under* a stationary cursor but no matching `mouseExited` to the one that
    /// scrolls away, so every tile the pointer passed kept its control shown.
    /// Enter/exit are mouse-movement events; scrolling moves the views instead,
    /// and only an owner that recomputes on scroll can stay correct.
    func setChoiceControlVisible(_ visible: Bool) {
        choiceControl.isHidden = !visible
    }

    /// Observable hover state — the assertion point for "at most one tile shows
    /// the control", which is the invariant the per-tile tracking areas broke.
    var isChoiceControlVisible: Bool {
        !choiceControl.isHidden
    }

    @objc private func choiceButtonClicked(_ sender: MediaChoiceButton) {
        // One resolution, shared with the SwiftUI control: pressing the act the
        // item already carries clears it to Not Rated.
        onMediaChoice?(sender.toggle.resolved(from: renderedDetail?.mediaChoice ?? .default))
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
        renderedFormattedDuration = content.formattedDuration

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
            if appliedBadgeContent != .none {
                applyBadgeContent(.none)
                appliedBadgeContent = .none
            }
            setAccessibilityLabel(nil)
            return
        }
        let content = MediaAssetTilePresentation.badgeContent(
            detail: detail,
            thumbnailPainted: paintedImagePixelSize != nil,
            formattedDuration: renderedFormattedDuration
        )
        badgeContent = content
        if appliedBadgeContent != content {
            applyBadgeContent(content)
            appliedBadgeContent = content
        }
        setAccessibilityLabel(
            MediaAssetTilePresentation.accessibilityLabel(detail: detail, badgeContent: content)
        )
        setAccessibilityValue(MediaAssetTilePresentation.accessibilityValue(detail: detail))
        for button in choiceButtons {
            button.setOn(button.toggle.choice == detail.mediaChoice)
        }
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
        let effectiveFade = fade && !MediaGridAnimation.prefersReducedMotion
        if effectiveFade, let layer = imageView.layer {
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
        renderedFormattedDuration = nil
        badgeContent = .none
        appliedPlaceholderIconName = nil
        appliedBadgeContent = .none
        badgeLabel.stringValue = ""
        badgeLabel.isHidden = true
        filmIconView.isHidden = true
        kindBadge.isHidden = true
        // Hover is re-asserted by `MediaGridBridge` on every render, so clearing
        // it here cannot outlive this pass.
        choiceControl.isHidden = true
        for button in choiceButtons {
            button.setOn(false)
        }
        updatePlaceholderPresentation()
        setSelected(false, animated: false)
        setAccessibilityLabel(nil)
        setAccessibilityValue(nil)
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
        let choiceButtonSize = Layout.choiceButtonSize
        let choiceSpacing = Layout.choiceButtonSpacing
        choiceControl.frame = MediaAssetTilePresentation.choiceGroupRect(
            buttonCount: choiceButtons.count,
            contentRect: contentView.frame
        )
        for (index, button) in choiceButtons.enumerated() {
            button.frame = CGRect(
                x: CGFloat(index) * (choiceButtonSize + choiceSpacing),
                y: 0,
                width: choiceButtonSize,
                height: choiceButtonSize
            )
        }
    }

    func setSelected(_ selected: Bool, animated: Bool) {
        guard let layer = contentView.layer else {
            return
        }
        let newWidth: CGFloat = selected ? 3 : 0
        let shouldAnimate = animated && !MediaGridAnimation.prefersReducedMotion
        if shouldAnimate, layer.borderWidth != newWidth {
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
        setAccessibilitySelected(selected)
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
        let unavailable = renderedDetail?.thumbnailUnavailable == true
        let iconName = MediaAssetTilePresentation.placeholderIconSystemName(
            for: renderedBestKind,
            thumbnailUnavailable: unavailable
        )
        if appliedPlaceholderIconName != iconName {
            placeholderIconView.image = MediaAssetTilePresentation.placeholderIcon(
                for: renderedBestKind,
                thumbnailUnavailable: unavailable
            )
            appliedPlaceholderIconName = iconName
        }
        placeholderIconView.frame = Layout.placeholderIconFrame(contentBounds: contentView.bounds)
    }
}
