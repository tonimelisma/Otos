import SwiftUI

/// The crop tool's canvas (ADR 0036, `docs/design/edit-panel.md`): the whole frame of the
/// photo, fitted to the pane, with the crop drawn over it — the area outside dimmed, a
/// rule-of-thirds grid inside, and eight handles. Passive: it holds only the drag in
/// progress, and reports every move and the release to the view model, which owns the
/// crop. The math is `EditCrop.moved(by:)` and `resized(_:by:fractionRatio:)`.
struct CropEditorView: View {
    let image: CGImage
    let crop: EditCrop
    /// Width over height in fractions of the frame while the aspect is constrained.
    let fractionRatio: Double?
    let setCrop: @MainActor (EditCrop, Bool) -> Void

    @State private var dragStart: EditCrop?

    private static let inset: CGFloat = 20
    private static let handleLength: CGFloat = 16
    private static let handleHitSize: CGFloat = 28

    var body: some View {
        GeometryReader { proxy in
            let frame = fittedFrame(in: proxy.size)
            let cropRect = rect(of: crop, in: frame)
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                outside(of: cropRect, in: frame)
                grid(in: cropRect)
                interior(cropRect, frame: frame)
                ForEach(CropHandle.allCases, id: \.self) { handle in
                    handleView(handle, cropRect: cropRect, frame: frame)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
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

    private func resized(_ start: EditCrop, _ handle: CropHandle, _ translation: CGSize, _ frame: CGRect) -> EditCrop {
        start.resized(handle, by: fraction(translation, of: frame), fractionRatio: fractionRatio)
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
