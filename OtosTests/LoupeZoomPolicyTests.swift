import CoreGraphics
import Foundation
@testable import OtosKit
import Testing

/// Loupe zoom geometry (APP-040) as pure numbers: fit, ceiling, toggle, step, and when
/// a sharper decode is needed.
struct LoupeZoomPolicyTests {
    @Test func fitAndCeiling() {
        // 6000 × 4000 px on a 2× display is a 3000 × 2000 pt document.
        let document = LoupeZoomPolicy.documentSize(nativePixelSize: CGSize(width: 6000, height: 4000), backingScale: 2)
        #expect(document == CGSize(width: 3000, height: 2000))

        let fit = LoupeZoomPolicy.fitMagnification(documentSize: document, paneSize: CGSize(width: 1500, height: 1500))
        #expect(fit == 0.5)
        #expect(LoupeZoomPolicy.maximumMagnification(fit: fit) == 1)
        #expect(LoupeZoomPolicy.clamp(3, fit: fit) == 1)
        #expect(LoupeZoomPolicy.clamp(0.1, fit: fit) == 0.5)

        // A small image that fills the pane below 100 percent cannot zoom past fit.
        let small = LoupeZoomPolicy.fitMagnification(documentSize: CGSize(width: 400, height: 300), paneSize: CGSize(width: 1200, height: 1200))
        #expect(small == 3)
        #expect(LoupeZoomPolicy.maximumMagnification(fit: small) == 3)
        #expect(LoupeZoomPolicy.toggleTarget(current: small, fit: small) == small)
    }

    @Test func toggleAndStep() {
        let fit: CGFloat = 0.5
        #expect(LoupeZoomPolicy.toggleTarget(current: 0.5, fit: fit) == 1)
        #expect(LoupeZoomPolicy.toggleTarget(current: 0.504, fit: fit) == 1)
        #expect(LoupeZoomPolicy.toggleTarget(current: 0.8, fit: fit) == 0.5)
        #expect(LoupeZoomPolicy.toggleTarget(current: 1, fit: fit) == 0.5)

        #expect(LoupeZoomPolicy.stepped(0.5, direction: 1, fit: fit) == 0.625)
        #expect(LoupeZoomPolicy.stepped(0.9, direction: 1, fit: fit) == 1)
        #expect(LoupeZoomPolicy.stepped(0.5, direction: -1, fit: fit) == 0.5)
        #expect(LoupeZoomPolicy.isFit(0.5, fit: fit))
        #expect(!LoupeZoomPolicy.isFit(0.6, fit: fit))
    }

    @Test func fullResolutionIsNeededOnlyWhenTheDecodeIsShort() {
        // A 4096-px decode of a 6000-px image is enough at fit (0.5 → 3000 px needed).
        #expect(!LoupeZoomPolicy.needsFullResolution(decodedLongEdge: 4096, nativeLongEdge: 6000, magnification: 0.5))
        // At 100 percent it needs all 6000.
        #expect(LoupeZoomPolicy.needsFullResolution(decodedLongEdge: 4096, nativeLongEdge: 6000, magnification: 1))
        // A decode already at native size never needs more.
        #expect(!LoupeZoomPolicy.needsFullResolution(decodedLongEdge: 6000, nativeLongEdge: 6000, magnification: 1))
        // Degenerate geometry answers 1, never divides by zero.
        #expect(LoupeZoomPolicy.fitMagnification(documentSize: .zero, paneSize: CGSize(width: 10, height: 10)) == 1)
    }
}
