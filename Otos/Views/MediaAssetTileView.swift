import AppKit
import Foundation
import OSLog
import QuartzCore

private final class FlippedView: NSView {
    override var isFlipped: Bool {
        true
    }
}

/// A flipped view that draws and never takes a click: clicks reach the tile beneath.
private final class PassThroughFlippedView: NSView {
    override var isFlipped: Bool {
        true
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }
}

/// Layer-backed host for the tile's thumbnail. Its layer contents belong to Otos: the
/// view draws nothing of its own, and `updateLayer` re-asserts `image`, so an AppKit
/// redisplay — every view in the window redisplays on a light/dark switch — can never
/// replace the painted thumbnail. An `NSImageView` cannot host it: AppKit owns that
/// control's layer and repaints it from the control's own `image` on redisplay.
private final class ThumbnailLayerView: NSView {
    var image: CGImage? {
        didSet {
            if image !== oldValue {
                layer?.contents = image
            }
        }
    }

    override var wantsUpdateLayer: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateLayer() {
        layer?.contents = image
    }
}

private final class MediaChoiceButton: NSButton {
    let toggle: MediaChoiceToggle
    /// Last symbol assigned; skip the NSImage lookup when the state is unchanged,
    /// because render runs on every reconfigure pass during scrolling.
    private var appliedSymbol: String?
    private var isOn = false

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
        self.isOn = isOn
        applyDiscColor()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyDiscColor()
    }

    /// A layer takes a `CGColor`, which is resolved once and does not follow appearance,
    /// so the disc is re-resolved under this view's appearance whenever it changes.
    private func applyDiscColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = isOn ? NSColor.controlAccentColor.cgColor : nil
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// Media tile view guide
//
// Pure renderer for controller-owned `TileContent`. The tile paints `content.image` into
// its own `ThumbnailLayerView` when present and otherwise shows the placeholder face; it
// holds no asset-identity paint state and never clears a painted image while an asset
// stays bound — the no-blank
// invariant is structural in `TileContentStore`, not defended here. A nil image means
// the store has never painted this id (or budget-dropped an unpinned off-screen entry);
// for a visible pinned id the store guarantees a non-nil image after first paint.
// `prepareForReuse` only clears the layer for AppKit recycling; the next `render`
// repaints from the store. Lower-right kind badges (video duration / film icon / RAW)
// are derived from detail plus paint state on every render — no badge state survives reuse.
// Layer colors (selection ring, placeholder fill) are `CGColor`s and are re-resolved on
// every effective-appearance change.

final class MediaAssetTileView: NSView, NSCollectionViewElement {
    private typealias Layout = MediaAssetTileLayout

    private let contentView = FlippedView()
    private let thumbnailView = ThumbnailLayerView()
    private let kindBadge = FlippedView()
    /// Lower-left mirror of the kind badge: the edited mark (DES-099).
    private let editBadge = FlippedView()
    private let editIconView = NSImageView()
    private let badgeLabel = NSTextField(labelWithString: "")
    private let filmIconView = NSImageView()
    private let placeholderIconView = NSImageView()
    private let choiceControl = NSVisualEffectView()
    /// Outlined faces (ADR 0047) in DES-061's accent border, on the thumbnail and under the
    /// badges. A flipped view hosts the layer so a box is measured from the top-left corner,
    /// as the loupe's is; it never takes a click.
    private let faceOutlineView = PassThroughFlippedView()
    private let faceOutlineLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.fillColor = nil
        layer.lineWidth = MediaAssetTilePresentation.selectionBorderWidth
        layer.isHidden = true
        return layer
    }()

    /// The outlined faces' boxes, as fractions of the upright photo; `MediaGridBridge` owns them.
    private var faceOutlineBoxes: [CGRect] = []
    private var choiceButtons: [MediaChoiceButton] = []
    var onMediaChoice: ((MediaChoice) -> Void)?
    /// How this tile shows the stack it is in (ADR 0052); `MediaGridBridge` owns it and
    /// re-asserts it on every render, as it does hover and face outlines.
    private(set) var stackPresentation: TileStackPresentation = .none

    /// Aspect-fit face size for the currently painted image; nil while placeholder.
    var paintedImagePixelSize: CGSize? {
        thumbnailView.image.map { CGSize(width: CGFloat($0.width), height: CGFloat($0.height)) }
    }

    /// The image the thumbnail layer is showing — the render input itself, so a
    /// redisplay that replaced it is observable, not just what the tile was told to paint.
    var displayedThumbnail: CGImage? {
        guard let contents = thumbnailView.layer?.contents,
              CFGetTypeID(contents as CFTypeRef) == CGImage.typeID
        else {
            return nil
        }
        return unsafeDowncast(contents as AnyObject, to: CGImage.self)
    }

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

        contentView.addSubview(thumbnailView)
        faceOutlineView.wantsLayer = true
        faceOutlineView.layer?.addSublayer(faceOutlineLayer)
        contentView.addSubview(faceOutlineView)

        kindBadge.wantsLayer = true
        kindBadge.layer?.backgroundColor = DesignPalette.badgeNSColor.cgColor
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

        editBadge.wantsLayer = true
        editBadge.layer?.backgroundColor = DesignPalette.badgeNSColor.cgColor
        editBadge.layer?.cornerRadius = Layout.badgeCornerRadius
        editBadge.layer?.maskedCorners = [.layerMaxXMaxYCorner]
        editBadge.layer?.masksToBounds = true
        editBadge.isHidden = true
        editIconView.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)
        editIconView.imageScaling = .scaleProportionallyDown
        editIconView.contentTintColor = .white
        editIconView.setAccessibilityElement(false)
        editBadge.addSubview(editIconView)
        contentView.addSubview(editBadge)

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

        applyAppearanceColors()

        // Accessibility: the tile is the unit VoiceOver navigates. A bare NSView
        // subclass is not an element by default — setting only a label leaves
        // VoiceOver nothing to land on.
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        thumbnailView.setAccessibilityElement(false)
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
            thumbnailView.image = nil
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
            formattedDuration: renderedFormattedDuration,
            stack: stackPresentation
        )
        badgeContent = content
        if appliedBadgeContent != content {
            applyBadgeContent(content)
            appliedBadgeContent = content
        }
        setAccessibilityLabel(
            MediaAssetTilePresentation.accessibilityLabel(detail: detail, badgeContent: content, stack: stackPresentation)
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
        case let .stackLabel(label):
            badgeLabel.stringValue = label
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
        if effectiveFade, let layer = thumbnailView.layer {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = MediaGridAnimation.thumbnailFadeDuration
            layer.add(transition, forKey: "thumbnailFade")
        }
        thumbnailView.image = image
        updatePlaceholderPresentation()
    }

    private func clearLayerForReuse() {
        thumbnailView.image = nil
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
        // Hover and face outlines are re-asserted by `MediaGridBridge` on every render, so
        // clearing them here cannot outlive this pass.
        choiceControl.isHidden = true
        faceOutlineBoxes = []
        faceOutlineLayer.isHidden = true
        stackPresentation = .none
        applyStackBand()
        for button in choiceButtons {
            button.setOn(false)
        }
        updatePlaceholderPresentation()
        setSelected(false, animated: false)
        setAccessibilityLabel(nil)
        setAccessibilityValue(nil)
    }

    func setStackPresentation(_ presentation: TileStackPresentation) {
        guard stackPresentation != presentation else { return }
        stackPresentation = presentation
        applyStackBand()
        configureBadge()
        needsLayout = true
    }

    /// An expanded stack's members sit on one band (DES-116): the tile's whole cell, gutter
    /// included, tinted, so neighbouring members read as one run; the key member's cell is
    /// outlined in secondary label, apart from the selection's accent ring on the picture.
    private func applyStackBand() {
        wantsLayer = true
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if stackPresentation.onBand {
                layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.14).cgColor
                layer?.borderColor = NSColor.secondaryLabelColor.cgColor
                layer?.borderWidth = stackPresentation.isKey ? 1 : 0
            } else {
                layer?.backgroundColor = nil
                layer?.borderWidth = 0
            }
        }
    }

    /// Whether a click at `pointInWindow` lands on the stack badge, the stack's expand and
    /// collapse control.
    func hitTestsStackBadge(at pointInWindow: CGPoint) -> Bool {
        guard stackPresentation.badgeLabel != nil, !kindBadge.isHidden else { return false }
        return kindBadge.bounds.contains(kindBadge.convert(pointInWindow, from: nil))
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

    /// The layout's frame, as given: a tile is the square the grid's arithmetic gives it
    /// (`MediaGridLayout`), never sized by its content. AppKit's default answer fits the
    /// view's constraints in a temporary Auto Layout engine for every tile it realizes,
    /// which was most of a batch's and a reload's per-tile main-thread cost
    /// (`docs/research/2026-11-15-grid-removal-without-a-reload.md`).
    func preferredLayoutAttributesFitting(
        _ layoutAttributes: NSCollectionViewLayoutAttributes
    ) -> NSCollectionViewLayoutAttributes {
        layoutAttributes
    }

    override func layout() {
        super.layout()
        contentView.frame = MediaAssetTilePresentation.contentRect(
            imagePixelSize: paintedImagePixelSize,
            bounds: bounds
        )
        thumbnailView.frame = contentView.bounds
        layoutFaceOutlines()
        updatePlaceholderPresentation()
        layoutKindBadge()
        layoutEditBadge()
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

    func setFaceOutlines(_ boxes: [CGRect]) {
        guard faceOutlineBoxes != boxes else {
            return
        }
        faceOutlineBoxes = boxes
        layoutFaceOutlines()
    }

    /// The boxes carried through the photo's saved edit onto the painted thumbnail; none
    /// while a placeholder shows, since there is no picture to place them on.
    private func layoutFaceOutlines() {
        let outlines = paintedImagePixelSize == nil ? [] : faceOutlineBoxes.compactMap {
            FaceOutline.onEditedPhoto($0, recipe: renderedDetail?.editRecipe, upright: renderedDetail?.nativePixelSize)
        }
        guard !outlines.isEmpty else {
            faceOutlineLayer.isHidden = true
            return
        }
        faceOutlineView.frame = contentView.bounds
        faceOutlineLayer.frame = faceOutlineView.bounds
        faceOutlineLayer.strokeColor = NSColor.controlAccentColor.cgColor
        faceOutlineLayer.path = FaceOutline.path(outlines, in: faceOutlineView.bounds)
        faceOutlineLayer.isHidden = false
    }

    func setSelected(_ selected: Bool, animated: Bool) {
        guard let layer = contentView.layer else {
            return
        }
        let newWidth: CGFloat = selected ? MediaAssetTilePresentation.selectionBorderWidth : 0
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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearanceColors()
        applyStackBand()
    }

    /// A layer takes a `CGColor`, which is resolved once and does not follow appearance,
    /// so the ring and placeholder fill are re-resolved under this view's appearance.
    private func applyAppearanceColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            contentView.layer?.borderColor = NSColor.controlAccentColor.cgColor
            contentView.layer?.backgroundColor = paintedImagePixelSize == nil
                ? NSColor.secondaryLabelColor.withAlphaComponent(0.12).cgColor
                : nil
        }
    }

    /// The edited mark sits in the lower-left corner, the kind badge's mirror, on a painted
    /// face large enough to carry badges at all; a placeholder carries none.
    private func layoutEditBadge() {
        let contentBounds = contentView.bounds
        guard let detail = renderedDetail,
              paintedImagePixelSize != nil,
              MediaAssetTilePresentation.isEdited(detail),
              MediaAssetTilePresentation.showsKindBadge(contentRect: contentBounds)
        else {
            editBadge.isHidden = true
            return
        }
        let side = Layout.badgeHeight
        editBadge.isHidden = false
        editBadge.frame = NSRect(x: 0, y: contentBounds.height - side, width: Layout.badgeMinWidth, height: side)
        editIconView.frame = NSRect(
            x: (Layout.badgeMinWidth - Layout.filmIconSize) / 2,
            y: (side - Layout.filmIconSize) / 2,
            width: Layout.filmIconSize,
            height: Layout.filmIconSize
        )
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
        case .durationText, .rawLabel, .stackLabel:
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
        applyAppearanceColors()
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
