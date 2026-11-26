@testable import OtosKit
import Testing

/// DES-093: text holds the keyboard in whichever window it is focused; photos only in the
/// catalog window; nothing acts on photos from a sheet or another window.
struct KeyboardFocusTests {
    @Test func textWinsAnywhereAndPhotosOnlyInTheCatalogWindow() {
        #expect(KeyboardFocus.of(keyWindowIsCatalog: true, firstResponderIsText: false) == .photos)
        #expect(KeyboardFocus.of(keyWindowIsCatalog: true, firstResponderIsText: true) == .text)
        #expect(KeyboardFocus.of(keyWindowIsCatalog: false, firstResponderIsText: true) == .text)
        #expect(KeyboardFocus.of(keyWindowIsCatalog: false, firstResponderIsText: false) == .elsewhere)
        #expect(KeyboardFocus.of(keyWindowIsCatalog: nil, firstResponderIsText: false) == .elsewhere)
    }
}
