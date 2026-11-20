import AppKit
import SwiftUI

/// The crop tool's canvas (ADR 0036, `docs/design/edit-panel.md`): the whole frame of the
/// photo, fitted to the pane, with the crop drawn over it — the area outside dimmed, a
/// rule-of-thirds grid inside, and eight handles. Passive: it holds only the drag in
/// progress, and reports every move and the release to the view model, which owns the
/// crop. The math is `EditCrop.moved(by:)` and `resized(_:by:fractionRatio:)`.
///
/// Keyboard (Keyboards; `hig-validation.md` F-13): while the canvas is shown, an AppKit key
/// view (`CropKeyCatcher`) holds first responder, taken from the filmstrip the way the
/// filmstrip takes it, and handed back when the tool ends. SwiftUI focus cannot take first
/// responder from an AppKit view. The arrow keys move the crop one pixel of the frame, ten
/// with Shift, and a key held down is saved as one step when it is released. Escape is the
/// loupe's Escape. Shift during a handle drag keeps the crop's shape as it was when the
/// drag began.
///
/// The straighten line (Lightroom Classic's Angle tool): while the panel's ruler is armed,
/// or while ⌘ is held, a drag anywhere on the canvas draws a line instead of moving the
/// crop, and letting go reports it; the view model turns the photo so it is level.
struct CropEditorView: View {
    let image: DisplayImage
    let crop: EditCrop
    /// Width over height in fractions of the frame while the aspect is constrained.
    let fractionRatio: Double?
    let setCrop: @MainActor (EditCrop, Bool) -> Void
    let isDrawingLine: Bool
    let straighten: @MainActor (CGPoint, CGPoint) -> Void
    let escape: @MainActor () -> Void

    @State private var dragStart: EditCrop?
    @State private var shiftHeld = false
    @State private var commandHeld = false
    /// The line being drawn, from its start to the pointer.
    @State private var line: (start: CGPoint, end: CGPoint)?

    private static let inset: CGFloat = 20
    private static let handleLength: CGFloat = 16
    private static let handleHitSize: CGFloat = 28

    var body: some View {
        GeometryReader { proxy in
            let frame = fittedFrame(in: proxy.size)
            let cropRect = rect(of: crop, in: frame)
            ZStack(alignment: .topLeading) {
                Image(decorative: image.cgImage, scale: 1)
                    .resizable()
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                outside(of: cropRect, in: frame)
                grid(in: cropRect)
                interior(cropRect, frame: frame)
                ForEach(CropHandle.allCases, id: \.self) { handle in
                    handleView(handle, cropRect: cropRect, frame: frame)
                }
                if isDrawingLine || commandHeld || line != nil {
                    lineCanvas(size: proxy.size)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .background(CropKeyCatcher(nudge: nudge, release: { setCrop(crop, false) }, escape: escape))
        .onModifierKeysChanged(mask: [.shift, .command]) { _, keys in
            shiftHeld = keys.contains(.shift)
            commandHeld = keys.contains(.command)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Crop")
        .accessibilityValue(
            "\(Int((crop.width * 100).rounded())) by \(Int((crop.height * 100).rounded())) percent of the photo"
        )
    }

    /// The photo's frame fitted inside the pane, inset so the handles have room.
    private func fittedFrame(in size: CGSize) -> CGRect {
        let available = CGSize(width: max(size.width - 2 * Self.inset, 1), height: max(size.height - 2 * Self.inset, 1))
        let scale = min(available.width / CGFloat(image.width), available.height / CGFloat(image.height))
        let fitted = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return CGRect(
            x: (size.width - fitted.width) / 2,
            y: (size.height - fitted.height) / 2,
            width: fitted.width,
            height: fitted.height
        )
    }

    private func rect(of crop: EditCrop, in frame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX + crop.left * frame.width,
            y: frame.minY + crop.top * frame.height,
            width: crop.width * frame.width,
            height: crop.height * frame.height
        )
    }

    private func outside(of cropRect: CGRect, in frame: CGRect) -> some View {
        Path { path in
            path.addRect(frame)
            path.addRect(cropRect)
        }
        .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
    }

    private func grid(in cropRect: CGRect) -> some View {
        Path { path in
            for third in [1.0 / 3, 2.0 / 3] {
                let lineX = cropRect.minX + cropRect.width * third
                let lineY = cropRect.minY + cropRect.height * third
                path.move(to: CGPoint(x: lineX, y: cropRect.minY))
                path.addLine(to: CGPoint(x: lineX, y: cropRect.maxY))
                path.move(to: CGPoint(x: cropRect.minX, y: lineY))
                path.addLine(to: CGPoint(x: cropRect.maxX, y: lineY))
            }
        }
        .stroke(Color.white.opacity(0.45), lineWidth: 0.5)
        .overlay {
            Path { $0.addRect(cropRect) }
                .stroke(Color.white, lineWidth: 1)
        }
        .allowsHitTesting(false)
    }

    /// The straighten line's layer: over the whole canvas, so the line can be drawn along a
    /// horizon anywhere in the photo, even outside the crop. It is drawn white over a dark
    /// outline, like the handles, so it reads on any photo.
    private func lineCanvas(size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .frame(width: size.width, height: size.height)
                .pointerStyle(.rectSelection)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            line = (value.startLocation, value.location)
                        }
                        .onEnded { value in
                            line = nil
                            straighten(value.startLocation, value.location)
                        }
                )
            if let line {
                Path { path in
                    path.move(to: line.start)
                    path.addLine(to: line.end)
                }
                .stroke(Color.black.opacity(0.5), lineWidth: 3)
                .overlay {
                    Path { path in
                        path.move(to: line.start)
                        path.addLine(to: line.end)
                    }
                    .stroke(Color.white, lineWidth: 1)
                }
                .allowsHitTesting(false)
            }
        }
    }

    /// Dragging inside the crop moves it.
    private func interior(_ cropRect: CGRect, frame: CGRect) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(width: cropRect.width, height: cropRect.height)
            .offset(x: cropRect.minX, y: cropRect.minY)
            .pointerStyle(.grabIdle)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = dragStart ?? crop
                        dragStart = start
                        setCrop(start.moved(by: fraction(value.translation, of: frame)), true)
                    }
                    .onEnded { value in
                        let start = dragStart ?? crop
                        dragStart = nil
                        setCrop(start.moved(by: fraction(value.translation, of: frame)), false)
                    }
            )
    }

    private func handleView(_ handle: CropHandle, cropRect: CGRect, frame: CGRect) -> some View {
        let center = CGPoint(
            x: cropRect.midX + CGFloat(handle.horizontal) * cropRect.width / 2,
            y: cropRect.midY + CGFloat(handle.vertical) * cropRect.height / 2
        )
        return CropHandleMark(handle: handle, length: Self.handleLength)
            .frame(width: Self.handleHitSize, height: Self.handleHitSize)
            .contentShape(Rectangle())
            .offset(x: center.x - Self.handleHitSize / 2, y: center.y - Self.handleHitSize / 2)
            .pointerStyle(.frameResize(position: handle.framePosition))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let start = dragStart ?? crop
                        dragStart = start
                        setCrop(resized(start, handle, value.translation, frame), true)
                    }
                    .onEnded { value in
                        let start = dragStart ?? crop
                        dragStart = nil
                        setCrop(resized(start, handle, value.translation, frame), false)
                    }
            )
    }

    /// A handle drag: the aspect's shape when one is set, otherwise the crop's own shape
    /// at the start of the drag while Shift is held, otherwise free.
    private func resized(_ start: EditCrop, _ handle: CropHandle, _ translation: CGSize, _ frame: CGRect) -> EditCrop {
        let ratio = fractionRatio ?? (shiftHeld && start.height > 0 ? start.width / start.height : nil)
        return start.resized(handle, by: fraction(translation, of: frame), fractionRatio: ratio)
    }

    /// An arrow key moves the crop by `pixels` of the frame in `direction` while it is down
    /// or repeating; its release saves it.
    private func nudge(_ direction: CGVector, _ pixels: CGFloat) {
        let delta = CGSize(
            width: direction.dx * pixels / CGFloat(max(image.width, 1)),
            height: direction.dy * pixels / CGFloat(max(image.height, 1))
        )
        setCrop(crop.moved(by: delta), true)
    }

    private func fraction(_ translation: CGSize, of frame: CGRect) -> CGSize {
        CGSize(width: translation.width / max(frame.width, 1), height: translation.height / max(frame.height, 1))
    }
}

/// A handle's mark: an L at a corner, a bar at an edge, white over a dark outline so it
/// reads on any photo.
private struct CropHandleMark: View {
    let handle: CropHandle
    let length: CGFloat

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            var path = Path()
            let horizontal = CGFloat(handle.horizontal), vertical = CGFloat(handle.vertical)
            if handle.horizontal != 0, handle.vertical != 0 {
                path.move(to: CGPoint(x: center.x - horizontal * length, y: center.y))
                path.addLine(to: center)
                path.addLine(to: CGPoint(x: center.x, y: center.y - vertical * length))
            } else if handle.horizontal != 0 {
                path.move(to: CGPoint(x: center.x, y: center.y - length / 2))
                path.addLine(to: CGPoint(x: center.x, y: center.y + length / 2))
            } else {
                path.move(to: CGPoint(x: center.x - length / 2, y: center.y))
                path.addLine(to: CGPoint(x: center.x + length / 2, y: center.y))
            }
            context.stroke(path, with: .color(.black.opacity(0.5)), lineWidth: 5)
            context.stroke(path, with: .color(.white), lineWidth: 3)
        }
        .allowsHitTesting(false)
    }
}

private extension CropHandle {
    var framePosition: FrameResizePosition {
        switch self {
        case .topLeft: .topLeading
        case .top: .top
        case .topRight: .topTrailing
        case .right: .trailing
        case .bottomRight: .bottomTrailing
        case .bottom: .bottom
        case .bottomLeft: .bottomLeading
        case .left: .leading
        }
    }
}

/// The crop canvas's keyboard: an AppKit view that takes first responder when it joins the
/// window and gives it back to whatever held it when it leaves. Arrow keys nudge (Shift for
/// ten pixels), their release saves, and Escape is the loupe's. A bare menu key
/// (`BareMenuKey`) goes to the menu bar, so C (Done Cropping) and the other single-key
/// commands still work; anything else goes up the responder chain, where Return reaches the
/// Done button.
struct CropKeyCatcher: NSViewRepresentable {
    let nudge: @MainActor (CGVector, CGFloat) -> Void
    let release: @MainActor () -> Void
    let escape: @MainActor () -> Void

    func makeNSView(context _: Context) -> CropKeyView {
        let view = CropKeyView()
        update(view)
        return view
    }

    func updateNSView(_ view: CropKeyView, context _: Context) {
        update(view)
    }

    private func update(_ view: CropKeyView) {
        view.nudge = nudge
        view.release = release
        view.escape = escape
    }
}

final class CropKeyView: NSView {
    var nudge: @MainActor (CGVector, CGFloat) -> Void = { _, _ in }
    var release: @MainActor () -> Void = {}
    var escape: @MainActor () -> Void = {}
    private weak var previousResponder: NSResponder?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        // A text field's first responder is the window's shared field editor, which leaves
        // the view tree with the focus; the field it edits is what gets the keyboard back.
        if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor {
            previousResponder = editor.delegate as? NSResponder
        } else {
            previousResponder = window.firstResponder
        }
        window.makeFirstResponder(self)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, let window, window.firstResponder === self {
            // Hand the keyboard back, so the filmstrip's arrows work again after cropping.
            if let previous = previousResponder as? NSView, previous.window === window {
                window.makeFirstResponder(previous)
            } else {
                window.makeFirstResponder(nil)
            }
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let pixels: CGFloat = modifiers.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 123: nudge(CGVector(dx: -1, dy: 0), pixels)
        case 124: nudge(CGVector(dx: 1, dy: 0), pixels)
        case 125: nudge(CGVector(dx: 0, dy: 1), pixels)
        case 126: nudge(CGVector(dx: 0, dy: -1), pixels)
        case 53: escape()
        default:
            if BareMenuKey.performMenuCommand(event) {
                return
            }
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if (123 ... 126).contains(event.keyCode) {
            release()
        } else {
            super.keyUp(with: event)
        }
    }
}
