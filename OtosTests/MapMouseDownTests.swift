import AppKit
@testable import OtosKit
import Testing

/// The map's mouse-down monitor at its AppKit boundary (`MapMouseDown`): which events it
/// hands to `mapMouseDown(clickCount:)`, with what count, built from synthesized `NSEvent`s.
/// The monitor itself is only the hop from `NSEvent.addLocalMonitorForEvents` to this
/// decision; no `NSApp` or window is needed.
struct MapMouseDownTests {
    private static let window = 7
    /// The map's frame in its window's coordinates.
    private static let frame = NSRect(x: 100, y: 50, width: 400, height: 300)

    private static func mouse(_ type: NSEvent.EventType, at point: NSPoint, clickCount: Int, window: Int = window) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window,
            context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1
        ))
    }

    // Validates: APP-058
    /// A single and a double click inside the map reach it with AppKit's count.
    @Test func aPressInsideTheMapCarriesItsClickCount() throws {
        let inside = NSPoint(x: 300, y: 200)
        let single = try #require(MapMouseDown(Self.mouse(.leftMouseDown, at: inside, clickCount: 1)))
        let double = try #require(MapMouseDown(Self.mouse(.leftMouseDown, at: inside, clickCount: 2)))
        #expect(single.clickCount(inWindow: Self.window, frame: Self.frame) == 1)
        #expect(double.clickCount(inWindow: Self.window, frame: Self.frame) == 2)
    }

    // Validates: APP-058
    /// A press outside the map's frame, or in another window, is not the map's: the event
    /// goes on to whatever is under it.
    @Test func aPressElsewhereIsNotTheMaps() throws {
        for clickCount in [1, 2] {
            let outside = try #require(MapMouseDown(Self.mouse(.leftMouseDown, at: NSPoint(x: 20, y: 200), clickCount: clickCount)))
            #expect(outside.clickCount(inWindow: Self.window, frame: Self.frame) == nil)
            let otherWindow = try #require(MapMouseDown(Self.mouse(
                .leftMouseDown, at: NSPoint(x: 300, y: 200), clickCount: clickCount, window: Self.window + 1
            )))
            #expect(otherWindow.clickCount(inWindow: Self.window, frame: Self.frame) == nil)
        }
    }

    // Validates: APP-058
    /// An event that is not a left mouse-down is no press here, and its click count, which
    /// raises on a non-mouse event, is never read.
    @Test func anyOtherEventIsNoPress() throws {
        let key = try #require(NSEvent.keyEvent(
            with: .keyDown, location: NSPoint(x: 300, y: 200), modifierFlags: [], timestamp: 0,
            windowNumber: Self.window, context: nil, characters: "a", charactersIgnoringModifiers: "a",
            isARepeat: false, keyCode: 0
        ))
        #expect(MapMouseDown(key) == nil)
        #expect(try MapMouseDown(Self.mouse(.leftMouseUp, at: NSPoint(x: 300, y: 200), clickCount: 2)) == nil)
    }
}
