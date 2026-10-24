import AppKit
import Testing

/// The one parent of every suite whose tests put a view in a real window: each such
/// suite is declared in an `extension AppKitWindowTests`.
///
/// AppKit's window list, key window and window teardown are process-wide, so two
/// window-hosting tests that interleave at a suspension race each other whichever suite
/// they belong to; a full run once deadlocked that way after 786 tests, parked in
/// `XCTWaiter`, and `objc_release` crashes during teardown are on record. `.serialized`
/// serializes only the tests *within* the suite it is applied to, and recursively the
/// suites nested in it — so it is applied here, once, and every window-hosting test runs
/// one at a time relative to every other. Tests that never order a window in stay
/// parallel.
@Suite(.serialized)
@MainActor
enum AppKitWindowTests {}

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
/// Every caller is a test in a suite nested in `AppKitWindowTests`.
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
