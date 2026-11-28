import AppKit
@testable import OtosKit
import Testing

extension AppKitWindowTests {
    /// APP-048 / `hig-validation.md` F-13: the crop canvas's key view takes the keyboard from
    /// whatever held it, turns arrows into nudges (ten pixels with Shift) saved on release,
    /// Escape into the loupe's Escape, and gives the keyboard back when it leaves.
    @MainActor
    struct CropKeyViewTests {
        // Validates: APP-048
        @Test func theCropKeyViewTakesTheKeyboardAndGivesItBack() {
            let window = orderedInTestWindow(width: 200, height: 100, contentView: NSView())
            defer { window.close() }
            let field = NSTextField()
            window.contentView?.addSubview(field)
            window.makeFirstResponder(field)
            let keys = CropKeyView()

            window.contentView?.addSubview(keys)
            #expect(window.firstResponder === keys)

            keys.removeFromSuperview()
            // The field holds the keyboard again, through the window's field editor.
            #expect((window.firstResponder as? NSTextView)?.delegate === field)
        }

        // Validates: APP-048
        @Test func arrowsNudgeAndTheirReleaseSaves() {
            let window = orderedInTestWindow(width: 200, height: 100, contentView: NSView())
            defer { window.close() }
            let keys = CropKeyView()
            window.contentView?.addSubview(keys)
            var nudges: [String] = []
            var released = 0
            var escaped = 0
            keys.nudge = { direction, pixels in nudges.append("\(Int(direction.dx)),\(Int(direction.dy))x\(Int(pixels))") }
            keys.release = { released += 1 }
            keys.escape = { escaped += 1 }

            keys.keyDown(with: keyEvent(.keyDown, keyCode: 123, window: window))
            keys.keyDown(with: keyEvent(.keyDown, keyCode: 126, modifiers: [.shift], window: window))
            keys.keyUp(with: keyEvent(.keyUp, keyCode: 126, window: window))
            keys.keyDown(with: keyEvent(.keyDown, keyCode: 53, window: window))

            #expect(nudges == ["-1,0x1", "0,-1x10"])
            #expect(released == 1)
            #expect(escaped == 1)
        }
    }
}

@MainActor
private func keyEvent(
    _ type: NSEvent.EventType,
    keyCode: UInt16,
    modifiers: NSEvent.ModifierFlags = [],
    window: NSWindow
) -> NSEvent {
    NSEvent.keyEvent(
        with: type,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        characters: "",
        charactersIgnoringModifiers: "",
        isARepeat: false,
        keyCode: keyCode
    )!
}
