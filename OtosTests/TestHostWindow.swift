import AppKit

/// An off-screen borderless window, ordered in with `contentView`, for tests that need
/// AppKit layout in a real window. The one way a test puts a view in a window.
///
/// Two settings are not cosmetic:
///
/// - `animationBehavior = .none`. Ordering a window in or out otherwise starts an
///   `_NSWindowTransformAnimation`, which runs on a dispatch worker thread and, in the
///   xctest host, never finishes: each order-in and each `close()` pins one thread for
///   the rest of the run. Enough pinned threads starve the process's worker pool, and
///   an unrelated actor's queued job then never runs: a hang, not a slow test.
/// - `isReleasedWhenClosed = false`. Swift owns the window through a strong reference,
///   so AppKit must not also release it on close; the default makes `close()` an
///   over-release, and `objc_release` crashes during suite runs are on record.
///
/// AppKit's window list retains an ordered-in window, so the caller closes it when done.
@MainActor
func orderedInTestWindow(width: CGFloat, height: CGFloat, contentView: NSView) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: -4000, y: -4000, width: width, height: height),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.animationBehavior = .none
    window.isReleasedWhenClosed = false
    window.contentView = contentView
    window.makeKeyAndOrderFront(nil)
    return window
}
