import AppKit
import SwiftUI

/// Loupe zoom view guide
///
/// The zoomable loupe image is an `NSScrollView` with `allowsMagnification`, so pinch
/// and spread about the cursor, two-finger pan when zoomed, and smart magnify come
/// from the platform rather than from gesture math (APP-040). The document view is
/// sized to the image's native pixel size over the backing scale, which makes
/// magnification `1` exactly one image pixel per device pixel; whichever decode is
/// currently held — the fit-size preview or the full-resolution one — is stretched
/// into that frame, so a sharper decode arriving later changes nothing but sharpness.
///
/// Ownership: the ViewModel owns zoom *intent* (`LoupeZoomCommand`) and receives what
/// the view *measured* (`LoupeZoomReport`); this view owns the live magnification
/// AppKit is animating. Reports are sent when a live magnify ends, when a command or
/// a refit lands, and on a bounds change only if the magnification moved by more than
/// the fit tolerance — panning never reports. Commands are applied once per
/// generation. A new asset refits; a pane resize refits only if the view was at fit.
struct LoupeZoomView: NSViewRepresentable {
    let assetID: MediaAssetID
    let image: CGImage
    let nativePixelSize: CGSize?
    let command: LoupeZoomCommand?
    var onReport: (LoupeZoomReport) -> Void = { _ in }
    var onDoubleClick: (CGPoint) -> Void = { _ in }
    /// While true a single click picks a neutral point: `onPick` receives it as a
    /// fraction of the image from its top-left corner, and the cursor is a crosshair.
    var isPicking = false
    var onPick: (CGPoint) -> Void = { _ in }

    func makeNSView(context _: Context) -> LoupeZoomScrollView {
        LoupeZoomScrollView(frame: .zero)
    }

    func updateNSView(_ view: LoupeZoomScrollView, context _: Context) {
        view.onReport = onReport
        view.onDoubleClick = onDoubleClick
        view.setPicking(isPicking, onPick: onPick)
        view.setContent(image: image, nativePixelSize: nativePixelSize, assetID: assetID)
        view.apply(command)
    }
}

final class LoupeZoomScrollView: NSScrollView {
    var onReport: (LoupeZoomReport) -> Void = { _ in }
    var onDoubleClick: (CGPoint) -> Void = { _ in }

    private let document = LoupeZoomDocumentView(frame: .zero)
    private var currentAssetID: MediaAssetID?
    private var appliedGeneration: UInt64 = 0
    private var lastReported: LoupeZoomReport?
    private var needsRefit = true
    private var observers: [NSObjectProtocol] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        allowsMagnification = true
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        usesPredominantAxisScrolling = false
        contentView = LoupeCenteringClipView()
        // After the clip-view swap: `drawsBackground` forwards to the clip view
        // installed at the time, and a fresh NSClipView paints an opaque default.
        // The SwiftUI pane owns the backdrop (DES-022); this view draws none.
        drawsBackground = false
        documentView = document
        contentView.postsBoundsChangedNotifications = true
        document.onDoubleClick = { [weak self] point in
            guard let self else { return }
            onDoubleClick(convert(point, from: document))
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveMagnifyNotification, object: self, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.report(force: true) }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.report(force: false) }
        })
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("LoupeZoomScrollView is never decoded")
    }

    isolated deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    var fitMagnification: CGFloat {
        LoupeZoomPolicy.fitMagnification(documentSize: document.frame.size, paneSize: bounds.size)
    }

    func setPicking(_ picking: Bool, onPick: @escaping (CGPoint) -> Void) {
        document.onPick = onPick
        if document.isPicking != picking {
            document.isPicking = picking
            window?.invalidateCursorRects(for: document)
        }
    }

    func setContent(image: CGImage, nativePixelSize: CGSize?, assetID: MediaAssetID) {
        document.image = image
        let pixels = nativePixelSize ?? CGSize(width: image.width, height: image.height)
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let size = LoupeZoomPolicy.documentSize(nativePixelSize: pixels, backingScale: scale)
        if document.frame.size != size {
            document.frame = NSRect(origin: .zero, size: size)
        }
        if assetID != currentAssetID {
            currentAssetID = assetID
            needsRefit = true
        }
        updateMagnificationBounds()
    }

    override func layout() {
        super.layout()
        updateMagnificationBounds()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let currentAssetID, let image = document.image {
            let native = CGSize(width: document.frame.width * (window?.backingScaleFactor ?? 2),
                                height: document.frame.height * (window?.backingScaleFactor ?? 2))
            setContent(image: image, nativePixelSize: native, assetID: currentAssetID)
        }
    }

    private func updateMagnificationBounds() {
        guard bounds.width > 0, bounds.height > 0, document.frame.width > 0 else { return }
        let wasAtFit = LoupeZoomPolicy.isFit(magnification, fit: minMagnification)
        let fit = fitMagnification
        minMagnification = fit
        maxMagnification = LoupeZoomPolicy.maximumMagnification(fit: fit)
        if needsRefit || wasAtFit {
            needsRefit = false
            magnification = fit
        } else {
            magnification = LoupeZoomPolicy.clamp(magnification, fit: fit)
        }
        report(force: true)
    }

    func apply(_ command: LoupeZoomCommand?) {
        guard let command, command.generation != appliedGeneration else { return }
        appliedGeneration = command.generation
        let fit = fitMagnification
        let target: CGFloat = switch command.target {
        case .fit: fit
        case let .magnification(value): LoupeZoomPolicy.clamp(value, fit: fit)
        }
        let anchor = command.anchor.map { contentView.convert($0, from: self) }
            ?? NSPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        if MediaGridAnimation.prefersReducedMotion {
            setMagnification(target, centeredAt: anchor)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.allowsImplicitAnimation = true
                animator().setMagnification(target, centeredAt: anchor)
            }
        }
        report(force: true)
    }

    private func report(force: Bool) {
        let next = LoupeZoomReport(magnification: magnification, fit: minMagnification)
        if !force, let last = lastReported,
           abs(last.magnification - next.magnification) <= next.fit * LoupeZoomPolicy.fitTolerance,
           last.fit == next.fit
        {
            return
        }
        lastReported = next
        onReport(next)
    }
}

/// Layer-backed image host. Draws whatever decode it holds stretched into its frame,
/// which is the native pixel size in points; a double-click reports its point.
final class LoupeZoomDocumentView: NSView {
    var onDoubleClick: (CGPoint) -> Void = { _ in }
    var isPicking = false
    var onPick: (CGPoint) -> Void = { _ in }
    var image: CGImage? {
        didSet {
            if image !== oldValue {
                layer?.contents = image
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.contentsGravity = .resize
        layer?.magnificationFilter = .linear
        layer?.minificationFilter = .trilinear
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("LoupeZoomDocumentView is never decoded")
    }

    override var isFlipped: Bool {
        true
    }

    override var acceptsFirstResponder: Bool {
        false
    }

    override func mouseDown(with event: NSEvent) {
        if isPicking, event.clickCount == 1, bounds.width > 0, bounds.height > 0 {
            // Flipped, so the point is already measured from the top-left corner.
            let point = convert(event.locationInWindow, from: nil)
            onPick(CGPoint(x: point.x / bounds.width, y: point.y / bounds.height))
            return
        }
        if event.clickCount == 2 {
            onDoubleClick(convert(event.locationInWindow, from: nil))
            return
        }
        super.mouseDown(with: event)
    }

    override func resetCursorRects() {
        if isPicking {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }
}

/// Keeps a document smaller than the clip centered — the letterbox at fit.
final class LoupeCenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }
        let documentFrame = documentView.frame
        if documentFrame.width < rect.width {
            rect.origin.x = (documentFrame.width - rect.width) / 2
        }
        if documentFrame.height < rect.height {
            rect.origin.y = (documentFrame.height - rect.height) / 2
        }
        return rect
    }
}
