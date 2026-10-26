import CoreGraphics
import Foundation

/// Loupe zoom policy guide
///
/// Pure geometry for the loupe's zoom (APP-040). Magnification is the scroll view's
/// own unit: `1` means one original pixel per device pixel, because the document view
/// has the decode's shape at the original's resolution, divided by the backing scale. "Fit" is the
/// magnification that letterboxes the whole image in the pane and is the floor; the
/// ceiling is 100 percent, or fit itself when a small image already fills the pane
/// at less than 100 percent. Every keyboard, menu and gesture path computes its target
/// here so the numbers cannot disagree.
nonisolated enum LoupeZoomPolicy {
    static let stepFactor: CGFloat = 1.25
    /// Within one percent of fit counts as fit — a pinch never lands exactly.
    static let fitTolerance: CGFloat = 0.01

    /// The document for `imagePixelSize`, the decode on screen, at the original's
    /// resolution. Its shape is always the decode's: the catalog's size can disagree with
    /// what the decoder shows (a HEIF rotated by its `irot` property records its stored,
    /// unrotated size), and a document of the wrong shape stretches the picture. Only the
    /// scale comes from the original, through its long edge, which no rotation changes.
    static func documentSize(imagePixelSize: CGSize, nativeLongEdge: CGFloat?, backingScale: CGFloat) -> CGSize {
        let scale = backingScale > 0 ? backingScale : 1
        let imageLongEdge = max(imagePixelSize.width, imagePixelSize.height)
        guard imageLongEdge > 0 else {
            return .zero
        }
        let pixelsPerImagePixel = (nativeLongEdge ?? imageLongEdge) / imageLongEdge
        return CGSize(
            width: imagePixelSize.width * pixelsPerImagePixel / scale,
            height: imagePixelSize.height * pixelsPerImagePixel / scale
        )
    }

    static func fitMagnification(documentSize: CGSize, paneSize: CGSize) -> CGFloat {
        guard documentSize.width > 0, documentSize.height > 0, paneSize.width > 0, paneSize.height > 0 else {
            return 1
        }
        return min(paneSize.width / documentSize.width, paneSize.height / documentSize.height)
    }

    static func maximumMagnification(fit: CGFloat) -> CGFloat {
        max(1, fit)
    }

    static func clamp(_ magnification: CGFloat, fit: CGFloat) -> CGFloat {
        min(max(magnification, fit), maximumMagnification(fit: fit))
    }

    static func isFit(_ magnification: CGFloat, fit: CGFloat) -> Bool {
        abs(magnification - fit) <= fit * fitTolerance
    }

    /// Double-click and Z: fit ↔ 100 percent. An image that cannot exceed fit stays put.
    static func toggleTarget(current: CGFloat, fit: CGFloat) -> CGFloat {
        isFit(current, fit: fit) ? maximumMagnification(fit: fit) : fit
    }

    /// ⌘= / ⌘−: one step of `stepFactor`, clamped to the range.
    static func stepped(_ magnification: CGFloat, direction: Int, fit: CGFloat) -> CGFloat {
        let next = direction > 0 ? magnification * stepFactor : magnification / stepFactor
        return clamp(next, fit: fit)
    }

    /// The decoded image is short of what this magnification shows: the pane needs
    /// `native × magnification` pixels along the long edge and has fewer.
    static func needsFullResolution(decodedLongEdge: Int, nativeLongEdge: Int, magnification: CGFloat) -> Bool {
        guard decodedLongEdge < nativeLongEdge else { return false }
        return CGFloat(decodedLongEdge) < CGFloat(nativeLongEdge) * magnification
    }
}

/// What the zoom view last measured: its magnification and the fit for its pane.
nonisolated struct LoupeZoomReport: Equatable, Sendable {
    var magnification: CGFloat
    var fit: CGFloat

    var isFit: Bool {
        LoupeZoomPolicy.isFit(magnification, fit: fit)
    }
}

/// A ViewModel-issued zoom the view applies once, identified by generation.
nonisolated struct LoupeZoomCommand: Equatable, Sendable {
    enum Target: Equatable, Sendable {
        case fit
        case magnification(CGFloat)
    }

    let target: Target
    /// Point in the scroll view's coordinates to keep under the cursor; nil centers.
    let anchor: CGPoint?
    let generation: UInt64
}
