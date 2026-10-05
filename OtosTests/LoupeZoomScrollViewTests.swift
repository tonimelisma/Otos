import AppKit
@testable import OtosKit
import Testing

/// The loupe pane's backdrop has one owner, the SwiftUI pane (DES-022): the zoom
/// scroll view that hosts the full decode paints no background of its own, so the
/// thumbnail-to-full-decode swap changes only the image, never the surface.
@MainActor
struct LoupeZoomScrollViewTests {
    @Test func zoomViewPaintsNoBackdrop() {
        let view = LoupeZoomScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        #expect(view.drawsBackground == false)
        #expect(view.contentView.drawsBackground == false)
    }
}
